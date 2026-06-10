//
//  InterTileBadgeTests.swift
//  interTests
//
//  Verifies the reusable SF-Symbol tile badge: it renders an image, uses the
//  corner-radius token, and swaps its image when the symbol is updated.
//

import XCTest
import AppKit
@testable import inter

final class InterTileBadgeTests: XCTestCase {

    func testBadgeRendersSymbolImage() {
        let badge = InterTileBadge(symbolName: InterDesignTokens.symbolMicMuted, tint: .white)
        XCTAssertNotNil(badge.currentImage, "Badge should render an image for a valid SF Symbol")
    }

    func testBadgeUsesCornerRadiusToken() {
        let badge = InterTileBadge(symbolName: InterDesignTokens.symbolCoHost, tint: .white)
        XCTAssertEqual(badge.layer?.cornerRadius, InterDesignTokens.badgeCornerRadius)
    }

    func testBadgeSymbolCanBeUpdated() {
        let badge = InterTileBadge(symbolName: InterDesignTokens.symbolHandRaised, tint: .white)
        let first = badge.currentImage
        badge.setSymbolName(InterDesignTokens.symbolCameraLocked)
        XCTAssertNotNil(badge.currentImage)
        XCTAssertFalse(first === badge.currentImage, "Updating the symbol should swap the image")
    }
}
