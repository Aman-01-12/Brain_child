//
//  SecureWhiteboardTextField.swift
//  inter
//
//  Hardened single-line text-entry field for the secure-interview whiteboard's
//  in-window text overlay (finding W1 / H2 / S-A6).
//
//  A plain SwiftUI `TextField` on macOS is backed by `NSTextField` editing
//  through the window's shared field editor (an `NSTextView`), whose default
//  right-click menu exposes "Spelling and Grammar → Show Spelling and Grammar"
//  (`showGuessPanel:`) and "Substitutions → Show Substitutions"
//  (`orderFrontSubstitutionsPanel:`) — both of which open an `NSPanel` OUT of
//  the captured interview surface. That is exactly the leak the code editor was
//  hardened against (H1), so the whiteboard's text entry must close it too.
//
//  This representable wraps the SAME hardened `SecureCodeTextView` the code
//  editor uses, so it inherits that class's sanitized contextual menu
//  (Cut/Copy/Paste/Select All only) and its `validRequestor` Services opt-out.
//  It is configured single-line (Return submits) with all substitution disables
//  applied, so entry is stored literally (no smart quotes/dashes) — the SwiftUI
//  `.autocorrectionDisabled` modifiers do NOT cover those field-editor
//  substitutions on macOS.
//
//  Local-only: no I/O, no networking — only AppKit text plumbing (R11.x).
//

import AppKit
import SwiftUI

/// A single-line, hardened text-entry field for the whiteboard text overlay.
struct SecureWhiteboardTextField: NSViewRepresentable {

    @Binding var text: String
    /// Hard cap on character count (R8.7), enforced as the candidate types.
    let characterLimit: Int
    /// Invoked when the candidate presses Return.
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, characterLimit: characterLimit, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> SecureCodeTextView {
        // Build a minimal TextKit stack so the document view is the hardened
        // SecureCodeTextView (inherits the H1 menu + Services hardening).
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = SecureCodeTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
        textView.textColor = NSColor(calibratedWhite: 0.96, alpha: 1.0)
        textView.insertionPointColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 2)

        // Literal-entry hardening (mirrors the code editor's secure config): all
        // substitution/auto-detection toggles OFF so smart quotes/dashes/replacement
        // never rewrite the entered text.
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
        return textView
    }

    func updateNSView(_ nsView: SecureCodeTextView, context: Context) {
        context.coordinator.onSubmit = onSubmit
        context.coordinator.characterLimit = characterLimit
        if nsView.string != text {
            nsView.string = text
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var characterLimit: Int
        var onSubmit: () -> Void

        init(text: Binding<String>, characterLimit: Int, onSubmit: @escaping () -> Void) {
            self.text = text
            self.characterLimit = characterLimit
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            var string = textView.string
            // Cap entry at the limit as the candidate types (R8.7).
            if string.count > characterLimit {
                string = String(string.prefix(characterLimit))
                textView.string = string
            }
            // Delegate callbacks arrive on the main thread; hop explicitly to
            // satisfy the @MainActor isolation of the captured SwiftUI state.
            MainActor.assumeIsolated { text.wrappedValue = string }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Single-line field: Return submits and swallows the newline so no
            // literal "\n" is ever inserted.
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                MainActor.assumeIsolated { onSubmit() }
                return true
            }
            return false
        }
    }
}
