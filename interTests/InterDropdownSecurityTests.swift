//
//  InterDropdownSecurityTests.swift
//  interTests
//
//  Regression tests for the dropdown child-panel security configuration
//  (paranoid finding #2): dropdown panels are separate NSWindows and must
//  mirror the parent window's capture protection and float above its level —
//  otherwise menus opened inside the secure interview window would be visible
//  to screen capture even though the window itself is NSWindowSharingNone.
//

import XCTest
import AppKit
@testable import inter

@MainActor
final class InterDropdownSecurityTests: XCTestCase {

    private func makeParentWindow(sharing: NSWindow.SharingType,
                                  level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.sharingType = sharing
        window.level = level
        return window
    }

    /// The secure interview window is NSWindowSharingNone — its dropdowns must be too.
    func testPanelMirrorsCaptureProtectedParent() {
        let parent = makeParentWindow(sharing: .none, level: .screenSaver)
        let panel = InterDropdownPanelFactory.makePanel(size: NSSize(width: 200, height: 100),
                                                        parentWindow: parent)
        XCTAssertEqual(panel.sharingType, .none,
                       "Dropdown panel must inherit capture protection from a protected parent")
    }

    /// Normal windows keep their (read-only) sharing — no over-tightening.
    func testPanelMirrorsNormalParentSharing() {
        let parent = makeParentWindow(sharing: .readOnly, level: .normal)
        let panel = InterDropdownPanelFactory.makePanel(size: NSSize(width: 200, height: 100),
                                                        parentWindow: parent)
        XCTAssertEqual(panel.sharingType, .readOnly)
    }

    /// Above an elevated parent (secure window at screen-saver level), the
    /// panel must sit ABOVE the parent or the menu renders behind it.
    func testPanelLevelExceedsElevatedParent() {
        let parent = makeParentWindow(sharing: .none, level: .screenSaver)
        let panel = InterDropdownPanelFactory.makePanel(size: NSSize(width: 200, height: 100),
                                                        parentWindow: parent)
        XCTAssertGreaterThan(panel.level.rawValue, parent.level.rawValue)
    }

    /// For normal-level parents the panel keeps standard menu stacking.
    func testPanelLevelAtLeastPopUpMenuForNormalParent() {
        let parent = makeParentWindow(sharing: .readOnly, level: .normal)
        let panel = InterDropdownPanelFactory.makePanel(size: NSSize(width: 200, height: 100),
                                                        parentWindow: parent)
        XCTAssertGreaterThanOrEqual(panel.level.rawValue, NSWindow.Level.popUpMenu.rawValue)
    }
}
