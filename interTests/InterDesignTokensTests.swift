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
}
