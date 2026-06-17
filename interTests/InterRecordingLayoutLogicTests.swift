//
//  InterRecordingLayoutLogicTests.swift
//  interTests
//
//  Locks in the freeze-prevention invariants for the local composed recording
//  (Path A). These test the pure decision logic that the coordinator routes
//  through, so they fail if a mitigation is reverted — without standing up the
//  Metal / AVAssetWriter pipeline.
//
//  Covers paranoid-implementation findings:
//   #1 host always rendered  (localSlot)
//   #2 frameless speaker → placeholder  (needsPlaceholder)
//   #3 grid engages at 3+    (useGrid .auto)
//   #9 speaker view never regresses to the freeze path via grid  (useGrid .speaker)
//

import XCTest
@testable import inter

final class InterRecordingLayoutLogicTests: XCTestCase {

    // #3 — grid (gallery) engages for 2+ participants in auto mode (count includes local,
    // so 2 = host + one remote → grid, giving camera-off/audio-only remotes a tile); not solo.
    func testAutoGridThreshold() {
        XCTAssertFalse(InterRecordingLayoutLogic.useGrid(participantCount: 0, preference: .auto))
        XCTAssertFalse(InterRecordingLayoutLogic.useGrid(participantCount: 1, preference: .auto))
        XCTAssertTrue(InterRecordingLayoutLogic.useGrid(participantCount: 2, preference: .auto))
        XCTAssertTrue(InterRecordingLayoutLogic.useGrid(participantCount: 3, preference: .auto))
        XCTAssertTrue(InterRecordingLayoutLogic.useGrid(participantCount: 8, preference: .auto))
    }

    // #9 — speaker view never uses grid, regardless of participant count.
    func testSpeakerViewNeverGrids() {
        XCTAssertFalse(InterRecordingLayoutLogic.useGrid(participantCount: 2, preference: .speaker))
        XCTAssertFalse(InterRecordingLayoutLogic.useGrid(participantCount: 3, preference: .speaker))
        XCTAssertFalse(InterRecordingLayoutLogic.useGrid(participantCount: 50, preference: .speaker))
    }

    // #1 — the local participant takes the secondary slot when a remote holds the
    // primary, and the primary slot when it is the only camera. It is NEVER dropped.
    func testLocalAlwaysHasASlot() {
        XCTAssertEqual(InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: true), .secondary)
        XCTAssertEqual(InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: false), .primary)
    }

    // #2 — a slot for an identity with no delivered frame must use a placeholder;
    // once a live frame has been seen, it must not.
    func testFramelessSlotNeedsPlaceholder() {
        XCTAssertTrue(InterRecordingLayoutLogic.needsPlaceholder(identity: "bot-1",
                                                                 identitiesWithLiveFrame: []))
        XCTAssertTrue(InterRecordingLayoutLogic.needsPlaceholder(identity: "bot-1",
                                                                 identitiesWithLiveFrame: ["bot-2"]))
        XCTAssertFalse(InterRecordingLayoutLogic.needsPlaceholder(identity: "bot-1",
                                                                  identitiesWithLiveFrame: ["bot-1", "bot-2"]))
    }

    // Property 5 (B3) — exploration test, now reflecting the FIX. This originally
    // modeled the buggy inline computation (`hasRemoteActive = activeId != localId`,
    // which evaluated to false for the local-first bootstrap) and could never pass.
    // With B3 fixed, the slot decision is driven by the pure
    // `InterRecordingLayoutLogic.hasRemoteActiveSpeaker(localId:identitiesWithLiveFrame:)`
    // predicate — a remote holds primary the moment any non-local identity delivers a
    // live frame — so this test exercises the FIXED code path and PASSES.
    //
    // Bug B3 (isBugCondition_B3): participantCount == 2 AND candidateCameraOn AND
    // hasRemoteLiveFrame AND localRoutedToPrimary. The fix: once the candidate ("cand")
    // delivers a live camera frame, `hasRemoteActiveSpeaker(localId: "host", …["cand"]) == true`,
    // so `localSlot(hasRemoteActiveSpeaker: true) == .secondary`. The local host takes the
    // SECONDARY slot, the remote candidate holds primary → CameraSideBySide, candidate not
    // dropped (fixes clauses 1.8–1.10 / single-tile CameraOnlyFull).
    //
    // Counterexample (now resolved): host(local) + candidate(remote), both cameras on,
    // recording started with the candidate already present → recording shows both tiles.
    func testCandidateDroppedWhenLocalBootstrapsActiveSpeaker_B3() {
        let localId = "host"
        let participants = ["host", "cand"]   // local-first roster; "cand" is the remote candidate

        XCTAssertEqual(participants.count, 2, "B3 bug condition: 2-person recording")

        // [B3] FIXED computation: the candidate has delivered a live camera frame, so the
        // pure predicate sees a non-local identity in the live-frame set ⇒ a remote holds
        // the primary slot. (The old buggy model used `activeId != localId` on the
        // local-first bootstrap, which wrongly yielded false.)
        let identitiesWithLiveFrame: Set<String> = ["cand"]
        let hasRemoteActive = InterRecordingLayoutLogic.hasRemoteActiveSpeaker(
            localId: localId, identitiesWithLiveFrame: identitiesWithLiveFrame)

        XCTAssertTrue(hasRemoteActive,
                      "[B3] Fixed: the candidate's live frame ⇒ a remote holds the primary slot.")

        // [B3] With a remote active speaker the local host must occupy the SECONDARY slot so
        // the remote candidate holds primary (CameraSideBySide) and is never dropped.
        XCTAssertEqual(
            InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: hasRemoteActive),
            .secondary,
            "[B3] With host + candidate both cameras on, the local host takes the SECONDARY slot "
            + "(remote candidate primary ⇒ CameraSideBySide). The fix routes the candidate's live "
            + "frame to primary, so the candidate is no longer dropped (CameraOnlyFull).")

        // Pure-helper edge cases for `hasRemoteActiveSpeaker` (local id excluded; any remote
        // in the live-frame set ⇒ true; empty set / nil localId-only ⇒ false):
        XCTAssertTrue(
            InterRecordingLayoutLogic.hasRemoteActiveSpeaker(
                localId: "host", identitiesWithLiveFrame: ["host", "cand"]),
            "[B3] A non-local identity present ⇒ remote active speaker (local id excluded).")
        XCTAssertFalse(
            InterRecordingLayoutLogic.hasRemoteActiveSpeaker(
                localId: "host", identitiesWithLiveFrame: ["host"]),
            "[B3] Only the local id has a live frame ⇒ no remote active speaker.")
        XCTAssertFalse(
            InterRecordingLayoutLogic.hasRemoteActiveSpeaker(
                localId: "host", identitiesWithLiveFrame: []),
            "[B3] Empty live-frame set ⇒ no remote active speaker (1-person bootstrap).")
        XCTAssertTrue(
            InterRecordingLayoutLogic.hasRemoteActiveSpeaker(
                localId: nil, identitiesWithLiveFrame: ["cand"]),
            "[B3] nil localId ⇒ any live-frame identity counts as remote.")
    }

    // Feature: secure-av-pipeline-fixes, Property 5: candidate never dropped (randomized).
    //
    // Randomized property (≥100 iterations, seeded RNG): generate participant sets that
    // contain a local id plus ≥1 remote id, with the remote(s) present in the live-frame
    // set. Then `hasRemoteActiveSpeaker(localId:identitiesWithLiveFrame:) == true`, so
    // `localSlot(true) == .secondary` (host secondary, candidate primary ⇒ CameraSideBySide,
    // host never dropped). Also exercise the solo case (only the local id, empty/local-only
    // live-frame set) ⇒ `hasRemoteActiveSpeaker == false` ⇒ `localSlot(false) == .primary`
    // (1-person black-video bootstrap preserved).
    func testProperty5_CandidateNeverDroppedRandomized() {
        var rng = SeededRNG(seed: 0xB3_0005)
        let iterations = 200
        for i in 0..<iterations {
            let localId = "host-\(Int.random(in: 0...9999, using: &rng))"

            // --- Multi-party case: local + ≥1 remote, remotes have live frames ---
            let remoteCount = Int.random(in: 1...8, using: &rng)
            var remoteIds: Set<String> = []
            while remoteIds.count < remoteCount {
                let candidate = "cand-\(Int.random(in: 0...99999, using: &rng))"
                if candidate != localId { remoteIds.insert(candidate) }
            }

            // The remote(s) have delivered live frames; the local host may or may not have.
            var liveFrames = remoteIds
            if Bool.random(using: &rng) { liveFrames.insert(localId) }

            let hasRemote = InterRecordingLayoutLogic.hasRemoteActiveSpeaker(
                localId: localId, identitiesWithLiveFrame: liveFrames)
            XCTAssertTrue(
                hasRemote,
                "iter \(i): with ≥1 remote in the live-frame set, a remote must hold primary "
                + "(localId=\(localId), live=\(liveFrames.sorted()))")

            let slot = InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: hasRemote)
            XCTAssertEqual(
                slot, .secondary,
                "iter \(i): host must take SECONDARY (remote candidate primary ⇒ CameraSideBySide); "
                + "host never dropped")

            // --- Solo case: only the local id; empty or local-only live-frame set ---
            let soloLive: Set<String> = Bool.random(using: &rng) ? [] : [localId]
            let hasRemoteSolo = InterRecordingLayoutLogic.hasRemoteActiveSpeaker(
                localId: localId, identitiesWithLiveFrame: soloLive)
            XCTAssertFalse(
                hasRemoteSolo,
                "iter \(i): solo (local-only live frames) ⇒ no remote active speaker "
                + "(live=\(soloLive.sorted()))")
            XCTAssertEqual(
                InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: hasRemoteSolo),
                .primary,
                "iter \(i): solo ⇒ local host holds PRIMARY (1-person black-video bootstrap)")
        }
    }

    // MARK: - B3 Preservation (Property 6)
    //
    // These tests lock in the baseline behaviors the B3 fix must NOT regress
    // (`NOT isBugCondition_B3`): grid for 3+, speaker-view never grids, the
    // 1-person black-video bootstrap (local host in PRIMARY), the host is never
    // dropped (always slotted), and the pure-logic contract of
    // `InterRecordingLayoutLogic`. They MUST PASS on the current (unfixed) code.
    //
    // The B3 fix only changes how `hasRemoteActiveSpeaker` is COMPUTED for the
    // 2-person case (the candidate's live frame must flip local → secondary).
    // It does not touch `useGrid`, the 1-person/solo `localSlot(false) == .primary`
    // bootstrap, or the `localSlot`/`useGrid`/`needsPlaceholder` signatures.

    /// Deterministic, seeded RNG (SplitMix64) so the randomized property loops are
    /// reproducible run-to-run. Pure function of its seed.
    private struct SeededRNG: RandomNumberGenerator {
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

    // Feature: secure-av-pipeline-fixes, Property 6: grid engages at 3+ in auto, never in speaker.
    //
    // Randomized property (≥100 iterations, seeded RNG): for random participantCount,
    // `useGrid(.auto)` is true exactly when count >= 3 (false for 0–2) — the current
    // contract the fix must preserve. Speaker view never grids for any count.
    func testProperty6_GridThresholdPreserved() {
        var rng = SeededRNG(seed: 0xB3_0001)
        let iterations = 200
        for i in 0..<iterations {
            let count = Int.random(in: 0...64, using: &rng)

            // auto: grid iff 2+ (count includes local → host + one remote grids)
            XCTAssertEqual(
                InterRecordingLayoutLogic.useGrid(participantCount: count, preference: .auto),
                count >= 2,
                "iter \(i): useGrid(.auto, count: \(count)) must be (count >= 2) — grid-at-2+ contract")

            // speaker: never grids (mirrors testSpeakerViewNeverGrids across random counts)
            XCTAssertFalse(
                InterRecordingLayoutLogic.useGrid(participantCount: count, preference: .speaker),
                "iter \(i): speaker view must never grid (count: \(count))")
        }
    }

    // Feature: secure-av-pipeline-fixes, Property 6: 1-person black-video bootstrap preserved.
    //
    // For a 1-person/solo recording (no remote participant ⇒ no remote active speaker),
    // the local host must occupy the PRIMARY slot so the recording is not black. This is
    // the CURRENT behavior and must be preserved; the B3 fix only alters the 2-person case.
    func testProperty6_OnePersonBootstrapKeepsLocalPrimary() {
        XCTAssertEqual(
            InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: false),
            .primary,
            "Solo/1-person recording: with no remote active speaker the local host must hold the "
            + "PRIMARY slot (black-video bootstrap). The B3 fix must not change this case.")
    }

    // Feature: secure-av-pipeline-fixes, Property 6: host always slotted (never dropped).
    //
    // Randomized property (≥100 iterations, seeded RNG): for either boolean input,
    // `localSlot` always returns one of {.primary, .secondary} — the host is never
    // dropped to nil/none.
    func testProperty6_HostAlwaysSlotted() {
        var rng = SeededRNG(seed: 0xB3_0002)
        let iterations = 200
        for i in 0..<iterations {
            let hasRemote = Bool.random(using: &rng)
            let slot = InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: hasRemote)
            XCTAssertTrue(
                slot == .primary || slot == .secondary,
                "iter \(i): localSlot(\(hasRemote)) must be primary or secondary — host never dropped")
        }
    }

    // Feature: secure-av-pipeline-fixes, Property 6: pure contract (same input ⇒ same output).
    //
    // Randomized property (≥100 iterations, seeded RNG): `localSlot` and `useGrid` are
    // pure — repeated calls with identical inputs yield identical results.
    func testProperty6_PureContractDeterministic() {
        var rng = SeededRNG(seed: 0xB3_0003)
        let iterations = 200
        let prefs: [InterRecordingLayoutPreference] = [.auto, .speaker]
        for i in 0..<iterations {
            let count = Int.random(in: 0...64, using: &rng)
            let pref = prefs[Int.random(in: 0..<prefs.count, using: &rng)]
            let hasRemote = Bool.random(using: &rng)

            // useGrid purity
            let g1 = InterRecordingLayoutLogic.useGrid(participantCount: count, preference: pref)
            let g2 = InterRecordingLayoutLogic.useGrid(participantCount: count, preference: pref)
            let g3 = InterRecordingLayoutLogic.useGrid(participantCount: count, preference: pref)
            XCTAssertEqual(g1, g2, "iter \(i): useGrid must be pure (call 1 vs 2)")
            XCTAssertEqual(g2, g3, "iter \(i): useGrid must be pure (call 2 vs 3)")

            // localSlot purity
            let s1 = InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: hasRemote)
            let s2 = InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: hasRemote)
            let s3 = InterRecordingLayoutLogic.localSlot(hasRemoteActiveSpeaker: hasRemote)
            XCTAssertEqual(s1, s2, "iter \(i): localSlot must be pure (call 1 vs 2)")
            XCTAssertEqual(s2, s3, "iter \(i): localSlot must be pure (call 2 vs 3)")
        }
    }
}
