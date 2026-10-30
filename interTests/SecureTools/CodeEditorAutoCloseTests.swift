//
//  CodeEditorAutoCloseTests.swift
//  interTests
//
//  Tests for Fix 2 — auto-closing brackets in the secure code editor
//  (`CodeEditorTextView.Coordinator.textView(_:shouldChangeTextIn:replacementString:)`).
//
//  These exercise the CodeMirror `closeBrackets` semantics — auto-close insert,
//  skip-over, delete-pair, and the quote guard — by driving the real
//  NSTextViewDelegate method against a real `SecureCodeTextView` built on the
//  SAME TextKit stack as `CodeEditorTextView.makeNSView` (manual layout manager
//  / text container / hardened text view), wired to a `CodeEditorViewModel` and
//  `Coordinator`.
//
//  Two design properties are validated:
//
//    • Property 3 (Validates Requirements 2.1, 2.2, 2.3, 2.6): auto-close
//      insert, skip-over, delete-pair, and the quote guard behave per
//      CodeMirror, asserted on the resulting `string` and selected range.
//
//    • Property 4 (Validates Requirements 2.4, 2.5) — CRDT parity. After every
//      auto-close insert and delete-pair the local edit path runs and
//      `viewModel.text == textView.string` (an AUTOMATED assertion, per Finding
//      #14). Skip-over produces no text change and thus no op. Non-pair chars,
//      typing into a selection, paste, multi-char replacements, and
//      attribute-only edits all pass through (the delegate returns `true`).
//
//  The repo convention (see `CodeEditorIntegrityPropertyTests`,
//  `BoardDocumentPropertyTests`) is XCTest-driven randomized loops backed by a
//  fixed-seed deterministic SplitMix64 RNG so every counterexample is
//  reproducible. The parity sweep below follows that convention.
//

import XCTest
import AppKit
@testable import inter

@MainActor
final class CodeEditorAutoCloseTests: XCTestCase {

    // MARK: - Deterministic, seeded RNG (SplitMix64)

    /// Deterministic SplitMix64 generator so a failing example is reproducible
    /// from the fixed seed. Named distinctly to avoid colliding with the
    /// `SeededGenerator` declared elsewhere in the same test target.
    private struct AutoCloseSeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed != 0 ? seed : 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Editor stack (mirrors CodeEditorTextView.makeNSView)

    /// Strong-reference holder for a fully wired editor stack. The coordinator
    /// keeps WEAK references to the text view / ruler, so the test
    /// must retain the whole stack for the lifetime of a case.
    private final class EditorContext {
        let scrollView: NSScrollView
        let textView: SecureCodeTextView
        let ruler: LineNumberRulerView
        let viewModel: CodeEditorViewModel
        let coordinator: CodeEditorTextView.Coordinator

        init(scrollView: NSScrollView,
             textView: SecureCodeTextView,
             ruler: LineNumberRulerView,
             viewModel: CodeEditorViewModel,
             coordinator: CodeEditorTextView.Coordinator) {
            self.scrollView = scrollView
            self.textView = textView
            self.ruler = ruler
            self.viewModel = viewModel
            self.coordinator = coordinator
        }
    }

    /// Build the SAME TextKit stack as `CodeEditorTextView.makeNSView`: a
    /// manually assembled storage / layout manager / container, the hardened
    /// `SecureCodeTextView`, the line-number ruler, a `CodeEditorViewModel`, and
    /// a bound `Coordinator`.
    ///
    /// The coordinator is deliberately NOT installed as `textView.delegate`, so
    /// the test drives the delegate method directly (and applies "allowed"
    /// edits itself) without AppKit re-entering the delegate during the
    /// coordinator's own `insertText` calls. The local edit path is driven
    /// explicitly via `coordinator.textDidChange(_:)`.
    private func makeEditor() -> EditorContext {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = SecureCodeTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = NSView.AutoresizingMask.width

        let editorFont = NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
        textView.font = editorFont
        textView.textColor = NSColor(calibratedWhite: 0.94, alpha: 1.0)
        textView.insertionPointColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)

        let viewModel = CodeEditorViewModel()

        // Apply the exact production secure configuration (13 substitution
        // disables off, undo + find bar on) via the representable.
        let representable = CodeEditorTextView(viewModel: viewModel)
        representable.applySecureConfiguration(textView)

        scrollView.documentView = textView

        let gutterFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView, font: gutterFont)
        scrollView.hasVerticalRuler = true
        scrollView.hasHorizontalRuler = false
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true

        viewModel.attach(textView: textView)

        let coordinator = representable.makeCoordinator()
        coordinator.bind(scrollView: scrollView, textView: textView, ruler: ruler)

        return EditorContext(scrollView: scrollView, textView: textView, ruler: ruler,
                             viewModel: viewModel, coordinator: coordinator)
    }

    // MARK: - Edit drivers

    /// Seed the editor with literal `text` and a caret (zero-length selection)
    /// at `caret`. The text is set directly on the text view (bypassing the
    /// auto-close delegate) and reflected into `viewModel.text` to model an
    /// already-synced starting state.
    private func seed(_ ctx: EditorContext, text: String, caret: Int) {
        ctx.textView.string = text
        ctx.textView.setSelectedRange(NSRange(location: caret, length: 0))
        ctx.viewModel.text = text
    }

    /// Drive a single edit through the auto-close delegate, mimicking AppKit:
    /// ask `shouldChangeTextIn`; if the delegate allows the edit, apply it
    /// directly (the coordinator is not the live delegate, so no re-entrancy);
    /// then run the local edit path (`textDidChange`) so `viewModel.text`
    /// reflects the resulting string. Returns the delegate's decision.
    @discardableResult
    private func performEdit(_ ctx: EditorContext,
                             range: NSRange,
                             replacement: String?,
                             driveLocalPath: Bool = true) -> Bool {
        let allowed = ctx.coordinator.textView(ctx.textView,
                                               shouldChangeTextIn: range,
                                               replacementString: replacement)
        if allowed {
            ctx.textView.insertText(replacement ?? "", replacementRange: range)
        }
        if driveLocalPath {
            ctx.coordinator.textDidChange(
                Notification(name: NSText.didChangeNotification, object: ctx.textView))
        }
        return allowed
    }

    /// Type a single character at the current caret (zero-length selection).
    @discardableResult
    private func typeChar(_ ctx: EditorContext, _ ch: String, driveLocalPath: Bool = true) -> Bool {
        let caret = ctx.textView.selectedRange()
        return performEdit(ctx, range: NSRange(location: caret.location, length: 0),
                           replacement: ch, driveLocalPath: driveLocalPath)
    }

    /// Press backspace at the current caret (deletes the char before the caret).
    @discardableResult
    private func backspace(_ ctx: EditorContext, driveLocalPath: Bool = true) -> Bool {
        let sel = ctx.textView.selectedRange()
        let range: NSRange = sel.length > 0
            ? sel
            : NSRange(location: max(0, sel.location - 1), length: sel.location > 0 ? 1 : 0)
        return performEdit(ctx, range: range, replacement: "", driveLocalPath: driveLocalPath)
    }

    // MARK: - Property 3: auto-close insert (P2.1)
    // Validates: Requirements 2.1, 2.4

    func testAutoCloseInsertParenthesis() {
        let ctx = makeEditor()
        seed(ctx, text: "", caret: 0)

        let allowed = typeChar(ctx, "(")

        XCTAssertFalse(allowed, "Auto-close should consume the keystroke (return false)")
        XCTAssertEqual(ctx.textView.string, "()", "Typing '(' into an empty buffer inserts the pair")
        XCTAssertEqual(ctx.textView.selectedRange(), NSRange(location: 1, length: 0),
                       "Caret should sit between the inserted pair")
        // CRDT parity (P2.4): the local edit path ran and the model agrees.
        XCTAssertEqual(ctx.viewModel.text, ctx.textView.string,
                       "viewModel.text must equal textView.string after an auto-close insert")
    }

    func testAutoCloseInsertAllBracketPairs() {
        let cases: [(open: String, expected: String)] = [
            ("(", "()"), ("[", "[]"), ("{", "{}"), ("\"", "\"\""), ("'", "''"),
        ]
        for c in cases {
            let ctx = makeEditor()
            seed(ctx, text: "", caret: 0)

            let allowed = typeChar(ctx, c.open)

            XCTAssertFalse(allowed, "Opener \(c.open) should be consumed")
            XCTAssertEqual(ctx.textView.string, c.expected,
                           "Typing \(c.open) should insert \(c.expected)")
            XCTAssertEqual(ctx.textView.selectedRange(), NSRange(location: 1, length: 0),
                           "Caret should be between the pair for \(c.open)")
            XCTAssertEqual(ctx.viewModel.text, ctx.textView.string,
                           "Parity must hold for opener \(c.open)")
        }
    }

    func testAutoCloseInsertMidString() {
        let ctx = makeEditor()
        seed(ctx, text: "ab", caret: 1)   // caret between a|b

        typeChar(ctx, "[")

        XCTAssertEqual(ctx.textView.string, "a[]b", "Pair inserted at the caret")
        XCTAssertEqual(ctx.textView.selectedRange(), NSRange(location: 2, length: 0),
                       "Caret between the inserted pair")
        XCTAssertEqual(ctx.viewModel.text, ctx.textView.string)
    }

    // MARK: - Property 3: skip-over (P2.2)
    // Validates: Requirements 2.2, 2.4

    func testSkipOverClosingParenthesis() {
        let ctx = makeEditor()
        seed(ctx, text: "()", caret: 1)   // (|)
        let before = ctx.textView.string

        // Skip-over is a pure caret move; it must NOT produce a text change /
        // op, so we do not drive the local edit path artificially.
        let allowed = typeChar(ctx, ")", driveLocalPath: false)

        XCTAssertFalse(allowed, "Skip-over should consume the keystroke")
        XCTAssertEqual(ctx.textView.string, before, "Skip-over must not change the text")
        XCTAssertEqual((ctx.textView.string as NSString).length, 2, "Length unchanged on skip-over")
        XCTAssertEqual(ctx.textView.selectedRange(), NSRange(location: 2, length: 0),
                       "Caret should move past the existing closer")
        // No op: the model still agrees with the (unchanged) string.
        XCTAssertEqual(ctx.viewModel.text, ctx.textView.string,
                       "Skip-over produces no text change, so the model stays in parity")
    }

    func testSkipOverEveryCloser() {
        let cases: [(seed: String, closer: String)] = [
            ("()", ")"), ("[]", "]"), ("{}", "}"), ("\"\"", "\""), ("''", "'"),
        ]
        for c in cases {
            let ctx = makeEditor()
            seed(ctx, text: c.seed, caret: 1)
            let before = ctx.textView.string

            let allowed = typeChar(ctx, c.closer, driveLocalPath: false)

            XCTAssertFalse(allowed, "Skip-over should consume \(c.closer)")
            XCTAssertEqual(ctx.textView.string, before, "No text change skipping \(c.closer)")
            XCTAssertEqual(ctx.textView.selectedRange(), NSRange(location: 2, length: 0),
                           "Caret moved past \(c.closer)")
        }
    }

    // MARK: - Property 3: delete-pair (P2.3)
    // Validates: Requirements 2.3, 2.4

    func testDeletePairOnBackspace() {
        let ctx = makeEditor()
        seed(ctx, text: "()", caret: 1)   // (|)
        let lengthBefore = (ctx.textView.string as NSString).length

        let allowed = backspace(ctx)

        XCTAssertFalse(allowed, "Delete-pair should consume the backspace")
        XCTAssertEqual(ctx.textView.string, "", "Backspace between an empty pair deletes both chars")
        XCTAssertEqual((ctx.textView.string as NSString).length, lengthBefore - 2,
                       "Length reduced by 2")
        // CRDT parity (P2.4).
        XCTAssertEqual(ctx.viewModel.text, ctx.textView.string,
                       "viewModel.text must equal textView.string after delete-pair")
    }

    func testDeletePairEveryBracketPair() {
        for pair in ["()", "[]", "{}", "\"\"", "''"] {
            let ctx = makeEditor()
            seed(ctx, text: pair, caret: 1)

            backspace(ctx)

            XCTAssertEqual(ctx.textView.string, "", "Backspace deletes both chars of \(pair)")
            XCTAssertEqual(ctx.viewModel.text, ctx.textView.string, "Parity for delete-pair \(pair)")
        }
    }

    func testBackspaceNonPairDeletesSingleChar() {
        let ctx = makeEditor()
        seed(ctx, text: "(x", caret: 2)   // not an empty pair around the caret

        let allowed = backspace(ctx)

        XCTAssertTrue(allowed, "Backspace over a non-pair char passes through")
        XCTAssertEqual(ctx.textView.string, "(", "Only the single char is deleted")
        XCTAssertEqual(ctx.viewModel.text, ctx.textView.string)
    }

    // MARK: - Property 3: quote guard (P2.6)
    // Validates: Requirements 2.6, 2.4

    func testQuoteGuardSkipsOverExistingQuote() {
        let ctx = makeEditor()
        seed(ctx, text: "\"\"", caret: 1)   // "|"
        let before = ctx.textView.string

        let allowed = typeChar(ctx, "\"", driveLocalPath: false)

        XCTAssertFalse(allowed, "Typing a quote before an identical quote should skip over")
        XCTAssertEqual(ctx.textView.string, before, "No new pair inserted; text unchanged")
        XCTAssertEqual((ctx.textView.string as NSString).length, 2, "No nested empty pair created")
        XCTAssertEqual(ctx.textView.selectedRange(), NSRange(location: 2, length: 0),
                       "Caret moves past the existing quote")
    }

    func testQuoteGuardSingleQuote() {
        let ctx = makeEditor()
        seed(ctx, text: "''", caret: 1)

        let allowed = typeChar(ctx, "'", driveLocalPath: false)

        XCTAssertFalse(allowed)
        XCTAssertEqual(ctx.textView.string, "''", "No nested empty single-quote pair")
        XCTAssertEqual(ctx.textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    // MARK: - Property 4: non-interference / pass-through (P2.5)
    // Validates: Requirements 2.5, 2.4

    func testNonPairCharacterPassesThrough() {
        let ctx = makeEditor()
        seed(ctx, text: "", caret: 0)

        let allowed = typeChar(ctx, "x")

        XCTAssertTrue(allowed, "A non-pair character must pass through (return true)")
        XCTAssertEqual(ctx.textView.string, "x")
        XCTAssertEqual(ctx.viewModel.text, ctx.textView.string)
    }

    func testTypingIntoSelectionPassesThrough() {
        let ctx = makeEditor()
        ctx.textView.string = "abcd"
        ctx.textView.setSelectedRange(NSRange(location: 1, length: 2))   // select "bc"
        ctx.viewModel.text = "abcd"

        // Typing an opener over a non-empty selection must NOT auto-close.
        let allowed = ctx.coordinator.textView(ctx.textView,
                                               shouldChangeTextIn: NSRange(location: 1, length: 2),
                                               replacementString: "(")

        XCTAssertTrue(allowed, "Typing into a selection passes through unchanged")
    }

    func testPasteMultiCharReplacementPassesThrough() {
        let ctx = makeEditor()
        seed(ctx, text: "", caret: 0)

        // Multi-character replacement (paste) at a caret.
        let allowed = ctx.coordinator.textView(ctx.textView,
                                               shouldChangeTextIn: NSRange(location: 0, length: 0),
                                               replacementString: "func foo() {}")

        XCTAssertTrue(allowed, "A multi-character paste must pass through unchanged")
    }

    func testAttributeOnlyChangePassesThrough() {
        let ctx = makeEditor()
        seed(ctx, text: "abc", caret: 0)

        // A nil replacement string is an attribute-only change (e.g. the
        // highlighter): the delegate must allow it.
        let allowed = ctx.coordinator.textView(ctx.textView,
                                               shouldChangeTextIn: NSRange(location: 0, length: 3),
                                               replacementString: nil)

        XCTAssertTrue(allowed, "Attribute-only (nil replacement) edits pass through")
    }

    func testTypingClosingCharWithoutMatchInserts() {
        // Typing ')' with no matching closer ahead is a plain literal insert.
        let ctx = makeEditor()
        seed(ctx, text: "", caret: 0)

        let allowed = typeChar(ctx, ")")

        XCTAssertTrue(allowed, "A lone closer with no skip-over target passes through")
        XCTAssertEqual(ctx.textView.string, ")")
        XCTAssertEqual(ctx.viewModel.text, ctx.textView.string)
    }

    // MARK: - Property 4: CRDT parity sweep (P2.4) — seeded SplitMix64
    // Validates: Requirements 2.4, 2.5

    /// Drive long, random sequences of bracket/quote/letter typing and
    /// backspaces through the auto-close delegate and assert, after EVERY edit,
    /// that the local edit path kept `viewModel.text == textView.string`. This
    /// is the automated CRDT-parity assertion required by Finding #14: no edit
    /// (auto-close insert, delete-pair, skip-over, or pass-through) may mutate
    /// the text-view string in a way the local edit path does not observe.
    func testCRDTParityUnderRandomEditSequences() {
        let palette = ["(", ")", "[", "]", "{", "}", "\"", "'", "a", "b", " ", "x", "\n"]
        let baseSeed: UInt64 = 0xC0DE_C105_E000_0001
        let sequences = 120
        let editsPerSequence = 40

        for s in 0..<sequences {
            var rng = AutoCloseSeededGenerator(seed: baseSeed &+ UInt64(s))
            let ctx = makeEditor()
            seed(ctx, text: "", caret: 0)

            for e in 0..<editsPerSequence {
                let roll = Int.random(in: 0..<100, using: &rng)
                let stringBefore = ctx.textView.string

                if roll < 20 {
                    // Backspace.
                    backspace(ctx)
                } else {
                    let ch = palette.randomElement(using: &rng) ?? "x"
                    let allowedBefore = ctx.textView.selectedRange()
                    let wasSkipOver = typeChar(ctx, ch) == false
                        && ctx.textView.string == stringBefore
                        && allowedBefore.length == 0
                    _ = wasSkipOver   // skip-over correctness covered by deterministic cases
                }

                // The core automated parity invariant: after each edit the
                // model mirrors the text view exactly (P2.4 / Finding #14).
                XCTAssertEqual(
                    ctx.viewModel.text, ctx.textView.string,
                    "CRDT parity broken (sequence \(s), seed 0x\(String(baseSeed &+ UInt64(s), radix: 16)), edit \(e)): viewModel.text != textView.string")
            }
        }
    }

    /// A focused parity check that every skip-over leaves the text untouched
    /// (no op) across all closer kinds, while the model stays in parity.
    func testSkipOverProducesNoOp() {
        for pair in ["()", "[]", "{}", "\"\"", "''"] {
            let ctx = makeEditor()
            seed(ctx, text: pair, caret: 1)
            let textBefore = ctx.textView.string
            let modelBefore = ctx.viewModel.text
            let closer = String(Array(pair)[1])

            let allowed = typeChar(ctx, closer, driveLocalPath: false)

            XCTAssertFalse(allowed, "Skip-over consumes the keystroke for \(pair)")
            XCTAssertEqual(ctx.textView.string, textBefore, "Skip-over is a no-op on the text for \(pair)")
            XCTAssertEqual(ctx.viewModel.text, modelBefore, "Skip-over produces no op for \(pair)")
        }
    }
}
