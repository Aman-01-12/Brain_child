//
//  CodeSyntaxHighlighterTests.swift
//  interTests
//
//  Unit tests for the native, no-web syntax highlighter that backs the secure
//  code editor's premium surface (collaborative-code-editor R1.2, R1.4, R5.1,
//  R5.3). Two behaviours are locked down here:
//
//    1. Tokenisation correctness — the PURE `(text, language) -> [(range,
//       tokenType)]` function classifies keywords, types, strings, comments,
//       and numbers for a couple of representative languages (Python and
//       JavaScript/TypeScript), at the exact UTF-16 ranges that line up with
//       `NSTextStorage`.
//    2. Attribute-only application — `applyHighlighting(to:language:in:)` writes
//       ONLY `NSAttributedString` colour attributes over the existing
//       `NSTextStorage`; it NEVER mutates the characters, so it cannot alter the
//       collaboratively-synced text (R1.4, R5.3).
//
//  The tests drive the production highlighter verbatim — no mocks — exercising
//  the same code path the editor's coordinator uses on edit and on a language
//  change.
//
//  Validates: Requirements 1.2, 1.4, 5.1, 5.3
//

import XCTest
import AppKit
@testable import inter

@MainActor
final class CodeSyntaxHighlighterTests: XCTestCase {

    // MARK: - Helpers

    /// Slice every emitted token's UTF-16 range back out of `text` so a test can
    /// assert on `(substring, tokenType)` pairs rather than brittle raw offsets.
    private func classify(_ text: String,
                          _ language: CodeLanguage) -> [(text: String, type: CodeTokenType)] {
        let ns = text as NSString
        return CodeSyntaxHighlighter.tokens(for: text, language: language).map {
            (ns.substring(with: $0.range), $0.type)
        }
    }

    /// `true` when the highlighter emitted a token of `type` whose text equals
    /// `fragment`.
    private func contains(_ tokens: [(text: String, type: CodeTokenType)],
                          _ fragment: String,
                          _ type: CodeTokenType) -> Bool {
        tokens.contains { $0.text == fragment && $0.type == type }
    }

    /// Build a minimal `NSTextStorage` seeded with `text` for the attribute
    /// tests, mirroring the editor's TextKit stack.
    private func makeStorage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        return storage
    }

    // MARK: - Python tokenisation (R1.2)

    func testPythonKeywordsStringsCommentsNumbers() {
        let source = "def greet(name):\n    return \"hi\"  # say hello\n"
        let tokens = classify(source, .python)

        XCTAssertTrue(contains(tokens, "def", .keyword), "`def` should be a keyword")
        XCTAssertTrue(contains(tokens, "return", .keyword), "`return` should be a keyword")
        XCTAssertTrue(contains(tokens, "\"hi\"", .string), "double-quoted literal should be a string")
        XCTAssertTrue(contains(tokens, "# say hello", .comment), "`#` runs to end of line as a comment")

        // The identifiers `greet` and `name` are NOT classified (they keep the
        // default text colour), so no keyword/type token should cover them.
        XCTAssertFalse(contains(tokens, "greet", .keyword))
        XCTAssertFalse(contains(tokens, "name", .type))
    }

    func testPythonBuiltinTypesAndNumbers() {
        let source = "count: int = 3.14"
        let tokens = classify(source, .python)

        XCTAssertTrue(contains(tokens, "int", .type), "`int` is a Python built-in type")
        XCTAssertTrue(contains(tokens, "3.14", .number), "decimal literal should be one number token")
    }

    func testPythonTripleQuotedStringSpansLines() {
        let source = "x = \"\"\"line one\nline two\"\"\"\n"
        let tokens = classify(source, .python)

        XCTAssertTrue(contains(tokens, "\"\"\"line one\nline two\"\"\"", .string),
                      "triple-quoted string should be a single multi-line string token")
    }

    // MARK: - JavaScript / TypeScript tokenisation (R1.2)

    func testJavaScriptKeywordsCommentsAndTemplateStrings() {
        let source = "const greeting = `hello`; // a note\n"
        let tokens = classify(source, .javascript)

        XCTAssertTrue(contains(tokens, "const", .keyword), "`const` should be a keyword")
        XCTAssertTrue(contains(tokens, "`hello`", .string), "backtick template literal should be a string")
        XCTAssertTrue(contains(tokens, "// a note", .comment), "`//` runs to end of line as a comment")
    }

    func testJavaScriptBlockCommentAndUppercaseType() {
        let source = "/* header */ class Widget {}"
        let tokens = classify(source, .javascript)

        XCTAssertTrue(contains(tokens, "/* header */", .comment), "`/* */` should be a block comment")
        XCTAssertTrue(contains(tokens, "class", .keyword), "`class` should be a keyword")
        XCTAssertTrue(contains(tokens, "Widget", .type),
                      "an uppercase identifier should be classified as a type")
    }

    func testTypeScriptPrimitiveTypeKeyword() {
        let source = "let total: number = 0;"
        let tokens = classify(source, .typescript)

        XCTAssertTrue(contains(tokens, "let", .keyword), "`let` should be a keyword")
        XCTAssertTrue(contains(tokens, "number", .type), "`number` is a TypeScript primitive type")
        XCTAssertTrue(contains(tokens, "0", .number), "`0` should be a number token")
    }

    // MARK: - Plain text emits no tokens

    func testPlainTextProducesNoTokens() {
        XCTAssertTrue(classify("def return class // 42", .plainText).isEmpty,
                      "Plain text must never tokenise — content keeps the default colour")
    }

    func testEmptyStringProducesNoTokens() {
        XCTAssertTrue(classify("", .python).isEmpty)
    }

    // MARK: - UTF-16 range alignment

    func testTokenRangesAreUTF16AlignedWithEmoji() {
        // A non-BMP emoji ahead of a keyword shifts UTF-16 offsets by 2 per
        // emoji. The slice round-trip proves the emitted ranges index the
        // NSString correctly (so attributes land on the right characters).
        let source = "# 😀\nreturn 7"
        let ns = source as NSString
        let raw = CodeSyntaxHighlighter.tokens(for: source, language: .python)

        guard let returnTok = raw.first(where: { ns.substring(with: $0.range) == "return" }) else {
            return XCTFail("expected a `return` keyword token")
        }
        XCTAssertEqual(returnTok.type, .keyword)
        XCTAssertTrue(contains(classify(source, .python), "7", .number))
    }

    // MARK: - Attribute-only application: never mutates characters (R1.4, R5.3)

    func testApplyHighlightingNeverChangesCharacters() {
        let source = "def f():\n    return 1  # c\n"
        let storage = makeStorage(source)

        // Whole-buffer pass (the language-change path) must not touch chars.
        CodeSyntaxHighlighter.applyHighlighting(
            to: storage, language: .python,
            in: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(storage.string, source, "highlighting must not alter the text")

        // Re-highlighting for a different language still leaves chars intact.
        CodeSyntaxHighlighter.applyHighlighting(
            to: storage, language: .javascript,
            in: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(storage.string, source, "a language change re-highlight must not alter the text")

        // Plain text (reset path) likewise leaves chars intact.
        CodeSyntaxHighlighter.applyHighlighting(
            to: storage, language: .plainText,
            in: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(storage.string, source, "resetting to plain text must not alter the text")
    }

    func testApplyHighlightingSetsColourAttributeOnKeyword() {
        let source = "return 1"
        let storage = makeStorage(source)

        CodeSyntaxHighlighter.applyHighlighting(
            to: storage, language: .python,
            in: NSRange(location: 0, length: storage.length))

        // The `return` keyword (offset 0) should carry the keyword colour.
        let keywordColour = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(keywordColour, CodeSyntaxHighlighter.color(for: .keyword),
                       "the keyword span should carry the keyword foreground colour")

        // The trailing number `1` (last char) should carry the number colour.
        let numberColour = storage.attribute(.foregroundColor, at: storage.length - 1,
                                             effectiveRange: nil) as? NSColor
        XCTAssertEqual(numberColour, CodeSyntaxHighlighter.color(for: .number),
                       "the number span should carry the number foreground colour")
    }

    func testApplyHighlightingClampsOutOfBoundsRange() {
        let source = "let x = 1"
        let storage = makeStorage(source)

        // A range past the end must be clamped, not crash, and must not mutate.
        CodeSyntaxHighlighter.applyHighlighting(
            to: storage, language: .javascript,
            in: NSRange(location: 0, length: storage.length + 500))
        XCTAssertEqual(storage.string, source)

        // An entirely out-of-range location is a no-op.
        CodeSyntaxHighlighter.applyHighlighting(
            to: storage, language: .javascript,
            in: NSRange(location: storage.length + 10, length: 5))
        XCTAssertEqual(storage.string, source)
    }

    // MARK: - Language selector coverage (R1.3)

    func testSelectorOffersAllRequiredLanguages() {
        let displayNames = Set(CodeLanguage.allCases.map { $0.displayName })
        for required in ["Python", "JavaScript", "TypeScript", "Java",
                         "C++", "C", "Go", "Plain text"] {
            XCTAssertTrue(displayNames.contains(required),
                          "language selector must offer \(required)")
        }
    }

    func testDisplayNameRoundTrips() {
        for language in CodeLanguage.allCases {
            XCTAssertEqual(CodeLanguage.fromDisplayName(language.displayName), language)
        }
        // Anything unrecognised falls back to plain text.
        XCTAssertEqual(CodeLanguage.fromDisplayName("Brainfuck"), .plainText)
    }
}
