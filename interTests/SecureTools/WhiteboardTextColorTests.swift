//
//  WhiteboardTextColorTests.swift
//  interTests
//
//  Fix 4 (collab-tool-ux-fixes spec): "colored text edits show in the element's
//  color, not white." This file proves the load-bearing, UNIT-REACHABLE parts of
//  design Correctness Property 6 / Requirements 4.1–4.5:
//
//    - 4.3 / 4.5 (KEY PROPERTY): the AppKit `nsColor(for:)` mapping produces the
//      SAME RGB as the SwiftUI `swiftUIColor(for:)` mapping for EVERY
//      `WhiteboardColor` case, so the inline field editor (AppKit) and the canvas
//      (SwiftUI) render identical ink. Exhaustiveness over `WhiteboardColor` is
//      asserted implicitly by iterating `WhiteboardColor.allCases` (the mapping's
//      `switch` has no `default`, so totality is also enforced at compile time).
//    - 4.2 (boundary): a newly committed text element carries `activeColor` as its
//      `strokeColor` — the same value `openTextEntry` seeds the overlay from for a
//      NEW edit — so the new-text seed source is correct at the model boundary.
//    - 4.1 (boundary): the re-open seed source, `editableTextElement(atWorld:)`,
//      returns the element whose `strokeColor` `openTextEntry` copies into the
//      overlay; we assert that source value round-trips through `nsColor(for:)`.
//    - 4.4: committing an edit to an existing element leaves its `strokeColor`
//      unchanged (`commitText` updates only `.text`/`.frame`).
//
//  REACHABILITY NOTE (intentionally NOT tested here):
//    `WhiteboardRootView.openTextEntry(atScreen:)` and the `@State textEntryColor`
//    it seeds are PRIVATE to the SwiftUI view and are not unit-accessible without
//    weakening production access modifiers (which this task must not do). The
//    seeding *behavior* (re-open → element.strokeColor, new → activeColor) is only
//    fully verifiable through the UI. We instead assert the publicly reachable
//    data SOURCES that `openTextEntry` reads from (`editableTextElement(...)`,
//    `viewModel.activeColor`) and the color mapping it pushes into the overlay,
//    which is the meaningful, regression-catching surface.
//
//  This project integrates no external PBT library; per the established
//  convention (see `BoardDocumentPropertyTests`, `StrokeModelPropertyTests`) the
//  property sweep is a fixed-seed deterministic SplitMix64 XCTest loop so any
//  counterexample is reproducible.
//

import AppKit
import SwiftUI
import XCTest
@testable import inter

// MARK: - Deterministic, seeded RNG
//
// Distinctly named so it does not collide with the SplitMix64 generators already
// declared in sibling test files in this target.

private struct ColorPBTGenerator: RandomNumberGenerator {
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

/// Minimum iterations for the seeded parity sweep (repo convention: ≥100).
private let kColorIterations = 150

/// Tolerance for an sRGB component comparison. The chromatic cases share the
/// exact same numeric triple on both sides (sRGB), so they match to <1e-3; the
/// gray cases (`.white`/`.black`) differ only by the gray→sRGB gamma conversion,
/// which is negligible near the 0.0 and ~1.0 endpoints these cases use.
private let kRGBEpsilon: CGFloat = 0.02

// MARK: - Color comparison helpers

/// Resolve an `NSColor` into the sRGB color space and return its RGBA components.
private func srgbComponents(_ color: NSColor, file: StaticString = #file, line: UInt = #line) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    guard let c = color.usingColorSpace(.sRGB) else {
        XCTFail("could not convert \(color) to sRGB", file: file, line: line)
        return (0, 0, 0, 0)
    }
    return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
}

/// Assert two `NSColor`s match component-wise in sRGB within `kRGBEpsilon`.
private func assertSameRGB(_ lhs: NSColor, _ rhs: NSColor, _ message: String,
                           file: StaticString = #file, line: UInt = #line) {
    let a = srgbComponents(lhs, file: file, line: line)
    let b = srgbComponents(rhs, file: file, line: line)
    XCTAssertEqual(a.r, b.r, accuracy: kRGBEpsilon, "\(message) — red", file: file, line: line)
    XCTAssertEqual(a.g, b.g, accuracy: kRGBEpsilon, "\(message) — green", file: file, line: line)
    XCTAssertEqual(a.b, b.b, accuracy: kRGBEpsilon, "\(message) — blue", file: file, line: line)
    XCTAssertEqual(a.a, b.a, accuracy: kRGBEpsilon, "\(message) — alpha", file: file, line: line)
}

@MainActor
final class WhiteboardTextColorTests: XCTestCase {

    // MARK: - Property 6: nsColor(for:) RGB-matches swiftUIColor(for:)
    //
    // Validates: Requirements 4.3, 4.5

    /// Exhaustive pass over EVERY `WhiteboardColor` case: the AppKit mapping must
    /// produce the same RGB as the SwiftUI mapping (converted to a common sRGB
    /// space). Iterating `allCases` also implicitly asserts exhaustiveness — a new
    /// case would be swept here and the production `switch` (no `default`) would
    /// fail to compile until mapped.
    func testProperty6_NSColorMatchesSwiftUIColor_AllCases() {
        XCTAssertFalse(WhiteboardColor.allCases.isEmpty, "WhiteboardColor must expose its cases")

        for color in WhiteboardColor.allCases {
            let ns = WhiteboardRootView.nsColor(for: color)
            let swiftUI = NSColor(WhiteboardRootView.swiftUIColor(for: color))
            assertSameRGB(ns, swiftUI,
                          "nsColor(for: \(color)) must RGB-match swiftUIColor(for: \(color))")
        }
    }

    /// Seeded sweep (≥100 iterations) over randomly drawn cases, per the repo's
    /// SplitMix64 convention, so any parity counterexample is reproducible.
    func testProperty6_NSColorMatchesSwiftUIColor_SeededSweep() {
        let base: UInt64 = 0xC010_0006_0000
        for i in 0..<kColorIterations {
            let seed = base &+ UInt64(i)
            var rng = ColorPBTGenerator(seed: seed)
            let color = WhiteboardColor.allCases.randomElement(using: &rng)!
            let ns = WhiteboardRootView.nsColor(for: color)
            let swiftUI = NSColor(WhiteboardRootView.swiftUIColor(for: color))
            assertSameRGB(ns, swiftUI,
                          "parity failed: seed=0x\(String(seed, radix: 16)) iteration=\(i) color=\(color)")
        }
    }

    /// Each case must resolve to a concrete (sRGB-convertible) opaque color — i.e.
    /// the mapping returns a configured color for every case, never a degenerate
    /// fully-transparent default.
    func testProperty6_NSColorIsConfiguredForEveryCase() {
        for color in WhiteboardColor.allCases {
            let comps = srgbComponents(WhiteboardRootView.nsColor(for: color))
            XCTAssertEqual(comps.a, 1.0, accuracy: 1e-6,
                           "nsColor(for: \(color)) must be fully opaque")
        }
    }

    // MARK: - 4.2 (boundary): new text uses activeColor
    //
    // `openTextEntry` seeds the overlay from `viewModel.activeColor` for a NEW
    // edit, and `commitText` creates the element with `strokeColor: activeColor`.
    // Asserting the committed element's color == activeColor verifies the new-text
    // seed source is consistent with what is persisted.

    func testNewTextElementUsesActiveColor() {
        for color in WhiteboardColor.allCases {
            let vm = WhiteboardViewModel()
            vm.activeColor = color
            vm.commitText("hello", atWorld: CGPoint(x: 100, y: 100), editing: nil)

            let texts = vm.renderedElements.filter { $0.kind == .text }
            XCTAssertEqual(texts.count, 1, "exactly one text element after a new commit (color=\(color))")
            XCTAssertEqual(texts.first?.strokeColor, color,
                           "a newly committed text element must adopt activeColor=\(color)")
        }
    }

    // MARK: - 4.1 (boundary): re-open seed source round-trips through nsColor
    //
    // `openTextEntry` seeds the overlay from `existing.strokeColor`, where
    // `existing == editableTextElement(atWorld:)`. We assert that source element's
    // color is what would be shown and that it maps through `nsColor(for:)`
    // identically to the canvas mapping.

    func testReopenSeedSourceReflectsElementColor() {
        let nonWhite: [WhiteboardColor] = WhiteboardColor.allCases.filter { $0 != .white }
        for color in nonWhite {
            let vm = WhiteboardViewModel()
            vm.activeColor = color
            let world = CGPoint(x: 100, y: 100)
            vm.commitText("colored", atWorld: world, editing: nil)

            guard let element = vm.renderedElements.first(where: { $0.kind == .text }),
                  let frame = element.frame else {
                XCTFail("expected a committed text element with a frame (color=\(color))")
                continue
            }

            // The seed source `openTextEntry` reads on re-open.
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let reopened = vm.editableTextElement(atWorld: center)
            XCTAssertEqual(reopened?.id, element.id,
                           "re-open must resolve the same element under its center (color=\(color))")
            XCTAssertEqual(reopened?.strokeColor, color,
                           "re-open seed color must be the element's strokeColor=\(color)")

            // The overlay would show nsColor(for: that strokeColor); it must equal
            // the canvas color for the same case — i.e. NOT hardcoded white.
            assertSameRGB(WhiteboardRootView.nsColor(for: reopened!.strokeColor),
                          NSColor(WhiteboardRootView.swiftUIColor(for: color)),
                          "re-open overlay color must match the canvas color (color=\(color))")
        }
    }

    // MARK: - 4.4: commit leaves strokeColor unchanged
    //
    // `commitText(editing:)` updates only `.text`/`.frame`, so a colored element
    // keeps its `strokeColor` across edits — the canvas color the overlay was
    // seeded from is preserved on commit.

    func testCommitEditPreservesStrokeColor() {
        let nonWhite: [WhiteboardColor] = WhiteboardColor.allCases.filter { $0 != .white }
        for color in nonWhite {
            let vm = WhiteboardViewModel()
            vm.activeColor = color
            let world = CGPoint(x: 100, y: 100)
            vm.commitText("first", atWorld: world, editing: nil)

            guard let original = vm.renderedElements.first(where: { $0.kind == .text }) else {
                XCTFail("expected a committed text element (color=\(color))")
                continue
            }
            XCTAssertEqual(original.strokeColor, color)

            // Re-commit (edit) the SAME element with different text while the active
            // color has since changed — the element's color must NOT follow it.
            vm.activeColor = .white
            vm.commitText("edited text", atWorld: world, editing: original.id)

            let edited = vm.renderedElements.first { $0.id == original.id }
            XCTAssertEqual(edited?.text, "edited text",
                           "edit must update the text (color=\(color))")
            XCTAssertEqual(edited?.strokeColor, color,
                           "commit must leave strokeColor unchanged (was \(color))")
        }
    }
}
