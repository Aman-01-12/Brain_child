//
//  InterDesignTokensTests.swift
//  interTests
//
//  Verifies the @objc tile-chrome token facade: every SF Symbol token resolves to a
//  real system symbol, metrics are positive, and the facade is wired to the canonical
//  token SSOT (DesignTokens.swift) rather than holding drifting copies.
//

import XCTest
import AppKit
@testable import inter

final class InterDesignTokensTests: XCTestCase {

    func testAllSymbolTokensResolveToRealSFSymbols() {
        for name in InterDesignTokens.allSymbolNames {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            XCTAssertNotNil(image, "SF Symbol token '\(name)' does not resolve to a real symbol")
        }
    }

    func testBadgeMetricsArePositive() {
        XCTAssertGreaterThan(InterDesignTokens.badgeSize, 0)
        XCTAssertGreaterThan(InterDesignTokens.badgeCornerRadius, 0)
        XCTAssertGreaterThan(InterDesignTokens.badgeSymbolPointSize, 0)
    }

    func testAccentColorsAreDistinct() {
        XCTAssertNotEqual(InterDesignTokens.accentDanger, InterDesignTokens.accentGold)
    }

    /// Locks the facade to the canonical SSOT: the accents must BE the catalogue's
    /// status hues, not independent copies that can drift.
    func testAccentsAreSourcedFromCanonicalStatusHues() {
        XCTAssertEqual(InterDesignTokens.accentDanger, InterStatus.danger)
        XCTAssertEqual(InterDesignTokens.accentGold, InterStatus.warning)
        XCTAssertEqual(InterDesignTokens.badgeCornerRadius, InterRadius.md)
    }

    /// Stage surfaces must come from the canonical InterColor SSOT (no drift), and the
    /// tile gradient ends must be distinct so the catalogue's tile look is preserved.
    func testStageAndTileTokensSourcedFromSSOT() {
        XCTAssertEqual(InterDesignTokens.stageBackground, InterColor.stage)
        XCTAssertEqual(InterDesignTokens.stageSurface, InterColor.stageSurface)
        XCTAssertEqual(InterDesignTokens.stageElevated, InterColor.stageElevated)
        XCTAssertEqual(InterDesignTokens.tileCornerRadius, InterRadius.lg)
        XCTAssertNotEqual(InterDesignTokens.tileGradientTop, InterDesignTokens.tileGradientBottom)
    }

    // MARK: - Foundation gate (Task 0): font + appearance

    /// General Sans must register from the bundle, not silently fall back to SF.
    func testGeneralSansResolvesNotSFFallback() {
        InterDesignTokens.registerFonts() // idempotent; self-contained
        let f = NSFont(name: "General Sans", size: 24)
        XCTAssertNotNil(f, "General Sans is not registered/bundled")
        XCTAssertEqual(f?.familyName, "General Sans",
                       "Font fell back to \(f?.familyName ?? "nil") — registration failed")
    }

    /// Stage colours are FIXED DARK — identical under both appearances.
    func testStageColorsAreAppearanceIndependent() {
        let d = resolve(InterColor.stageSurface, .darkAqua)
        let l = resolve(InterColor.stageSurface, .aqua)
        XCTAssertEqual(d, l, "stage-surface must not change with appearance")
    }

    /// Theme colours ARE appearance-aware — they must differ between light and dark.
    func testThemeColorsDoChangeWithAppearance() {
        let d = resolve(InterColor.background, .darkAqua)
        let l = resolve(InterColor.background, .aqua)
        XCTAssertNotEqual(d, l, "theme background must differ by appearance")
    }

    /// Resolve a (possibly dynamic) NSColor to concrete sRGB components under `name`.
    private func resolve(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var out: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)
        }
        return out
    }
}
