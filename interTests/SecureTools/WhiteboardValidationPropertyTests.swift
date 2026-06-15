//
//  WhiteboardValidationPropertyTests.swift
//  interTests
//
//  Randomized property-based test for the whiteboard element-creation
//  validation gates (design Correctness Property 7), driven END-TO-END through
//  the `WhiteboardViewModel` so the gates are exercised exactly as the SwiftUI
//  gesture layer would invoke them.
//
//  This project does not integrate a PBT library (SwiftCheck etc.); all tests
//  are XCTest. The property is therefore expressed as an XCTest-driven
//  randomized loop: it runs a MINIMUM of 100 iterations, generates inputs from
//  a fixed-seed deterministic RNG (so any failure is reproducible), and prints
//  the offending iteration's inputs on failure.
//
//  `WhiteboardViewModel` is `@MainActor`, so the test case is annotated
//  accordingly.
//

import XCTest
import CoreGraphics
@testable import inter

// MARK: - Deterministic, seeded RNG
//
// A distinctly-named SplitMix64 generator (the `StrokeModelPropertyTests`
// target already declares a `SeededGenerator`; Swift would reject a duplicate
// type name across the same test target, so this one is named differently).
// Seeded with a fixed value so every run draws the same sequence of inputs and
// any counterexample is reproducible.

struct WhiteboardSeededGenerator: RandomNumberGenerator {
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

// MARK: - Randomized generators

/// The minimum number of iterations the property runs (design: ≥100).
private let kIterations = 200

private func randomColor(_ rng: inout WhiteboardSeededGenerator) -> WhiteboardColor {
    WhiteboardColor.allCases.randomElement(using: &rng)!
}

private func randomPoint(_ rng: inout WhiteboardSeededGenerator,
                         range: ClosedRange<CGFloat> = 0...500) -> CGPoint {
    CGPoint(x: CGFloat.random(in: range, using: &rng),
            y: CGFloat.random(in: range, using: &rng))
}

private func randomString(_ rng: inout WhiteboardSeededGenerator, length: Int) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 -_/.,'\"")
    return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
}

@MainActor
final class WhiteboardValidationPropertyTests: XCTestCase {

    // Feature: secure-tools-swiftui-migration, Property 7: Element-creation validation gates — for any attempted element creation, the model gains exactly one element when the input is valid and is left unchanged when the input is invalid: freehand zero-length paths add nothing; shape drags with width or height below 4 points add nothing; text of length 1–256 adds one text element while empty text adds nothing.
    func testProperty7_ElementCreationValidationGates() {
        var rng = WhiteboardSeededGenerator(seed: 0x7A11D)

        for iteration in 0..<kIterations {
            // A fresh view model per iteration so transient state (e.g. the
            // `shapeNotCreated` flag) never leaks across cases.
            let viewModel = WhiteboardViewModel()
            viewModel.selectColor(randomColor(&rng))

            let before = viewModel.model.elements.count

            // Mix all gate cases across iterations.
            switch Int.random(in: 0..<7, using: &rng) {

            // ---- Freehand: real multi-point stroke (R7.5) → exactly one element.
            case 0:
                viewModel.selectTool(.freehand)
                let start = randomPoint(&rng)
                viewModel.beginFreehandStroke(at: start)
                // Append several points each spaced strictly > 1.5 pt from the
                // last retained point, so coalescing keeps >= 2 points.
                var current = start
                let extra = Int.random(in: 1...8, using: &rng)
                for _ in 0..<extra {
                    let dx = CGFloat.random(in: 2...20, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                    let dy = CGFloat.random(in: 2...20, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                    current = CGPoint(x: current.x + dx, y: current.y + dy)
                    viewModel.appendFreehandPoint(current)
                }
                viewModel.endFreehandStroke()
                XCTAssertEqual(viewModel.model.elements.count, before + 1,
                               "Property 7 (freehand valid) failed at iteration \(iteration): expected exactly one freehand element added")
                if case .freehand = viewModel.model.elements.last?.kind {} else {
                    XCTFail("Property 7 (freehand valid) failed at iteration \(iteration): added element is not freehand")
                }

            // ---- Freehand: zero-length path, no movement (R7.6) → unchanged.
            case 1:
                viewModel.selectTool(.freehand)
                let start = randomPoint(&rng)
                viewModel.beginFreehandStroke(at: start)
                viewModel.endFreehandStroke()
                XCTAssertEqual(viewModel.model.elements.count, before,
                               "Property 7 (freehand no-move) failed at iteration \(iteration): model changed on a zero-length path")

            // ---- Freehand: all appended points within < 1.5 pt (R7.6) → unchanged.
            case 2:
                viewModel.selectTool(.freehand)
                let start = randomPoint(&rng)
                viewModel.beginFreehandStroke(at: start)
                let extra = Int.random(in: 1...8, using: &rng)
                for _ in 0..<extra {
                    // Offsets strictly inside the 1.5 pt coalescing threshold.
                    let dx = CGFloat.random(in: -1.0...1.0, using: &rng)
                    let dy = CGFloat.random(in: -1.0...1.0, using: &rng)
                    viewModel.appendFreehandPoint(CGPoint(x: start.x + dx, y: start.y + dy))
                }
                viewModel.endFreehandStroke()
                XCTAssertEqual(viewModel.model.elements.count, before,
                               "Property 7 (freehand sub-threshold) failed at iteration \(iteration): coalesced points should leave model unchanged")

            // ---- Shape: width AND height >= 4 (R8.1) → exactly one shape.
            case 3:
                viewModel.selectTool(.shape)
                let start = randomPoint(&rng)
                let dw = CGFloat.random(in: 4...300, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                let dh = CGFloat.random(in: 4...300, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                let end = CGPoint(x: start.x + dw, y: start.y + dh)
                viewModel.beginShapeDrag(at: start)
                viewModel.updateShapeDrag(to: end)
                viewModel.commitShapeDrag(at: end)
                XCTAssertEqual(viewModel.model.elements.count, before + 1,
                               "Property 7 (shape valid) failed at iteration \(iteration): expected exactly one shape element (w=\(abs(dw)), h=\(abs(dh)))")
                if case .shape = viewModel.model.elements.last?.kind {} else {
                    XCTFail("Property 7 (shape valid) failed at iteration \(iteration): added element is not a shape")
                }

            // ---- Shape: width OR height < 4 (R8.2) → unchanged + flag set.
            case 4:
                viewModel.selectTool(.shape)
                let start = randomPoint(&rng)
                // Make at least one dimension sub-threshold.
                let smallIsWidth = Bool.random(using: &rng)
                let small = CGFloat.random(in: 0..<4, using: &rng)
                let other = CGFloat.random(in: 0...300, using: &rng)
                let dw = (smallIsWidth ? small : other) * (Bool.random(using: &rng) ? 1 : -1)
                let dh = (smallIsWidth ? other : small) * (Bool.random(using: &rng) ? 1 : -1)
                let end = CGPoint(x: start.x + dw, y: start.y + dh)
                viewModel.beginShapeDrag(at: start)
                viewModel.updateShapeDrag(to: end)
                viewModel.commitShapeDrag(at: end)
                XCTAssertEqual(viewModel.model.elements.count, before,
                               "Property 7 (shape too small) failed at iteration \(iteration): model changed for w=\(abs(dw)), h=\(abs(dh))")
                XCTAssertTrue(viewModel.shapeNotCreated,
                              "Property 7 (shape too small) failed at iteration \(iteration): shapeNotCreated flag not raised")

            // ---- Text: 1...256 chars (R8.5) → exactly one text element.
            case 5:
                viewModel.selectTool(.text)
                let length = Int.random(in: 1...256, using: &rng)
                let string = randomString(&rng, length: length)
                viewModel.placeText(string, at: randomPoint(&rng))
                XCTAssertEqual(viewModel.model.elements.count, before + 1,
                               "Property 7 (text valid) failed at iteration \(iteration): expected exactly one text element (len=\(length))")
                if case .text = viewModel.model.elements.last?.kind {} else {
                    XCTFail("Property 7 (text valid) failed at iteration \(iteration): added element is not text")
                }

            // ---- Text: empty string (R8.6) → unchanged.
            default:
                viewModel.selectTool(.text)
                viewModel.placeText("", at: randomPoint(&rng))
                XCTAssertEqual(viewModel.model.elements.count, before,
                               "Property 7 (text empty) failed at iteration \(iteration): model changed on empty text")
            }
        }
    }
}
