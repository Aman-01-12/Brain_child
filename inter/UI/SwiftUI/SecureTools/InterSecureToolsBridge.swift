//
//  InterSecureToolsBridge.swift
//  inter
//
//  AppKit↔SwiftUI bridge for the two candidate-facing secure-interview tools
//  (the Tool_Bridge). Follows the established InterSecureChromeBridge pattern:
//  an `@objc` / `@MainActor` `NSObject` subclass that owns its view models for
//  the session and vends `lazy` `NSHostingView` content views to the shipping
//  Objective-C host (`InterSecureToolHostView`).
//
//  Scope B rule (unchanged): SwiftUI never owns a window. The host view stays
//  the captured `NSView`; this bridge only vends *content* `NSView`s (hosting
//  views) to swap into the host's leaf slot. No `NSWindow` is created here
//  (R3.8).
//
//  Ownership / lifetime:
//    - Exactly one CodeEditorViewModel and one WhiteboardViewModel are owned for
//      the whole session (R3.7). The bridge holds them strongly; the hosting
//      views observe them.
//    - `codeEditorHostingView` / `whiteboardHostingView` are `lazy`, so the same
//      NSHostingView instance is returned on every request (R3.1, R3.2). Because
//      the host view is captured once and lives the whole session, this shared-
//      instance guarantee is what keeps the capture pipeline pointed at a stable
//      leaf.
//    - `invalidateHandlers()` detaches both view models at session teardown (M2)
//      so the editor's weak text-view linkage and the whiteboard's transient
//      gesture state / re-publish subscription are released rather than living
//      until an arbitrary later collection (R3.6).
//

import AppKit
import SwiftUI

@objc(InterSecureToolsBridge)
@MainActor
public final class InterSecureToolsBridge: NSObject {

    // Exactly one shared view model per tool surface (R3.7). Held strongly for
    // the session; the hosting views observe them.
    private let codeEditorViewModel = CodeEditorViewModel()
    private let whiteboardViewModel = WhiteboardViewModel()

    // MARK: - Collaborative session state (R8.3, R4.4)

    /// The shared RGA document for the collaborative editor. Created ONCE per
    /// session in `configureCollaboration(roomController:)` and held strongly so
    /// it survives editor↔whiteboard tool switches for the whole call — only
    /// session teardown (`invalidateHandlers()`) clears it (R8.3, R4.4).
    private var codeEditorDocument: CodeEditorDocument?

    /// The DataChannel transport controller driving `codeEditorDocument`. Owned
    /// strongly for the session; `InterRoomController.codeEditorController` holds
    /// only a `weak` back-reference, which teardown clears (R8.1).
    private var codeEditorController: InterCodeEditorController?

    /// Weak reference to the room controller we wired the editor into, kept so
    /// teardown can clear `roomController.codeEditorController` and remove the
    /// DataChannel routing (R8.1).
    private weak var wiredRoomController: InterRoomController?

    /// Secure code-editor content view. Lazy + shared: the SAME NSHostingView
    /// instance is returned on every request (R3.1, R3.2). Layout is driven by
    /// the host via autoresizing, matching the chrome bridge's convention.
    @objc public private(set) lazy var codeEditorHostingView: NSView = {
        let host = NSHostingView(rootView: CodeEditorRootView(viewModel: codeEditorViewModel))
        host.translatesAutoresizingMaskIntoConstraints = true
        return host
    }()

    /// Whiteboard content view. Lazy + shared: the SAME NSHostingView instance
    /// is returned on every request (R3.1, R3.2).
    @objc public private(set) lazy var whiteboardHostingView: NSView = {
        let host = NSHostingView(rootView: WhiteboardRootView(viewModel: whiteboardViewModel))
        host.translatesAutoresizingMaskIntoConstraints = true
        return host
    }()

    @objc public override init() {
        super.init()
    }

    // MARK: - Collaborative wiring (R2.1, R8.3, R4.4)

    /// Stand up the collaborative code editor for the session and wire it to the
    /// LiveKit DataChannel via `roomController` — mirroring how the chat / poll /
    /// Q&A controllers are attached to the room. Construct the shared
    /// `CodeEditorDocument` (keyed on the local attested identity) and its
    /// `InterCodeEditorController`, register the controller on the room so the
    /// topic dispatcher routes `codeEditor` data into it, attach the production
    /// transport, and `configure` the already-vended view model so remote
    /// ops/cursor/language land in the editor surface.
    ///
    /// The document + controller are created ONCE and held for the whole call;
    /// calling this again (e.g. a re-attach after reconnect) re-points the wiring
    /// at the same document so content is never lost across tool switches or
    /// reconnects (R8.3, R4.4). Safe to call only after the room is connected
    /// (the local attested identity must be available).
    @objc public func configureCollaboration(roomController: InterRoomController) {
        // The document `site` MUST be the local attested identity: the peer's
        // controller rejects any insert whose `id.site` != the attested sender
        // (InterCodeEditorController.handleOps). Wiring with a placeholder site
        // would make every local edit silently rejected by the peer. So require
        // a real identity here (this is called after the room connects, mirroring
        // when chat/poll/qa attach); fail SAFE (no-op + log) rather than fail
        // corrupt if it is somehow not yet available — a later call will wire it.
        let identity = roomController.localParticipantIdentity
        guard !identity.isEmpty else {
            interLogError(InterLog.room,
                "InterSecureToolsBridge: skipping collaboration wiring — local participant identity not yet available")
            return
        }

        // Reuse the session document/controller if already created; otherwise
        // build them once and keep them alive for the call.
        let document: CodeEditorDocument
        let controller: InterCodeEditorController
        if let existingDoc = codeEditorDocument, let existingController = codeEditorController {
            document = existingDoc
            controller = existingController
        } else {
            document = CodeEditorDocument(site: identity)
            controller = InterCodeEditorController(document: document, localIdentity: identity)
            codeEditorDocument = document
            codeEditorController = controller
        }

        // Responder-selection seam (R4.1): the interview host answers snapshot
        // requests immediately; a non-host peer falls back after a delay.
        controller.isLocalParticipantHost = { [weak roomController] in
            roomController?.isHost ?? false
        }

        // Register on the room so the DataChannel dispatcher routes `codeEditor`
        // data into this controller (mirrors pollController / qaController), and
        // attach the production transport + flush anything queued offline.
        wiredRoomController = roomController
        roomController.codeEditorController = controller
        controller.attach(to: roomController, identity: identity)

        // Drive the editor surface from the shared document.
        codeEditorViewModel.configure(document: document, controller: controller)

        // Mounting the editor mid-call: request the current authoritative
        // document so a late joiner / reconnector is never stale or empty
        // (R4.1, R4.2).
        controller.beginRecovery()
    }

    /// Make the wrapped NSTextView the window's first responder when the editor
    /// is mounted (R3.3). Returns `NO` — leaving the existing first responder
    /// unchanged — when the editor is not in the hierarchy or cannot become
    /// first responder (R3.4, R6.4).
    @discardableResult
    @objc public func focusCodeEditor() -> Bool {
        codeEditorViewModel.requestFocus()
    }

    /// Empty the whiteboard model + both undo/redo histories so the next capture
    /// is blank (R3.5, R9.5).
    @objc public func clearWhiteboard() {
        whiteboardViewModel.clear()
    }

    /// Drop per-session references at teardown (M2). Mirrors
    /// InterSecureChromeBridge.invalidateHandlers(): detaches both view models so
    /// the editor's weak text-view linkage and the whiteboard's transient state /
    /// re-publish subscription are released (R3.6).
    @objc public func invalidateHandlers() {
        // Stop the collaborative editor transport and unwire it from the room so
        // nothing leaks or dangles (R8.1):
        //   • detach() flushes/stops pending-op + coalesce timers and drops the
        //     room/transport references;
        //   • reset() clears all transient buffers (pending/queued ops, buffered
        //     remote ops, snapshot assemblies, rate-limiter windows, recovery
        //     timers);
        //   • clearing the room's weak back-reference removes the DataChannel
        //     routing so received `codeEditor` data is no longer dispatched here.
        if let controller = codeEditorController {
            controller.detach()
            controller.reset()
        }
        wiredRoomController?.codeEditorController = nil
        wiredRoomController = nil
        codeEditorController = nil

        // Release the session document + buffers only on teardown (NOT on tool
        // switches), per R8.3 / R4.4.
        codeEditorDocument = nil

        // Detach both view models so the editor's weak text-view linkage,
        // remote-cursor overlays, and the whiteboard's transient state /
        // re-publish subscription are released (R3.6, R8.1).
        codeEditorViewModel.detach()
        whiteboardViewModel.detach()
    }
}
