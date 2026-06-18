//
//  CodeEditorViewModelDiffTests.swift
//  interTests
//
//  Unit tests for the load-bearing local-edit → RGA-ops translation helpers in
//  CodeEditorViewModel: `characterDiff` (Character-grained, the basis for
//  localInsert/localDelete) and `utf16Diff` (UTF-16-grained, the basis for
//  caret preservation). A regression in either silently corrupts collaborative
//  edits, so these lock down the single-change-region contract and the
//  reconstruct-old→new invariant.
//
//  Validates: Requirements 2.1, 2.5
//

import XCTest
@testable import inter

@MainActor
final class CodeEditorViewModelDiffTests: XCTestCase {

    // Apply a characterDiff back onto `old` and assert it reproduces `new`.
    private func reconstruct(_ old: String, _ d: (offset: Int, deleted: Int, inserted: String)) -> String {
        let chars = Array(old)
        let pre = String(chars[0 ..< d.offset])
        let post = String(chars[(d.offset + d.deleted)...])
        return pre + d.inserted + post
    }

    private func assertDiffReconstructs(_ old: String, _ new: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let d = CodeEditorViewModel.characterDiff(old: old, new: new)
        XCTAssertEqual(reconstruct(old, d), new,
                       "diff must reconstruct new from old", file: file, line: line)
    }

    // MARK: - characterDiff: single-region shape

    func testInsertAtEnd() {
        let d = CodeEditorViewModel.characterDiff(old: "let x", new: "let x = 1")
        XCTAssertEqual(d.offset, 5)
        XCTAssertEqual(d.deleted, 0)
        XCTAssertEqual(d.inserted, " = 1")
    }

    func testInsertAtStart() {
        let d = CodeEditorViewModel.characterDiff(old: "bar", new: "foobar")
        XCTAssertEqual(d.offset, 0)
        XCTAssertEqual(d.deleted, 0)
        XCTAssertEqual(d.inserted, "foo")
    }

    func testInsertInMiddle() {
        let d = CodeEditorViewModel.characterDiff(old: "ac", new: "abc")
        XCTAssertEqual(d.offset, 1)
        XCTAssertEqual(d.deleted, 0)
        XCTAssertEqual(d.inserted, "b")
    }

    func testPureDelete() {
        let d = CodeEditorViewModel.characterDiff(old: "abcdef", new: "abef")
        XCTAssertEqual(d.offset, 2)
        XCTAssertEqual(d.deleted, 2)   // "cd"
        XCTAssertEqual(d.inserted, "")
    }

    func testReplaceRegion() {
        let d = CodeEditorViewModel.characterDiff(old: "color: red", new: "color: blue")
        XCTAssertEqual(d.offset, 7)
        XCTAssertEqual(d.deleted, 3)   // "red"
        XCTAssertEqual(d.inserted, "blue")
    }

    func testNoChangeProducesEmptyDiff() {
        let d = CodeEditorViewModel.characterDiff(old: "same", new: "same")
        XCTAssertEqual(d.deleted, 0)
        XCTAssertEqual(d.inserted, "")
    }

    func testFullClear() {
        let d = CodeEditorViewModel.characterDiff(old: "wipe", new: "")
        XCTAssertEqual(d.offset, 0)
        XCTAssertEqual(d.deleted, 4)
        XCTAssertEqual(d.inserted, "")
    }

    func testFromEmpty() {
        let d = CodeEditorViewModel.characterDiff(old: "", new: "hello")
        XCTAssertEqual(d.offset, 0)
        XCTAssertEqual(d.deleted, 0)
        XCTAssertEqual(d.inserted, "hello")
    }

    // MARK: - reconstruct invariant across varied edits (incl. shared affixes)

    func testReconstructInvariant() {
        let cases: [(String, String)] = [
            ("", "x"),
            ("x", ""),
            ("abc", "aXbc"),
            ("abcabc", "abXabc"),         // ambiguous prefix/suffix overlap
            ("hello world", "hello brave world"),
            ("123456", "1456"),
            ("repeat repeat", "repeat"),
            ("aaa", "aaaa"),
            ("aaaa", "aaa"),
        ]
        for (old, new) in cases { assertDiffReconstructs(old, new) }
    }

    // MARK: - emoji / non-BMP: Character-grained offsets stay character-based

    func testCharacterGrainedWithEmoji() {
        // Inserting after a non-BMP emoji: the Character offset is 2 (😀 + space),
        // NOT the UTF-16 offset (which would be 3).
        let d = CodeEditorViewModel.characterDiff(old: "😀 ", new: "😀 hi")
        XCTAssertEqual(d.offset, 2)
        XCTAssertEqual(d.inserted, "hi")
        assertDiffReconstructs("😀 ", "😀 hi")
    }

    // MARK: - utf16Diff: UTF-16-grained region for caret math

    func testUTF16DiffPlainInsert() {
        let d = CodeEditorViewModel.utf16Diff(old: "let x" as NSString, new: "let x = 1" as NSString)
        XCTAssertEqual(d.offset, 5)
        XCTAssertEqual(d.deleted, 0)
        XCTAssertEqual(d.inserted, 4)
    }

    func testUTF16DiffCountsUTF16UnitsForEmoji() {
        // A non-BMP emoji is 2 UTF-16 units, so an insert after it lands at
        // offset 3 in UTF-16 space (vs 2 in Character space).
        let d = CodeEditorViewModel.utf16Diff(old: "😀 " as NSString, new: "😀 hi" as NSString)
        XCTAssertEqual(d.offset, 3, "UTF-16 prefix length includes the surrogate pair")
        XCTAssertEqual(d.deleted, 0)
        XCTAssertEqual(d.inserted, 2)
    }
}
