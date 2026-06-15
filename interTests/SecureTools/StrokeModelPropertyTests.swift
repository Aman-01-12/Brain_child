//
//  StrokeModelPropertyTests.swift
//  interTests
//
//  Randomized property-based tests for the pure whiteboard `StrokeModel`
//  logic layer (design Correctness Properties 2–9).
//
//  This project does not integrate a PBT library (SwiftCheck etc.); all tests
//  are XCTest. These properties are therefore expressed as XCTest-driven
//  randomized loops: each property runs a MINIMUM of 100 iterations, generates
//  inputs from a fixed-seed deterministic RNG (so any failure is reproducible),
//  and prints the offending iteration's inputs on failure.
//
//  StrokeModel is `@MainActor`, so the test case is annotated accordingly.
//

import XCTest
import CoreGraphics
@testable import inter

// MARK: - Deterministic, seeded RNG

/// A small SplitMix64 generator. Seeded with a fixed value per property so
/// every run draws the same sequence of inputs and any counterexample is
/// reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Randomized element generators

/// The minimum number of iterations every property runs (design: ≥100).
private let kIterations = 150

private func randomColor(_ rng: inout SeededGenerator) -> WhiteboardColor {
    WhiteboardColor.allCases.randomElement(using: &rng)!
}

private func randomPoint(_ rng: inout SeededGenerator,
                         range: ClosedRange<CGFloat> = 0...500) -> CGPoint {
    CGPoint(x: CGFloat.random(in: range, using: &rng),
            y: CGFloat.random(in: range, using: &rng))
}

private func randomString(_ rng: inout SeededGenerator, length: Int) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 -_/.")
    return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
}

private func randomShapeKind(_ rng: inout SeededGenerator) -> ShapeKind {
    [ShapeKind.rectangle, .ellipse, .line].randomElement(using: &rng)!
}

/// A randomized freehand / shape / text element with random color & geometry.
private func randomElement(_ rng: inout SeededGenerator) -> WhiteboardElement {
    switch Int.random(in: 0..<3, using: &rng) {
    case 0:
        let count = Int.random(in: 1...8, using: &rng)
        let points = (0..<count).map { _ in randomPoint(&rng) }
        return WhiteboardElement(kind: .freehand(points: points), color: randomColor(&rng))
    case 1:
        let rect = CGRect(x: CGFloat.random(in: 0...400, using: &rng),
                          y: CGFloat.random(in: 0...400, using: &rng),
                          width: CGFloat.random(in: 4...120, using: &rng),
                          height: CGFloat.random(in: 4...120, using: &rng))
        return WhiteboardElement(kind: .shape(rect: rect, kind: randomShapeKind(&rng)),
                                 color: randomColor(&rng))
    default:
        let length = Int.random(in: 1...24, using: &rng)
        return WhiteboardElement(kind: .text(string: randomString(&rng, length: length),
                                             origin: randomPoint(&rng)),
                                 color: randomColor(&rng))
    }
}

@MainActor
final class StrokeModelPropertyTests: XCTestCase {

    /// Seed a fresh model with `count` random elements.
    private func seededModel(_ count: Int, _ rng: inout SeededGenerator) -> StrokeModel {
        let model = StrokeModel()
        for _ in 0..<count { model.add(randomElement(&rng)) }
        return model
    }

    // Feature: secure-tools-swiftui-migration, Property 2: Undo/redo round-trip restores state — for any model and any reversible change, undo then redo returns elements to the post-change state.
    func testProperty2_UndoRedoRoundTrip() {
        var rng = SeededGenerator(seed: 0xA11CE)
        for iteration in 0..<kIterations {
            let model = seededModel(Int.random(in: 0...6, using: &rng), &rng)

            // Apply exactly one reversible change: add, or (when possible) remove.
            let doRemove = !model.elements.isEmpty && Bool.random(using: &rng)
            if doRemove {
                let index = Int.random(in: 0..<model.elements.count, using: &rng)
                model.removeElement(at: index)
            } else {
                model.add(randomElement(&rng))
            }

            let postChange = model.elements

            model.undo()
            model.redo()

            XCTAssertEqual(model.elements, postChange,
                           "Property 2 failed at iteration \(iteration): doRemove=\(doRemove), postChange count=\(postChange.count)")
        }
    }

    // Feature: secure-tools-swiftui-migration, Property 3: Undo past empty history is a no-op — empty undo/redo history leaves elements unchanged and raises no error.
    func testProperty3_EmptyHistoryNoOp() {
        var rng = SeededGenerator(seed: 0xE3E3)
        for iteration in 0..<kIterations {
            // Scenario A: a brand-new model has empty histories.
            let fresh = StrokeModel()
            fresh.undo()
            fresh.redo()
            XCTAssertEqual(fresh.elements, [],
                           "Property 3 (fresh) failed at iteration \(iteration)")

            // Scenario B: build state, then drain the undo history entirely; an
            // extra undo must be a no-op, and likewise an extra redo once redo
            // is drained.
            let model = seededModel(Int.random(in: 1...6, using: &rng), &rng)
            while !model.undoStack.isEmpty { model.undo() }
            let afterDrainUndo = model.elements
            model.undo() // extra undo on empty history
            XCTAssertEqual(model.elements, afterDrainUndo,
                           "Property 3 (extra undo) failed at iteration \(iteration)")

            while !model.redoStack.isEmpty { model.redo() }
            let afterDrainRedo = model.elements
            model.redo() // extra redo on empty history
            XCTAssertEqual(model.elements, afterDrainRedo,
                           "Property 3 (extra redo) failed at iteration \(iteration)")
        }
    }

    // Feature: secure-tools-swiftui-migration, Property 4: A new change discards the redo history — recording any new reversible change empties the redo history.
    func testProperty4_NewChangeDiscardsRedo() {
        var rng = SeededGenerator(seed: 0x4ED0)
        for iteration in 0..<kIterations {
            let model = seededModel(Int.random(in: 2...6, using: &rng), &rng)

            // Undo at least once so the redo history is non-empty.
            let undoCount = Int.random(in: 1...model.undoStack.count, using: &rng)
            for _ in 0..<undoCount { model.undo() }
            XCTAssertFalse(model.redoStack.isEmpty,
                           "Property 4 setup failed at iteration \(iteration): redo history should be non-empty")

            // Record any new reversible change.
            if !model.elements.isEmpty && Bool.random(using: &rng) {
                model.removeElement(at: Int.random(in: 0..<model.elements.count, using: &rng))
            } else {
                model.add(randomElement(&rng))
            }

            XCTAssertTrue(model.redoStack.isEmpty,
                          "Property 4 failed at iteration \(iteration): redo history not discarded")
        }
    }

    // Feature: secure-tools-swiftui-migration, Property 5: Undo history is bounded to 50 — the undo history never exceeds 50 entries and retains the 50 most recent changes.
    func testProperty5_UndoHistoryBounded() {
        var rng = SeededGenerator(seed: 0x5050)
        for iteration in 0..<kIterations {
            let model = StrokeModel()
            let total = StrokeModel.historyLimit + Int.random(in: 1...80, using: &rng)
            var recorded: [WhiteboardChange] = []
            for _ in 0..<total {
                let element = randomElement(&rng)
                model.add(element)
                recorded.append(.add(element))
            }

            XCTAssertLessThanOrEqual(model.undoStack.count, StrokeModel.historyLimit,
                                     "Property 5 failed at iteration \(iteration): undoStack count \(model.undoStack.count) exceeds limit")

            // Retains exactly the 50 most recent changes.
            let expected = Array(recorded.suffix(StrokeModel.historyLimit))
            XCTAssertEqual(model.undoStack, expected,
                           "Property 5 failed at iteration \(iteration): undoStack is not the 50 most recent changes (total added=\(total))")
        }
    }

    // Feature: secure-tools-swiftui-migration, Property 6: Clear empties model and both histories — clear leaves elements, undo history, and redo history all empty.
    func testProperty6_ClearEmptiesEverything() {
        var rng = SeededGenerator(seed: 0xC1EA8)
        for iteration in 0..<kIterations {
            let model = seededModel(Int.random(in: 0...8, using: &rng), &rng)
            // Mix in some undo/redo so both stacks may hold entries.
            let undoCount = model.undoStack.isEmpty ? 0 : Int.random(in: 0...model.undoStack.count, using: &rng)
            for _ in 0..<undoCount { model.undo() }

            model.clear()

            XCTAssertEqual(model.elements, [],
                           "Property 6 failed at iteration \(iteration): elements not empty")
            XCTAssertTrue(model.undoStack.isEmpty,
                          "Property 6 failed at iteration \(iteration): undo history not empty")
            XCTAssertTrue(model.redoStack.isEmpty,
                          "Property 6 failed at iteration \(iteration): redo history not empty")
        }
    }

    // Feature: secure-tools-swiftui-migration, Property 8: Eraser removes only when an element is hit — hitTest returns the topmost hit element index or nil; removing it removes exactly one element, and a miss leaves the collection unchanged.
    func testProperty8_EraserHitTestRemoval() {
        var rng = SeededGenerator(seed: 0x8E8A)
        for iteration in 0..<kIterations {
            let model = seededModel(Int.random(in: 0...8, using: &rng), &rng)
            let elementsBefore = model.elements
            let point = candidatePoint(for: elementsBefore, &rng)

            // Independent oracle: the topmost (highest index) element containing
            // the point, mirroring StrokeModel's hit-test geometry & tolerance.
            let expectedIndex = elementsBefore.indices.reversed().first {
                referenceContains(elementsBefore[$0], point)
            }

            let hit = model.hitTest(point)
            XCTAssertEqual(hit, expectedIndex,
                           "Property 8 failed at iteration \(iteration): hitTest=\(String(describing: hit)) expected=\(String(describing: expectedIndex)) point=\(point)")

            if let index = hit {
                let removed = elementsBefore[index]
                model.removeElement(at: index)
                XCTAssertEqual(model.elements.count, elementsBefore.count - 1,
                               "Property 8 failed at iteration \(iteration): expected exactly one removal")
                XCTAssertFalse(model.elements.contains(where: { $0.id == removed.id }),
                               "Property 8 failed at iteration \(iteration): hit element still present")
                var expectedRemaining = elementsBefore
                expectedRemaining.remove(at: index)
                XCTAssertEqual(model.elements, expectedRemaining,
                               "Property 8 failed at iteration \(iteration): wrong element removed / order changed")
            } else {
                // A miss: the eraser does nothing, collection unchanged.
                XCTAssertEqual(model.elements, elementsBefore,
                               "Property 8 failed at iteration \(iteration): miss altered the collection (point=\(point))")
            }
        }
    }

    // Feature: secure-tools-swiftui-migration, Property 9: Active color is applied to created elements — any shape or text element created while a color is active carries that color.
    func testProperty9_ActiveColorApplied() {
        var rng = SeededGenerator(seed: 0x9C01)
        for iteration in 0..<kIterations {
            let model = StrokeModel()
            let color = randomColor(&rng)
            model.activeColor = color

            // Create a shape or text element using the active color (the model
            // convention: created shape/text elements carry the active color).
            let element: WhiteboardElement
            if Bool.random(using: &rng) {
                let rect = CGRect(x: 0, y: 0,
                                  width: CGFloat.random(in: 4...100, using: &rng),
                                  height: CGFloat.random(in: 4...100, using: &rng))
                element = WhiteboardElement(kind: .shape(rect: rect, kind: randomShapeKind(&rng)),
                                            color: model.activeColor)
            } else {
                let length = Int.random(in: 1...24, using: &rng)
                element = WhiteboardElement(kind: .text(string: randomString(&rng, length: length),
                                                        origin: randomPoint(&rng)),
                                            color: model.activeColor)
            }
            model.add(element)

            XCTAssertEqual(model.elements.last?.color, color,
                           "Property 9 failed at iteration \(iteration): created element color \(String(describing: model.elements.last?.color)) != active \(color)")
        }
    }

    // MARK: - Point selection that exercises both hit and miss branches

    /// Produce a point that, across iterations, lands on elements roughly as
    /// often as it misses: sometimes anchored to an element's geometry (likely
    /// hit), sometimes far away (guaranteed miss), sometimes purely random.
    private func candidatePoint(for elements: [WhiteboardElement],
                                _ rng: inout SeededGenerator) -> CGPoint {
        switch Int.random(in: 0..<3, using: &rng) {
        case 0 where !elements.isEmpty:
            return anchorPoint(elements.randomElement(using: &rng)!)
        case 1:
            return CGPoint(x: 100_000, y: 100_000) // guaranteed miss
        default:
            return randomPoint(&rng, range: -50...550)
        }
    }

    private func anchorPoint(_ element: WhiteboardElement) -> CGPoint {
        switch element.kind {
        case .freehand(let points):
            return points.first ?? .zero
        case .shape(let rect, _):
            return CGPoint(x: rect.midX, y: rect.midY)
        case .text(_, let origin):
            return origin
        }
    }
}

// MARK: - Reference hit-test oracle
//
// Mirrors the private geometry used by `StrokeModel.hitTest(_:)` so Property 8
// can independently verify the topmost-hit selection. Kept in sync with
// StrokeModel: hit tolerance 8.0; text glyph box ~8pt/char wide, 16pt tall.

private let kHitTolerance: CGFloat = 8.0
private let kApproxCharWidth: CGFloat = 8.0
private let kApproxLineHeight: CGFloat = 16.0

private func referenceContains(_ element: WhiteboardElement, _ point: CGPoint) -> Bool {
    switch element.kind {
    case .freehand(let points):
        return referenceFreehandContains(points, point)
    case .shape(let rect, let kind):
        return referenceShapeContains(rect, kind: kind, point: point)
    case .text(let string, let origin):
        return referenceTextContains(string, origin: origin, point: point)
    }
}

private func referenceFreehandContains(_ points: [CGPoint], _ point: CGPoint) -> Bool {
    guard let first = points.first else { return false }
    if points.count == 1 {
        return refDistance(first, point) <= kHitTolerance
    }
    for index in 0..<(points.count - 1) {
        if refDistanceToSegment(point, points[index], points[index + 1]) <= kHitTolerance {
            return true
        }
    }
    return false
}

private func referenceShapeContains(_ rect: CGRect, kind: ShapeKind, point: CGPoint) -> Bool {
    let normalized = rect.standardized
    switch kind {
    case .rectangle, .ellipse:
        return normalized.insetBy(dx: -kHitTolerance, dy: -kHitTolerance).contains(point)
    case .line:
        let start = CGPoint(x: rect.minX, y: rect.minY)
        let end = CGPoint(x: rect.maxX, y: rect.maxY)
        return refDistanceToSegment(point, start, end) <= kHitTolerance
    }
}

private func referenceTextContains(_ string: String, origin: CGPoint, point: CGPoint) -> Bool {
    let width = max(kApproxCharWidth, CGFloat(string.count) * kApproxCharWidth)
    let box = CGRect(x: origin.x, y: origin.y, width: width, height: kApproxLineHeight)
    return box.insetBy(dx: -kHitTolerance, dy: -kHitTolerance).contains(point)
}

private func refDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

private func refDistanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    if lengthSquared == 0 {
        return refDistance(point, a)
    }
    var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
    t = min(max(t, 0), 1)
    let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    return refDistance(point, projection)
}
