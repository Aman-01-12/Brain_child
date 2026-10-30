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
//  One-way candidate tool share model: the candidate's code editor and
//  whiteboard are LOCAL, single-user surfaces. The view models stay in their
//  LOCAL in-memory mode (the CRDT `configure(document:controller:)` path is no
//  longer wired); the candidate edits locally and may publish the rendered
//  surface as a screen-share via the capture pipeline.
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
//      gesture state are released rather than living until an arbitrary later
//      collection (R3.6).
//

import AppKit
import SwiftUI

@objc(InterSecureToolsBridge)
@MainActor
public final class InterSecureToolsBridge: NSObject {

    // Exactly one shared view model per tool surface (R3.7). Held strongly for
    // the session; the hosting views observe them. Used in LOCAL mode only — the
    // CRDT `configure(document:controller:)` path is never invoked.
    private let codeEditorViewModel = CodeEditorViewModel()
    private let whiteboardViewModel = WhiteboardViewModel()

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
    /// the editor's weak text-view linkage and the whiteboard's transient state
    /// are released (R3.6).
    @objc public func invalidateHandlers() {
        // Detach both view models so the editor's weak text-view linkage and the
        // whiteboard's transient gesture state are released (R3.6).
        codeEditorViewModel.detach()
        whiteboardViewModel.detach()
    }
}
