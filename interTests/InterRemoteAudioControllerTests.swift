//
//  InterRemoteAudioControllerTests.swift
//  interTests
//
//  Tests for the pure speaker-mute / recording-sink reconciliation policy
//  (spec: recording-safe-speaker-mute). The policy is side-effect-free, so the
//  edge-case coverage (recording started before/after a join, join during
//  recording, leave/rejoin, toggle) can be proven without a live LiveKit room.
//

import XCTest
@testable import inter

final class InterRemoteAudioControllerTests: XCTestCase {

    // MARK: - Volume (R1, R3)

    func testVolumeForMuteState() {
        XCTAssertEqual(InterRemoteAudioPolicy.volume(muted: true), 0.0)
        XCTAssertEqual(InterRemoteAudioPolicy.volume(muted: false), 1.0)
    }

    // MARK: - Desired sinks (R2 + edge cases)

    func testDesiredSinks_noneWhenNotRecording() {
        let sids: Set<String> = ["a", "b", "c"]
        XCTAssertEqual(InterRemoteAudioPolicy.desiredSinks(recordingActive: false, trackSids: sids), [])
    }

    func testDesiredSinks_allTracksWhenRecording() {
        let sids: Set<String> = ["a", "b", "c"]
        XCTAssertEqual(InterRemoteAudioPolicy.desiredSinks(recordingActive: true, trackSids: sids), sids)
    }

    func testDesiredSinks_emptyTracks() {
        XCTAssertEqual(InterRemoteAudioPolicy.desiredSinks(recordingActive: true, trackSids: []), [])
    }

    // MARK: - Diff (idempotent, order-independent)

    func testSinkDiff_addsMissingRemovesExtra() {
        let (add, remove) = InterRemoteAudioPolicy.sinkDiff(current: ["a", "b"], desired: ["b", "c"])
        XCTAssertEqual(add, ["c"])
        XCTAssertEqual(remove, ["a"])
    }

    func testSinkDiff_noChangeWhenEqual() {
        let (add, remove) = InterRemoteAudioPolicy.sinkDiff(current: ["a", "b"], desired: ["a", "b"])
        XCTAssertTrue(add.isEmpty)
        XCTAssertTrue(remove.isEmpty)
    }

    // MARK: - Convergence simulation (the three named edge cases + combinations)

    /// Model the controller's reconcile: apply the diff to `current`, assert it equals desired.
    private func applyReconcile(current: inout Set<String>, recordingActive: Bool, tracks: Set<String>) {
        let desired = InterRemoteAudioPolicy.desiredSinks(recordingActive: recordingActive, trackSids: tracks)
        let (add, remove) = InterRemoteAudioPolicy.sinkDiff(current: current, desired: desired)
        current.subtract(remove)
        current.formUnion(add)
        XCTAssertEqual(current, desired, "reconcile must converge to desired sink set")
    }

    func testEdge_recordingStartedBeforeAnyParticipant() {
        var sinks: Set<String> = []
        var tracks: Set<String> = []
        var recording = false
        // record starts (no participants)
        recording = true; applyReconcile(current: &sinks, recordingActive: recording, tracks: tracks)
        XCTAssertTrue(sinks.isEmpty)
        // participant joins later
        tracks.insert("p1"); applyReconcile(current: &sinks, recordingActive: recording, tracks: tracks)
        XCTAssertEqual(sinks, ["p1"])
    }

    func testEdge_recordingStartedAfterParticipantJoined() {
        var sinks: Set<String> = []
        var tracks: Set<String> = ["p1"]   // already present
        var recording = false
        recording = true; applyReconcile(current: &sinks, recordingActive: recording, tracks: tracks)
        XCTAssertEqual(sinks, ["p1"], "start-reconcile must add sinks for pre-existing participants")
    }

    func testEdge_participantJoinsDuringRecording() {
        var sinks: Set<String> = ["p1"]
        var tracks: Set<String> = ["p1"]
        let recording = true
        tracks.insert("p2"); applyReconcile(current: &sinks, recordingActive: recording, tracks: tracks)
        XCTAssertEqual(sinks, ["p1", "p2"])
    }

    func testEdge_stopRecordingRemovesAllSinks() {
        var sinks: Set<String> = ["p1", "p2"]
        let tracks: Set<String> = ["p1", "p2"]
        applyReconcile(current: &sinks, recordingActive: false, tracks: tracks)
        XCTAssertTrue(sinks.isEmpty)
    }

    /// Property: for any randomized sequence of events, the reconciled sink set always
    /// equals `recordingActive ? tracks : {}` — coverage is order-independent.
    func testProperty_reconcileConvergesForRandomSequences() {
        var rng = SeededRNG(seed: 0xA5A5_1234)
        let pool = ["p1", "p2", "p3", "p4", "p5"]
        for _ in 0..<500 {
            var sinks: Set<String> = []
            var tracks: Set<String> = []
            var recording = false
            for _ in 0..<40 {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: tracks.insert(pool[Int.random(in: 0..<pool.count, using: &rng)])   // join
                case 1: if !tracks.isEmpty { tracks.remove(tracks.randomElement(using: &rng)!) } // leave
                case 2: recording = true     // start
                default: recording = false   // stop
                }
                applyReconcile(current: &sinks, recordingActive: recording, tracks: tracks)
            }
            // Final invariant
            let expected = recording ? tracks : []
            XCTAssertEqual(sinks, expected)
        }
    }
}

// Deterministic RNG so the randomized property is reproducible.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed != 0 ? seed : 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
