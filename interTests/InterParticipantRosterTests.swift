// interTests/InterParticipantRosterTests.swift
// Unit tests for InterParticipantRoster snapshot computation.

import XCTest
@testable import inter

final class InterParticipantRosterTests: XCTestCase {

    private func makeRoster() -> (InterParticipantRoster, SnapshotSink) {
        let sink = SnapshotSink()
        let roster = InterParticipantRoster()
        roster.onSnapshot = { sink.last = $0 }
        return (roster, sink)
    }

    final class SnapshotSink {
        var last: [InterParticipantSnapshotEntry] = []
    }

    func test_localOnly_emitsSingleLocalEntry() {
        let (roster, sink) = makeRoster()
        roster.setLocal(identity: "me", displayName: "Me", cameraOn: false, micMuted: false)
        XCTAssertEqual(sink.last.count, 1)
        XCTAssertTrue(sink.last[0].isLocal)
        XCTAssertEqual(sink.last[0].identity, "me")
        XCTAssertFalse(sink.last[0].cameraOn)
    }

    func test_localFirstThenRemoteJoinOrder() {
        let (roster, sink) = makeRoster()
        roster.setLocal(identity: "me", displayName: "Me", cameraOn: true, micMuted: false)
        roster.participantJoined("a", displayName: "Alice")
        roster.participantJoined("b", displayName: "Bob")
        XCTAssertEqual(sink.last.map { $0.identity }, ["me", "a", "b"])
        XCTAssertTrue(sink.last[0].isLocal)
        XCTAssertFalse(sink.last[1].isLocal)
    }

    func test_remoteCameraOn_requiresUnmuteAndFirstFrame() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        // joined but no track/frame yet → camera off (avatar)
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.cameraOn)
        // subscribed + unmuted but still no frame → still off (avoid black feed)
        roster.cameraSubscribed("a")
        roster.cameraMuted("a", muted: false)
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.cameraOn)
        // first frame arrives → camera on
        roster.cameraFirstFrame("a")
        XCTAssertTrue(sink.last.first { $0.identity == "a" }!.cameraOn)
    }

    func test_remoteCameraMute_turnsOffEvenAfterFrame() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.cameraSubscribed("a")
        roster.cameraMuted("a", muted: false)
        roster.cameraFirstFrame("a")
        XCTAssertTrue(sink.last.first { $0.identity == "a" }!.cameraOn)
        roster.cameraMuted("a", muted: true)
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.cameraOn)
    }

    // MARK: - Mic mute truth table (F1/F2 — single source of truth)
    //
    // The host's mic-off badge + cause caption + "Ask to Unmute" menu all hinge on the
    // roster's micMuted. These rows lock the invariant that fixes the mute-on-join bug:
    // a participant is assumed MUTED until a live audio track proves otherwise, and a
    // normal (unmuted) joiner flips to live the moment didSubscribeTrack seeds isMuted.

    func test_remoteMic_defaultsMuted_untilProvenLive() {
        // F2: a freshly-joined participant (e.g. mute-on-join, who publishes NO audio
        // track and so never emits a mic event) must read MUTED, not live.
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        XCTAssertTrue(sink.last.first { $0.identity == "a" }!.micMuted,
                      "a joiner with no audio track yet must default to muted")
    }

    func test_remoteMic_seededLive_onUnmutedSubscribe() {
        // F1: a normal joiner with a live mic flips to live once the audio subscribe
        // seeds publication.isMuted == false (mirrors InterLiveKitSubscriber's audio branch).
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.micMuted("a", muted: false)   // didSubscribeTrack seed: live track
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.micMuted)
    }

    func test_remoteMic_muteUnmuteRoundTrip() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.micMuted("a", muted: false)
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.micMuted)
        roster.micMuted("a", muted: true)    // they self-mute
        XCTAssertTrue(sink.last.first { $0.identity == "a" }!.micMuted)
        roster.micMuted("a", muted: false)   // and unmute again
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.micMuted)
    }

    func test_participantLeft_removesEntry() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.participantJoined("b", displayName: "Bob")
        roster.participantLeft("a")
        XCTAssertEqual(sink.last.map { $0.identity }, ["b"])
    }

    func test_resync_reemitsCurrentSnapshot() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        sink.last = []
        roster.resync()
        XCTAssertEqual(sink.last.map { $0.identity }, ["a"])
    }

    func test_activeSpeaker_setsIsSpeakingOnMatchingEntry() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.participantJoined("b", displayName: "Bob")
        roster.setActiveSpeaker("b")
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.isSpeaking)
        XCTAssertTrue(sink.last.first { $0.identity == "b" }!.isSpeaking)
        roster.setActiveSpeaker("")   // none
        XCTAssertFalse(sink.last.first { $0.identity == "b" }!.isSpeaking)
    }

    func test_displayNameUpdate_reflectedInSnapshot() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "a")
        roster.updateDisplayName("Alice", for: "a")
        XCTAssertEqual(sink.last.first { $0.identity == "a" }!.displayName, "Alice")
    }

    func test_micMuteAndHandRaise_reflectedInSnapshot() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.micMuted("a", muted: true)
        roster.handRaised("a", raised: true)
        let e = sink.last.first { $0.identity == "a" }!
        XCTAssertTrue(e.micMuted)
        XCTAssertTrue(e.handRaised)
    }

    // MARK: - Local mic/cam propagation + no-op guard
    //
    // The self-tile mic badge is driven by the local snapshot entry's micMuted. The
    // normal-call bug was a stale seed (micMuted=YES while the mic was on) that was
    // never corrected; the wiring controller now pushes the true state via
    // setLocalMicMuted/setLocalCameraOn. These rows lock the propagation and the
    // no-change guard that keeps those frequent pushes from re-emitting needlessly.

    func test_setLocalMicMuted_updatesLocalSnapshotEntry() {
        let (roster, sink) = makeRoster()
        roster.setLocal(identity: "me", displayName: "Me", cameraOn: true, micMuted: true)
        XCTAssertTrue(sink.last.first { $0.isLocal }!.micMuted, "seeded muted")
        roster.setLocalMicMuted(false)   // mic turns on (the fix path)
        XCTAssertFalse(sink.last.first { $0.isLocal }!.micMuted,
                       "self-tile must reflect mic-on after setLocalMicMuted(false)")
    }

    func test_setLocalCameraOn_updatesLocalSnapshotEntry() {
        let (roster, sink) = makeRoster()
        roster.setLocal(identity: "me", displayName: "Me", cameraOn: false, micMuted: false)
        XCTAssertFalse(sink.last.first { $0.isLocal }!.cameraOn)
        roster.setLocalCameraOn(true)
        XCTAssertTrue(sink.last.first { $0.isLocal }!.cameraOn)
    }

    func test_setLocalMicMuted_noChangeDoesNotReemit() {
        let roster = InterParticipantRoster()
        var emits = 0
        roster.onSnapshot = { _ in emits += 1 }
        roster.setLocal(identity: "me", displayName: "Me", cameraOn: true, micMuted: false)
        XCTAssertEqual(emits, 1, "initial seed emits once")
        roster.setLocalMicMuted(false)   // same value
        XCTAssertEqual(emits, 1, "no-op push must not re-emit (guards snapshot churn)")
        roster.setLocalMicMuted(true)    // real change
        XCTAssertEqual(emits, 2, "a real change emits")
    }

    func test_setLocalCameraOn_noChangeDoesNotReemit() {
        let roster = InterParticipantRoster()
        var emits = 0
        roster.onSnapshot = { _ in emits += 1 }
        roster.setLocal(identity: "me", displayName: "Me", cameraOn: true, micMuted: false)
        XCTAssertEqual(emits, 1)
        roster.setLocalCameraOn(true)    // same value
        XCTAssertEqual(emits, 1, "no-op push must not re-emit")
        roster.setLocalCameraOn(false)   // real change
        XCTAssertEqual(emits, 2)
    }

    func test_setLocalMicMuted_beforeLocalSeed_isNoOp() {
        // Guard: pushing before the local entry exists must not crash or fabricate one.
        let roster = InterParticipantRoster()
        var emits = 0
        roster.onSnapshot = { _ in emits += 1 }
        roster.setLocalMicMuted(false)
        XCTAssertEqual(emits, 0, "no local entry yet → nothing to update")
    }

    // MARK: - B5 preservation (Property 10) — idempotent seeding / no duplicates / camera-on derivation
    //
    // Feature: secure-av-pipeline-fixes, Property 10: Preservation — B5 idempotent seeding,
    // no duplicate tiles, camera-on derivation stays `subscribed && !muted && firstFrameSeen`.
    //
    // These lock in the BASELINE behavior the B5 fix (adding `reseedPresence` to the kiosk wiring)
    // must not regress. `reseedPresence` replays participantJoined/cameraSubscribed/cameraMuted
    // for already-present participants, so the roster's seeding must be idempotent (no duplicate
    // entries) and its camera-on derivation must be unchanged. Validates: Requirements 3.14, 3.15, 3.16.

    /// Small deterministic, seedable RNG (xorshift64*) so the randomized property loop is
    /// reproducible. The project uses XCTest only (no SwiftCheck), so property tests are
    /// seeded randomized loops.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed != 0 ? seed : 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545F4914F6CDD1D
        }
    }

    /// Mirror of the roster's per-identity remote presence/media state, used to compute the
    /// EXPECTED camera-on value independently of the roster under test.
    private struct ModelState {
        var subscribed = false
        var cameraMuted = true       // assume off until proven on (matches RemoteState)
        var firstFrameSeen = false
        var camOn: Bool { subscribed && !cameraMuted && firstFrameSeen }
    }

    func test_property_seedingIdempotentAndCameraOnDerivationPreserved() {
        // Feature: secure-av-pipeline-fixes, Property 10: Preservation — no duplicate identity in
        // the emitted snapshot, and camera-on == subscribed && !muted && firstFrameSeen per entry.
        var rng = SeededRNG(seed: 0xB5_0000_5EED)   // fixed seed → reproducible
        let iterations = 200
        let identities = ["a", "b", "c"]   // small set; repeats drive idempotent re-seeding

        for iteration in 0..<iterations {
            let (roster, sink) = makeRoster()
            var model: [String: ModelState] = [:]

            let ops = 8 + Int(rng.next() % 12)   // 8…19 ops per iteration
            for _ in 0..<ops {
                let id = identities[Int(rng.next() % UInt64(identities.count))]
                switch rng.next() % 4 {
                case 0:
                    // participantJoined — first seeding creates the entry; re-seeding is a no-op
                    // for media state (only refreshes displayName).
                    roster.participantJoined(id, displayName: "name-\(id)")
                    if model[id] == nil { model[id] = ModelState() }
                case 1:
                    roster.cameraSubscribed(id)
                    if model[id] != nil { model[id]!.subscribed = true }
                case 2:
                    let muted = (rng.next() % 2) == 0
                    roster.cameraMuted(id, muted: muted)
                    if model[id] != nil {
                        model[id]!.cameraMuted = muted
                        model[id]!.firstFrameSeen = false   // roster resets firstFrameSeen on mute/unmute
                    }
                default:
                    roster.cameraFirstFrame(id)
                    if model[id] != nil { model[id]!.firstFrameSeen = true }
                }
            }

            let snapshot = sink.last

            // (1) No duplicate identity in the emitted snapshot (no duplicate tiles) — R3.15.
            let ids = snapshot.map { $0.identity }
            XCTAssertEqual(Set(ids).count, ids.count,
                           "iteration \(iteration): snapshot contains duplicate identities \(ids)")

            // Exactly one entry per seeded identity — R3.14.
            XCTAssertEqual(Set(ids), Set(model.keys),
                           "iteration \(iteration): snapshot identities \(Set(ids)) != seeded \(Set(model.keys))")

            // (2) Camera-on equals subscribed && !muted && firstFrameSeen for each entry — R3.16.
            for entry in snapshot {
                guard let expected = model[entry.identity] else { continue }
                XCTAssertEqual(entry.cameraOn, expected.camOn,
                               "iteration \(iteration): \(entry.identity) cameraOn=\(entry.cameraOn) expected \(expected.camOn) "
                               + "(subscribed=\(expected.subscribed) muted=\(expected.cameraMuted) firstFrame=\(expected.firstFrameSeen))")
            }
        }
    }

    func test_reseedingAlreadyPresentParticipant_isIdempotentNoOp() {
        // Feature: secure-av-pipeline-fixes, Property 10: Preservation — re-seeding an
        // already-present participant does NOT create a duplicate entry. Validates: Requirements 3.14, 3.15.
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        XCTAssertEqual(sink.last.map { $0.identity }, ["a"])

        // reseedPresence-style replay: join again + re-seed camera state for an existing identity.
        roster.participantJoined("a", displayName: "Alice")
        roster.cameraSubscribed("a")
        roster.cameraMuted("a", muted: false)
        roster.participantJoined("a", displayName: "Alice")   // replayed again

        XCTAssertEqual(sink.last.filter { $0.identity == "a" }.count, 1,
                       "re-seeding an already-present participant must not create a duplicate tile")
        XCTAssertEqual(sink.last.map { $0.identity }, ["a"], "still exactly one entry for a")
    }

    func test_reseedAlongsideAttach_oneEntryPerIdentity() {
        // Feature: secure-av-pipeline-fixes, Property 10: Preservation — seeding alongside
        // attach/participantDidConnect produces a roster with exactly one entry per identity.
        // Validates: Requirements 3.14, 3.15.
        let (roster, sink) = makeRoster()
        // attach-time seed
        roster.participantJoined("host", displayName: "Host")
        roster.cameraSubscribed("host")
        roster.cameraMuted("host", muted: true)
        // participantDidConnect for a second identity
        roster.participantJoined("cand", displayName: "Candidate")
        // reseedPresence replays BOTH
        roster.participantJoined("host", displayName: "Host")
        roster.cameraSubscribed("host")
        roster.cameraMuted("host", muted: true)
        roster.participantJoined("cand", displayName: "Candidate")

        let ids = sink.last.map { $0.identity }
        XCTAssertEqual(ids, ["host", "cand"], "exactly one entry per identity, join order preserved")
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicate identities")
    }

    func test_cameraOnDerivation_requiresAllThreeConditions() {
        // Feature: secure-av-pipeline-fixes, Property 10: Preservation — camera-on derivation
        // stays subscribed && !muted && firstFrameSeen. Validates: Requirements 3.16.
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        func camOn() -> Bool { sink.last.first { $0.identity == "a" }!.cameraOn }

        XCTAssertFalse(camOn(), "joined only → off")
        roster.cameraSubscribed("a")
        XCTAssertFalse(camOn(), "subscribed but muted + no frame → off")
        roster.cameraMuted("a", muted: false)
        XCTAssertFalse(camOn(), "unmuted but no frame → off")
        roster.cameraFirstFrame("a")
        XCTAssertTrue(camOn(), "subscribed && !muted && firstFrameSeen → on")
    }
}
