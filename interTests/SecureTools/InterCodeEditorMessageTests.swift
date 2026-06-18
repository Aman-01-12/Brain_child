//
//  InterCodeEditorMessageTests.swift
//  interTests
//
//  Decoder-robustness + round-trip tests for the collaborative-code-editor
//  WIRE layer `InterCodeEditorMessage` (spec Task 3.3; design "Correctness
//  Properties" Property 9 — Decoder robustness).
//
//  Property 9: malformed / oversized / out-of-range messages are rejected
//  WITHOUT mutating state or crashing — exercised with fuzz-style generators of
//  arbitrary bytes and structures.
//  Validates: Requirements 5.4, 6.3
//
//  This project does NOT integrate an external PBT library; the established
//  convention (see `CodeEditorDocumentTests`, `StrokeModelPropertyTests`,
//  `WhiteboardValidationPropertyTests`) is XCTest-driven randomized loops backed
//  by a fixed-seed deterministic SplitMix64 RNG. We follow that convention so
//  the fuzz portion is reproducible: each iteration derives its own seed
//  (`base &+ iteration`) which is printed on failure. The decoder invariant
//  asserted under fuzzing is: `fromJSONData` returns either `nil` OR a message
//  that is `isStructurallyValid` — never a half-formed value, and never a crash.
//

import XCTest
@testable import inter

// MARK: - Deterministic, seeded RNG (SplitMix64), file-private to this suite

private struct WireFuzzGenerator: RandomNumberGenerator {
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

/// Minimum fuzz iterations (design/Task 3.3: ≥100 for the fuzz portion).
private let kFuzzIterations = 200

final class InterCodeEditorMessageTests: XCTestCase {

    // MARK: - Round-trip: encode each variant, decode back to an equal value

    func testRoundTrip_OpsMessage() {
        let ops: [Op] = [
            .insert(id: ElementID(site: "A", seq: 1), value: "h", originLeft: nil),
            .insert(id: ElementID(site: "A", seq: 2), value: "i", originLeft: ElementID(site: "A", seq: 1)),
            .delete(id: ElementID(site: "B", seq: 7))
        ]
        let message = InterCodeEditorMessage.opsMessage(ops, senderIdentity: "A")

        guard let data = message.toJSONData(),
              let decoded = InterCodeEditorMessage.fromJSONData(data) else {
            return XCTFail("ops message failed to encode/decode")
        }
        XCTAssertEqual(decoded, message, "ops envelope did not round-trip")
        XCTAssertEqual(decoded.toOps(), ops, "ops did not round-trip back to the model")
    }

    func testRoundTrip_CursorMessage() {
        let anchor = ElementID(site: "A", seq: 3)
        let head = ElementID(site: "B", seq: 9)
        let message = InterCodeEditorMessage.cursorMessage(anchorId: anchor, headId: head, senderIdentity: "A")

        guard let data = message.toJSONData(),
              let decoded = InterCodeEditorMessage.fromJSONData(data) else {
            return XCTFail("cursor message failed to encode/decode")
        }
        XCTAssertEqual(decoded, message, "cursor envelope did not round-trip")
        let cursor = decoded.toCursor()
        XCTAssertEqual(cursor?.anchor, anchor)
        XCTAssertEqual(cursor?.head, head)
    }

    func testRoundTrip_LanguageMessage() {
        let message = InterCodeEditorMessage.languageMessage(language: "python", lamport: 42, senderIdentity: "A")

        guard let data = message.toJSONData(),
              let decoded = InterCodeEditorMessage.fromJSONData(data) else {
            return XCTFail("language message failed to encode/decode")
        }
        XCTAssertEqual(decoded, message, "language envelope did not round-trip")
        let language = decoded.toLanguage()
        XCTAssertEqual(language?.language, "python")
        XCTAssertEqual(language?.lamport, 42)
    }

    func testRoundTrip_SnapshotRequestMessage() {
        let message = InterCodeEditorMessage.snapshotRequestMessage(senderIdentity: "A")

        guard let data = message.toJSONData(),
              let decoded = InterCodeEditorMessage.fromJSONData(data) else {
            return XCTFail("snapshotRequest message failed to encode/decode")
        }
        XCTAssertEqual(decoded, message, "snapshotRequest envelope did not round-trip")
        XCTAssertEqual(decoded.type, .snapshotRequest)
    }

    func testRoundTrip_SnapshotMessage() {
        let elements: [Element] = [
            Element(id: ElementID(site: "A", seq: 1), value: "x", originLeft: nil, deleted: false),
            Element(id: ElementID(site: "A", seq: 2), value: "y", originLeft: ElementID(site: "A", seq: 1), deleted: true),
            Element(id: ElementID(site: "B", seq: 5), value: "z", originLeft: ElementID(site: "A", seq: 1), deleted: false)
        ]
        let snapshot = Snapshot(elements: elements, seqVector: ["A": 2, "B": 5])
        let message = InterCodeEditorMessage.snapshotMessage(snapshot, language: "go", lamport: 7, senderIdentity: "A")

        guard let data = message.toJSONData(),
              let decoded = InterCodeEditorMessage.fromJSONData(data) else {
            return XCTFail("snapshot message failed to encode/decode")
        }
        XCTAssertEqual(decoded, message, "snapshot envelope did not round-trip")

        guard let recovered = decoded.toSnapshot() else {
            return XCTFail("snapshot did not decode back to the model")
        }
        XCTAssertEqual(recovered.snapshot.elements, elements, "snapshot elements did not round-trip")
        XCTAssertEqual(recovered.language, "go")
        XCTAssertEqual(recovered.lamport, 7)
        // seqVector is reconstructed from element ids (max seq per site).
        XCTAssertEqual(recovered.snapshot.seqVector, ["A": 2, "B": 5], "seqVector reconstruction wrong")
    }

    /// A multi-SCALAR but single-`Character` value (emoji) is a valid character
    /// and must survive the round-trip.
    func testRoundTrip_MultiScalarGraphemeValue() {
        let ops: [Op] = [.insert(id: ElementID(site: "A", seq: 1), value: "🇮🇳", originLeft: nil)]
        let message = InterCodeEditorMessage.opsMessage(ops, senderIdentity: "A")
        guard let data = message.toJSONData(),
              let decoded = InterCodeEditorMessage.fromJSONData(data) else {
            return XCTFail("emoji op failed to encode/decode")
        }
        XCTAssertEqual(decoded.toOps(), ops, "multi-scalar grapheme did not round-trip")
    }

    // MARK: - Ceiling: oversized payloads are rejected

    func testOversizedPayloadRejected() {
        // Build a STRUCTURALLY VALID snapshot whose encoding exceeds the 12 KB
        // ceiling; it must be rejected purely on size.
        var elements: [Element] = []
        for i in 0..<2000 {
            elements.append(Element(id: ElementID(site: "A", seq: UInt64(i + 1)),
                                    value: "x",
                                    originLeft: i == 0 ? nil : ElementID(site: "A", seq: UInt64(i)),
                                    deleted: false))
        }
        let snapshot = Snapshot(elements: elements, seqVector: ["A": 2000])
        let message = InterCodeEditorMessage.snapshotMessage(snapshot, language: "c", lamport: 1, senderIdentity: "A")

        guard let data = message.toJSONData() else { return XCTFail("could not encode oversized snapshot") }
        XCTAssertGreaterThan(data.count, InterCodeEditorMessage.maxMessageBytes,
                             "test fixture is not actually oversized")
        XCTAssertNil(InterCodeEditorMessage.fromJSONData(data),
                     "oversized payload (> maxMessageBytes) must be rejected")
    }

    // MARK: - Structural rejection: unknown type / kind, missing / out-of-range

    func testUnknownTypeRejected() {
        let json = #"{"type":"bogus","senderIdentity":"A"}"#
        XCTAssertNil(InterCodeEditorMessage.fromJSONData(Data(json.utf8)),
                     "unknown discriminator must be rejected")
    }

    func testUnknownOpKindRejected() {
        let json = #"{"type":"ops","senderIdentity":"A","ops":[{"kind":"patch","id":{"site":"A","seq":1}}]}"#
        XCTAssertNil(InterCodeEditorMessage.fromJSONData(Data(json.utf8)),
                     "unknown op kind must be rejected")
    }

    func testMissingPayloadRejected() {
        let cases = [
            #"{"type":"ops","senderIdentity":"A"}"#,        // no ops
            #"{"type":"ops","senderIdentity":"A","ops":[]}"#, // empty batch
            #"{"type":"cursor","senderIdentity":"A"}"#,     // no cursor
            #"{"type":"language","senderIdentity":"A"}"#,   // no language
            #"{"type":"snapshot","senderIdentity":"A"}"#    // no snapshot
        ]
        for json in cases {
            XCTAssertNil(InterCodeEditorMessage.fromJSONData(Data(json.utf8)),
                         "missing required payload must be rejected: \(json)")
        }
    }

    func testMissingRequiredFieldsRejected() {
        let cases = [
            // insert without a value
            #"{"type":"ops","senderIdentity":"A","ops":[{"kind":"ins","id":{"site":"A","seq":1}}]}"#,
            // empty site (malformed id)
            #"{"type":"ops","senderIdentity":"A","ops":[{"kind":"del","id":{"site":"","seq":1}}]}"#,
            // empty-string language register
            #"{"type":"language","senderIdentity":"A","language":{"language":"","lamport":1}}"#,
            // cursor with malformed (empty-site) head
            #"{"type":"cursor","senderIdentity":"A","cursor":{"anchorId":{"site":"A","seq":1},"headId":{"site":"","seq":2}}}"#
        ]
        for json in cases {
            XCTAssertNil(InterCodeEditorMessage.fromJSONData(Data(json.utf8)),
                         "missing/invalid required field must be rejected: \(json)")
        }
    }

    func testNonSingleCharacterValueRejected() {
        let cases = [
            // multi-character value
            #"{"type":"ops","senderIdentity":"A","ops":[{"kind":"ins","id":{"site":"A","seq":1},"value":"ab"}]}"#,
            // empty-string value
            #"{"type":"ops","senderIdentity":"A","ops":[{"kind":"ins","id":{"site":"A","seq":1},"value":""}]}"#
        ]
        for json in cases {
            XCTAssertNil(InterCodeEditorMessage.fromJSONData(Data(json.utf8)),
                         "non-single-Character value must be rejected: \(json)")
        }
    }

    func testOutOfRangeNumbersRejected() {
        let cases = [
            // negative seq (UInt64 cannot be negative)
            #"{"type":"ops","senderIdentity":"A","ops":[{"kind":"del","id":{"site":"A","seq":-1}}]}"#,
            // seq beyond UInt64.max
            #"{"type":"ops","senderIdentity":"A","ops":[{"kind":"del","id":{"site":"A","seq":99999999999999999999999999}}]}"#,
            // negative lamport
            #"{"type":"language","senderIdentity":"A","language":{"language":"go","lamport":-5}}"#
        ]
        for json in cases {
            XCTAssertNil(InterCodeEditorMessage.fromJSONData(Data(json.utf8)),
                         "out-of-range number must be rejected: \(json)")
        }
    }

    // MARK: - Truncated / empty / garbage bytes

    func testEmptyDataRejected() {
        XCTAssertNil(InterCodeEditorMessage.fromJSONData(Data()),
                     "empty data must be rejected")
    }

    func testTruncatedJSONRejected() {
        let ops: [Op] = [.insert(id: ElementID(site: "A", seq: 1), value: "h", originLeft: nil)]
        let message = InterCodeEditorMessage.opsMessage(ops, senderIdentity: "A")
        guard let data = message.toJSONData(), data.count > 4 else {
            return XCTFail("could not build fixture")
        }
        // Drop the trailing bytes — the JSON is now structurally incomplete.
        for drop in [1, 2, 5] where drop < data.count {
            let truncated = data.prefix(data.count - drop)
            XCTAssertNil(InterCodeEditorMessage.fromJSONData(Data(truncated)),
                         "truncated JSON (dropped \(drop)) must be rejected")
        }
    }

    /// Fuzz: arbitrary random bytes must NEVER crash the decoder, and must
    /// NEVER yield a structurally-invalid message. ≥100 seeded iterations; the
    /// seed is printed on failure so any counterexample can be replayed.
    func testFuzz_ArbitraryBytesNeverCrashOrYieldInvalid() {
        let base: UInt64 = 0xC0DE_0009_0000
        for i in 0..<kFuzzIterations {
            let seed = base &+ UInt64(i)
            var rng = WireFuzzGenerator(seed: seed)

            // Random length, occasionally above the ceiling to exercise that path.
            let length = Int(rng.next() % 16_384)
            var bytes = [UInt8]()
            bytes.reserveCapacity(length)
            for _ in 0..<length { bytes.append(UInt8(rng.next() & 0xFF)) }
            let data = Data(bytes)

            // The decoder must not crash. The invariant: it returns nil, or a
            // message that is structurally valid — never an invalid object.
            if let decoded = InterCodeEditorMessage.fromJSONData(data) {
                XCTAssertTrue(decoded.isStructurallyValid,
                              "Fuzz produced an invalid message: seed=0x\(String(seed, radix: 16)) iteration=\(i)")
                XCTAssertLessThanOrEqual(data.count, InterCodeEditorMessage.maxMessageBytes,
                                         "Fuzz accepted oversized payload: seed=0x\(String(seed, radix: 16)) iteration=\(i)")
            }
        }
    }

    /// Fuzz: mutate a VALID encoded message by flipping random bytes. The result
    /// must still be rejected-or-valid, never invalid, never a crash.
    func testFuzz_MutatedValidMessageNeverYieldsInvalid() {
        let base: UInt64 = 0xC0DE_0009_5000
        let seedOps: [Op] = [
            .insert(id: ElementID(site: "A", seq: 1), value: "h", originLeft: nil),
            .insert(id: ElementID(site: "A", seq: 2), value: "i", originLeft: ElementID(site: "A", seq: 1))
        ]
        guard let valid = InterCodeEditorMessage.opsMessage(seedOps, senderIdentity: "A").toJSONData() else {
            return XCTFail("could not build fixture")
        }

        for i in 0..<kFuzzIterations {
            let seed = base &+ UInt64(i)
            var rng = WireFuzzGenerator(seed: seed)
            var bytes = [UInt8](valid)
            let flips = Int(rng.next() % 8) + 1
            for _ in 0..<flips {
                guard !bytes.isEmpty else { break }
                let index = Int(rng.next() % UInt64(bytes.count))
                bytes[index] = UInt8(rng.next() & 0xFF)
            }
            let data = Data(bytes)
            if let decoded = InterCodeEditorMessage.fromJSONData(data) {
                XCTAssertTrue(decoded.isStructurallyValid,
                              "Mutation produced an invalid message: seed=0x\(String(seed, radix: 16)) iteration=\(i)")
            }
        }
    }
}
