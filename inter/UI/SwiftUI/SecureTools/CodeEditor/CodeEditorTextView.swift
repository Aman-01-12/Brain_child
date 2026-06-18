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
//  Native premium surface (collaborative-code-editor R1, R2.4):
//    - An NSRulerView line-number gutter draws 1-based line numbers in the
//      monospaced theme font (R1.1).
//    - A native, no-web syntax highlighter (CodeSyntaxHighlighter) applies
//      colour ATTRIBUTES over the existing NSTextStorage — re-run on the changed
//      paragraph on edit and over the whole buffer on a language change; it
//      never mutates characters (R1.2, R1.4, R5.1, R5.3).
//    - A labelled remote-cursor/selection overlay maps the peer's element-id
//      anchors to live offsets and draws a coloured caret + selection rect,
//      snapping to the nearest live neighbour when an anchor is tombstoned
//      (R2.4). It is drawn with AppKit (no `.drawingGroup()`), preserving the
//      capture pipeline (R5.2).
//    - The coordinator reports local caret/selection changes back to the view
//      model so the peer can render this client's cursor (R2.6).
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

// MARK: - Remote cursor / selection overlay (R2.4)

/// A transparent overlay, hosted as a subview of the text view, that draws each
/// remote participant's selection rectangle, caret, and a small labelled pill.
/// Hit-testing is disabled so it never intercepts editing. Pure AppKit drawing
/// (no `.drawingGroup()`), so it does not break the capture pipeline (R5.2).
final class RemoteCursorOverlayView: NSView {

    /// A resolved remote marker: the live UTF-16 range, a label, and a colour.
    struct Marker {
        let label: String
        let range: NSRange
        let color: NSColor
    }

    weak var codeTextView: NSTextView?
    private var markers: [Marker] = []

    override var isFlipped: Bool { true }

    // Pass every click through to the text view beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(markers: [Marker]) {
        self.markers = markers
        needsDisplay = true
    }

    /// Deterministic per-identity colour so each peer keeps a stable hue for the
    /// session.
    static func color(forIdentity identity: String) -> NSColor {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in identity.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.65, brightness: 0.95, alpha: 1.0)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = codeTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let inset = textView.textContainerInset
        let length = (textView.string as NSString).length

        for marker in markers {
            // Clamp into the live document so a stale offset can never crash.
            let loc = min(max(marker.range.location, 0), length)
            let len = min(marker.range.length, length - loc)
            let range = NSRange(location: loc, length: max(0, len))

            // Selection rectangles, drawn per visual line.
            if range.length > 0 {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                          actualCharacterRange: nil)
                marker.color.withAlphaComponent(0.22).setFill()
                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                    _, _, _, lineGlyphRange, _ in
                    let intersection = NSIntersectionRange(glyphRange, lineGlyphRange)
                    guard intersection.length > 0 else { return }
                    var r = layoutManager.boundingRect(forGlyphRange: intersection, in: container)
                    r.origin.x += inset.width
                    r.origin.y += inset.height
                    NSBezierPath(rect: r).fill()
                }
            }

            // Caret at the head end of the selection.
            let caret = caretRect(atCharIndex: range.location + range.length,
                                  textView: textView,
                                  layoutManager: layoutManager,
                                  container: container,
                                  inset: inset)
            marker.color.setFill()
            NSBezierPath(rect: caret).fill()

            drawLabel(marker.label, color: marker.color, near: caret)
        }
    }

    private func caretRect(atCharIndex index: Int,
                           textView: NSTextView,
                           layoutManager: NSLayoutManager,
                           container: NSTextContainer,
                           inset: NSSize) -> NSRect {
        let content = textView.string as NSString
        let length = content.length
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
        let lineHeight = layoutManager.defaultLineHeight(for: font)

        guard length > 0 else {
            return NSRect(x: inset.width, y: inset.height, width: 2, height: lineHeight)
        }

        let safe = min(max(index, 0), length)
        if safe >= length {
            // End of document.
            let lastGlyph = max(0, layoutManager.numberOfGlyphs - 1)
            var effective = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph,
                                                          effectiveRange: &effective)
            if content.character(at: length - 1) == 0x0A {
                let extra = layoutManager.extraLineFragmentRect
                let r = extra.height > 0 ? extra : lineRect
                return NSRect(x: inset.width + r.minX, y: inset.height + r.minY,
                              width: 2, height: r.height)
            }
            let used = layoutManager.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1),
                                                  in: container)
            return NSRect(x: inset.width + used.maxX, y: inset.height + lineRect.minY,
                          width: 2, height: lineRect.height)
        }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: safe)
        var effective = NSRange()
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effective)
        let location = layoutManager.location(forGlyphAt: glyphIndex)
        return NSRect(x: inset.width + lineRect.minX + location.x, y: inset.height + lineRect.minY,
                      width: 2, height: lineRect.height)
    }

    private func drawLabel(_ text: String, color: NSColor, near caret: NSRect) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.0, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let label = text as NSString
        let textSize = label.size(withAttributes: attrs)
        let padding: CGFloat = 3.0
        let pill = NSRect(x: caret.minX,
                          y: max(0, caret.minY - (textSize.height + 2 * padding)),
                          width: textSize.width + 2 * padding,
                          height: textSize.height + 2 * padding)
        color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 3.0, yRadius: 3.0).fill()
        label.draw(at: NSPoint(x: pill.minX + padding, y: pill.minY + padding), withAttributes: attrs)
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

        // Remote cursor / selection overlay (R2.4).
        let overlay = RemoteCursorOverlayView(frame: textView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.codeTextView = textView
        textView.addSubview(overlay)

        // Register the text view with the model for focus activation / teardown.
        viewModel.attach(textView: textView)

        // Wire the coordinator and run an initial highlight pass over whatever
        // content the model seeded (late-join documents are non-empty).
        context.coordinator.bind(scrollView: scrollView, textView: textView,
                                 ruler: ruler, overlay: overlay)
        context.coordinator.highlightWholeBuffer()
        context.coordinator.refreshGutter()
        context.coordinator.refreshRemoteCursors()

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

        // Keep the overlay sized to the (vertically growing) text view and
        // re-resolve remote cursor anchors against the current document (R2.4).
        coordinator.overlay?.frame = textView.bounds
        coordinator.refreshRemoteCursors()
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
    /// the coordinator reads @MainActor view-model/document state (language,
    /// document, remoteCursors). Isolating the whole coordinator keeps that
    /// access sound without scattering `MainActor.assumeIsolated` across every
    /// helper. (Swift 5 mode: a @MainActor class may satisfy the nonisolated
    /// NSTextViewDelegate requirements.)
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        private let viewModel: CodeEditorViewModel

        private(set) weak var scrollView: NSScrollView?
        private(set) weak var textView: NSTextView?
        private weak var ruler: LineNumberRulerView?
        weak var overlay: RemoteCursorOverlayView?

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
                  ruler: LineNumberRulerView, overlay: RemoteCursorOverlayView) {
            self.scrollView = scrollView
            self.textView = textView
            self.ruler = ruler
            self.overlay = overlay
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
                refreshRemoteCursors()
            }
        }

        /// Report the local caret/selection so the peer can render this client's
        /// remote cursor (R2.6). The view model maps the UTF-16 NSRange to stable
        /// element ids; in non-collaborative mode it is a no-op.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            MainActor.assumeIsolated {
                viewModel.reportLocalSelection(range)
            }
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

        // MARK: Remote cursors (R2.4)

        func refreshRemoteCursors() {
            guard let overlay = overlay, let textView = textView else { return }
            guard let document = viewModel.document, !viewModel.remoteCursors.isEmpty else {
                overlay.update(markers: [])
                return
            }

            let text = textView.string
            var markers: [RemoteCursorOverlayView.Marker] = []
            for (identity, cursor) in viewModel.remoteCursors {
                guard let anchorOffset = liveCharOffset(for: cursor.anchor, in: document),
                      let headOffset = liveCharOffset(for: cursor.head, in: document) else { continue }
                let lo = min(anchorOffset, headOffset)
                let hi = max(anchorOffset, headOffset)
                let u16lo = Self.utf16Offset(forCharacterOffset: lo, in: text)
                let u16hi = Self.utf16Offset(forCharacterOffset: hi, in: text)
                markers.append(.init(
                    label: Self.shortLabel(for: identity),
                    range: NSRange(location: u16lo, length: max(0, u16hi - u16lo)),
                    color: RemoteCursorOverlayView.color(forIdentity: identity)))
            }
            overlay.update(markers: markers)
        }

        /// Resolve an element id to a live character offset, snapping to the
        /// nearest live neighbour when the anchor element is tombstoned (R2.4).
        private func liveCharOffset(for id: ElementID, in document: CodeEditorDocument) -> Int? {
            if let offset = document.offset(of: id) { return offset }
            guard let arrayIndex = document.elements.firstIndex(where: { $0.id == id }) else { return nil }

            // Nearest live element to the right anchors at its own offset.
            var i = arrayIndex
            while i < document.elements.count {
                if !document.elements[i].deleted {
                    return document.offset(of: document.elements[i].id)
                }
                i += 1
            }
            // Otherwise the nearest live element to the left, anchoring just
            // after it.
            i = arrayIndex - 1
            while i >= 0 {
                if !document.elements[i].deleted,
                   let offset = document.offset(of: document.elements[i].id) {
                    return offset + 1
                }
                i -= 1
            }
            return 0
        }

        /// A compact label for the cursor pill (first segment of the identity).
        private static func shortLabel(for identity: String) -> String {
            let trimmed = identity.split(separator: "-").first.map(String.init) ?? identity
            return String(trimmed.prefix(12))
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
