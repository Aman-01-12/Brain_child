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
//  Native premium surface (local single-user editor):
//    - An NSRulerView line-number gutter draws 1-based line numbers in the
//      monospaced theme font (R1.1).
//    - A native, no-web syntax highlighter (CodeSyntaxHighlighter) applies
//      colour ATTRIBUTES over the existing NSTextStorage — re-run on the changed
//      paragraph on edit and over the whole buffer on a language change; it
//      never mutates characters (R1.2, R1.4, R5.1, R5.3).
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

// MARK: - Line-number gutter (R1.1)

/// An `NSRulerView` that draws 1-based line numbers down the left edge in the
/// monospaced theme font. Pure AppKit drawing — no web runtime, no
/// `.drawingGroup()` (R1.1, R5.1, R5.2).
final class LineNumberRulerView: NSRulerView {

    private weak var codeTextView: NSTextView?
    private let labelFont: NSFont
    private let labelColor = NSColor(calibratedWhite: 0.50, alpha: 1.0)
    private let gutterBackground = NSColor(calibratedWhite: 0.08, alpha: 1.0)

    init(scrollView: NSScrollView, textView: NSTextView, font: NSFont) {
        self.codeTextView = textView
        self.labelFont = font
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("LineNumberRulerView is created programmatically only")
    }

    /// Grow the gutter to fit the widest line number (so 4- and 5-digit files
    /// still align). Called on text change.
    func recomputeThickness(for string: String) {
        let lineCount = max(1, string.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } })
        let digits = String(lineCount).count
        let sample = String(repeating: "0", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: labelFont]).width
        let target = max(40, ceil(width) + 12)
        if abs(target - ruleThickness) > 0.5 { ruleThickness = target }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView = scrollView else { return }

        gutterBackground.setFill()
        bounds.fill()

        let content = textView.string as NSString
        let yInset = textView.textContainerInset.height
        let visibleRect = scrollView.contentView.bounds

        let attrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor,
        ]

        func drawNumber(_ number: Int, atY y: CGFloat, height: CGFloat) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            let x = ruleThickness - size.width - 5
            let drawY = y + (height - size.height) / 2
            label.draw(at: NSPoint(x: x, y: drawY), withAttributes: attrs)
        }

        // Empty document: a single "1".
        guard content.length > 0 else {
            let lineHeight = layoutManager.defaultLineHeight(for: labelFont)
            drawNumber(1, atY: yInset - visibleRect.minY, height: lineHeight)
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                            actualGlyphRange: nil)

        // 1-based line number at the first visible character.
        var lineNumber = 1
        var i = 0
        while i < visibleCharRange.location {
            if content.character(at: i) == 0x0A { lineNumber += 1 }
            i += 1
        }

        // Walk logical lines, labelling the first fragment of each.
        var glyphIndex = glyphRange.location
        let glyphEnd = NSMaxRange(glyphRange)
        while glyphIndex < glyphEnd {
            let charForGlyph = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = content.lineRange(for: NSRange(location: charForGlyph, length: 0))
            let firstGlyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var effective = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: firstGlyph,
                                                          effectiveRange: &effective)
            drawNumber(lineNumber, atY: lineRect.minY + yInset - visibleRect.minY,
                       height: lineRect.height)
            lineNumber += 1

            let nextChar = NSMaxRange(lineRange)
            guard nextChar > charForGlyph, nextChar <= content.length else { break }
            glyphIndex = layoutManager.glyphIndexForCharacter(at: nextChar)
        }

        // Trailing empty line when the document ends in a newline.
        if content.character(at: content.length - 1) == 0x0A {
            let extra = layoutManager.extraLineFragmentRect
            let height = extra.height > 0 ? extra.height : layoutManager.defaultLineHeight(for: labelFont)
            drawNumber(lineNumber, atY: extra.minY + yInset - visibleRect.minY, height: height)
        }
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
        let editorFont = NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
        textView.font = editorFont
        textView.textColor = NSColor(calibratedWhite: 0.94, alpha: 1.0)
        textView.insertionPointColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)

        applySecureConfiguration(textView)

        textView.delegate = context.coordinator
        scrollView.documentView = textView

        // Line-number gutter (R1.1).
        let gutterFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView, font: gutterFont)
        scrollView.hasVerticalRuler = true
        scrollView.hasHorizontalRuler = false
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true

        // Register the text view with the model for focus activation / teardown.
        viewModel.attach(textView: textView)

        // Wire the coordinator and run an initial highlight pass over the
        // editor's content.
        context.coordinator.bind(scrollView: scrollView, textView: textView,
                                 ruler: ruler)
        context.coordinator.highlightWholeBuffer()
        context.coordinator.refreshGutter()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }

        // A language change re-highlights the WHOLE buffer for the new language
        // without touching characters (R1.4).
        if viewModel.language != coordinator.lastLanguage {
            coordinator.lastLanguage = viewModel.language
            coordinator.highlightWholeBuffer()
        }

        // A programmatic / remote-driven text change (the model rewrote the
        // string) re-highlights the changed range and refreshes the gutter
        // (local typing is handled in textDidChange).
        if textView.string != coordinator.previousText {
            coordinator.highlightChangedRange()
            coordinator.refreshGutter()
        }
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

    /// Main-actor isolated: every entry point (NSViewRepresentable make/update on
    /// main, NSTextViewDelegate callbacks on main) runs on the main thread, and
    /// the coordinator reads @MainActor view-model state (language). Isolating
    /// the whole coordinator keeps that
    /// access sound without scattering `MainActor.assumeIsolated` across every
    /// helper. (Swift 5 mode: a @MainActor class may satisfy the nonisolated
    /// NSTextViewDelegate requirements.)
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        private let viewModel: CodeEditorViewModel

        private(set) weak var scrollView: NSScrollView?
        private(set) weak var textView: NSTextView?
        private weak var ruler: LineNumberRulerView?

        /// The language last applied to the buffer, so updateNSView can detect a
        /// change and re-highlight (R1.4).
        var lastLanguage: String

        /// The text last seen by the highlighter, used to compute the changed
        /// range for incremental re-highlighting and to detect programmatic
        /// (remote) rewrites in updateNSView.
        var previousText: String = ""

        init(viewModel: CodeEditorViewModel) {
            self.viewModel = viewModel
            self.lastLanguage = viewModel.language
        }

        func bind(scrollView: NSScrollView, textView: NSTextView,
                  ruler: LineNumberRulerView) {
            self.scrollView = scrollView
            self.textView = textView
            self.ruler = ruler
            self.lastLanguage = viewModel.language
            self.previousText = textView.string
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let string = textView.string
            // The view model is @MainActor; textDidChange is delivered on the
            // main thread, but hop explicitly to satisfy the isolation contract.
            MainActor.assumeIsolated {
                viewModel.text = string
                highlightChangedRange()
                refreshGutter()
            }
        }

        // MARK: Auto-closing brackets (R2.1–R2.6)

        /// CodeMirror `closeBrackets` pairs: opener → closer. Symmetric quotes
        /// map to themselves.
        private static let bracketPairs: [Character: Character] =
            ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]

        /// The set of closing characters (mirror of `bracketPairs` values) used
        /// for the skip-over check.
        private static let closers = Set([")", "]", "}", "\"", "'"].map { Character($0) })

        /// The opener whose pair closes with `closer`, or nil if `closer` is not
        /// a recognized closing character.
        private static func openerFor(closer: Character) -> Character? {
            bracketPairs.first(where: { $0.value == closer })?.key
        }

        /// Implements CodeMirror `closeBrackets` semantics — auto-close insert,
        /// skip-over, delete-pair, and the quote guard — for typed input.
        ///
        /// Every branch either returns `true` (the edit proceeds through the
        /// normal AppKit edit machinery and `textDidChange` fires) or performs
        /// `insertText(_:replacementRange:)` / `setSelectedRange(_:)` and returns
        /// `false`. The `insertText` calls are ordinary text-view edits, so
        /// `textDidChange` still runs and `viewModel.text = textView.string`
        /// derives the CRDT ops uniformly — there is NO path that mutates the
        /// text-view string while bypassing the local edit path. A bare caret
        /// move (skip-over) intentionally changes no characters, producing no op.
        func textView(_ textView: NSTextView,
                      shouldChangeTextIn affectedRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }   // nil = attribute-only
            let ns = textView.string as NSString

            // --- Type a single character into a caret (no selection). ---
            if replacement.count == 1, affectedRange.length == 0, let ch = replacement.first {
                let nextChar: Character? = affectedRange.location < ns.length
                    ? Character(ns.substring(with: NSRange(location: affectedRange.location, length: 1)))
                    : nil

                // (a) Skip-over: typing a closer when the next char is that same closer.
                if Self.closers.contains(ch), nextChar == ch {
                    textView.setSelectedRange(NSRange(location: affectedRange.location + 1, length: 0))
                    return false   // consume; no insertion
                }

                // (b) Auto-close: typing an opener inserts opener+closer, caret between.
                if let closer = Self.bracketPairs[ch] {
                    // Quote guard: do not double-insert when already against an
                    // identical quote (the skip-over above covers moving past it).
                    let isQuote = (ch == "\"" || ch == "'")
                    if !(isQuote && nextChar == ch) {
                        textView.insertText(String(ch) + String(closer),
                                            replacementRange: affectedRange)
                        textView.setSelectedRange(NSRange(location: affectedRange.location + 1, length: 0))
                        return false
                    }
                }
            }

            // --- Backspace inside an empty pair deletes BOTH chars. ---
            if replacement.isEmpty, affectedRange.length == 1 {
                let loc = affectedRange.location
                if loc < ns.length {
                    let deleted = Character(ns.substring(with: NSRange(location: loc, length: 1)))
                    let after = loc + 1 < ns.length
                        ? Character(ns.substring(with: NSRange(location: loc + 1, length: 1)))
                        : nil
                    if let opener = Self.openerFor(closer: after ?? " "), opener == deleted,
                       let closer = Self.bracketPairs[deleted], closer == after {
                        textView.insertText("", replacementRange: NSRange(location: loc, length: 2))
                        return false
                    }
                }
            }

            return true   // all other edits proceed normally
        }

        // MARK: Highlighting (R1.2, R1.4)

        func highlightWholeBuffer() {
            guard let textView = textView, let storage = textView.textStorage else { return }
            let language = CodeLanguage.fromDisplayName(viewModel.language)
            CodeSyntaxHighlighter.applyHighlighting(
                to: storage, language: language,
                in: NSRange(location: 0, length: storage.length))
            previousText = textView.string
        }

        func highlightChangedRange() {
            guard let textView = textView, let storage = textView.textStorage else { return }
            let new = textView.string as NSString
            let old = previousText as NSString
            guard !old.isEqual(to: new as String) else { return }

            let changed = Self.changedRange(from: old, to: new)
            previousText = textView.string

            guard new.length > 0 else { return }
            let loc = min(max(changed.location, 0), new.length)
            let len = min(changed.length, new.length - loc)
            let safeChanged = NSRange(location: loc, length: max(0, len))
            let paragraph = new.paragraphRange(for: safeChanged)

            let language = CodeLanguage.fromDisplayName(viewModel.language)
            CodeSyntaxHighlighter.applyHighlighting(to: storage, language: language, in: paragraph)
        }

        // MARK: Gutter (R1.1)

        func refreshGutter() {
            guard let ruler = ruler, let textView = textView else { return }
            ruler.recomputeThickness(for: textView.string)
            ruler.needsDisplay = true
        }

        // MARK: Offset helpers

        /// Single-region UTF-16 diff: the range in `new` that differs from
        /// `old` (common prefix/suffix stripped).
        static func changedRange(from old: NSString, to new: NSString) -> NSRange {
            let oldLen = old.length
            let newLen = new.length
            var prefix = 0
            let maxPrefix = min(oldLen, newLen)
            while prefix < maxPrefix && old.character(at: prefix) == new.character(at: prefix) {
                prefix += 1
            }
            var suffix = 0
            let maxSuffix = min(oldLen, newLen) - prefix
            while suffix < maxSuffix
                && old.character(at: oldLen - 1 - suffix) == new.character(at: newLen - 1 - suffix) {
                suffix += 1
            }
            let insertedLen = newLen - prefix - suffix
            return NSRange(location: prefix, length: max(0, insertedLen))
        }

        /// Convert a `Character` offset (document space) to a UTF-16 offset
        /// (text-view space), clamped into range.
        static func utf16Offset(forCharacterOffset charOffset: Int, in text: String) -> Int {
            let clamped = min(max(charOffset, 0), text.count)
            let index = text.index(text.startIndex, offsetBy: clamped)
            return text.utf16.distance(from: text.utf16.startIndex,
                                       to: index.samePosition(in: text.utf16) ?? text.utf16.endIndex)
        }
    }
}
