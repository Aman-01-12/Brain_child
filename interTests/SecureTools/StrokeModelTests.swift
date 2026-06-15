//
//  StrokeModelTests.swift
//  interTests
//
//  Example / edge-case unit tests for the pure whiteboard `StrokeModel` logic
//  layer. These complement the randomized property tests in
//  `StrokeModelPropertyTests.swift` with concrete, named scenarios:
//  draw-order append, removal by index, the 50-entry history-limit boundary
//  (exactly 50, then 51 → oldest dropped), and clear from a populated state.
//
//  StrokeModel is `@MainActor`, so the test case is annotated accordingly.
//
//  _Requirements: 9.5, 9.7_
//

import XCTest
import CoreGraphics
@testable import inter

@MainActor
final class StrokeModelTests: XCTestCase {

    // MARK: Helpers

    private func freehand(_ x: CGFloat, _ y: CGFloat,
                          color: WhiteboardColor = .white) -> WhiteboardElement {
        WhiteboardElement(kind: .freehand(points: [CGPoint(x: x, y: y)]), color: color)
    }

    // MARK: Draw-order append

    func testAddPreservesDrawOrder() {
        let model = StrokeModel()
        let a = freehand(0, 0, color: .red)
        let b = freehand(1, 1, color: .green)
        let c = freehand(2, 2, color: .blue)

        model.add(a)
        model.add(b)
        model.add(c)

        XCTAssertEqual(model.elements.count, 3)
        XCTAssertEqual(model.elements.map(\.id), [a.id, b.id, c.id],
                       "elements must be stored in draw order (append to end)")
        XCTAssertEqual(model.elements.last?.id, c.id, "last added element is topmost")
    }

    // MARK: Removal by index

    func testRemoveElementByIndex() {
        let model = StrokeModel()
        let a = freehand(0, 0)
        let b = freehand(1, 1)
        let c = freehand(2, 2)
        model.add(a)
        model.add(b)
        model.add(c)

        model.removeElement(at: 1) // remove b

        XCTAssertEqual(model.elements.map(\.id), [a.id, c.id],
                       "removing the middle element keeps the rest in order")
    }

    func testRemoveOutOfRangeIndexIsIgnored() {
        let model = StrokeModel()
        let a = freehand(0, 0)
        model.add(a)

        model.removeElement(at: 5)   // out of range, must not crash or mutate
        model.removeElement(at: -1)

        XCTAssertEqual(model.elements.map(\.id), [a.id])
    }

    // MARK: History-limit boundary (exactly 50, then 51)

    func testHistoryLimitAtExactly50() {
        let model = StrokeModel()
        var added: [WhiteboardElement] = []
        for i in 0..<50 {
            let e = freehand(CGFloat(i), 0)
            added.append(e)
            model.add(e)
        }

        XCTAssertEqual(model.undoStack.count, 50,
                       "exactly 50 changes fit within the history limit")
        XCTAssertEqual(model.undoStack, added.map { .add($0) },
                       "all 50 changes are retained, oldest first")
    }

    func testHistoryLimitDropsOldestAt51() {
        let model = StrokeModel()
        var added: [WhiteboardElement] = []
        for i in 0..<51 {
            let e = freehand(CGFloat(i), 0)
            added.append(e)
            model.add(e)
        }

        XCTAssertEqual(model.undoStack.count, 50,
                       "the 51st change must not grow the history beyond 50")
        // The oldest (first) change is dropped; the retained window is the last 50.
        XCTAssertEqual(model.undoStack, Array(added.suffix(50)).map { .add($0) },
                       "oldest change dropped; 50 most recent retained")
        XCTAssertEqual(model.undoStack.first, .add(added[1]),
                       "the first retained change is the second element added")
    }

    // MARK: Clear from a populated state

    func testClearFromPopulatedState() {
        let model = StrokeModel()
        for i in 0..<5 { model.add(freehand(CGFloat(i), 0)) }
        // Leave a non-empty redo history too.
        model.undo()
        model.undo()

        XCTAssertFalse(model.elements.isEmpty)
        XCTAssertFalse(model.undoStack.isEmpty)
        XCTAssertFalse(model.redoStack.isEmpty)

        model.clear()

        XCTAssertEqual(model.elements, [], "clear empties the element collection")
        XCTAssertTrue(model.undoStack.isEmpty, "clear empties the undo history")
        XCTAssertTrue(model.redoStack.isEmpty, "clear empties the redo history")
    }
}
