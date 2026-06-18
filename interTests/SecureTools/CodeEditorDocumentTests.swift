//
//  CodeEditorDocumentTests.swift
//  interTests
//
//  Property-based tests for the RGA convergence core `CodeEditorDocument`
//  (collaborative-code-editor spec, Task 2; design "Correctness Properties"
//  1–7). The RGA's algebraic laws (commutativity, idempotency, causal
//  integrity, intention preservation, tombstone soundness, offset↔ID
//  round-trip, size-clamp safety) are the load-bearing convergence guarantees
//  every transport/UI layer is built on, so they are proven here against the
//  pure model FIRST.
//
//  This project does NOT integrate an external PBT library (SwiftCheck, etc.);
//  the established convention (see `StrokeModelPropertyTests`,
//  `WhiteboardValidationPropertyTests`, `CodeEditorIntegrityPropertyTests`) is
//  XCTest-driven randomized loops backed by a fixed-seed deterministic
//  SplitMix64 RNG. We follow that convention so this file is consistent with
//  its siblings and so any counterexample is reproducible:
//    - Every property runs ≥100 seeded iterations (`kRGAIterations`).
//    - Each iteration derives its own seed (`base &+ iteration`) which is
//      printed, together with the generated op trace, on failure — so a failing
//      example can be replayed exactly.
//
//  `CodeEditorDocument` is `@MainActor`, so the test case is annotated
//  accordingly.
//

import XCTest
@testable import inter

// MARK: - Deterministic, seeded RNG
//
// A SplitMix64 generator, distinctly named so it does not collide with the
// `SeededGenerator` / `WhiteboardSeededGenerator` already declared elsewhere in
// the same test target. Seeded per-iteration so every draw is reproducible.

private struct RGASeededGenerator: RandomNumberGenerator {
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

/// Minimum iterations per property (design/Task 2.9: ≥100).
private let kRGAIterations = 150

/// A generous cap so the op-generator never trips the size clamp (Property 7
/// exercises the clamp deliberately with its own small cap).
private let kBigCap = 1_000_000

private let kAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 \n\t(){};=+")

private func randomText(_ rng: inout RGASeededGenerator, length: Int) -> String {
    String((0..<length).map { _ in kAlphabet.randomElement(using: &rng)! })
}

// MARK: - Op trace (printed on failure for reproducibility)

private func describe(_ op: Op) -> String {
    func tag(_ id: ElementID) -> String { "\(id.site)#\(id.seq)" }
    switch op.kind {
    case .insert:
        let left = op.originLeft.map(tag) ?? "HEAD"
        let value = op.value.map { String($0) } ?? "?"
        return "ins(\(tag(op.id))='\(value)' after \(left))"
    case .delete:
        return "del(\(tag(op.id)))"
    }
}

private func trace(_ ops: [Op]) -> String {
    "[\n  " + ops.map(describe).joined(separator: "\n  ") + "\n]"
}

// MARK: - Two-site op-stream generator (Task 2.1)
//
// Drives two "author" documents (sites "A" and "B"). Each round one author
// performs a random local insert/delete; its generated ops are accumulated into
// a single global op SET. Authors sync their outboxes probabilistically: when
// they sync, subsequent inserts anchor to the *other* site's characters
// (cross-site `originLeft` dependencies); between syncs they edit independently
// (true concurrency after the same origin). The returned set is internally
// consistent — every insert's `originLeft` is `nil` or the id of another op in
// the set — so it can be replayed into a fresh replica in ANY permutation
// (out-of-order inserts/deletes are buffered by the document until ready).

@MainActor
private func generateOpSet(_ rng: inout RGASeededGenerator) -> [Op] {
    let a = CodeEditorDocument(site: "A", maxLiveChars: kBigCap)
    let b = CodeEditorDocument(site: "B", maxLiveChars: kBigCap)

    var all: [Op] = []
    var aOutbox: [Op] = []
    var bOutbox: [Op] = []

    func randomLocalOp(_ doc: CodeEditorDocument) -> [Op] {
        // Bias toward inserts so the document grows; delete only when non-empty.
        if doc.liveCount > 0 && Int.random(in: 0..<3, using: &rng) == 0 {
            let lo = Int.random(in: 0..<doc.liveCount, using: &rng)
            let span = Int.random(in: 1...3, using: &rng)
            let hi = min(lo + span, doc.liveCount)
            return doc.localDelete(range: lo..<hi)
        } else {
            let offset = Int.random(in: 0...doc.liveCount, using: &rng)
            let len = Int.random(in: 1...4, using: &rng)
            return doc.localInsert(at: offset, randomText(&rng, length: len))
        }
    }

    let rounds = Int.random(in: 6...26, using: &rng)
    for _ in 0..<rounds {
        // Probabilistic sync: deliver each author's outbox to the other.
        if Int.random(in: 0..<3, using: &rng) == 0 {
            for op in aOutbox { b.integrate(op) }
            for op in bOutbox { a.integrate(op) }
            aOutbox.removeAll(keepingCapacity: true)
            bOutbox.removeAll(keepingCapacity: true)
        }

        let useA = Bool.random(using: &rng)
        let ops = randomLocalOp(useA ? a : b)
        all.append(contentsOf: ops)
        if useA { aOutbox.append(contentsOf: ops) } else { bOutbox.append(contentsOf: ops) }
    }
    return all
}

// MARK: - Replica + comparison helpers

@MainActor
private func replica(applying ops: [Op], site: String = "R") -> CodeEditorDocument {
    let doc = CodeEditorDocument(site: site, maxLiveChars: kBigCap)
    for op in ops { doc.integrate(op) }
    return doc
}

/// The ordered sequence of LIVE elements as `"site#seq=char"` tokens. Two
/// replicas that have converged must produce identical signatures (identical
/// text AND identical live element ordering).
@MainActor
private func liveSignature(_ doc: CodeEditorDocument) -> [String] {
    doc.elements.filter { !$0.deleted }.map { "\($0.id.site)#\($0.id.seq)=\($0.value)" }
}

/// Independently-computed 0-based live rank of `id` (ignores the document's own
/// offset/index machinery), or `nil` if `id` is unknown or tombstoned.
@MainActor
private func independentLiveRank(of id: ElementID, in doc: CodeEditorDocument) -> Int? {
    var rank = 0
    for el in doc.elements {
        if el.id == id { return el.deleted ? nil : rank }
        if !el.deleted { rank += 1 }
    }
    return nil
}

// MARK: - Properties

@MainActor
final class CodeEditorDocumentTests: XCTestCase {

    // Feature: collaborative-code-editor, Property 1: Convergence / commutativity —
    // two replicas that integrate the same op SET in ANY order have identical
    // rendered text AND identical live element ordering.
    // Validates: Requirements 2.2, 2.3
    func testProperty1_ConvergenceCommutativity() {
        let base: UInt64 = 0xC0DE_0001_0000
        for i in 0..<kRGAIterations {
            let seed = base &+ UInt64(i)
            var rng = RGASeededGenerator(seed: seed)
            let ops = generateOpSet(&rng)

            // Replica 1: original generation order.
            let r1 = replica(applying: ops)
            // Replica 2: a different (shuffled) integration order of the SAME set.
            var shuffleRNG = RGASeededGenerator(seed: seed ^ 0xFFFF)
            let shuffled = ops.shuffled(using: &shuffleRNG)
            let r2 = replica(applying: shuffled)
            // Replica 3: reverse order (stress: many children before parents).
            let r3 = replica(applying: ops.reversed())

            let msg = { (which: String) in
                "Property 1 (\(which)) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)\nops=\(trace(ops))"
            }
            XCTAssertEqual(r1.text, r2.text, msg("text r1==r2"))
            XCTAssertEqual(r1.text, r3.text, msg("text r1==r3"))
            XCTAssertEqual(liveSignature(r1), liveSignature(r2), msg("ordering r1==r2"))
            XCTAssertEqual(liveSignature(r1), liveSignature(r3), msg("ordering r1==r3"))
        }
    }

    // Feature: collaborative-code-editor, Property 2: Idempotency — integrating any
    // op twice, and applying a full snapshot twice, equals applying it once.
    // Validates: Requirements 4.3, 8.4
    func testProperty2_Idempotency() {
        let base: UInt64 = 0xC0DE_0002_0000
        for i in 0..<kRGAIterations {
            let seed = base &+ UInt64(i)
            var rng = RGASeededGenerator(seed: seed)
            let ops = generateOpSet(&rng)

            let msg = { (which: String) in
                "Property 2 (\(which)) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)\nops=\(trace(ops))"
            }

            // Each op applied once.
            let once = replica(applying: ops)
            // Each op applied twice (re-delivery).
            let twice = CodeEditorDocument(site: "R", maxLiveChars: kBigCap)
            for op in ops {
                twice.integrate(op)
                twice.integrate(op)
            }
            XCTAssertEqual(liveSignature(once), liveSignature(twice), msg("op twice == once"))
            XCTAssertEqual(once.text, twice.text, msg("op twice text"))
            XCTAssertEqual(once.liveCount, twice.liveCount, msg("op twice liveCount"))

            // Snapshot idempotency: applying a snapshot twice to a fresh replica
            // equals applying it once.
            let snap = once.snapshot()
            let snapOnce = CodeEditorDocument(site: "S", maxLiveChars: kBigCap)
            snapOnce.applySnapshot(snap)
            let snapTwice = CodeEditorDocument(site: "S", maxLiveChars: kBigCap)
            snapTwice.applySnapshot(snap)
            snapTwice.applySnapshot(snap)
            XCTAssertEqual(liveSignature(snapOnce), liveSignature(snapTwice), msg("snapshot twice ordering"))
            XCTAssertEqual(snapOnce.text, snapTwice.text, msg("snapshot twice text"))
            // And a snapshot reproduces the source document's rendered text.
            XCTAssertEqual(snapOnce.text, once.text, msg("snapshot reproduces source text"))
            XCTAssertEqual(liveSignature(snapOnce), liveSignature(once), msg("snapshot reproduces source ordering"))
        }
    }

    // Feature: collaborative-code-editor, Property 3: Causal integrity — delivering
    // inserts out of order (a child before its `originLeft`) yields, once all ops
    // are integrated, the SAME text as in-order delivery.
    // Validates: Requirements 2.3, 4.2
    func testProperty3_CausalIntegrity() {
        let base: UInt64 = 0xC0DE_0003_0000
        for i in 0..<kRGAIterations {
            let seed = base &+ UInt64(i)
            var rng = RGASeededGenerator(seed: seed)
            let ops = generateOpSet(&rng)

            // In-order (causally-respecting generation order) reference.
            let inOrder = replica(applying: ops)

            // Reversed delivery forces, for every dependency chain, children to
            // arrive strictly before their `originLeft` (worst case for the
            // causal-readiness buffers).
            let reversed = replica(applying: ops.reversed())

            // A shuffle that interleaves the two sites arbitrarily.
            var shuffleRNG = RGASeededGenerator(seed: seed ^ 0xABCD)
            let outOfOrder = replica(applying: ops.shuffled(using: &shuffleRNG))

            let msg = { (which: String) in
                "Property 3 (\(which)) failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)\nops=\(trace(ops))"
            }
            XCTAssertEqual(inOrder.text, reversed.text, msg("reversed delivery"))
            XCTAssertEqual(inOrder.text, outOfOrder.text, msg("shuffled delivery"))
            // No insert may be silently dropped: every reachable insert id whose
            // origin is present must be integrated (no permanent buffering).
            XCTAssertEqual(inOrder.elements.count, reversed.elements.count, msg("no dropped/stuck ops"))
        }
    }

    // Feature: collaborative-code-editor, Property 4: Intention preservation — a
    // character inserted between live neighbours `a` and `b` stays between `a`
    // and `b` after concurrent edits.
    // Validates: Requirements 2.3
    func testProperty4_IntentionPreservation() {
        let base: UInt64 = 0xC0DE_0004_0000
        var produced = 0
        for i in 0..<kRGAIterations {
            let seed = base &+ UInt64(i)
            var rng = RGASeededGenerator(seed: seed)

            // Author A builds a document with at least two live characters.
            let a = CodeEditorDocument(site: "A", maxLiveChars: kBigCap)
            var setup: [Op] = []
            let seedLen = Int.random(in: 2...8, using: &rng)
            setup.append(contentsOf: a.localInsert(at: 0, randomText(&rng, length: seedLen)))
            guard a.liveCount >= 2 else { continue }

            // Pick adjacent live neighbours a(left)=k, b(right)=k+1.
            let k = Int.random(in: 0..<(a.liveCount - 1), using: &rng)
            let aID = a.id(at: k)!
            let bID = a.id(at: k + 1)!

            // Insert the "intention" character X between them (originLeft = aID).
            let insertX = a.localInsert(at: k + 1, "X")
            XCTAssertEqual(insertX.count, 1, "Property 4 setup: expected one insert op (seed=0x\(String(seed, radix: 16)))")
            let cID = insertX[0].id
            setup.append(contentsOf: insertX)

            // Concurrent edits from site B: B starts from A's state, then performs
            // random INSERTS anywhere (never deleting a/b/c), producing genuine
            // concurrency around the same region.
            let b = CodeEditorDocument(site: "B", maxLiveChars: kBigCap)
            for op in setup { b.integrate(op) }
            var concurrent: [Op] = []
            let bEdits = Int.random(in: 1...10, using: &rng)
            for _ in 0..<bEdits {
                let offset = Int.random(in: 0...b.liveCount, using: &rng)
                concurrent.append(contentsOf: b.localInsert(at: offset, randomText(&rng, length: Int.random(in: 1...3, using: &rng))))
            }

            // Integrate the full set into a fresh replica in a shuffled order.
            let allOps = setup + concurrent
            var shuffleRNG = RGASeededGenerator(seed: seed ^ 0x5151)
            let r = replica(applying: allOps.shuffled(using: &shuffleRNG))

            let msg = "Property 4 failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)\nsetup+concurrent=\(trace(allOps))"
            guard let oa = r.offset(of: aID), let oc = r.offset(of: cID), let ob = r.offset(of: bID) else {
                XCTFail("Property 4: a/b/c must all remain live. \(msg)")
                continue
            }
            XCTAssertLessThan(oa, oc, "Property 4 (a before c) \(msg)")
            XCTAssertLessThan(oc, ob, "Property 4 (c before b) \(msg)")
            produced += 1
        }
        XCTAssertGreaterThan(produced, 0, "Property 4 produced no exercised iterations")
    }

    // Feature: collaborative-code-editor, Property 5: Tombstone soundness — deleted
    // characters never reappear; `text` never contains a tombstoned element; and
    // liveCount matches text length.
    // Validates: Requirements 2.3, 5.4
    func testProperty5_TombstoneSoundness() {
        let base: UInt64 = 0xC0DE_0005_0000
        for i in 0..<kRGAIterations {
            let seed = base &+ UInt64(i)
            var rng = RGASeededGenerator(seed: seed)
            let firstBatch = generateOpSet(&rng)

            let doc = replica(applying: firstBatch)
            // Record every id that is currently a tombstone.
            let deletedIDs = Set(doc.elements.filter { $0.deleted }.map { $0.id })

            // Apply a second, independent batch of ops on top.
            var rng2 = RGASeededGenerator(seed: seed ^ 0x7777)
            let secondBatch = generateOpSet(&rng2)
            for op in secondBatch { doc.integrate(op) }

            let msg = "Property 5 failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)\nfirst=\(trace(firstBatch))\nsecond=\(trace(secondBatch))"

            // liveCount equals rendered text length.
            XCTAssertEqual(doc.text.count, doc.liveCount, "Property 5 (liveCount==text.count) \(msg)")

            // text is exactly the in-order concatenation of LIVE element values —
            // no tombstoned element contributes a character.
            let expected = String(doc.elements.filter { !$0.deleted }.map { $0.value })
            XCTAssertEqual(doc.text, expected, "Property 5 (text == live concat) \(msg)")

            // Deleted characters never reappear: once a tombstone, always a
            // tombstone, regardless of later integration.
            for id in deletedIDs {
                XCTAssertNil(doc.offset(of: id), "Property 5 (deleted id resurrected: \(id.site)#\(id.seq)) \(msg)")
                if let idx = doc.elements.firstIndex(where: { $0.id == id }) {
                    XCTAssertTrue(doc.elements[idx].deleted, "Property 5 (tombstone cleared: \(id.site)#\(id.seq)) \(msg)")
                }
            }
        }
    }

    // Feature: collaborative-code-editor, Property 6: Offset↔ID round-trip — for
    // every live offset o, offset(of: id(at: o)) == o; and an id-anchored cursor
    // resolves to the correct shifted offset after remote inserts/deletes
    // elsewhere.
    // Validates: Requirements 2.4, 2.5
    func testProperty6_OffsetIDRoundTrip() {
        let base: UInt64 = 0xC0DE_0006_0000
        for i in 0..<kRGAIterations {
            let seed = base &+ UInt64(i)
            var rng = RGASeededGenerator(seed: seed)
            let ops = generateOpSet(&rng)
            let doc = replica(applying: ops)

            let msg = "Property 6 failed: seed=0x\(String(seed, radix: 16)) iteration=\(i)\nops=\(trace(ops))"

            // Round-trip for every live offset.
            for o in 0..<doc.liveCount {
                guard let id = doc.id(at: o) else {
                    XCTFail("Property 6 (id(at:\(o)) was nil with liveCount=\(doc.liveCount)) \(msg)")
                    continue
                }
                XCTAssertEqual(doc.offset(of: id), o, "Property 6 (round-trip at offset \(o)) \(msg)")
            }
            // Out-of-range offsets resolve to nil.
            XCTAssertNil(doc.id(at: doc.liveCount), "Property 6 (offset == liveCount must be nil) \(msg)")
            XCTAssertNil(doc.id(at: -1), "Property 6 (negative offset must be nil) \(msg)")

            // Cursor-anchor survival: anchor to a live id, then apply remote ops
            // elsewhere; the anchor must still resolve to its correct (shifted)
            // offset.
            guard doc.liveCount >= 1 else { continue }
            let o0 = Int.random(in: 0..<doc.liveCount, using: &rng)
            let anchorID = doc.id(at: o0)!

            // Deterministic shift: insert `k` remote chars strictly to the LEFT of
            // the anchor (anchored at the anchor's live-left neighbour, or HEAD).
            let leftID = o0 > 0 ? doc.id(at: o0 - 1) : nil
            let k = Int.random(in: 0...6, using: &rng)
            var remoteSeq: UInt64 = 900_000
            for _ in 0..<k {
                doc.integrate(.insert(id: ElementID(site: "Z", seq: remoteSeq), value: "•", originLeft: leftID))
                remoteSeq += 1
            }

            // The anchor must still be live and report the independently-computed
            // live rank, and the round-trip must still hold.
            guard let shifted = doc.offset(of: anchorID) else {
                XCTFail("Property 6 (anchor lost after remote inserts) \(msg)")
                continue
            }
            XCTAssertEqual(shifted, independentLiveRank(of: anchorID, in: doc),
                           "Property 6 (anchor offset != independent rank) \(msg)")
            XCTAssertEqual(shifted, o0 + k,
                           "Property 6 (anchor not shifted by \(k) left-inserts: o0=\(o0)) \(msg)")
            XCTAssertEqual(doc.id(at: shifted), anchorID,
                           "Property 6 (anchor round-trip after shift) \(msg)")
        }
    }

    // Feature: collaborative-code-editor, Property 7: Size-clamp safety — with a
    // small `maxLiveChars`, local inserts past the cap are refused (return [] and
    // set didHitSizeLimit) while REMOTE ops via `integrate` still apply; the doc
    // never exceeds the cap from local input.
    // Validates: Requirements 6.3
    func testProperty7_SizeClampSafety() {
        let base: UInt64 = 0xC0DE_0007_0000
        for i in 0..<kRGAIterations {
            let seed = base &+ UInt64(i)
            var rng = RGASeededGenerator(seed: seed)

            let cap = Int.random(in: 1...12, using: &rng)
            let doc = CodeEditorDocument(site: "A", maxLiveChars: cap)
            let msg = "Property 7 failed: seed=0x\(String(seed, radix: 16)) iteration=\(i) cap=\(cap)"

            // Drive a mix of local inserts/deletes; assert local input NEVER pushes
            // liveCount past the cap, and refusals set the flag + return [].
            let localRounds = Int.random(in: 5...20, using: &rng)
            for _ in 0..<localRounds {
                if doc.liveCount > 0 && Int.random(in: 0..<4, using: &rng) == 0 {
                    let lo = Int.random(in: 0..<doc.liveCount, using: &rng)
                    let hi = min(lo + Int.random(in: 1...3, using: &rng), doc.liveCount)
                    _ = doc.localDelete(range: lo..<hi)
                } else {
                    let len = Int.random(in: 1...6, using: &rng)
                    let before = doc.liveCount
                    let ops = doc.localInsert(at: Int.random(in: 0...doc.liveCount, using: &rng),
                                              randomText(&rng, length: len))
                    if before + len > cap {
                        // Must be refused wholesale.
                        XCTAssertTrue(ops.isEmpty, "Property 7 (over-cap insert not refused) \(msg)")
                        XCTAssertTrue(doc.didHitSizeLimit, "Property 7 (didHitSizeLimit not set) \(msg)")
                        XCTAssertEqual(doc.liveCount, before, "Property 7 (refused insert mutated doc) \(msg)")
                    } else {
                        XCTAssertEqual(ops.count, len, "Property 7 (accepted insert wrong op count) \(msg)")
                    }
                }
                XCTAssertLessThanOrEqual(doc.liveCount, cap, "Property 7 (cap exceeded by local input) \(msg)")
            }

            // REMOTE ops must ALWAYS apply — convergence is never sacrificed for
            // the cap. Integrate remote inserts beyond the cap and assert they
            // take effect (liveCount may now exceed the cap).
            let liveBeforeRemote = doc.liveCount
            let remoteCount = Int.random(in: 1...8, using: &rng)
            var remoteSeq: UInt64 = 500_000
            var leftID = doc.liveCount > 0 ? doc.id(at: doc.liveCount - 1) : nil
            for _ in 0..<remoteCount {
                let id = ElementID(site: "B", seq: remoteSeq)
                doc.integrate(.insert(id: id, value: "r", originLeft: leftID))
                remoteSeq += 1
                leftID = id
            }
            XCTAssertEqual(doc.liveCount, liveBeforeRemote + remoteCount,
                           "Property 7 (remote ops were refused by the cap) \(msg)")

            // A subsequent LOCAL insert is still refused once at/over the cap, and
            // the flag is set — local input remains bounded even though remote ops
            // pushed the document over the cap.
            doc.clearSizeLimitFlag()
            let beforeFinalInsert = doc.liveCount
            let refused = doc.localInsert(at: 0, "Z")
            if beforeFinalInsert + 1 > cap {
                XCTAssertTrue(refused.isEmpty, "Property 7 (local insert not refused after remote overflow) \(msg)")
                XCTAssertTrue(doc.didHitSizeLimit, "Property 7 (flag not set after remote overflow) \(msg)")
                XCTAssertEqual(doc.liveCount, beforeFinalInsert, "Property 7 (refused insert mutated doc after overflow) \(msg)")
            }
        }
    }
}
