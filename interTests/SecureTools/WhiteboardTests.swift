//
//  WhiteboardTests.swift
//  interTests
//
//  Example / edge-case unit tests for the `WhiteboardViewModel` gesture and
//  overlay behavior (tasks 5.4). These complement the randomized Property 7
//  gate tests with concrete, named scenarios.
//
//  `WhiteboardViewModel` is `@MainActor`, so the test case is annotated
//  accordingly.
//
//  Validates: Requirements 7.4, 8.2, 8.4, 8.7, 8.8.
//

import XCTest
import CoreGraphics
@testable import inter

@MainActor
final class WhiteboardTests: XCTestCase {

    // MARK: - Freehand commit on release (R7.4, R7.5)

    func testFreehandCommitOnReleaseAddsOneElement() {
        let viewModel = WhiteboardViewModel()
        viewModel.selectTool(.freehand)

        viewModel.beginFreehandStroke(at: CGPoint(x: 10, y: 10))
        // Points spaced well beyond the 1.5 pt coalescing threshold.
        viewModel.appendFreehandPoint(CGPoint(x: 30, y: 12))
        viewModel.appendFreehandPoint(CGPoint(x: 55, y: 40))
        viewModel.appendFreehandPoint(CGPoint(x: 80, y: 70))

        // The live stroke is published while dragging (R7.4).
        XCTAssertNotNil(viewModel.inProgressStroke, "in-progress stroke should be published while drawing")

        viewModel.endFreehandStroke()

        XCTAssertEqual(viewModel.model.elements.count, 1, "release should commit exactly one freehand element")
        if case .freehand(let points) = viewModel.model.elements.first?.kind {
            XCTAssertGreaterThanOrEqual(points.count, 2, "a real stroke retains at least two points")
        } else {
            XCTFail("committed element should be a freehand stroke")
        }
        XCTAssertNil(viewModel.inProgressStroke, "in-progress stroke should clear after release")
    }

    func testFreehandNoMovePressReleaseAddsNothing() {
        let viewModel = WhiteboardViewModel()
        viewModel.selectTool(.freehand)

        viewModel.beginFreehandStroke(at: CGPoint(x: 100, y: 100))
        viewModel.endFreehandStroke() // no movement

        XCTAssertEqual(viewModel.model.elements.count, 0, "a no-move press/release must add no element")
        XCTAssertNil(viewModel.inProgressStroke)
    }

    // MARK: - Shape "not created" indication (R8.1, R8.2)

    func testShapeBelowThresholdSetsNotCreatedAndAddsNothing() {
        let viewModel = WhiteboardViewModel()
        viewModel.selectTool(.shape)

        let start = CGPoint(x: 50, y: 50)
        let end = CGPoint(x: 52, y: 90) // width 2 (< 4), height 40
        viewModel.beginShapeDrag(at: start)
        viewModel.updateShapeDrag(to: end)
        viewModel.commitShapeDrag(at: end)

        XCTAssertEqual(viewModel.model.elements.count, 0, "a sub-4pt drag must add no element")
        XCTAssertTrue(viewModel.shapeNotCreated, "a sub-4pt drag must raise the 'shape not created' indication")
        XCTAssertNil(viewModel.inProgressShape, "in-progress shape should clear after commit")
    }

    func testShapeAtOrAboveThresholdAddsShapeWithActiveKind() {
        let viewModel = WhiteboardViewModel()
        viewModel.selectTool(.shape)
        viewModel.selectShapeKind(.ellipse)

        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 60, y: 90) // 50 x 80, both >= 4
        viewModel.beginShapeDrag(at: start)
        viewModel.updateShapeDrag(to: end)
        viewModel.commitShapeDrag(at: end)

        XCTAssertEqual(viewModel.model.elements.count, 1, "a >= 4x4 drag must add exactly one shape")
        if case .shape(let rect, let kind) = viewModel.model.elements.first?.kind {
            XCTAssertEqual(kind, .ellipse, "the created shape must carry the active shape kind")
            XCTAssertEqual(rect.width, 50, accuracy: 0.001)
            XCTAssertEqual(rect.height, 80, accuracy: 0.001)
        } else {
            XCTFail("committed element should be a shape")
        }
    }

    // MARK: - Eraser (R8.3, R8.4)

    func testEraserOnEmptyLocationIsNoOp() {
        let viewModel = WhiteboardViewModel()
        // Seed one shape far from the eraser point.
        viewModel.selectTool(.shape)
        viewModel.beginShapeDrag(at: CGPoint(x: 0, y: 0))
        viewModel.commitShapeDrag(at: CGPoint(x: 40, y: 40))
        let countBefore = viewModel.model.elements.count
        XCTAssertEqual(countBefore, 1)

        viewModel.selectTool(.eraser)
        viewModel.eraseAt(CGPoint(x: 5_000, y: 5_000)) // far miss

        XCTAssertEqual(viewModel.model.elements.count, countBefore, "erasing empty space must be a no-op")
    }

    func testEraserOnHitRemovesTopmostElement() {
        let viewModel = WhiteboardViewModel()
        viewModel.selectTool(.shape)

        // Two overlapping rectangles; the second is drawn on top (topmost).
        viewModel.beginShapeDrag(at: CGPoint(x: 0, y: 0))
        viewModel.commitShapeDrag(at: CGPoint(x: 100, y: 100))
        let bottomID = viewModel.model.elements[0].id

        viewModel.beginShapeDrag(at: CGPoint(x: 20, y: 20))
        viewModel.commitShapeDrag(at: CGPoint(x: 80, y: 80))
        let topID = viewModel.model.elements[1].id

        XCTAssertEqual(viewModel.model.elements.count, 2)

        viewModel.selectTool(.eraser)
        viewModel.eraseAt(CGPoint(x: 50, y: 50)) // inside both; topmost wins

        XCTAssertEqual(viewModel.model.elements.count, 1, "eraser must remove exactly one element")
        XCTAssertEqual(viewModel.model.elements.first?.id, bottomID, "the bottom element must remain")
        XCTAssertFalse(viewModel.model.elements.contains { $0.id == topID }, "the topmost element must be removed")
    }

    // MARK: - Text 256-char cap (R8.7)

    func testLimitTextInputCapsAt256() {
        let viewModel = WhiteboardViewModel()
        let raw = String(repeating: "x", count: 300)
        let limited = viewModel.limitTextInput(raw)
        XCTAssertEqual(limited.count, 256, "limitTextInput must cap entry at 256 characters")
    }

    func testPlaceTextStoresExactly256WhenOverCap() {
        let viewModel = WhiteboardViewModel()
        viewModel.selectTool(.text)
        let raw = String(repeating: "a", count: 300)
        viewModel.placeText(raw, at: CGPoint(x: 10, y: 10))

        XCTAssertEqual(viewModel.model.elements.count, 1)
        if case .text(let string, _) = viewModel.model.elements.first?.kind {
            XCTAssertEqual(string.count, 256, "placed text longer than 256 chars must be stored capped at 256")
        } else {
            XCTFail("committed element should be text")
        }
    }

    // MARK: - Active color selection (R8.8, plus R8.9 carry-through)

    func testSelectColorChangesActiveColorAndCarriesToCreatedShape() {
        let viewModel = WhiteboardViewModel()
        viewModel.selectColor(.red)
        XCTAssertEqual(viewModel.activeColor, .red, "selectColor must update the active color")

        viewModel.selectTool(.shape)
        viewModel.beginShapeDrag(at: CGPoint(x: 0, y: 0))
        viewModel.commitShapeDrag(at: CGPoint(x: 40, y: 40))
        XCTAssertEqual(viewModel.model.elements.last?.color, .red, "a shape created after selecting a color must carry it")

        // Switch color; a subsequent text element must carry the new color.
        viewModel.selectColor(.blue)
        XCTAssertEqual(viewModel.activeColor, .blue)
        viewModel.selectTool(.text)
        viewModel.placeText("hello", at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(viewModel.model.elements.last?.color, .blue, "text created after switching color must carry the new color")
    }
}
