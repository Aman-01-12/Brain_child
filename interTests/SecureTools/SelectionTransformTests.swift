//
//  SelectionTransformTests.swift
//  interTests
//
//  Property-based + unit tests for the pure selection/transform geometry layer
//  `SelectionTransformController` (collaborative-whiteboard spec, Task 4; design
//  "Correctness Properties" 6, 7, 8). The transform math lives in the pure,
//  value-only `SelectionGeometry` + `BoardTransform` namespace (the natural PBT
//  target for Property 6 — no `BoardDocument` needed), while the controller owns
//  the local selection set and fans a multi-element operation out into one
//  `BoardOp` per affected member (Property 8) by driving `BoardDocument`.
//
//  This project does NOT integrate an external PBT library; the established
//  convention (see `BoardDocumentPropertyTests`, `CodeEditorDocumentTests`) is
//  XCTest-driven randomized loops backed by a fixed-seed deterministic
//  SplitMix64 RNG. We follow that convention so every counterexample is
//  reproducible:
//    - Every property runs ≥100 seeded iterations (`kSelectionIterations`).
//    - Each iteration derives its own seed (`base &+ iteration`) which is
//      printed on failure so a failing example can be replayed exactly.
//
//  RNG naming: this file uses a DISTINCTLY-named generator
//  (`SelectionPBTGenerator`) so it does not collide with the
//  `BoardPBTGenerator` / `WhiteboardWireFuzzGenerator` / `RGASeededGenerator`
//  already declared in the same test target.
//
//  `SelectionTransformController` and `BoardDocument` are `@MainActor`, so the
//  test case is annotated accordingly.
//
//  Float tolerance for Property 6 (`kEpsilon`): the model stores `CGFloat`
//  (a `Double` on 64-bit), coordinates are bounded to a few thousand world
//  units, and each restore is a handful of affine steps, so accumulated error
//  stays far below 1e-9. We assert geometry is restored within 1e-6 — a tight,
//  meaningful tolerance that still leaves orders-of-magnitude headroom.
//

import CoreGraphics
import XCTest
@testable import inter

// MARK: - Deterministic, seeded RNG

private struct SelectionPBTGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Minimum iterations per property (design/Task 4: ≥100).
private let kSelectionIterations = 150

/// Float tolerance for Property 6 geometry restoration (see file header).
private let kEpsilon: CGFloat = 1e-6

/// A generous cap so the document never trips the element/stroke clamps in
/// these (geometry-focused) tests.
private let kBigCap = 1_000_000

private let kColors: [WhiteboardColor] = [.white, .red, .orange, .yellow, .green, .blue, .purple, .black]

// MARK: - Random value helpers
//
// Coordinates and factors are kept moderate so transform restoration error
// stays comfortably under `kEpsilon`. Scale factors are bounded away from zero
// (so they stay invertible) and to [0.25, 4] (so intermediate magnitudes — and
// their inverses — stay sane).

private func randCoord(_ rng: inout SelectionPBTGenerator) -> CGFloat {
    CGFloat(Int.random(in: -400...400, using: &rng))
}

private func randPoint(_ rng: inout SelectionPBTGenerator) -> CGPoint {
    CGPoint(x: randCoord(&rng), y: randCoord(&rng))
}

private func randPoints(_ rng: inout SelectionPBTGenerator) -> [CGPoint] {
    let n = Int.random(in: 1...12, using: &rng)
    return (0..<n).map { _ in randPoint(&rng) }
}

private func randRect(_ rng: inout SelectionPBTGenerator) -> CGRect {
    CGRect(x: randCoord(&rng),
           y: randCoord(&rng),
           width: CGFloat(Int.random(in: 1...300, using: &rng)),
           height: CGFloat(Int.random(in: 1...300, using: &rng)))
}

private func randAngle(_ rng: inout SelectionPBTGenerator) -> CGFloat {
    // Any rotation in (-π, π]; integer-derived fraction for reproducibility.
    let n = Int.random(in: -180...180, using: &rng)
    return CGFloat(n) * .pi / 180
}

private func randScaleFactor(_ rng: inout SelectionPBTGenerator) -> CGFloat {
    // [0.25, 4] in 0.05 steps; never zero (stays invertible).
    let n = Int.random(in: 5...80, using: &rng)
    return CGFloat(n) / 20
}

private func randColor(_ rng: inout SelectionPBTGenerator) -> WhiteboardColor {
    kColors.randomElement(using: &rng)!
}

// MARK: - Approximate geometry comparison (Property 6)

private func approxEqual(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = kEpsilon) -> Bool {
    abs(a - b) <= eps
}

private func approxEqual(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = kEpsilon) -> Bool {
    approxEqual(a.x, b.x, eps) && approxEqual(a.y, b.y, eps)
}

private func approxEqual(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = kEpsilon) -> Bool {
    approxEqual(a.origin.x, b.origin.x, eps) && approxEqual(a.origin.y, b.origin.y, eps)
        && approxEqual(a.size.width, b.size.width, eps) && approxEqual(a.size.height, b.size.height, eps)
}

/// Whether two elements have the same geometry (points / frame / rotation)
/// within `eps`. Style/structure are ignored — transforms touch geometry only.
private func geometryApproxEqual(_ a: BoardElement, _ b: BoardElement, _ eps: CGFloat = kEpsilon) -> Bool {
    switch (a.points, b.points) {
    case (.some(let pa), .some(let pb)):
        guard pa.count == pb.count else { return false }
        for (x, y) in zip(pa, pb) where !approxEqual(x, y, eps) { return false }
    case (.none, .none):
        break
    default:
        return false
    }
    switch (a.frame, b.frame) {
    case (.some(let fa), .some(let fb)):
        if !approxEqual(fa, fb, eps) { return false }
    case (.none, .none):
        break
    default:
        return false
    }
    return approxEqual(a.rotation, b.rotation, eps)
}

// MARK: - Element value builders (pure value layer — no document)

/// Builds a random points-based element (freehand / line / arrow).
private func randomPointsElement(_ rng: inout SelectionPBTGenerator, id: String = "e") -> BoardElement {
    let kinds: [BoardElementKind] = [.freehand, .line, .arrow]
    return BoardElement(
        id: id,
        present: true,
        kind: kinds.randomElement(using: &rng)!,
        points: randPoints(&rng),
        frame: nil,
        rotation: 0,
        strokeColor: randColor(&rng),
        strokeWidth: CGFloat(Int.random(in: 1...8, using: &rng)),
        text: nil,
        zKey: "a0",
        groupId: nil,
        deleted: false,
        v: BoardVersionTags()
    )
}

/// Builds a random frame-based element (rectangle / ellipse / text), possibly
/// already rotated.
private func randomFrameElement(_ rng: inout SelectionPBTGenerator, id: String = "e") -> BoardElement {
    let kinds: [BoardElementKind] = [.rectangle, .ellipse, .text]
    let kind = kinds.randomElement(using: &rng)!
    return BoardElement(
        id: id,
        present: true,
        kind: kind,
        points: nil,
        frame: randRect(&rng),
        rotation: randAngle(&rng),
        strokeColor: randColor(&rng),
        strokeWidth: CGFloat(Int.random(in: 1...8, using: &rng)),
        text: kind == .text ? "hi" : nil,
        zKey: "a0",
        groupId: nil,
        deleted: false,
        v: BoardVersionTags()
    )
}

private func randomElement(_ rng: inout SelectionPBTGenerator, id: String = "e") -> BoardElement {
    Bool.random(using: &rng) ? randomPointsElement(&rng, id: id) : randomFrameElement(&rng, id: id)
}

/// A random ordered transform list assembled in the LOCKED translate → rotate →
/// scale order (the controller's invariant). Each step is independently
/// invertible, so the list's `inverse` restores the original geometry.
private func randomTransformList(_ rng: inout SelectionPBTGenerator) -> [BoardTransform] {
    [
        .move(dx: randCoord(&rng), dy: randCoord(&rng)),
        .rotate(angle: randAngle(&rng), about: randPoint(&rng)),
        .scale(sx: randScaleFactor(&rng), sy: randScaleFactor(&rng), anchor: randPoint(&rng))
    ]
}

// MARK: - Rendered signature (Property 8 peer convergence)

private func sigRect(_ r: CGRect) -> String { "\(r.origin.x),\(r.origin.y),\(r.size.width),\(r.size.height)" }

private func sigPoints(_ pts: [CGPoint]?) -> String {
    guard let pts = pts else { return "nil" }
    return pts.map { "\($0.x):\($0.y)" }.joined(separator: "|")
}

private func elementSignature(_ el: BoardElement) -> String {
    [
        el.id,
        el.kind.rawValue,
        sigPoints(el.points),
        el.frame.map(sigRect) ?? "nil",
        "\(el.rotation)",
        "\(el.strokeColor)",
        "\(el.strokeWidth)",
        el.text ?? "nil",
        el.zKey,
        el.groupId ?? "nil"
    ].joined(separator: "~")
}

@MainActor
private func renderedSignature(_ doc: BoardDocument) -> [String] {
    doc.renderedElements.map(elementSignature)
}

// MARK: - Document / selection builders (Properties 7, 8 + unit cases)

@MainActor
private func makeDoc(_ site: String) -> BoardDocument {
    BoardDocument(site: site, maxElements: kBigCap, maxStrokePoints: kBigCap, maxHistoryEntries: kBigCap)
}

/// Adds `count` random elements to `doc`, returning all the add ops (so a peer
/// can be seeded with the identical base board) and the new ids.
@MainActor
private func seedElements(_ doc: BoardDocument, count: Int, _ rng: inout SelectionPBTGenerator)
    -> (ops: [BoardOp], ids: [BoardElementID]) {
    var ops: [BoardOp] = []
    for _ in 0..<count {
        let color = randColor(&rng)
        let width = CGFloat(Int.random(in: 1...8, using: &rng))
        let added: [BoardOp]
        switch Int.random(in: 0..<3, using: &rng) {
        case 0:  added = doc.addElement(kind: .freehand, points: randPoints(&rng), strokeColor: color, strokeWidth: width)
        case 1:  added = doc.addElement(kind: .rectangle, frame: randRect(&rng), strokeColor: color, strokeWidth: width)
        default: added = doc.addElement(kind: .ellipse, frame: randRect(&rng), strokeColor: color, strokeWidth: width)
        }
        ops.append(contentsOf: added)
    }
    let ids = ops.compactMap { $0.kind == .add ? $0.id : nil }
    return (ops, ids)
}

// MARK: - Tests

@MainActor
final class SelectionTransformTests: XCTestCase {

    // MARK: Property 6 — transform inverse + no-ops (R3.4, R3.5, R3.6)

    // Feature: collaborative-whiteboard, Property 6: Transform correctness —
    // applying any move/rotate/scale list then its inverse restores each member's
    // geometry within float tolerance (kEpsilon=1e-6); and a zero move / unit
    // scale / zero rotate is a no-op.
    // Validates: Requirements 3.4, 3.5, 3.6
    func testProperty6_TransformInverseRestoresGeometry() {
        let base: UInt64 = 0x5E1E_0006_0000
        for i in 0..<kSelectionIterations {
            let seed = base &+ UInt64(i)
            var rng = SelectionPBTGenerator(seed: seed)
            let element = randomElement(&rng)
            let transforms = randomTransformList(&rng)

            let msg = "Property 6 (inverse) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)"

            // Forward then inverse (locked order; inverse is the reversed list of
            // per-step inverses) restores the original geometry.
            let forward = SelectionGeometry.apply(transforms, to: element)
            let restored = SelectionGeometry.apply(transforms.inverse, to: forward)
            XCTAssertTrue(geometryApproxEqual(restored, element), msg + " — geometry not restored")

            // No-ops: zero move / unit scale / zero rotate leave geometry unchanged.
            let nopMsg = "Property 6 (no-op) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)"
            let zeroMove = SelectionGeometry.apply([.move(dx: 0, dy: 0)], to: element)
            XCTAssertTrue(geometryApproxEqual(zeroMove, element), nopMsg + " — zero move changed geometry")

            let unitScale = SelectionGeometry.apply([.scale(sx: 1, sy: 1, anchor: randPoint(&rng))], to: element)
            XCTAssertTrue(geometryApproxEqual(unitScale, element), nopMsg + " — unit scale changed geometry")

            let zeroRotate = SelectionGeometry.apply([.rotate(angle: 0, about: randPoint(&rng))], to: element)
            XCTAssertTrue(geometryApproxEqual(zeroRotate, element), nopMsg + " — zero rotate changed geometry")
        }
    }

    // MARK: Property 7 — group selection integrity (R3.8)

    // Feature: collaborative-whiteboard, Property 7: Group selection integrity —
    // selecting any member of a group yields the WHOLE group; after ungroup,
    // selecting a former member yields ONLY that element.
    // Validates: Requirements 3.8
    func testProperty7_GroupSelectionIntegrity() {
        let base: UInt64 = 0x5E1E_0007_0000
        for i in 0..<kSelectionIterations {
            let seed = base &+ UInt64(i)
            var rng = SelectionPBTGenerator(seed: seed)

            let doc = makeDoc("A")
            let total = Int.random(in: 3...7, using: &rng)
            let (_, ids) = seedElements(doc, count: total, &rng)
            guard ids.count == total else {
                XCTFail("Property 7 setup: expected \(total) ids, got \(ids.count) (seed=0x\(String(seed, radix: 16)))")
                continue
            }

            let controller = SelectionTransformController(document: doc)
            let msg = "Property 7 failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)"

            // Group a random subset (≥2). The rest stay ungrouped.
            let groupSize = Int.random(in: 2...total, using: &rng)
            let groupIds = Array(ids.shuffled(using: &rng).prefix(groupSize))
            let groupSet = Set(groupIds)
            let nonGroupIds = ids.filter { !groupSet.contains($0) }

            let groupOps = doc.group(groupIds)
            XCTAssertEqual(groupOps.count, groupSize, msg + " — group did not emit one op per member")

            // Selecting ANY single group member expands to the whole group.
            for member in groupIds {
                let result = controller.setSelection([member])
                XCTAssertEqual(result, groupSet, msg + " — selecting member \(member) did not yield the whole group")
                XCTAssertEqual(controller.selection, groupSet, msg + " — controller.selection mismatch for \(member)")
            }

            // Selecting a non-grouped element yields only that element.
            for loner in nonGroupIds {
                let result = controller.setSelection([loner])
                XCTAssertEqual(result, [loner], msg + " — non-grouped \(loner) expanded unexpectedly")
            }

            // Ungroup, then selecting a former member yields ONLY that element.
            let ungroupOps = doc.ungroup(groupIds)
            XCTAssertEqual(ungroupOps.count, groupSize, msg + " — ungroup did not emit one op per member")
            for former in groupIds {
                let result = controller.setSelection([former])
                XCTAssertEqual(result, [former], msg + " — after ungroup, \(former) still expanded to the group")
            }
        }
    }

    // MARK: Property 8 — multi-select op fan-out (R3.10, R2.2)

    // Feature: collaborative-whiteboard, Property 8: Multi-select op fan-out —
    // a transform/restyle/reorder/delete on an N-element selection emits exactly
    // N BoardOps (one per affected member), and applying those ops on a peer
    // BoardDocument yields an identical board (convergence).
    // Validates: Requirements 3.10, 2.2
    func testProperty8_MultiSelectOpFanOut() {
        let base: UInt64 = 0x5E1E_0008_0000
        for i in 0..<kSelectionIterations {
            let seed = base &+ UInt64(i)
            var rng = SelectionPBTGenerator(seed: seed)

            let doc = makeDoc("A")
            let peer = makeDoc("B")

            // Seed an identical base board on both replicas.
            let n = Int.random(in: 2...6, using: &rng)
            let (addOps, ids) = seedElements(doc, count: n, &rng)
            for op in addOps { peer.integrate(op) }
            guard ids.count == n else {
                XCTFail("Property 8 setup: expected \(n) ids, got \(ids.count) (seed=0x\(String(seed, radix: 16)))")
                continue
            }

            let controller = SelectionTransformController(document: doc)
            controller.setSelection(Set(ids))
            XCTAssertEqual(controller.selectedElements.count, n,
                           "Property 8: selection should hold all \(n) members (seed=0x\(String(seed, radix: 16)))")

            // Pick one fan-out category. Each emits exactly one op per member.
            let category = Int.random(in: 0..<4, using: &rng)
            let label: String
            let ops: [BoardOp]
            switch category {
            case 0:
                label = "move"
                ops = controller.move(dx: CGFloat(Int.random(in: 1...50, using: &rng)),
                                      dy: CGFloat(Int.random(in: 1...50, using: &rng)))
            case 1:
                label = "restyle"
                // Restyle fans out across the selection (one update op per member).
                var collected: [BoardOp] = []
                let color = randColor(&rng)
                for el in controller.selectedElements {
                    collected.append(contentsOf: doc.updateElement(el.id, [.strokeColor(color)]))
                }
                ops = collected
            case 2:
                label = "reorder(toFront)"
                ops = controller.bringSelectionToFront()
            default:
                label = "delete"
                ops = controller.deleteSelection()
            }

            let msg = "Property 8 (\(label)) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i) N=\(n)"
            XCTAssertEqual(ops.count, n, msg + " — expected exactly N ops, got \(ops.count)")

            // Apply the fan-out ops on the peer; both boards must converge.
            for op in ops { peer.integrate(op) }
            XCTAssertEqual(renderedSignature(doc), renderedSignature(peer), msg + " — peer did not converge")
            XCTAssertEqual(doc.liveCount, peer.liveCount, msg + " — liveCount diverged")
        }
    }

    // MARK: Unit cases (4.4)

    // Feature: collaborative-whiteboard, Unit: marquee intersection selects every
    // element whose world bounds intersect the dragged region (R3.2).
    func testUnit_MarqueeIntersectionSelection() {
        let doc = makeDoc("A")
        let inside = doc.addElement(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 50, height: 50),
                                    strokeColor: .red, strokeWidth: 2)
        let outside = doc.addElement(kind: .rectangle, frame: CGRect(x: 200, y: 200, width: 50, height: 50),
                                     strokeColor: .blue, strokeWidth: 2)
        guard let insideID = inside.first?.id, let outsideID = outside.first?.id else {
            return XCTFail("setup: adds produced no ops")
        }
        let controller = SelectionTransformController(document: doc)

        // Marquee covering only the first element's bounds.
        let result = controller.selectMarquee(CGRect(x: -10, y: -10, width: 100, height: 100))
        XCTAssertEqual(result, [insideID], "marquee should select only the intersecting element")
        XCTAssertFalse(result.contains(outsideID), "marquee selected a non-intersecting element")

        // A marquee spanning both selects both.
        let both = controller.selectMarquee(CGRect(x: -10, y: -10, width: 400, height: 400))
        XCTAssertEqual(both, [insideID, outsideID], "wide marquee should select both elements")
    }

    // Feature: collaborative-whiteboard, Unit: a single click selects the TOPMOST
    // (frontmost / highest zKey) element under the point (R3.1).
    func testUnit_TopmostHitSingleSelection() {
        let doc = makeDoc("A")
        // Two fully-overlapping rectangles; the second added is frontmost.
        let back = doc.addElement(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  strokeColor: .red, strokeWidth: 2)
        let front = doc.addElement(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                   strokeColor: .blue, strokeWidth: 2)
        guard let backID = back.first?.id, let frontID = front.first?.id else {
            return XCTFail("setup: adds produced no ops")
        }
        let controller = SelectionTransformController(document: doc)

        let result = controller.selectSingle(at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(result, [frontID], "topmost (frontmost) element should win the single-click hit")
        XCTAssertFalse(result.contains(backID), "single click selected the occluded element")

        // Clicking empty canvas clears the selection.
        let cleared = controller.selectSingle(at: CGPoint(x: 1000, y: 1000))
        XCTAssertTrue(cleared.isEmpty, "click on empty canvas should clear the selection")
    }

    // Feature: collaborative-whiteboard, Unit: resizing a ROTATED selection scales
    // the member's frame while leaving its rotation untouched (the documented
    // rotated-resize approximation), emitting exactly one op (R3.5).
    func testUnit_ResizeOfRotatedSelection() {
        let doc = makeDoc("A")
        let rotation: CGFloat = .pi / 6
        let added = doc.addElement(kind: .rectangle, frame: CGRect(x: -50, y: -50, width: 100, height: 100),
                                   rotation: rotation, strokeColor: .green, strokeWidth: 2)
        guard let id = added.first?.id else { return XCTFail("setup: add produced no ops") }
        let controller = SelectionTransformController(document: doc)
        controller.setSelection([id])

        guard let box = controller.selectionBounds else { return XCTFail("rotated selection has no bounds") }
        let old = doc.element(id: id)
        XCTAssertNotNil(old?.frame)

        // Drag the bottom-right handle outward to enlarge the selection.
        let ops = controller.resize(handle: .bottomRight,
                                    to: CGPoint(x: box.maxX + 60, y: box.maxY + 60))
        XCTAssertEqual(ops.count, 1, "resizing a single rotated selection should emit exactly one op")

        let new = doc.element(id: id)
        XCTAssertEqual(new?.rotation, rotation, "rotation must be unchanged by a resize (documented approximation)")
        XCTAssertNotEqual(new?.frame, old?.frame, "resize should have changed the frame")
        if let nf = new?.frame, let of = old?.frame {
            XCTAssertGreaterThan(nf.width, of.width, "outward resize should enlarge the width")
            XCTAssertGreaterThan(nf.height, of.height, "outward resize should enlarge the height")
        }
    }

    // Feature: collaborative-whiteboard, Unit: pure scale-parameter derivation for
    // a resize handle drag — the anchor is the opposite corner and the factors are
    // the proportional box-size change (R3.5).
    func testUnit_ScaleParametersFromHandleDrag() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)

        guard let p = SelectionTransformController.scaleParameters(handle: .bottomRight, box: box,
                                                                   to: CGPoint(x: 150, y: 200)) else {
            return XCTFail("scaleParameters returned nil for a non-degenerate box")
        }
        XCTAssertEqual(p.anchor, CGPoint(x: 0, y: 0), "bottom-right drag anchors at the top-left corner")
        XCTAssertEqual(p.sx, 1.5, accuracy: kEpsilon, "sx should be (150-0)/100")
        XCTAssertEqual(p.sy, 2.0, accuracy: kEpsilon, "sy should be (200-0)/100")

        // A degenerate (zero-width) box on the dragged axis returns nil.
        let degenerate = CGRect(x: 0, y: 0, width: 0, height: 100)
        XCTAssertNil(SelectionTransformController.scaleParameters(handle: .right, box: degenerate,
                                                                  to: CGPoint(x: 50, y: 50)),
                     "a zero-width box should yield no horizontal scale parameters")
    }
}
