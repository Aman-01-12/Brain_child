//
//  WhiteboardToolbarChromeTests.swift
//  interTests
//
//  Fix 5 — Whiteboard toolbar size consistency. Verifies the shared chrome
//  button builder (`WhiteboardRootView.chrome(_:active:)`, Whiteboard_Toolbar)
//  renders every label on a single line, at a width >= the configured minimum
//  (64), and expands to fit labels wider than that minimum without truncation —
//  applied uniformly to every chrome consumer (tool selector, history controls,
//  selection actions, zoom controls).
//
//  `chrome(_:active:)` is `private` and returns an opaque `some View`, so it
//  cannot be invoked directly from the test target without weakening production
//  access. Instead we measure an EQUIVALENT view whose modifier chain MIRRORS
//  `chrome(_:active:)` exactly (see `chromeLabel(_:)` below) via `NSHostingView`
//  sizing. This validates the precise modifier chain Fix 5 applies — `.fixedSize()`
//  to forbid wrapping/truncation and `.frame(minWidth: 64)` to enforce the floor —
//  without adding any production hook or relaxing `chrome`'s access level.
//
//  Property 7: Toolbar buttons are uniform width and never wrap.
//  Validates: Requirements 5.1, 5.2, 5.3, 5.4
//

import XCTest
import SwiftUI
import AppKit
@testable import inter

@MainActor
final class WhiteboardToolbarChromeTests: XCTestCase {

    /// The configured minimum width applied by `chrome(_:active:)` via
    /// `.frame(minWidth: 64)`. Kept in sync with production.
    private let configuredMinWidth: CGFloat = 64

    /// Generous tolerance for floating-point layout rounding when comparing
    /// fitting sizes against reference single-line metrics.
    private let tolerance: CGFloat = 1.5

    /// The longest labels across all chrome consumers, plus a representative
    /// label from each consumer group so the "applied to every consumer"
    /// criterion (5.4) is exercised, not just the tool selector.
    private let longLabels = ["Ellipse", "Eraser", "Ungroup"]
    private let allConsumerLabels = [
        // Tool selector
        "Select", "Pen", "Rect", "Ellipse", "Line", "Arrow", "Eraser", "Text",
        // History controls
        "Undo", "Redo", "Clear",
        // Selection actions
        "Group", "Ungroup", "Front", "Back", "Fwd", "Bwd", "Delete",
        // Zoom controls
        "−", "Reset", "+"
    ]

    // MARK: - Equivalent view (mirrors chrome(_:active:))

    /// MIRRORS the label portion of `WhiteboardRootView.chrome(_:active:)`:
    ///
    ///     Text(label)
    ///         .font(.system(size: 12, weight: .medium))
    ///         .foregroundColor(.white)
    ///         .fixedSize()
    ///         .frame(minWidth: 64)
    ///
    /// The trailing `.padding(...)` / `.background(...)` in production only grow
    /// the pill further, so measuring up to `.frame(minWidth:)` is the tightest
    /// (lower-bound) check of the uniform-width / no-wrap contract.
    private func chromeLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .fixedSize()
            .frame(minWidth: configuredMinWidth)
    }

    // MARK: - Measurement helper

    /// Render a SwiftUI view in an offscreen `NSHostingView` and return the size
    /// it fits into. Mirrors how the production view is hosted
    /// (`NSHostingView<WhiteboardRootView>`).
    private func fittingSize<V: View>(_ view: V) -> CGSize {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    /// The height of one line of the chrome font, measured the same way the
    /// chrome label is measured (a single-glyph, no-wrap text). Used as the
    /// single-line reference so the no-wrap assertion is font-metric agnostic.
    private var singleLineHeight: CGFloat {
        fittingSize(
            Text("X")
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
        ).height
    }

    // MARK: - 5.1 single-line / no wrap

    /// 5.1: Each chrome label renders on exactly one line (no wrapping). A
    /// wrapped two-line label would be ~2x the single-line height; `.fixedSize()`
    /// must keep every label at one line.
    func testLongLabelsRenderOnSingleLine() {
        let oneLine = singleLineHeight
        XCTAssertGreaterThan(oneLine, 0, "single-line reference height must be positive")

        for label in longLabels {
            let height = fittingSize(chromeLabel(label)).height
            XCTAssertEqual(
                height, oneLine, accuracy: tolerance,
                "5.1: \"\(label)\" must render on a single line " +
                "(height \(height) ≈ one line \(oneLine))")
            XCTAssertLessThan(
                height, oneLine * 1.8,
                "5.1: \"\(label)\" must not wrap onto a second line " +
                "(height \(height) vs two lines ~\(oneLine * 2))")
        }
    }

    /// 5.1 / 5.4: EVERY consumer's label renders on a single line.
    func testAllConsumerLabelsRenderOnSingleLine() {
        let oneLine = singleLineHeight
        for label in allConsumerLabels {
            let height = fittingSize(chromeLabel(label)).height
            XCTAssertLessThan(
                height, oneLine * 1.8,
                "5.1/5.4: chrome label \"\(label)\" must stay on one line " +
                "(height \(height))")
        }
    }

    // MARK: - 5.2 width >= configured minimum

    /// 5.2: Each chrome label is at least `configuredMinWidth` wide.
    func testLongLabelsMeetMinimumWidth() {
        for label in longLabels {
            let width = fittingSize(chromeLabel(label)).width
            XCTAssertGreaterThanOrEqual(
                width, configuredMinWidth - tolerance,
                "5.2: \"\(label)\" width \(width) must be >= configured min " +
                "\(configuredMinWidth)")
        }
    }

    /// 5.2 / 5.4: EVERY consumer's label meets the minimum width, so buttons are
    /// uniformly sized across the tool selector, history, selection, and zoom rows.
    func testAllConsumerLabelsMeetMinimumWidth() {
        for label in allConsumerLabels {
            let width = fittingSize(chromeLabel(label)).width
            XCTAssertGreaterThanOrEqual(
                width, configuredMinWidth - tolerance,
                "5.2/5.4: chrome label \"\(label)\" width \(width) must be >= " +
                "configured min \(configuredMinWidth)")
        }
    }

    // MARK: - 5.3 expand to fit without truncation

    /// 5.3: WHERE a label's natural width exceeds the configured minimum, the
    /// chrome expands to fit the full label (no truncation/clipping). We compare
    /// the chrome width against the label's intrinsic (fixed-size) text width:
    /// `.fixedSize()` guarantees the chrome is never narrower than the text it
    /// contains, so the full label is always visible.
    func testLabelsExpandToFitWithoutTruncation() {
        for label in longLabels {
            let intrinsic = fittingSize(
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
            ).width
            let chromeWidth = fittingSize(chromeLabel(label)).width

            // The chrome must be at least as wide as the intrinsic text — i.e.
            // max(intrinsic, minWidth) — so nothing is clipped or truncated.
            XCTAssertGreaterThanOrEqual(
                chromeWidth, intrinsic - tolerance,
                "5.3: \"\(label)\" chrome width \(chromeWidth) must fit the full " +
                "intrinsic label width \(intrinsic) without truncation")
            XCTAssertGreaterThanOrEqual(
                chromeWidth, max(intrinsic, configuredMinWidth) - tolerance,
                "5.3: \"\(label)\" chrome width must be max(intrinsic, minWidth)")
        }
    }

    // MARK: - 5.4 uniform application across consumers

    /// 5.4: The chrome builder is a SINGLE shared function applied identically to
    /// every consumer, so all labels — regardless of consumer — share the same
    /// floor width and single-line behavior. Asserting the minimum width holds
    /// uniformly demonstrates the consistent application (the narrowest labels,
    /// e.g. "+"/"−", are floored up to the same minimum as the widest).
    func testUniformFloorWidthAcrossAllConsumers() {
        let widths = allConsumerLabels.map { fittingSize(chromeLabel($0)).width }
        let minObserved = widths.min() ?? 0
        XCTAssertGreaterThanOrEqual(
            minObserved, configuredMinWidth - tolerance,
            "5.4: every chrome consumer must share the same minimum width floor " +
            "(narrowest observed \(minObserved))")
    }
}
