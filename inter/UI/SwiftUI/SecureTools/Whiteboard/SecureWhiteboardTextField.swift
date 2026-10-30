//
//  SecureWhiteboardTextField.swift
//  inter
//
//  Excalidraw-style INLINE, AUTO-GROWING text editor for the secure-interview
//  whiteboard's in-window text overlay (R4.1, R4.2) — extended from the original
//  hardened single-line field (finding W1 / H2 / S-A6).
//
//  Behaviour (R4):
//    • Auto-grows to fit content: it does NOT wrap, so a long line grows the
//      editor RIGHTWARD, and pressing Return inserts a newline that grows it
//      DOWNWARD. The measured content size is reported back via `onSizeChange`
//      so the SwiftUI overlay frames the editor exactly to its content.
//    • Commit is via the Escape key (or the overlay's Done button / click-away);
//      Return inserts a newline (multi-line text), matching Excalidraw.
//
//  Hardening preserved verbatim (R4.6 / S-A6):
//    • Wraps the SAME hardened `SecureCodeTextView` the code editor uses, so it
//      inherits the sanitised contextual menu (Cut/Copy/Paste/Select All only)
//      and the `validRequestor` Services opt-out — no Spelling/Substitutions
//      `NSPanel` can open out of the captured surface.
//    • ALL substitution/auto-detection toggles are OFF, so entry is stored
//      LITERALLY (no smart quotes/dashes/replacement). The SwiftUI
//      `.autocorrectionDisabled` modifiers do NOT cover those field-editor
//      substitutions on macOS.
//
//  Local-only: no I/O, no networking — only AppKit text plumbing (R11.x).
//

import AppKit
import SwiftUI

/// A multi-line, auto-growing, hardened text editor for the whiteboard's inline
/// text overlay.
struct SecureWhiteboardTextField: NSViewRepresentable {

    @Binding var text: String
    /// Hard cap on character count, enforced as the candidate types.
    let characterLimit: Int
    /// Ink color for the inline editor, seeded from the element's `strokeColor`
    /// so colored text edits render in their real color instead of white (R4.1,
    /// R4.2).
    let textColor: NSColor
    /// Invoked when the candidate commits (Escape).
    var onCommit: () -> Void
    /// Reports the measured content size so the overlay can auto-grow.
    var onSizeChange: (CGSize) -> Void

    /// Point size of the inline editor font (world-independent; the overlay is
    /// positioned in screen space).
    static let fontSize: CGFloat = 16.0

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, characterLimit: characterLimit,
                    onCommit: onCommit, onSizeChange: onSizeChange)
    }

    func makeNSView(context: Context) -> SecureCodeTextView {
        // Build a minimal TextKit stack so the document view is the hardened
        // SecureCodeTextView (inherits the H1 menu + Services hardening).
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        // A very wide, non-tracking container so lines NEVER wrap — the editor
        // grows rightward instead (R4.2).
        let textContainer = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = SecureCodeTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        // Resizable in BOTH axes so it can grow right + down (R4.2).
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = []
        textView.textContainerInset = NSSize(width: 2, height: 2)

        // Literal-entry hardening (mirrors the code editor's secure config): all
        // substitution/auto-detection toggles OFF so smart quotes/dashes never
        // rewrite the entered text (R4.6).
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        if textView.responds(to: #selector(setter: NSTextView.isAutomaticQuoteSubstitutionEnabled)) {
            textView.isAutomaticQuoteSubstitutionEnabled = false
        }
        if textView.responds(to: #selector(setter: NSTextView.isAutomaticTextCompletionEnabled)) {
            textView.isAutomaticTextCompletionEnabled = false
        }

        textView.string = text
        context.coordinator.attach(textView)
        // Report the initial size (and focus) on the next runloop tick so the
        // overlay frames the empty editor.
        DispatchQueue.main.async { [weak textView] in
            guard let textView = textView else { return }
            textView.window?.makeFirstResponder(textView)
            // The hosting window only exists once the view is in the hierarchy,
            // so (re)bind the own-window resign observer now (Finding #6).
            context.coordinator.bindWindowObserver(to: textView.window)
            context.coordinator.reportSize()
        }
        return textView
    }

    func updateNSView(_ nsView: SecureCodeTextView, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onSizeChange = onSizeChange
        context.coordinator.characterLimit = characterLimit
        // Reflect a live color change while editing (R4.2).
        nsView.textColor = textColor
        if nsView.string != text {
            // An external seed change means a NEW editing session began without a
            // fresh `attach(_:)` (re-open of an element / new `textEntryEditingID`
            // / non-empty seed): reset the per-session commit guard so this
            // session can commit again, and re-bind the window observer in case
            // the hosting window changed (Findings #5 / #6).
            context.coordinator.beginSession()
            nsView.string = text
            context.coordinator.reportSize()
        } else {
            // Keep the observer bound to the current window even when the seed is
            // unchanged (e.g. the view moved to a new window).
            context.coordinator.bindWindowObserver(to: nsView.window)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var characterLimit: Int
        var onCommit: () -> Void
        var onSizeChange: (CGSize) -> Void
        private weak var textView: NSTextView?

        /// Per-session guard against double-commit (resign + Escape race). Reset
        /// to `false` at the START of each editing session so the persisted
        /// Coordinator does NOT silently block second-and-later sessions
        /// (Finding #5).
        private var didCommit = false
        /// The editor's OWN hosting window — the resign observer is scoped to it,
        /// not `object: nil`, so an unrelated window resigning key does not
        /// spuriously commit (Finding #6).
        private weak var observedWindow: NSWindow?

        init(text: Binding<String>, characterLimit: Int,
             onCommit: @escaping () -> Void, onSizeChange: @escaping (CGSize) -> Void) {
            self.text = text
            self.characterLimit = characterLimit
            self.onCommit = onCommit
            self.onSizeChange = onSizeChange
        }

        deinit {
            // Remove the window-resign observer and clear the window reference on
            // teardown (Finding #6).
            if let observedWindow = observedWindow {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.didResignKeyNotification, object: observedWindow)
            }
            observedWindow = nil
        }

        /// Begin a new editing session: clear the per-session commit guard so a
        /// fresh edit can commit again (Finding #5), and (re)bind the
        /// window-resign observer to the editor's OWN window.
        func attach(_ textView: NSTextView) {
            self.textView = textView
            didCommit = false
            bindWindowObserver(to: textView.window)
        }

        /// Reset the per-session commit guard when `updateNSView` transitions the
        /// field into a NEW active edit (new `textEntryEditingID` / non-empty
        /// seed) without a fresh `attach(_:)`, and re-bind the window observer in
        /// case the hosting window changed (Findings #5 / #6).
        func beginSession() {
            didCommit = false
            bindWindowObserver(to: textView?.window)
        }

        /// Scope the window-resign observer to the text view's own window only
        /// (not `object: nil`), and re-bind if the hosting window changes between
        /// sessions (Finding #6).
        func bindWindowObserver(to window: NSWindow?) {
            guard window !== observedWindow else { return }
            if let previous = observedWindow {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.didResignKeyNotification, object: previous)
            }
            observedWindow = window
            if let window = window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowResignedKey(_:)),
                    name: NSWindow.didResignKeyNotification, object: window)
            }
        }

        @objc private func windowResignedKey(_ note: Notification) {
            commitOnce()
        }

        /// Fires when the field editor resigns first responder (click-outside /
        /// tab away) — the focus-loss case (R3.1).
        func textDidEndEditing(_ notification: Notification) {
            commitOnce()
        }

        /// Idempotent commit: invokes `onCommit()` at most once per editing
        /// session so the Escape, resign, and window-resign paths cannot
        /// double-fire (R3.5).
        private func commitOnce() {
            guard !didCommit else { return }
            didCommit = true
            MainActor.assumeIsolated { onCommit() }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            var string = textView.string
            if string.count > characterLimit {
                string = String(string.prefix(characterLimit))
                textView.string = string
            }
            MainActor.assumeIsolated {
                text.wrappedValue = string
                reportSize()
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Escape commits the inline editor; Return inserts a newline so the
            // editor grows downward (R4.2). `cancelOperation:` is the Escape key.
            // Routed through `commitOnce()` so it cannot double-fire with the
            // resign / window-resign paths (R3.3 / R3.5).
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                commitOnce()
                return true
            }
            return false
        }

        /// Measure the laid-out content and report it so the overlay auto-grows.
        func reportSize() {
            guard let textView = textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).size
            let inset = textView.textContainerInset
            let size = CGSize(width: used.width + inset.width * 2,
                              height: used.height + inset.height * 2)
            onSizeChange(size)
        }
    }
}
