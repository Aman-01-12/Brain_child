//
//  BoardDocumentPropertyTests.swift
//  interTests
//
//  Property-based tests for the LWW-Element-Map convergence core
//  `BoardDocument` (collaborative-whiteboard spec, Task 2; design "Correctness
//  Properties" 1–5 and 11). A whiteboard is a *set of independently-addressable
//  elements* (not a character sequence), so every mutable property of an
//  element is its own last-writer-wins register tagged with a `(lamport, site)`
//  `BoardStamp`. Convergence is therefore a *structural* guarantee — operations
//  commute (different elements / different properties) or resolve by the
//  deterministic total order on `(lamport, site)` (same property of the same
//  element), and every operation is idempotent. These are the load-bearing
//  guarantees every transport/UI layer is built on, so they are proven here
//  against the pure model FIRST.
//
//  This project does NOT integrate an external PBT library (SwiftCheck, etc.);
//  the established convention (see `CodeEditorDocumentTests`,
//  `StrokeModelPropertyTests`, `WhiteboardValidationPropertyTests`) is
//  XCTest-driven randomized loops backed by a fixed-seed deterministic
//  SplitMix64 RNG. We follow that convention so this file is consistent with
//  its siblings and so any counterexample is reproducible:
//    - Every property runs ≥100 seeded iterations (`kBoardIterations`).
//    - Each iteration derives its own seed (`base &+ iteration`) which is
//      printed, together with the generated op trace, on failure — so a failing
//      example can be replayed exactly.
//
//  `BoardDocument` is `@MainActor`, so the test case is annotated accordingly.
//

import CoreGraphics
import XCTest
@testable import inter

// MARK: - Deterministic, seeded RNG
//
// A SplitMix64 generator, distinctly named so it does not collide with the
// `SeededGenerator` / `WhiteboardSeededGenerator` / `RGASeededGenerator` already
// declared elsewhere in the same test target. Seeded per-iteration so every
// draw is reproducible.

private struct BoardPBTGenerator: RandomNumberGenerator {
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

/// Minimum iterations per property (design/Task 2.8: ≥100).
private let kBoardIterations = 150

/// A generous cap so the op-generator never trips the element/stroke clamps
/// (Property 11 exercises the clamp deliberately with its own small cap).
private let kBoardBigCap = 1_000_000

private let kTextAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 ()[]{}<>=+-")

// MARK: - Random value helpers (all integer-derived so stored LWW values
// compare exactly — there is no floating-point arithmetic in the model, only
// register assignment, so equality is exact).

private func boardRandomText(_ rng: inout BoardPBTGenerator, length: Int) -> String {
    guard length > 0 else { return "" }
    return String((0..<length).map { _ in kTextAlphabet.randomElement(using: &rng)! })
}

private func boardRandomPoint(_ rng: inout BoardPBTGenerator) -> CGPoint {
    CGPoint(x: CGFloat(Int.random(in: -500...500, using: &rng)),
            y: CGFloat(Int.random(in: -500...500, using: &rng)))
}

private func boardRandomPoints(_ rng: inout BoardPBTGenerator) -> [CGPoint] {
    let n = Int.random(in: 1...20, using: &rng)
    return (0..<n).map { _ in boardRandomPoint(&rng) }
}

private func boardRandomRect(_ rng: inout BoardPBTGenerator) -> CGRect {
    CGRect(x: CGFloat(Int.random(in: -300...300, using: &rng)),
           y: CGFloat(Int.random(in: -300...300, using: &rng)),
           width: CGFloat(Int.random(in: 1...400, using: &rng)),
           height: CGFloat(Int.random(in: 1...400, using: &rng)))
}

private func boardRandomColor(_ rng: inout BoardPBTGenerator) -> WhiteboardColor {
    WhiteboardColor.allCases.randomElement(using: &rng)!
}

private func boardRandomNonWhiteColor(_ rng: inout BoardPBTGenerator) -> WhiteboardColor {
    WhiteboardColor.allCases.filter { $0 != .white }.randomElement(using: &rng)!
}

// MARK: - Op trace (printed on failure for reproducibility)

private func describe(_ p: BoardPropertyValue) -> String {
    switch p {
    case .present(let b):     return "present=\(b)"
    case .kind(let k):        return "kind=\(k.rawValue)"
    case .points(let pts):    return "points(\(pts.count))"
    case .frame(let f):       return "frame=\(rectSig(f))"
    case .rotation(let r):    return "rot=\(r)"
    case .strokeColor(let c): return "color=\(c)"
    case .strokeWidth(let w): return "width=\(w)"
    case .text(let t):        return "text=\(t.map { "'\($0)'" } ?? "nil")"
    case .zKey(let z):        return "zKey='\(z)'"
    case .groupId(let g):     return "group=\(g ?? "nil")"
    case .deleted(let d):     return "deleted=\(d)"
    }
}

private func describe(_ op: BoardOp) -> String {
    let kind: String
    switch op.kind {
    case .add:    kind = "add"
    case .update: kind = "upd"
    case .delete: kind = "del"
    }
    let patch = op.patch.map(describe).joined(separator: ",")
    return "\(kind)(\(op.id) @\(op.stamp.lamport)#\(op.stamp.site) [\(patch)])"
}

private func trace(_ ops: [BoardOp]) -> String {
    "[\n  " + ops.map(describe).joined(separator: "\n  ") + "\n]"
}

// MARK: - Rendered-board signature & comparison helpers

private func rectSig(_ r: CGRect) -> String {
    "\(r.origin.x),\(r.origin.y),\(r.size.width),\(r.size.height)"
}

private func pointsSig(_ pts: [CGPoint]?) -> String {
    guard let pts = pts else { return "nil" }
    return pts.map { "\($0.x):\($0.y)" }.joined(separator: "|")
}

/// A stable, fully-detailed signature token for one rendered element: id plus
/// every rendered field (kind, geometry, style, text, z-order key, group). Two
/// replicas that have converged must produce identical signatures in identical
/// order (`renderedElements` is already sorted back-to-front by `zKey`, id).
private func signature(_ el: BoardElement) -> String {
    [
        el.id,
        el.kind.rawValue,
        pointsSig(el.points),
        el.frame.map(rectSig) ?? "nil",
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
    doc.renderedElements.map(signature)
}

@MainActor
private func renderedOrder(_ doc: BoardDocument) -> [BoardElementID] {
    doc.renderedElements.map { $0.id }
}

// MARK: - Replica + generator builders

@MainActor
private func makeDoc(_ site: String) -> BoardDocument {
    BoardDocument(site: site,
                  maxElements: kBoardBigCap,
                  maxStrokePoints: kBoardBigCap,
                  maxHistoryEntries: kBoardBigCap)
}

/// A fresh replica that has integrated `ops` in the given order. Because every
/// op carries a full `(id, stamp, patch)` and `integrate` is order-independent
/// (per-property LWW + causal placeholder materialisation), the integration
/// order does not affect the converged state.
@MainActor
private func replica(applying ops: [BoardOp], site: String = "R") -> BoardDocument {
    let doc = makeDoc(site)
    for op in ops { doc.integrate(op) }
    return doc
}

@MainActor
private func randomAdd(_ doc: BoardDocument, _ rng: inout BoardPBTGenerator) -> [BoardOp] {
    let kinds: [BoardElementKind] = [.freehand, .rectangle, .ellipse, .line, .arrow, .text]
    let kind = kinds.randomElement(using: &rng)!
    let color = boardRandomColor(&rng)
    let width = CGFloat(Int.random(in: 1...8, using: &rng))
    switch kind {
    case .freehand, .line, .arrow:
        return doc.addElement(kind: kind, points: boardRandomPoints(&rng),
                              strokeColor: color, strokeWidth: width)
    case .text:
        return doc.addElement(kind: .text, frame: boardRandomRect(&rng),
                              strokeColor: color, strokeWidth: width,
                              text: boardRandomText(&rng, length: Int.random(in: 1...8, using: &rng)))
    case .rectangle, .ellipse:
        return doc.addElement(kind: kind, frame: boardRandomRect(&rng),
                              strokeColor: color, strokeWidth: width)
    }
}

@MainActor
private func randomReorder(_ doc: BoardDocument, _ id: BoardElementID, _ rng: inout BoardPBTGenerator) -> [BoardOp] {
    switch Int.random(in: 0..<4, using: &rng) {
    case 0:  return doc.bringToFront(id)
    case 1:  return doc.sendToBack(id)
    case 2:  return doc.bringForward(id)
    default: return doc.sendBackward(id)
    }
}

@MainActor
private func randomPatch(_ el: BoardElement, _ rng: inout BoardPBTGenerator) -> [BoardPropertyValue] {
    switch Int.random(in: 0..<6, using: &rng) {
    case 0:  return [.frame(boardRandomRect(&rng))]
    case 1:  return [.rotation(CGFloat(Int.random(in: 0...359, using: &rng)))]
    case 2:  return [.strokeColor(boardRandomColor(&rng))]
    case 3:  return [.strokeWidth(CGFloat(Int.random(in: 1...8, using: &rng)))]
    case 4:  return [.text(boardRandomText(&rng, length: Int.random(in: 0...8, using: &rng)))]
    default: return [.points(boardRandomPoints(&rng))]
    }
}

@MainActor
private func randomLocalOp(_ doc: BoardDocument, _ rng: inout BoardPBTGenerator) -> [BoardOp] {
    let rendered = doc.renderedElements
    let roll = Int.random(in: 0..<10, using: &rng)

    // Bias toward adds (and always add on an empty board) so the board grows.
    if rendered.isEmpty || roll < 4 {
        return randomAdd(doc, &rng)
    } else if roll < 6 {
        let el = rendered.randomElement(using: &rng)!
        return doc.updateElement(el.id, randomPatch(el, &rng))
    } else if roll < 7 {
        let el = rendered.randomElement(using: &rng)!
        return doc.deleteElement(el.id)
    } else if roll < 9 {
        let el = rendered.randomElement(using: &rng)!
        return randomReorder(doc, el.id, &rng)
    } else {
        // Group an existing group's members back apart, or form a new group.
        if let grouped = rendered.first(where: { $0.groupId != nil }), Bool.random(using: &rng) {
            let gid = grouped.groupId!
            let ids = rendered.filter { $0.groupId == gid }.map { $0.id }
            return doc.ungroup(ids)
        } else if rendered.count >= 2 {
            let count = Int.random(in: 2...min(4, rendered.count), using: &rng)
            let ids = Array(rendered.shuffled(using: &rng).prefix(count)).map { $0.id }
            return doc.group(ids)
        }
        return []
    }
}

/// Two-site op-stream generator (Task 2.1). Drives two author documents (sites
/// "A" and "B"). Each round one author performs a random local
/// add/update/delete/reorder/group op; its generated ops are accumulated into a
/// single global op SET. Authors sync their outboxes probabilistically: between
/// syncs they edit independently (true concurrency — same prior state, divergent
/// writes); on sync each author observes the other's ops (cross-site causal
/// dependencies). The returned set carries full `(id, stamp, patch)` per op, so
/// it can be replayed into a fresh replica in ANY permutation.
@MainActor
private func generateOpSet(_ rng: inout BoardPBTGenerator) -> [BoardOp] {
    let a = makeDoc("A")
    let b = makeDoc("B")

    var all: [BoardOp] = []
    var aOut: [BoardOp] = []
    var bOut: [BoardOp] = []

    let rounds = Int.random(in: 8...28, using: &rng)
    for _ in 0..<rounds {
        // Probabilistic sync: deliver each author's outbox to the other.
        if Int.random(in: 0..<3, using: &rng) == 0 {
            for op in aOut { b.integrate(op) }
            for op in bOut { a.integrate(op) }
            aOut.removeAll(keepingCapacity: true)
            bOut.removeAll(keepingCapacity: true)
        }

        let useA = Bool.random(using: &rng)
        let ops = randomLocalOp(useA ? a : b, &rng)
        all.append(contentsOf: ops)
        if useA { aOut.append(contentsOf: ops) } else { bOut.append(contentsOf: ops) }
    }
    return all
}

// MARK: - Properties

@MainActor
final class BoardDocumentPropertyTests: XCTestCase {

    // Feature: collaborative-whiteboard, Property 1: Convergence / commutativity —
    // two replicas that integrate the same op SET in ANY order render an identical
    // board (non-deleted elements in zKey order, with all properties).
    // Validates: Requirements 2.2, 2.3
    func testProperty1_ConvergenceCommutativity() {
        let base: UInt64 = 0xB0A2_0001_0000
        for i in 0..<kBoardIterations {
            let seed = base &+ UInt64(i)
            var rng = BoardPBTGenerator(seed: seed)
            let ops = generateOpSet(&rng)

            // Replica 1: original generation order.
            let r1 = replica(applying: ops)
            // Replica 2: a different (shuffled) integration order of the SAME set.
            var shuffleRNG = BoardPBTGenerator(seed: seed ^ 0xFFFF)
            let r2 = replica(applying: ops.shuffled(using: &shuffleRNG))
            // Replica 3: reverse order (stress: updates/deletes before adds).
            let r3 = replica(applying: ops.reversed())

            let msg = { (which: String) in
                "Property 1 (\(which)) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)\nops=\(trace(ops))"
            }
            XCTAssertEqual(renderedSignature(r1), renderedSignature(r2), msg("r1==r2"))
            XCTAssertEqual(renderedSignature(r1), renderedSignature(r3), msg("r1==r3"))
            XCTAssertEqual(r1.liveCount, r2.liveCount, msg("liveCount r1==r2"))
            XCTAssertEqual(r1.liveCount, r3.liveCount, msg("liveCount r1==r3"))
        }
    }

    // Feature: collaborative-whiteboard, Property 2: Idempotency — integrating any
    // op twice, and applying a full snapshot twice, equals applying it once (safe
    // under redelivery and snapshot/op overlap).
    // Validates: Requirements 6.3, 11.4
    func testProperty2_Idempotency() {
        let base: UInt64 = 0xB0A2_0002_0000
        for i in 0..<kBoardIterations {
            let seed = base &+ UInt64(i)
            var rng = BoardPBTGenerator(seed: seed)
            let ops = generateOpSet(&rng)

            let msg = { (which: String) in
                "Property 2 (\(which)) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)\nops=\(trace(ops))"
            }

            // Each op applied once vs. twice (re-delivery).
            let once = replica(applying: ops)
            let twice = makeDoc("R")
            for op in ops {
                twice.integrate(op)
                twice.integrate(op)
            }
            XCTAssertEqual(renderedSignature(once), renderedSignature(twice), msg("op twice == once"))
            XCTAssertEqual(once.liveCount, twice.liveCount, msg("op twice liveCount"))

            // Snapshot idempotency: applying a snapshot twice to a fresh replica
            // equals applying it once, and reproduces the source board.
            let snap = once.snapshot()
            let snapOnce = makeDoc("S")
            snapOnce.applySnapshot(snap)
            let snapTwice = makeDoc("S")
            snapTwice.applySnapshot(snap)
            snapTwice.applySnapshot(snap)
            XCTAssertEqual(renderedSignature(snapOnce), renderedSignature(snapTwice), msg("snapshot twice"))
            XCTAssertEqual(renderedSignature(snapOnce), renderedSignature(once), msg("snapshot reproduces source"))
            XCTAssertEqual(snapOnce.liveCount, once.liveCount, msg("snapshot liveCount"))
        }
    }

    // Feature: collaborative-whiteboard, Property 3: Per-property LWW
    // non-interference — concurrent updates to DIFFERENT properties of the same
    // element both survive; concurrent updates to the SAME property resolve to the
    // higher (lamport, site) on both replicas, regardless of integration order.
    // Validates: Requirements 2.3
    func testProperty3_PerPropertyLWWNonInterference() {
        let base: UInt64 = 0xB0A2_0003_0000
        for i in 0..<kBoardIterations {
            let seed = base &+ UInt64(i)
            var rng = BoardPBTGenerator(seed: seed)

            // A single shared element (added at a low stamp, so later concurrent
            // writes always win over the add's own property defaults).
            let src = makeDoc("A")
            let addOps = src.addElement(kind: .rectangle, frame: boardRandomRect(&rng),
                                        strokeColor: .white, strokeWidth: 1)
            guard let addOp = addOps.first else {
                XCTFail("Property 3 setup: add produced no op (seed=0x\(String(seed, radix: 16)))")
                continue
            }
            let id = addOp.id

            // --- Different properties: frame (site A) vs. strokeColor (site B). ---
            let frameVal = boardRandomRect(&rng)
            let colorVal = boardRandomNonWhiteColor(&rng)
            let opFrame = BoardOp.update(id: id, patch: [.frame(frameVal)],
                                         stamp: BoardStamp(lamport: UInt64(Int.random(in: 10...80, using: &rng)), site: "A"))
            let opColor = BoardOp.update(id: id, patch: [.strokeColor(colorVal)],
                                         stamp: BoardStamp(lamport: UInt64(Int.random(in: 10...80, using: &rng)), site: "B"))

            let diffMsg = "Property 3 (different props) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)"
            for r in [replica(applying: [addOp, opFrame, opColor]),
                      replica(applying: [addOp, opColor, opFrame])] {
                guard let el = r.element(id: id) else { XCTFail(diffMsg + " — element missing"); continue }
                XCTAssertEqual(el.frame, frameVal, diffMsg + " — frame write lost")
                XCTAssertEqual(el.strokeColor, colorVal, diffMsg + " — color write lost")
            }

            // --- Same property: two frame writes; higher (lamport, site) wins. ---
            let f1 = boardRandomRect(&rng)
            let f2 = CGRect(x: f1.origin.x + 1000, y: f1.origin.y + 7,
                            width: f1.size.width + 13, height: f1.size.height + 1) // guaranteed distinct
            let s1 = BoardStamp(lamport: UInt64(Int.random(in: 10...60, using: &rng)), site: "A")
            let s2 = BoardStamp(lamport: UInt64(Int.random(in: 10...60, using: &rng)), site: "B")
            let op1 = BoardOp.update(id: id, patch: [.frame(f1)], stamp: s1)
            let op2 = BoardOp.update(id: id, patch: [.frame(f2)], stamp: s2)
            let winner = (s1 > s2) ? f1 : f2

            let sameMsg = "Property 3 (same prop) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i) s1=\(s1.lamport)#\(s1.site) s2=\(s2.lamport)#\(s2.site)"
            for r in [replica(applying: [addOp, op1, op2]),
                      replica(applying: [addOp, op2, op1])] {
                XCTAssertEqual(r.element(id: id)?.frame, winner, sameMsg)
            }
        }
    }

    // Feature: collaborative-whiteboard, Property 4: Delete-wins safety — a delete
    // concurrent with an update leaves the element absent on both replicas (the
    // delete touches the `deleted` register, the update touches others, so the
    // tombstone survives regardless of relative stamps); and a deleted element
    // never reappears via a ≤-stamped re-assertion.
    // Validates: Requirements 2.3, 9.4
    func testProperty4_DeleteWins() {
        let base: UInt64 = 0xB0A2_0004_0000
        for i in 0..<kBoardIterations {
            let seed = base &+ UInt64(i)
            var rng = BoardPBTGenerator(seed: seed)

            let src = makeDoc("A")
            let addOps = src.addElement(kind: .ellipse, frame: boardRandomRect(&rng),
                                        strokeColor: boardRandomColor(&rng), strokeWidth: 2)
            guard let addOp = addOps.first, let liveEl = src.element(id: addOp.id) else {
                XCTFail("Property 4 setup failed (seed=0x\(String(seed, radix: 16)))")
                continue
            }
            let id = addOp.id

            // A concurrent update (touches frame) and a delete, applied in BOTH
            // orders — the element must be absent either way (delete-wins).
            let updateStamp = BoardStamp(lamport: UInt64(Int.random(in: 5...40, using: &rng)), site: "A")
            let deleteStamp = BoardStamp(lamport: UInt64(Int.random(in: 5...40, using: &rng)), site: "B")
            let updateOp = BoardOp.update(id: id, patch: [.frame(boardRandomRect(&rng))], stamp: updateStamp)
            let deleteOp = BoardOp.delete(id: id, stamp: deleteStamp)

            let msg = "Property 4 failed: seed=0x\(String(seed, radix: 16)) iteration=\(i) upd=\(updateStamp.lamport)#\(updateStamp.site) del=\(deleteStamp.lamport)#\(deleteStamp.site)"
            for r in [replica(applying: [addOp, updateOp, deleteOp]),
                      replica(applying: [addOp, deleteOp, updateOp])] {
                XCTAssertFalse(r.renderedOrderContains(id), msg + " — deleted element still rendered")
                XCTAssertEqual(r.element(id: id)?.deleted, true, msg + " — tombstone cleared")
            }

            // Resurrection guard: after a delete at stamp Sd, a re-add (deleted=false)
            // at a stamp ≤ Sd must NOT bring the element back; a strictly-higher
            // stamp re-add does (the intended undo path).
            let lowReAdd = BoardOp.add(element: liveEl,
                                       stamp: BoardStamp(lamport: deleteStamp.lamport, site: "")) // < deleteStamp (same lamport, "" < "B")
            let lowReplica = replica(applying: [addOp, deleteOp])
            lowReplica.integrate(lowReAdd)
            XCTAssertFalse(lowReplica.renderedOrderContains(id),
                           msg + " — element resurrected by a ≤-stamped re-add")
            XCTAssertEqual(lowReplica.element(id: id)?.deleted, true,
                           msg + " — tombstone cleared by a ≤-stamped re-add")

            let highReAdd = BoardOp.add(element: liveEl,
                                        stamp: BoardStamp(lamport: deleteStamp.lamport + 1, site: "A"))
            let highReplica = replica(applying: [addOp, deleteOp])
            highReplica.integrate(highReAdd)
            XCTAssertTrue(highReplica.renderedOrderContains(id),
                          msg + " — strictly-higher re-add failed to restore (control)")
        }
    }

    // Feature: collaborative-whiteboard, Property 5: Z-order convergence — for any
    // set of concurrent reorder operations over a shared base, replicas converge to
    // the same back-to-front element ordering (`zKey` is an LWW register).
    // Validates: Requirements 2.3, 3.9
    func testProperty5_ZOrderConvergence() {
        let base: UInt64 = 0xB0A2_0005_0000
        for i in 0..<kBoardIterations {
            let seed = base &+ UInt64(i)
            var rng = BoardPBTGenerator(seed: seed)

            let a = makeDoc("A")
            let b = makeDoc("B")
            var all: [BoardOp] = []

            // Shared base: adds on A, synced into B so both can reorder them.
            let n = Int.random(in: 3...7, using: &rng)
            for _ in 0..<n {
                let ops = randomAdd(a, &rng)
                all.append(contentsOf: ops)
                for op in ops { b.integrate(op) }
            }

            // Concurrent reorders on each site (NOT cross-synced → true concurrency).
            let ra = Int.random(in: 2...6, using: &rng)
            for _ in 0..<ra {
                if let el = a.renderedElements.randomElement(using: &rng) {
                    all.append(contentsOf: randomReorder(a, el.id, &rng))
                }
            }
            let rb = Int.random(in: 2...6, using: &rng)
            for _ in 0..<rb {
                if let el = b.renderedElements.randomElement(using: &rng) {
                    all.append(contentsOf: randomReorder(b, el.id, &rng))
                }
            }

            let r1 = replica(applying: all)
            var shuffleRNG = BoardPBTGenerator(seed: seed ^ 0xABCD)
            let r2 = replica(applying: all.shuffled(using: &shuffleRNG))
            let r3 = replica(applying: all.reversed())

            let msg = { (which: String) in
                "Property 5 (\(which)) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)\nops=\(trace(all))"
            }
            XCTAssertEqual(renderedOrder(r1), renderedOrder(r2), msg("order r1==r2"))
            XCTAssertEqual(renderedOrder(r1), renderedOrder(r3), msg("order r1==r3"))
            XCTAssertEqual(renderedSignature(r1), renderedSignature(r2), msg("full r1==r2"))
        }
    }

    // Feature: collaborative-whiteboard, Property 11: Size-clamp safety — with a
    // small `maxElements`, local adds past the cap are refused (return [] and set
    // `didHitElementCap`) while REMOTE ops via `integrate` are ALWAYS applied; local
    // input never pushes `liveCount` past the cap.
    // Validates: Requirements 8.3
    func testProperty11_SizeClampSafety() {
        let base: UInt64 = 0xB0A2_000B_0000
        for i in 0..<kBoardIterations {
            let seed = base &+ UInt64(i)
            var rng = BoardPBTGenerator(seed: seed)

            let cap = Int.random(in: 1...8, using: &rng)
            let doc = BoardDocument(site: "A", maxElements: cap,
                                    maxStrokePoints: kBoardBigCap, maxHistoryEntries: kBoardBigCap)
            let msg = "Property 11 failed: seed=0x\(String(seed, radix: 16)) iteration=\(i) cap=\(cap)"

            // Drive local adds past the cap; each add is one element.
            let attempts = cap + Int.random(in: 1...5, using: &rng)
            for _ in 0..<attempts {
                let before = doc.liveCount
                let ops = randomAdd(doc, &rng)
                if before < cap {
                    XCTAssertEqual(ops.count, 1, msg + " — under-cap add was refused")
                    XCTAssertEqual(doc.liveCount, before + 1, msg + " — under-cap add did not apply")
                } else {
                    XCTAssertTrue(ops.isEmpty, msg + " — over-cap local add not refused")
                    XCTAssertTrue(doc.didHitElementCap, msg + " — didHitElementCap not set")
                    XCTAssertEqual(doc.liveCount, before, msg + " — refused add mutated the board")
                }
                XCTAssertLessThanOrEqual(doc.liveCount, cap, msg + " — cap exceeded by local input")
            }
            XCTAssertEqual(doc.liveCount, cap, msg + " — board did not fill to the cap")

            // REMOTE ops must ALWAYS apply — convergence is never sacrificed for the
            // cap. Integrate remote adds beyond the cap; liveCount may now exceed it.
            let remote = makeDoc("B")
            let liveBeforeRemote = doc.liveCount
            let remoteCount = Int.random(in: 1...6, using: &rng)
            for _ in 0..<remoteCount {
                for op in randomAdd(remote, &rng) { doc.integrate(op) }
            }
            XCTAssertEqual(doc.liveCount, liveBeforeRemote + remoteCount,
                           msg + " — remote ops were refused by the cap")
            XCTAssertGreaterThan(doc.liveCount, cap, msg + " — remote overflow did not exceed the cap")

            // A subsequent LOCAL add is still refused (liveCount ≥ cap), even though
            // remote ops pushed the board over the cap.
            doc.clearCapFlags()
            let beforeFinal = doc.liveCount
            let refused = randomAdd(doc, &rng)
            XCTAssertTrue(refused.isEmpty, msg + " — local add not refused after remote overflow")
            XCTAssertTrue(doc.didHitElementCap, msg + " — flag not set after remote overflow")
            XCTAssertEqual(doc.liveCount, beforeFinal, msg + " — refused add mutated board after overflow")
        }
    }

    // Feature: collaborative-whiteboard, z-order key length is BOUNDED.
    // Regression test for the CodeRabbit chunking finding: sequential appends
    // must produce O(log N)-length z-keys, never O(N). The old "append a mid
    // digit" scheme (one extra char per add) diverged past ~256 sequential adds.
    // This fails if that O(N) scheme is restored.
    func testZOrderKeyLength_SequentialAppendsStayBounded() {
        let doc = makeDoc("A")
        var insertionOrder: [BoardElementID] = []
        let count = 3_000
        for _ in 0..<count {
            let ops = doc.addElement(kind: .rectangle,
                                     frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                     strokeColor: .white, strokeWidth: 1)
            guard ops.count == 1 else { return XCTFail("each add must yield exactly one op") }
            insertionOrder.append(ops[0].id)
        }

        let rendered = doc.renderedElements
        XCTAssertEqual(rendered.count, count, "every appended element must be present locally")

        // O(log N): ~3–4 chars for thousands of elements. The old append-a-digit
        // scheme produced keys up to `count` chars here. 32 is a generous ceiling
        // the bounded scheme stays under but an O(N) scheme blows past.
        let maxLen = rendered.map { $0.zKey.count }.max() ?? 0
        XCTAssertLessThan(maxLen, 32,
            "append keys must stay short under bounded growth (got \(maxLen))")

        // Each append lands on top, so render order (sorted by zKey) equals
        // insertion order — the keys are correctly increasing.
        XCTAssertEqual(rendered.map { $0.id }, insertionOrder,
            "sequential appends must preserve insertion order")
    }
}

// MARK: - Test-only conveniences

private extension BoardDocument {
    /// Whether `id` currently appears on the rendered board.
    func renderedOrderContains(_ id: BoardElementID) -> Bool {
        renderedElements.contains { $0.id == id }
    }
}
