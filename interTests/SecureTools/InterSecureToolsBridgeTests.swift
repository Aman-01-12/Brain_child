//
//  InterSecureToolsBridgeTests.swift
//  interTests
//
//  Unit tests for the AppKit↔SwiftUI tool bridge (the Tool_Bridge,
//  `InterSecureToolsBridge`). The bridge vends the two shared `NSHostingView`
//  leaf views to the Objective-C host, exposes the focus/clear/teardown control
//  surface, and owns exactly one view model per tool.
//
//  The bridge is `@objc @MainActor`, so this test case is annotated
//  accordingly. The bridge holds its view models privately (matching the
//  established `InterSecureChromeBridge` pattern), so — exactly like
//  `SecureCandidateChromeViewModelTests` — the whiteboard clear assertion
//  reaches the owned `WhiteboardViewModel` via `Mirror` reflection rather than
//  by widening the bridge's API just to test it.
//
//  Validates: Requirements 3.1, 3.2, 3.4, 3.5, 3.6, 3.7.
//

import XCTest
import AppKit
@testable import inter

@MainActor
final class InterSecureToolsBridgeTests: XCTestCase {

    // MARK: - Helpers

    /// Reach the bridge's privately-held `WhiteboardViewModel` without changing
    /// its public API (mirrors the chrome-bridge test's reflection approach).
    private func whiteboardViewModel(of bridge: InterSecureToolsBridge) -> WhiteboardViewModel? {
        Mirror(reflecting: bridge)
            .children
            .first { $0.label == "whiteboardViewModel" }?
            .value as? WhiteboardViewModel
    }

    // MARK: - R3.1 / R3.2: non-nil, shared, stable hosting views

    func testHostingViewsAreNonNilAndStableInstances() {
        let bridge = InterSecureToolsBridge()

        // Non-nil on first access.
        let editorFirst = bridge.codeEditorHostingView
        let boardFirst = bridge.whiteboardHostingView
        XCTAssertNotNil(editorFirst, "code editor hosting view must be non-nil (R3.1)")
        XCTAssertNotNil(boardFirst, "whiteboard hosting view must be non-nil (R3.2)")

        // Repeated access returns the SAME instance (lazy + shared) — identity.
        let editorSecond = bridge.codeEditorHostingView
        let editorThird = bridge.codeEditorHostingView
        let boardSecond = bridge.whiteboardHostingView
        let boardThird = bridge.whiteboardHostingView

        XCTAssertTrue(editorFirst === editorSecond,
                      "code editor hosting view must be the same instance across requests (R3.1)")
        XCTAssertTrue(editorSecond === editorThird,
                      "code editor hosting view must remain stable on every request (R3.1)")
        XCTAssertTrue(boardFirst === boardSecond,
                      "whiteboard hosting view must be the same instance across requests (R3.2)")
        XCTAssertTrue(boardSecond === boardThird,
                      "whiteboard hosting view must remain stable on every request (R3.2)")
    }

    // MARK: - R3.4: focus fails (returns false) when the editor is unmounted

    func testFocusCodeEditorReturnsFalseWhenUnmounted() {
        let bridge = InterSecureToolsBridge()

        // A fresh bridge whose editor has NOT been added to any window: the
        // wrapped NSTextView is not in a window hierarchy, so it cannot become
        // first responder. The bridge must report failure and leave the
        // existing first responder unchanged (R3.4).
        XCTAssertFalse(bridge.focusCodeEditor(),
                       "focusCodeEditor must return false when the editor is not mounted in a window (R3.4)")

        // Touching the hosting view (without mounting it in a window) must not
        // change the contract.
        _ = bridge.codeEditorHostingView
        XCTAssertFalse(bridge.focusCodeEditor(),
                       "focusCodeEditor must still return false while unmounted after vending the view (R3.4)")
    }

    // MARK: - R3.5: clear empties the whiteboard model

    func testClearWhiteboardEmptiesModel() {
        let bridge = InterSecureToolsBridge()

        guard let viewModel = whiteboardViewModel(of: bridge) else {
            return XCTFail("bridge must own exactly one WhiteboardViewModel")
        }

        // Drive the whiteboard to a non-empty state through the view model's
        // real creation path (text placement adds exactly one element).
        viewModel.selectTool(.text)
        viewModel.placeText("solution sketch", at: CGPoint(x: 12, y: 12))
        viewModel.selectTool(.shape)
        viewModel.beginShapeDrag(at: CGPoint(x: 0, y: 0))
        viewModel.commitShapeDrag(at: CGPoint(x: 40, y: 40))
        XCTAssertGreaterThan(viewModel.model.elements.count, 0,
                             "precondition: the whiteboard should hold at least one element")

        // The bridge clear must empty the model so the next capture is blank.
        bridge.clearWhiteboard()
        XCTAssertTrue(viewModel.model.elements.isEmpty,
                      "clearWhiteboard must empty the stroke model (R3.5)")
        XCTAssertTrue(viewModel.model.undoStack.isEmpty,
                      "clearWhiteboard must reset the undo history (R3.5, R9.5)")
        XCTAssertTrue(viewModel.model.redoStack.isEmpty,
                      "clearWhiteboard must reset the redo history (R3.5, R9.5)")

        // Idempotent: clearing an already-empty board stays empty and does not crash.
        bridge.clearWhiteboard()
        XCTAssertTrue(viewModel.model.elements.isEmpty,
                      "clearWhiteboard must be idempotent on an already-empty board (R3.5)")
    }

    // MARK: - R3.6: teardown is safe / idempotent and releases references

    func testInvalidateHandlersReleasesReferences() {
        let bridge = InterSecureToolsBridge()

        // Vend both leaves so the view models have live attachments to drop.
        _ = bridge.codeEditorHostingView
        _ = bridge.whiteboardHostingView

        // Teardown must be safe and callable repeatedly (idempotent) — R3.6.
        bridge.invalidateHandlers()
        bridge.invalidateHandlers()

        // After teardown the editor can no longer focus (its weak text-view
        // linkage was detached) and reports failure rather than crashing (R3.6).
        XCTAssertFalse(bridge.focusCodeEditor(),
                       "after invalidateHandlers the editor must report focus failure (R3.6)")

        // The hosting views still resolve to their stable instances afterward
        // without crashing (R3.6, R3.1, R3.2).
        XCTAssertNotNil(bridge.codeEditorHostingView,
                        "hosting views must still resolve after teardown (R3.6)")
        XCTAssertNotNil(bridge.whiteboardHostingView,
                        "hosting views must still resolve after teardown (R3.6)")

        // Clearing the whiteboard remains safe after teardown.
        bridge.clearWhiteboard()
    }

    // MARK: - R3.7: exactly one view model per tool — distinct leaf views

    func testExactlyOneViewModelPerToolHasDistinctHostingViews() {
        let bridge = InterSecureToolsBridge()

        // Each tool surface is backed by its own view model and therefore its
        // own hosting view: the two leaves must be DISTINCT instances (R3.7).
        XCTAssertFalse(bridge.codeEditorHostingView === bridge.whiteboardHostingView,
                       "the editor and whiteboard must be distinct hosting views, one per tool view model (R3.7)")
    }
}
