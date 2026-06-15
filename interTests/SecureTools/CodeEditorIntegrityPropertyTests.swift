//
//  CodeEditorIntegrityPropertyTests.swift
//  interTests
//
//  Property-based test for the secure code editor's literal-text integrity.
//  With all 13 Substitution_Disables off, ANY string the candidate types or
//  pastes must be stored byte-for-byte — no smart-quote, smart-dash, text
//  replacement, autocorrect, or data/link substitution may rewrite it.
//
//  This is an XCTest-based property test (NO external PBT dependency): a
//  SEEDED, reproducible RNG drives a randomized loop of >=100 iterations, with
//  generators biased toward the inputs most likely to trigger substitution
//  (straight quotes, apostrophes, double hyphens, URLs, double spaces, and code
//  punctuation). Each iteration exercises BOTH the typing path (insertText) and
//  the paste path (general pasteboard + paste:).
//

import XCTest
import AppKit
@testable import inter

@MainActor
final class CodeEditorIntegrityPropertyTests: XCTestCase {

    // MARK: - Seeded RNG (reproducible)

    /// Deterministic splitmix64 generator so a failing example is reproducible
    /// from the fixed seed.
    private struct SeededGenerator: RandomNumberGenerator {
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

    /// Tokens biased toward substitution-triggering content. Includes straight
    /// quotes, apostrophes, double hyphens, URLs, double spaces, and code
    /// punctuation — exactly what smart-quote/dash/link substitution would
    /// rewrite if it were enabled.
    private static let biasedTokens: [String] = [
        "\"", "\"", "'", "'", "--", "---", "  ", "    ",
        "http://example.com", "https://test.io/path?q=1&r=2", "www.site.com",
        "->", "=>", "===", "!=", "<=", ">=", "&&", "||",
        "{", "}", "[", "]", "(", ")",
        ";", ":", ",", ".", "...", "//", "/*", "*/",
        "let x = \"y\";", "a -- b", "don't", "can't",
        "func foo() {}", "1.5 -- 2.0", "name@host.com",
        "x", "y", "z", "0", "1", "_", " ", "\n", "\t",
        "café", "naïve", "x = y"
    ]

    private func randomString(using rng: inout SeededGenerator) -> String {
        let tokenCount = Int.random(in: 0...12, using: &rng)
        var result = ""
        for _ in 0..<tokenCount {
            result += Self.biasedTokens.randomElement(using: &rng) ?? "x"
        }
        return result
    }

    // MARK: - Configured text-view factory

    private func makeConfiguredTextView() -> SecureCodeTextView {
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

        // Apply the exact production secure configuration.
        let representable = CodeEditorTextView(viewModel: CodeEditorViewModel())
        representable.applySecureConfiguration(textView)
        return textView
    }

    // MARK: - Property 1

    // Feature: secure-tools-swiftui-migration, Property 1: For any input string (including characters that would normally trigger quote/dash/text substitution, autocorrect, or data/link detection), entering or pasting it into the Code_Editor results in stored characters exactly equal to the input, with no substitution applied.
    func testLiteralTextIntegrity() {
        var rng = SeededGenerator(seed: 0xC0DE_ED17_0001)
        let iterations = 200

        for i in 0..<iterations {
            let input = randomString(using: &rng)

            // --- Typing path: insertText through the substitution pipeline. ---
            let typingView = makeConfiguredTextView()
            let fullRange = NSRange(location: 0, length: (typingView.string as NSString).length)
            typingView.insertText(input, replacementRange: fullRange)
            XCTAssertEqual(
                typingView.string, input,
                "Typing path (iteration \(i), seed 0xC0DEED170001): stored text differs from input. Input: \(debugRepr(input))")

            // --- Paste path: general pasteboard + paste:. ---
            let pasteView = makeConfiguredTextView()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(input, forType: .string)
            pasteView.selectAll(nil)
            pasteView.paste(nil)
            XCTAssertEqual(
                pasteView.string, input,
                "Paste path (iteration \(i), seed 0xC0DEED170001): stored text differs from input. Input: \(debugRepr(input))")
        }
    }

    /// Renders a string with escapes so a failing example is unambiguous in logs.
    private func debugRepr(_ s: String) -> String {
        return "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            + "\""
    }
}
