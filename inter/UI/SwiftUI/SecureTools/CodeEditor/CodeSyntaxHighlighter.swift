//
//  CodeSyntaxHighlighter.swift
//  inter
//
//  Native, dependency-light syntax highlighter for the secure code editor
//  (Code_Editor). This is the R1.2 / R1.4 highlighter: a PURE function
//  `(text, language) -> [(range, tokenType)]` plus a thin applier that writes
//  `NSAttributedString` colour attributes over the editor's existing
//  `NSTextStorage`. It NEVER mutates characters — only the `.foregroundColor`
//  attribute — so it cannot alter the synced text (R1.4, R5.3).
//
//  There is deliberately NO web/JS runtime here (R5.1): tokenisation is a
//  single-pass regular-grammar scanner over the document's characters, driven
//  by a per-language table (keywords / built-in types / comment + string
//  delimiters). A tree-sitter-class backend is a possible future enhancement
//  but must remain non-web.
//
//  The scanner tracks UTF-16 offsets so the emitted `NSRange`s line up exactly
//  with `NSTextStorage` (whose ranges are UTF-16 based).
//

import AppKit

// MARK: - Token + language model

/// The syntactic classes the highlighter recognises. `plain` is never emitted
/// (un-tokenised spans simply keep the editor's default text colour).
enum CodeTokenType: Equatable {
    case keyword
    case type
    case string
    case comment
    case number
}

/// The languages offered by the editor's selector (R1.3). `rawValue` is stable
/// for persistence/wire use; `displayName` is what the picker shows and what the
/// view model's `language` register stores.
enum CodeLanguage: String, CaseIterable, Identifiable {
    case python
    case javascript
    case typescript
    case java
    case cpp
    case c
    case go
    case plainText

    var id: String { rawValue }

    /// Human-facing name shown in the language selector and stored in the view
    /// model's shared `language` register.
    var displayName: String {
        switch self {
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .java: return "Java"
        case .cpp: return "C++"
        case .c: return "C"
        case .go: return "Go"
        case .plainText: return "Plain text"
        }
    }

    /// Resolve a display name (the view model's `language` value) back to a
    /// language case, defaulting to `.plainText` for anything unrecognised.
    static func fromDisplayName(_ name: String) -> CodeLanguage {
        CodeLanguage.allCases.first { $0.displayName == name } ?? .plainText
    }
}

// MARK: - Per-language grammar

/// A regular-grammar description of a language: enough to colour keywords,
/// built-in types, strings, comments, and numbers without a parser.
private struct LanguageGrammar {
    let keywords: Set<String>
    let types: Set<String>
    /// Line-comment lead-ins (e.g. `//`, `#`).
    let lineComments: [String]
    /// Block-comment delimiters (e.g. `/* */`), if any.
    let blockComment: (open: String, close: String)?
    /// Quote characters that open/close a single-line string.
    let stringDelimiters: Set<Character>
    /// Whether the language has triple-quoted strings (Python `"""` / `'''`).
    let tripleQuoted: Bool
    /// Whether the language has backtick strings that may span lines
    /// (JS/TS template literals, Go raw strings).
    let backtickStrings: Bool
    /// Colour identifiers that begin with an uppercase letter as types
    /// (class/struct names in Java, C++, Go, TS, …).
    let uppercaseIsType: Bool
}

// MARK: - Highlighter

enum CodeSyntaxHighlighter {

    // MARK: Theme colours (dark)

    /// The default editor text colour (white @ 0.94), used to reset a range
    /// before re-applying token colours. Mirrors `CodeEditorTextView`.
    static let defaultTextColor = NSColor(calibratedWhite: 0.94, alpha: 1.0)

    private static let keywordColor = NSColor(srgbRed: 0.78, green: 0.47, blue: 0.87, alpha: 1.0)
    private static let typeColor    = NSColor(srgbRed: 0.31, green: 0.78, blue: 0.82, alpha: 1.0)
    private static let stringColor  = NSColor(srgbRed: 0.81, green: 0.57, blue: 0.47, alpha: 1.0)
    private static let commentColor = NSColor(srgbRed: 0.42, green: 0.60, blue: 0.33, alpha: 1.0)
    private static let numberColor  = NSColor(srgbRed: 0.71, green: 0.81, blue: 0.66, alpha: 1.0)

    static func color(for token: CodeTokenType) -> NSColor {
        switch token {
        case .keyword: return keywordColor
        case .type: return typeColor
        case .string: return stringColor
        case .comment: return commentColor
        case .number: return numberColor
        }
    }

    // MARK: Apply attributes (R1.2, R1.4)

    /// Re-colour `range` of `textStorage` for `language`: reset the range to the
    /// default colour, then apply token colours. Attribute-only — never mutates
    /// characters (R1.4). `range` is whole-buffer on a language change and the
    /// changed paragraph(s) on an edit. Out-of-bounds ranges are clamped.
    static func applyHighlighting(to textStorage: NSTextStorage,
                                  language: CodeLanguage,
                                  in range: NSRange) {
        let full = NSRange(location: 0, length: textStorage.length)
        let clamped = NSIntersectionRange(range, full)
        guard clamped.length > 0 else { return }

        textStorage.beginEditing()
        textStorage.removeAttribute(.foregroundColor, range: clamped)
        textStorage.addAttribute(.foregroundColor, value: defaultTextColor, range: clamped)

        if language != .plainText {
            let substring = (textStorage.string as NSString).substring(with: clamped)
            for token in tokens(for: substring, language: language) {
                let actual = NSRange(location: clamped.location + token.range.location,
                                     length: token.range.length)
                textStorage.addAttribute(.foregroundColor,
                                         value: color(for: token.type),
                                         range: actual)
            }
        }
        textStorage.endEditing()
    }

    // MARK: Pure tokeniser (R1.2)

    /// The pure highlighting function: classify `text` for `language` into a
    /// list of `(UTF-16 range, token type)`. Deterministic and side-effect free
    /// — the unit of behaviour the design specifies for R1.2. Returns an empty
    /// list for `.plainText`.
    static func tokens(for text: String,
                       language: CodeLanguage) -> [(range: NSRange, type: CodeTokenType)] {
        guard language != .plainText else { return [] }
        let grammar = grammar(for: language)

        let chars = Array(text)
        let n = chars.count
        guard n > 0 else { return [] }

        // Prefix sum of UTF-16 lengths so a character index maps to a UTF-16
        // offset in O(1).
        var u16Start = [Int](repeating: 0, count: n + 1)
        for k in 0 ..< n {
            u16Start[k + 1] = u16Start[k] + String(chars[k]).utf16.count
        }
        func rangeFor(_ start: Int, _ end: Int) -> NSRange {
            NSRange(location: u16Start[start], length: u16Start[end] - u16Start[start])
        }

        var result: [(range: NSRange, type: CodeTokenType)] = []
        var i = 0

        func matches(_ s: String, at idx: Int) -> Bool {
            let sc = Array(s)
            guard idx + sc.count <= n else { return false }
            for k in 0 ..< sc.count where chars[idx + k] != sc[k] { return false }
            return true
        }

        while i < n {
            let c = chars[i]

            // Line comment.
            if let lead = grammar.lineComments.first(where: { matches($0, at: i) }) {
                let start = i
                i += lead.count
                while i < n && chars[i] != "\n" { i += 1 }
                result.append((rangeFor(start, i), .comment))
                continue
            }

            // Block comment.
            if let block = grammar.blockComment, matches(block.open, at: i) {
                let start = i
                i += block.open.count
                while i < n && !matches(block.close, at: i) { i += 1 }
                if i < n { i += block.close.count }
                result.append((rangeFor(start, i), .comment))
                continue
            }

            // Triple-quoted string (Python).
            if grammar.tripleQuoted, c == "\"" || c == "'" {
                let triple = String(repeating: String(c), count: 3)
                if matches(triple, at: i) {
                    let start = i
                    i += 3
                    while i < n && !matches(triple, at: i) { i += 1 }
                    if i < n { i += 3 }
                    result.append((rangeFor(start, i), .string))
                    continue
                }
            }

            // Single-line / backtick string.
            if grammar.stringDelimiters.contains(c) || (grammar.backtickStrings && c == "`") {
                let quote = c
                let multiline = (quote == "`")
                let start = i
                i += 1
                while i < n {
                    if chars[i] == "\\" { i += min(2, n - i); continue }
                    if chars[i] == quote { i += 1; break }
                    if !multiline && chars[i] == "\n" { break }
                    i += 1
                }
                result.append((rangeFor(start, i), .string))
                continue
            }

            // Number literal.
            if c.isNumber || (c == "." && i + 1 < n && chars[i + 1].isNumber) {
                let start = i
                i += 1
                while i < n {
                    let d = chars[i]
                    if d.isHexDigit || d == "." || d == "_" || d == "x" || d == "X"
                        || d == "e" || d == "E" || d == "b" || d == "o" {
                        i += 1
                    } else {
                        break
                    }
                }
                result.append((rangeFor(start, i), .number))
                continue
            }

            // Identifier / keyword / type.
            if c.isLetter || c == "_" {
                let start = i
                i += 1
                while i < n && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                let word = String(chars[start ..< i])
                if grammar.keywords.contains(word) {
                    result.append((rangeFor(start, i), .keyword))
                } else if grammar.types.contains(word)
                            || (grammar.uppercaseIsType && (word.first?.isUppercase ?? false)) {
                    result.append((rangeFor(start, i), .type))
                }
                continue
            }

            i += 1
        }

        return result
    }

    // MARK: Grammar tables

    private static func grammar(for language: CodeLanguage) -> LanguageGrammar {
        switch language {
        case .python:
            return LanguageGrammar(
                keywords: [
                    "def", "return", "if", "elif", "else", "for", "while", "in", "not",
                    "and", "or", "import", "from", "as", "class", "try", "except", "finally",
                    "with", "lambda", "yield", "pass", "break", "continue", "global",
                    "nonlocal", "is", "del", "raise", "assert", "async", "await",
                    "True", "False", "None",
                ],
                types: ["int", "float", "str", "bool", "list", "dict", "tuple", "set",
                        "bytes", "object", "type", "complex", "frozenset", "bytearray"],
                lineComments: ["#"],
                blockComment: nil,
                stringDelimiters: ["\"", "'"],
                tripleQuoted: true,
                backtickStrings: false,
                uppercaseIsType: false)

        case .javascript:
            return LanguageGrammar(
                keywords: jsKeywords,
                types: [],
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "'"],
                tripleQuoted: false,
                backtickStrings: true,
                uppercaseIsType: true)

        case .typescript:
            return LanguageGrammar(
                keywords: jsKeywords.union([
                    "interface", "type", "enum", "implements", "public", "private",
                    "protected", "readonly", "namespace", "declare", "abstract",
                    "keyof", "infer", "is", "asserts", "satisfies",
                ]),
                types: ["string", "number", "boolean", "any", "unknown", "never", "void",
                        "object", "symbol", "bigint", "undefined", "null"],
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "'"],
                tripleQuoted: false,
                backtickStrings: true,
                uppercaseIsType: true)

        case .java:
            return LanguageGrammar(
                keywords: [
                    "abstract", "assert", "boolean", "break", "byte", "case", "catch",
                    "char", "class", "const", "continue", "default", "do", "double",
                    "else", "enum", "extends", "final", "finally", "float", "for", "goto",
                    "if", "implements", "import", "instanceof", "int", "interface", "long",
                    "native", "new", "package", "private", "protected", "public", "return",
                    "short", "static", "strictfp", "super", "switch", "synchronized",
                    "this", "throw", "throws", "transient", "try", "void", "volatile",
                    "while", "true", "false", "null", "var", "record", "sealed", "yield",
                ],
                types: [],
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "'"],
                tripleQuoted: false,
                backtickStrings: false,
                uppercaseIsType: true)

        case .cpp:
            return LanguageGrammar(
                keywords: [
                    "alignas", "alignof", "and", "asm", "auto", "bool", "break", "case",
                    "catch", "char", "class", "const", "constexpr", "continue", "decltype",
                    "default", "delete", "do", "double", "else", "enum", "explicit",
                    "export", "extern", "false", "float", "for", "friend", "goto", "if",
                    "inline", "int", "long", "mutable", "namespace", "new", "noexcept",
                    "nullptr", "operator", "private", "protected", "public", "register",
                    "return", "short", "signed", "sizeof", "static", "struct", "switch",
                    "template", "this", "throw", "true", "try", "typedef", "typename",
                    "union", "unsigned", "using", "virtual", "void", "volatile", "while",
                ],
                types: ["size_t", "string", "vector", "map", "set", "wchar_t", "int8_t",
                        "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
                        "uint64_t"],
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "'"],
                tripleQuoted: false,
                backtickStrings: false,
                uppercaseIsType: true)

        case .c:
            return LanguageGrammar(
                keywords: [
                    "auto", "break", "case", "char", "const", "continue", "default", "do",
                    "double", "else", "enum", "extern", "float", "for", "goto", "if",
                    "inline", "int", "long", "register", "restrict", "return", "short",
                    "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
                    "unsigned", "void", "volatile", "while", "_Bool",
                ],
                types: ["size_t", "wchar_t", "int8_t", "int16_t", "int32_t", "int64_t",
                        "uint8_t", "uint16_t", "uint32_t", "uint64_t", "FILE"],
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "'"],
                tripleQuoted: false,
                backtickStrings: false,
                uppercaseIsType: true)

        case .go:
            return LanguageGrammar(
                keywords: [
                    "break", "case", "chan", "const", "continue", "default", "defer",
                    "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
                    "interface", "map", "package", "range", "return", "select", "struct",
                    "switch", "type", "var", "nil", "true", "false", "iota",
                ],
                types: ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
                        "uint32", "uint64", "uintptr", "float32", "float64", "complex64",
                        "complex128", "string", "bool", "byte", "rune", "error"],
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "'"],
                tripleQuoted: false,
                backtickStrings: true,
                uppercaseIsType: true)

        case .plainText:
            return LanguageGrammar(
                keywords: [], types: [], lineComments: [], blockComment: nil,
                stringDelimiters: [], tripleQuoted: false, backtickStrings: false,
                uppercaseIsType: false)
        }
    }

    /// Shared base keyword set for JavaScript and TypeScript.
    private static let jsKeywords: Set<String> = [
        "var", "let", "const", "function", "return", "if", "else", "for", "while", "do",
        "switch", "case", "break", "continue", "new", "delete", "typeof", "instanceof",
        "in", "of", "this", "class", "extends", "super", "import", "export", "from",
        "default", "try", "catch", "finally", "throw", "async", "await", "yield", "void",
        "null", "undefined", "true", "false", "static", "get", "set",
    ]
}
