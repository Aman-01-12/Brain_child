//
//  CodeEditorViewModel.swift
//  inter
//
//  View model backing the SwiftUI secure code editor (Code_Editor). It is the
//  bridge between the native editor surface (`CodeEditorTextView`) and the
//  collaborative model/transport layers:
//
//    • When a shared `CodeEditorDocument` + `InterCodeEditorController` are
//      installed via `configure(document:controller:)`, the model becomes the
//      collaborative seam: local NSText edits are diffed into RGA insert/delete
//      ops (applied to the document and published over the DataChannel), and
//      remote ops/cursor/language changes are surfaced back to the surface
//      (R2.1, R2.4, R2.5, R3.1, R3.2).
//    • Until then it behaves exactly as the original one-way surface: `text` is
//      a plain in-memory @Published string with no networking side effect, so
//      the existing `InterSecureToolsBridge` contract and the placeholder
//      visibility in `CodeEditorRootView` are unchanged (R1.1, R8.1).
//
//  The rendered `text` is BACKED by the shared document once collaborative: it
//  always mirrors `document.text`, and applying a remote op refreshes it
//  WITHOUT resetting the local caret (the caret is shifted relative to the
//  surrounding text — R2.5). Strong references to the document + controller are
//  held for the whole session; `detach()` clears them at teardown (R8.1).
//
//  Follows the established @MainActor ObservableObject pattern used by
//  InterSecureChromeBridge's view models.
//

import AppKit
import SwiftUI

@MainActor
final class CodeEditorViewModel: ObservableObject {

    /// The editor's rendered text. WHILE no collaborative document is installed
    /// this is a plain in-memory @Published string (the original one-way
    /// behaviour — R11.4). ONCE `configure(document:controller:)` has run it is
    /// BACKED by the shared `CodeEditorDocument`: a local change (set by the
    /// surface's text-did-change) is diffed into RGA ops, and a remote change
    /// refreshes it from the document (R1.1, R2.1).
    ///
    /// `didSet` performs the local-edit → ops bridge. Refreshes driven by remote
    /// ops set this property while `isApplyingRemoteChange` is `true` so they do
    /// not echo back out as new local ops.
    @Published var text: String = "" {
        didSet {
            guard !isApplyingRemoteChange else { return }
            bridgeLocalTextChange()
        }
    }

    /// The current language selection, synchronised as an LWW register across
    /// both clients (R3.2). The surface observes this to drive re-highlighting
    /// (Task 7); changing it locally is done through `setLanguage(_:)`.
    @Published var language: String = "Plain text"

    /// Remote cursors/selections keyed by the attested sender identity (R2.4).
    /// Each entry anchors to stable element ids; the surface (Task 7) maps these
    /// to offsets and draws a labelled marker.
    @Published private(set) var remoteCursors: [String: RemoteCursor] = [:]

    /// `true` when the most recent local insert was refused for exceeding the
    /// document size cap (R6.3). The surface shows a non-blocking notice.
    @Published private(set) var didHitSizeLimit: Bool = false

    /// `true` when the controller could not heal a divergence and asked for a
    /// resync (R8.4). The surface shows a non-blocking notice; local editing
    /// stays alive.
    @Published private(set) var needsResync: Bool = false

    /// A remote participant's cursor/selection, anchored to stable element ids.
    struct RemoteCursor: Equatable {
        let anchor: ElementID
        let head: ElementID
    }

    // MARK: Session-scoped collaborators (R8.1)

    /// The shared RGA document. Strongly held for the whole session; the bridge
    /// (Task 10) installs it via `configure`. `nil` in the non-collaborative
    /// one-way mode.
    private(set) var document: CodeEditorDocument?

    /// The DataChannel transport controller. Strongly held for the session.
    /// `nil` in the non-collaborative one-way mode.
    private(set) var controller: InterCodeEditorController?

    /// Weak link to the wrapped NSTextView. Weak avoids a retain cycle between
    /// the view model (held strongly by the bridge) and the text view (held by
    /// the hosting view hierarchy).
    private weak var textView: NSTextView?

    // MARK: Language register bookkeeping (R3.1, R3.3)

    /// Lamport clock for the language register; bumped on a local change and
    /// advanced past any higher remote value so concurrent changes converge to
    /// the highest `(lamport, site)` (R3.3).
    private var languageLamport: UInt64 = 0

    /// The site that authored the current language value (the tie-break key for
    /// equal Lamport values).
    private var languageSite: String = ""

    /// Guard suppressing the local-edit bridge WHILE a remote change is being
    /// applied to `text` / the text view (so a remote op never echoes back out
    /// as a fresh local op).
    private var isApplyingRemoteChange = false

    // MARK: - Surface wiring

    /// Called by CodeEditorTextView.makeNSView to register the wrapped text
    /// view so focus activation can reach it. If a collaborative document is
    /// already installed (late attach), the text view is seeded with the
    /// current document text so late-join content is visible immediately.
    func attach(textView: NSTextView) {
        self.textView = textView
        if document != nil, textView.string != text {
            isApplyingRemoteChange = true
            textView.string = text
            isApplyingRemoteChange = false
        }
    }

    /// Makes the wrapped NSTextView the window's first responder so keystrokes
    /// route to the editor (R6.1). Returns `false` — leaving the existing first
    /// responder unchanged — when the text view is not attached, is not in a
    /// window, or cannot become first responder (R6.4).
    func requestFocus() -> Bool {
        guard let tv = textView, let window = tv.window else { return false }
        return window.makeFirstResponder(tv)
    }

    /// Releases the weak text-view linkage AND the session-scoped collaborators
    /// at teardown (R8.1). The controller/document buffers, timers, and
    /// transport handlers are torn down by their owner (the bridge, Task 10);
    /// here the view model simply drops its strong references and clears its
    /// observable state so nothing dangles.
    func detach() {
        if controller?.delegate === self {
            controller?.delegate = nil
        }
        controller = nil
        document = nil
        remoteCursors.removeAll()
        didHitSizeLimit = false
        needsResync = false
        textView = nil
    }

    // MARK: - Collaborative configuration (R8.3, R4.4)

    /// Install the session-scoped shared document + transport controller,
    /// switching the model into collaborative mode (R2.1). The model becomes
    /// the controller's delegate so remote ops/cursor/language land here. The
    /// rendered state is seeded from the document WITHOUT generating local ops
    /// (so installing a non-empty late-join document does not re-publish it).
    func configure(document: CodeEditorDocument, controller: InterCodeEditorController) {
        self.document = document
        self.controller = controller
        controller.delegate = self
        languageSite = document.site

        isApplyingRemoteChange = true
        text = document.text
        if let tv = textView { tv.string = document.text }
        isApplyingRemoteChange = false
    }

    // MARK: - Language selection (R3.1, R3.2)

    /// Change the editor language locally: advance the Lamport register, publish
    /// the change to the peer (R3.1), and update the published `language` so the
    /// surface re-highlights the existing content for the new language without
    /// touching the text (R3.2). In the non-collaborative mode it just updates
    /// the local published value.
    func setLanguage(_ newLanguage: String) {
        guard newLanguage != language else { return }
        guard let controller = controller, let document = document else {
            language = newLanguage
            return
        }
        languageLamport += 1
        languageSite = document.site
        language = newLanguage
        controller.sendLanguage(newLanguage, lamport: languageLamport)
    }

    // MARK: - Local cursor reporting (R2.4)

    /// Report the local caret/selection so the peer can render a remote-cursor
    /// marker (R2.4). The UTF-16 NSRange from the text view is mapped to stable
    /// element ids; if the document is empty (nothing to anchor to) the update
    /// is skipped. Anchoring to ids (not offsets) lets the peer keep the marker
    /// correct as the document changes around it.
    func reportLocalSelection(_ range: NSRange) {
        guard let document = document, let controller = controller else { return }
        guard let anchor = anchorID(forUTF16Offset: range.location, in: document),
              let head = anchorID(forUTF16Offset: range.location + range.length, in: document)
        else { return }
        controller.sendCursor(anchor: anchor, head: head)
    }

    /// Resolve a UTF-16 caret offset to the nearest stable live element id:
    /// prefer the element AT the offset, else the element immediately to its
    /// left (so an end-of-document caret still anchors). Returns `nil` for an
    /// empty document.
    private func anchorID(forUTF16Offset utf16Offset: Int, in document: CodeEditorDocument) -> ElementID? {
        let charOffset = Self.characterOffset(forUTF16Offset: utf16Offset, in: document.text)
        if let id = document.id(at: charOffset) { return id }
        if charOffset > 0, let id = document.id(at: charOffset - 1) { return id }
        return nil
    }

    // MARK: - Notice acknowledgement

    /// Dismiss the size-limit notice (e.g. once characters have been removed).
    func clearSizeLimitNotice() {
        didHitSizeLimit = false
        document?.clearSizeLimitFlag()
    }

    /// Dismiss the resync notice once recovery has surfaced fresh state.
    func clearResyncNotice() {
        needsResync = false
    }

    // MARK: - Local-edit → ops bridge (R2.1)

    /// Diff the newly-set `text` against the document's authoritative text and
    /// translate the change into RGA insert/delete ops, applying them to the
    /// document and publishing them via the controller (R2.1). A no-op WHILE no
    /// collaborative document is installed (one-way mode). If the document
    /// refuses an insert at the size cap, the rendered text is reconciled back
    /// to the document so the two never diverge (R6.3).
    private func bridgeLocalTextChange() {
        guard let document = document else { return }
        let newValue = text
        let diff = Self.characterDiff(old: document.text, new: newValue)
        guard diff.deleted > 0 || !diff.inserted.isEmpty else { return }

        if diff.deleted > 0 {
            applyLocalDelete(range: diff.offset ..< (diff.offset + diff.deleted))
        }
        if !diff.inserted.isEmpty {
            applyLocalInsert(at: diff.offset, diff.inserted)
        }

        // Reconcile if the document diverged from the rendered text (e.g. an
        // insert refused by the size clamp): re-render from the authoritative
        // document so the surface matches the model exactly.
        if document.text != text {
            refreshRenderedText()
        }
    }

    private func applyLocalInsert(at offset: Int, _ string: String) {
        if let controller = controller {
            controller.applyLocalInsert(at: offset, string)
        } else {
            _ = document?.localInsert(at: offset, string)
        }
    }

    private func applyLocalDelete(range: Range<Int>) {
        if let controller = controller {
            controller.applyLocalDelete(range: range)
        } else {
            _ = document?.localDelete(range: range)
        }
    }

    // MARK: - Remote-change application (R2.2, R2.5)

    /// Refresh the rendered text from the authoritative document after remote
    /// ops were integrated, preserving the local caret RELATIVE to the
    /// surrounding text (R2.5). The caret/selection is shifted by the net change
    /// the remote edit produced rather than reset, so the local user's position
    /// is undisturbed. Sets `text` under the remote-change guard so it does not
    /// re-enter the local-edit bridge.
    private func refreshRenderedText() {
        guard let document = document else { return }
        let newText = document.text
        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        if let tv = textView {
            let oldNS = tv.string as NSString
            let newNS = newText as NSString
            let selection = tv.selectedRange()
            let change = Self.utf16Diff(old: oldNS, new: newNS)

            tv.string = newText

            let maxLen = newNS.length
            let loc = Self.shiftOffset(selection.location, change: change)
            let end = Self.shiftOffset(selection.location + selection.length, change: change)
            let clampedLoc = min(max(loc, 0), maxLen)
            let clampedEnd = min(max(end, clampedLoc), maxLen)
            tv.setSelectedRange(NSRange(location: clampedLoc, length: clampedEnd - clampedLoc))
        }

        text = newText
    }

    // MARK: - Diff & offset helpers

    /// Character-grained diff between two strings reduced to a single change
    /// region: the common prefix length, the number of deleted characters, and
    /// the inserted substring. Operates on `Character`s so the offsets line up
    /// with the document's live character offsets.
    static func characterDiff(old: String, new: String) -> (offset: Int, deleted: Int, inserted: String) {
        let o = Array(old)
        let n = Array(new)
        var prefix = 0
        let maxPrefix = min(o.count, n.count)
        while prefix < maxPrefix && o[prefix] == n[prefix] { prefix += 1 }

        var suffix = 0
        let maxSuffix = min(o.count, n.count) - prefix
        while suffix < maxSuffix && o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }

        let deleted = o.count - prefix - suffix
        let inserted = String(n[prefix ..< (n.count - suffix)])
        return (prefix, deleted, inserted)
    }

    /// UTF-16-grained single-region diff used for caret math against the text
    /// view (whose offsets are UTF-16 units).
    static func utf16Diff(old: NSString, new: NSString) -> (offset: Int, deleted: Int, inserted: Int) {
        let oldLen = old.length
        let newLen = new.length
        var prefix = 0
        let maxPrefix = min(oldLen, newLen)
        while prefix < maxPrefix && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }

        var suffix = 0
        let maxSuffix = min(oldLen, newLen) - prefix
        while suffix < maxSuffix
            && old.character(at: oldLen - 1 - suffix) == new.character(at: newLen - 1 - suffix) {
            suffix += 1
        }

        let deleted = oldLen - prefix - suffix
        let inserted = newLen - prefix - suffix
        return (prefix, deleted, inserted)
    }

    /// Shift a caret offset across a single change region so it stays anchored
    /// relative to the surrounding text (R2.5): unchanged before the change,
    /// translated by the net delta after it, clamped to the change point if it
    /// fell inside a deleted span.
    private static func shiftOffset(_ offset: Int, change: (offset: Int, deleted: Int, inserted: Int)) -> Int {
        if offset <= change.offset { return offset }
        if offset >= change.offset + change.deleted { return offset + change.inserted - change.deleted }
        return change.offset + change.inserted
    }

    /// Convert a UTF-16 offset (text-view space) into a `Character` offset
    /// (document space), clamped into the valid range.
    private static func characterOffset(forUTF16Offset utf16Offset: Int, in text: String) -> Int {
        let ns = text as NSString
        let clamped = min(max(utf16Offset, 0), ns.length)
        guard let stringIndex = text.utf16.index(text.utf16.startIndex, offsetBy: clamped,
                                                  limitedBy: text.utf16.endIndex)?
            .samePosition(in: text) else {
            return text.count
        }
        return text.distance(from: text.startIndex, to: stringIndex)
    }
}

// MARK: - InterCodeEditorControllerDelegate (R2.2, R2.4, R3.2, R6.3, R8.4)

extension CodeEditorViewModel: InterCodeEditorControllerDelegate {

    /// Remote ops were integrated into the shared document. Refresh the rendered
    /// text from the authoritative document, preserving the local caret (R2.2,
    /// R2.5).
    func codeEditorController(_ controller: InterCodeEditorController,
                              didIntegrateRemoteOps ops: [Op],
                              from senderIdentity: String) {
        refreshRenderedText()
    }

    /// A remote cursor/selection update arrived; publish it for the surface to
    /// render (R2.4).
    func codeEditorController(_ controller: InterCodeEditorController,
                              didReceiveRemoteCursorAnchor anchor: ElementID,
                              head: ElementID,
                              from senderIdentity: String) {
        remoteCursors[senderIdentity] = RemoteCursor(anchor: anchor, head: head)
    }

    /// A remote language change arrived. Adopt it under LWW semantics — the
    /// highest `(lamport, site)` wins — and advance the local Lamport register so
    /// a subsequent local change supersedes it (R3.2, R3.3).
    func codeEditorController(_ controller: InterCodeEditorController,
                              didReceiveLanguage language: String,
                              lamport: UInt64,
                              from senderIdentity: String) {
        let wins = lamport > languageLamport
            || (lamport == languageLamport && senderIdentity > languageSite)
        if wins {
            languageLamport = lamport
            languageSite = senderIdentity
            self.language = language
        } else {
            // Keep our own register ahead so future local changes dominate.
            languageLamport = max(languageLamport, lamport)
        }
    }

    /// A local insert was refused at the size cap (R6.3); surface the notice.
    func codeEditorControllerDidHitSizeLimit(_ controller: InterCodeEditorController) {
        didHitSizeLimit = true
    }

    /// The controller could not heal a divergence (R8.4); surface a
    /// non-blocking notice while local editing continues.
    func codeEditorControllerDidRequestResync(_ controller: InterCodeEditorController) {
        needsResync = true
    }
}
