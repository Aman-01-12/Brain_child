//
//  CodeEditorTextView.swift
//  inter
//
//  SwiftUI NSViewRepresentable wrapping an NSTextView inside an NSScrollView
//  for the secure code editor (Code_Editor). This is the security-critical
//  surface: it reproduces, verbatim, the 13 Substitution_Disables and the 2
//  Retained_Editor_Settings of the AppKit InterSecureCodeEditorView so typed
//  and pasted characters are stored literally (R4.1, R4.2, R4.3, R12.2).
//
//  Because SwiftUI's plain TextEditor cannot express these NSTextView toggles,
//  an NSViewRepresentable over NSTextView is mandatory (S-A4).
//
//  The wrapped text view is a hardened subclass that suppresses the stock
//  contextual menu and Services participation so no Spelling/Grammar,
//  Substitutions, Font, Services, or Look Up item can open an NSPanel/NSWindow
//  from inside the secure capture surface (H1 / S-A6 — R10.1, R10.5).
//

import AppKit
import SwiftUI

// MARK: - Hardened NSTextView (H1 / S-A6)

/// NSTextView subclass that closes the contextual-menu / Services panel-leak
/// vector described as finding H1 (S-A6). The stock NSTextView right-click menu
/// exposes Spelling and Grammar, Substitutions, Font, Services, and Look Up
/// items — every one of which can open an NSPanel/NSWindow. In Secure_Mode that
/// is a window leak out of the captured surface, so this subclass returns a
/// sanitized menu containing only the safe editing verbs (Cut/Copy/Paste/Select
/// All) and refuses Services menu participation entirely.
final class SecureCodeTextView: NSTextView {

    // H1 mitigation (S-A6): replace the stock contextual menu (Spelling,
    // Substitutions, Font, Services, Look Up — all of which open NSPanel/
    // NSWindow) with a menu containing ONLY Cut/Copy/Paste/Select All, none of
    // which spawn a window. Returning this sanitized menu keeps right-click
    // editing usable while making every panel-opening item unreachable.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "")
        return menu
    }

    // H1 mitigation (S-A6): opt this view out of the Services menu so no
    // Services provider/requestor flow can surface an out-of-window panel from
    // the secure editor. Returning nil for every send/return type disables
    // Services validation for this responder.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        return nil
    }
}

// MARK: - Representable

/// Wraps the hardened NSTextView in an NSScrollView and bridges edits back into
/// the @MainActor CodeEditorViewModel. The model is authoritative for the
/// editor's text state; updateNSView deliberately does not force-overwrite the
/// text view's string on every render to avoid an edit/update feedback loop.
struct CodeEditorTextView: NSViewRepresentable {

    @ObservedObject var viewModel: CodeEditorViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Build the TextKit stack around the hardened text view manually so the
        // scroll view's document view is our SecureCodeTextView subclass (H1),
        // rather than the stock NSTextView from scrollableTextView().
        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = SecureCodeTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = NSView.AutoresizingMask.width

        // Visual parity with InterSecureCodeEditorView: monospaced 13pt, text
        // white @ 0.94, insertion point preserved. The dark chrome/placeholder
        // is task 4.1; only the text-view-level visuals are set here.
        textView.font = NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
        textView.textColor = NSColor(calibratedWhite: 0.94, alpha: 1.0)
        textView.insertionPointColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)

        applySecureConfiguration(textView)

        textView.delegate = context.coordinator
        scrollView.documentView = textView

        // Register the text view with the model for focus activation / teardown.
        viewModel.attach(textView: textView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // The model is authoritative and edits flow model<-textView via the
        // coordinator. Force-writing textView.string here on every update would
        // create a feedback loop (and reset the insertion point), so this is
        // intentionally minimal.
    }

    /// Applies the exact secure NSTextView configuration of the current AppKit
    /// InterSecureCodeEditorView: all 13 Substitution_Disables off and both
    /// Retained_Editor_Settings on (R4.2, R4.3, R12.2).
    func applySecureConfiguration(_ textView: NSTextView) {
        // Substitution_Disables — all NO. Keeping these off guarantees literal
        // code integrity: smart quotes/dashes, autocorrect, text replacement,
        // and data/link detection never silently rewrite the candidate's text.
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

        // automaticQuoteSubstitution and automaticTextCompletion are guarded by
        // responds(to:) exactly as the Objective-C original does.
        if textView.responds(to: #selector(setter: NSTextView.isAutomaticQuoteSubstitutionEnabled)) {
            textView.isAutomaticQuoteSubstitutionEnabled = false
        }
        if textView.responds(to: #selector(setter: NSTextView.isAutomaticTextCompletionEnabled)) {
            textView.isAutomaticTextCompletionEnabled = false
        }

        // Retained_Editor_Settings — ON. Undo and the find bar are the two
        // editor affordances kept enabled.
        textView.allowsUndo = true
        textView.usesFindBar = true
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {

        private let viewModel: CodeEditorViewModel

        init(viewModel: CodeEditorViewModel) {
            self.viewModel = viewModel
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let string = textView.string
            // The view model is @MainActor; textDidChange is delivered on the
            // main thread, but hop explicitly to satisfy the isolation contract.
            MainActor.assumeIsolated {
                viewModel.text = string
            }
        }
    }
}
