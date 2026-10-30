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
//  Fix 1 (collab-tool-ux-fixes) extends this file with Property 1 (function-call
//  and subscript/bracket tokens are coloured) and Property 2 (no double-
//  classification, purity, UTF-16 range alignment, and exhaustive colour table),
//  including a seeded SplitMix64 sweep for the purity / range-alignment checks.
//
//  Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 5.1, 5.3
//

import XCTest
import AppKit
@testable import inter

// MARK: - Deterministic, seeded RNG (Fix 1 sweeps)
//
// This project does NOT integrate an external PBT library; the established
// convention (see `BoardDocumentPropertyTests`, `CodeEditorDocumentTests`) is
// XCTest-driven randomized loops backed by a fixed-seed deterministic
// SplitMix64 RNG, so every counterexample is reproducible. The generator is
// distinctly named to avoid colliding with the `BoardPBTGenerator` /
// `SeededGenerator` declarations elsewhere in the same test target.

private struct HighlighterPBTGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Minimum iterations per property sweep (design/Task 1.3: ≥100).
private let kHighlighterIterations = 150

/// Alphabet for the purity / range-alignment sweep: letters, digits, the bracket
/// and operator punctuation set, comment/quote characters, whitespace, and a
/// non-BMP emoji + a combining-friendly accented char so UTF-16 alignment is
/// actually exercised (multi-byte characters shift offsets).
private let kHighlighterAlphabet: [Character] = Array(
    "abcdefgABCDEFG_0123456789 \t\n()[]{}+-*/%=<>!&|^~?:.,;\"'`#😀é"
)

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

    // MARK: - Fix 1 helpers

    /// `true` when a low surrogate (0xDC00–0xDFFF) sits at `index`, which would
    /// mean a token boundary split a surrogate pair (UTF-16 mis-alignment).
    private func isLowSurrogate(_ ns: NSString, at index: Int) -> Bool {
        guard index >= 0, index < ns.length else { return false }
        let unit = ns.character(at: index)
        return unit >= 0xDC00 && unit <= 0xDFFF
    }

    // MARK: - Fix 1 / Property 1: function-call and subscript/bracket tokens
    // Validates: Requirements 1.1, 1.3

    /// P1.1 — `function_new(x)` → `function_new` is `.functionCall` over EXACTLY
    /// the identifier's UTF-16 range.
    func testProperty1_FunctionCallColoredOverIdentifierRange() {
        let source = "function_new(x)"
        let tokens = classify(source, .javascript)
        XCTAssertTrue(contains(tokens, "function_new", .functionCall),
                      "an identifier immediately followed by `(` should be a function call")

        let raw = CodeSyntaxHighlighter.tokens(for: source, language: .javascript)
        let call = raw.first { $0.type == .functionCall }
        XCTAssertEqual(call?.range, NSRange(location: 0, length: 12),
                       "the `.functionCall` token must span exactly `function_new`")
    }

    /// P1.1 — intervening spaces/tabs between the identifier and `(` are ignored.
    func testProperty1_FunctionCallSkipsSpacesAndTabs() {
        for source in ["foo (x)", "foo\t(x)", "foo  \t (x)"] {
            let tokens = classify(source, .javascript)
            XCTAssertTrue(contains(tokens, "foo", .functionCall),
                          "identifier + spaces/tabs + `(` is a call: \(source.debugDescription)")
        }
    }

    /// P1.1 boundary — a keyword/type immediately followed by `(` stays a
    /// keyword/type (the call heuristic only applies to non-keyword/non-type ids).
    func testProperty1_KeywordOrTypeFollowedByParenIsNotFunctionCall() {
        let kw = classify("if (x)", .javascript)
        XCTAssertTrue(contains(kw, "if", .keyword))
        XCTAssertFalse(contains(kw, "if", .functionCall), "`if` must remain a keyword, not a call")

        let ty = classify("Widget(x)", .javascript)   // uppercaseIsType in JS
        XCTAssertTrue(contains(ty, "Widget", .type))
        XCTAssertFalse(contains(ty, "Widget", .functionCall), "`Widget` must remain a type, not a call")
    }

    /// P1.3 — `arr[i]` → `[` and `]` are single-char `.punctuation` tokens; `arr`
    /// (not followed by `(`) is not a call.
    func testProperty1_SubscriptBracketsArePunctuation() {
        let source = "arr[i]"
        let tokens = classify(source, .javascript)
        XCTAssertTrue(contains(tokens, "[", .punctuation), "`[` should be punctuation")
        XCTAssertTrue(contains(tokens, "]", .punctuation), "`]` should be punctuation")
        XCTAssertFalse(contains(tokens, "arr", .functionCall),
                       "`arr` is a subscript base, not a call")
    }

    /// P1.3 — every bracket and recognized operator character emits a single-char
    /// `.punctuation` token.
    func testProperty1_BracketsAndOperatorsArePunctuation() {
        for ch in "()[]{}+-*/%=<>!&|^~?:.,;" {
            let source = "a \(ch) b"   // surrounded by spaces so nothing combines into a comment/number
            let tokens = classify(source, .javascript)
            XCTAssertTrue(contains(tokens, String(ch), .punctuation),
                          "`\(ch)` should emit a single-character punctuation token")
        }
    }

    // MARK: - Fix 1 / Property 2: no double-classification, purity, totality
    // Validates: Requirements 1.2, 1.4, 1.5, 1.6, 1.7

    /// P1.2 — a bare identifier (not a keyword/type, not followed by `(`) emits no
    /// token and keeps the default colour.
    func testProperty2_BareIdentifierEmitsNoToken() {
        XCTAssertTrue(classify("foobar", .javascript).isEmpty,
                      "a bare identifier must emit no token")
    }

    /// P1.4 — bracket/operator/`/`/`.` characters inside a string are part of the
    /// string token, never `.punctuation`.
    func testProperty2_NoPunctuationInsideStrings() {
        let tokens = classify("\"a(b)[c]/d.e\"", .javascript)
        XCTAssertTrue(contains(tokens, "\"a(b)[c]/d.e\"", .string),
                      "the whole quoted span is one string token")
        XCTAssertFalse(tokens.contains { $0.type == .punctuation },
                       "characters inside a string must not be classified as punctuation")
    }

    /// P1.4 — characters inside a line comment (including the opening `//`) are
    /// part of the comment, never `.punctuation`.
    func testProperty2_NoPunctuationInsideLineComment() {
        let tokens = classify("// a(b)[c].d\n", .javascript)
        XCTAssertTrue(contains(tokens, "// a(b)[c].d", .comment))
        XCTAssertFalse(tokens.contains { $0.type == .punctuation },
                       "the `/` opening a comment and chars within it are comment, not punctuation")
    }

    /// P1.4 — the `/` characters opening/closing a block comment are part of the
    /// comment, never `.punctuation`.
    func testProperty2_NoPunctuationInsideBlockComment() {
        let tokens = classify("/* x(y) */", .javascript)
        XCTAssertTrue(contains(tokens, "/* x(y) */", .comment))
        XCTAssertFalse(tokens.contains { $0.type == .punctuation },
                       "block-comment delimiters must not be punctuation")
    }

    /// P1.4 — a `.` inside a numeric literal stays part of the number, not
    /// `.punctuation`.
    func testProperty2_DotInNumericLiteralIsNotPunctuation() {
        let tokens = classify("3.14", .javascript)
        XCTAssertTrue(contains(tokens, "3.14", .number), "the float is a single number token")
        XCTAssertFalse(contains(tokens, ".", .punctuation),
                       "the `.` inside a numeric literal must stay part of the number")
    }

    /// P1.7 — `color(for:)` returns a configured, distinct colour for all seven
    /// `CodeTokenType` cases (exhaustive switch, no default).
    func testProperty2_ColorTableIsTotalAndDistinct() {
        // CodeTokenType is not CaseIterable; enumerate the seven cases explicitly
        // so a future added case forces this list (and the switch) to be revisited.
        let allCases: [CodeTokenType] = [
            .keyword, .type, .string, .comment, .number, .functionCall, .punctuation,
        ]
        var seen: [NSColor] = []
        for tokenType in allCases {
            let colour = CodeSyntaxHighlighter.color(for: tokenType)
            for prior in seen {
                XCTAssertNotEqual(colour, prior,
                                  "each token category must map to a distinct colour (\(tokenType))")
            }
            seen.append(colour)
        }
        XCTAssertEqual(seen.count, 7, "all seven token categories must be covered")
    }

    /// P1.5 (purity / side-effect free) + P1.6 (range alignment): a seeded
    /// SplitMix64 sweep over random source strings and languages. Each iteration
    /// derives its own seed (printed on failure) so any counterexample replays.
    func testProperty2_PurityAndRangeAlignmentSweep() {
        let base: UInt64 = 0xC0DE_F1F1_0000
        let languages: [CodeLanguage] = [
            .python, .javascript, .typescript, .java, .cpp, .c, .go,
        ]
        for i in 0 ..< kHighlighterIterations {
            let seed = base &+ UInt64(i)
            var rng = HighlighterPBTGenerator(seed: seed)
            let length = Int.random(in: 0 ... 80, using: &rng)
            let source = String((0 ..< length).map { _ in
                kHighlighterAlphabet.randomElement(using: &rng)!
            })
            let language = languages.randomElement(using: &rng)!
            let ns = source as NSString
            let u16 = ns.length

            let msg = "Fix1 purity/range sweep failed: seed=0x\(String(seed, radix: 16)) "
                + "iteration=\(i) lang=\(language.displayName) source=\(source.debugDescription)"

            // P1.5 — deterministic & side-effect free: two calls produce identical output.
            let first = CodeSyntaxHighlighter.tokens(for: source, language: language)
            let second = CodeSyntaxHighlighter.tokens(for: source, language: language)
            XCTAssertEqual(first.count, second.count, msg + " — non-deterministic token count")
            for (a, b) in zip(first, second) {
                XCTAssertEqual(a.range, b.range, msg + " — non-deterministic range")
                XCTAssertEqual(a.type, b.type, msg + " — non-deterministic type")
            }

            // P1.6 — every range within [0, utf16.count] and UTF-16-aligned.
            for token in first {
                XCTAssertGreaterThanOrEqual(token.range.location, 0, msg + " — negative location")
                XCTAssertGreaterThanOrEqual(token.range.length, 0, msg + " — negative length")
                let end = token.range.location + token.range.length
                XCTAssertLessThanOrEqual(end, u16, msg + " — range past end of buffer")
                // Boundaries must not split a surrogate pair (a low surrogate at a
                // boundary means a multi-byte char was cut in half).
                XCTAssertFalse(isLowSurrogate(ns, at: token.range.location),
                               msg + " — start splits a surrogate pair")
                XCTAssertFalse(isLowSurrogate(ns, at: end),
                               msg + " — end splits a surrogate pair")
                // Round-trip: slicing yields a string of exactly the range's UTF-16 length.
                XCTAssertEqual((ns.substring(with: token.range) as NSString).length,
                               token.range.length, msg + " — range not UTF-16-aligned")
            }

            // P1.5 — applyHighlighting mutates only attributes: characters are
            // byte-for-byte unchanged before and after a highlight pass.
            let storage = makeStorage(source)
            CodeSyntaxHighlighter.applyHighlighting(
                to: storage, language: language,
                in: NSRange(location: 0, length: storage.length))
            XCTAssertEqual(storage.string, source, msg + " — applyHighlighting mutated characters")
        }
    }
}
