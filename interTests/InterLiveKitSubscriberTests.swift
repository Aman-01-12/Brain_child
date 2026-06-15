// interTests/InterLiveKitSubscriberTests.swift
// Tests for InterLiveKitSubscriber [1.8.12]
// Validates: dual track receive patterns, no frame leaks, quality switching.

import XCTest
import CoreVideo
@testable import inter

// MARK: - Mock Track Renderer

private class MockTrackRenderer: NSObject, InterRemoteTrackRenderer {
    var cameraFrameCount = 0
    var screenShareFrameCount = 0
    var mutedKinds: [InterTrackKind] = []
    var unmutedKinds: [InterTrackKind] = []
    var endedKinds: [InterTrackKind] = []
    var lastParticipantId: String?

    func didReceiveRemoteCameraFrame(_ pixelBuffer: CVPixelBuffer, fromParticipant participantId: String) {
        cameraFrameCount += 1
        lastParticipantId = participantId
    }

    func didReceiveRemoteScreenShareFrame(_ pixelBuffer: CVPixelBuffer, fromParticipant participantId: String) {
        screenShareFrameCount += 1
        lastParticipantId = participantId
    }

    func remoteTrackDidMute(_ kind: InterTrackKind, forParticipant participantId: String) {
        mutedKinds.append(kind)
        lastParticipantId = participantId
    }

    func remoteTrackDidUnmute(_ kind: InterTrackKind, forParticipant participantId: String) {
        unmutedKinds.append(kind)
        lastParticipantId = participantId
    }

    func remoteTrackDidEnd(_ kind: InterTrackKind, forParticipant participantId: String) {
        endedKinds.append(kind)
        lastParticipantId = participantId
    }
}

// MARK: - Tests
//
// Note: property loops below use the shared `SeededGenerator` (SplitMix64) declared in
// interTests/SecureTools/StrokeModelPropertyTests.swift for reproducible, seeded randomness.

final class InterLiveKitSubscriberTests: XCTestCase {

    var subscriber: InterLiveKitSubscriber!

    override func setUp() {
        super.setUp()
        subscriber = InterLiveKitSubscriber()
    }

    override func tearDown() {
        subscriber.detach()
        subscriber = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertNil(subscriber.trackRenderer)
        XCTAssertEqual(subscriber.detectedCameraFormat, 0)
        XCTAssertEqual(subscriber.detectedScreenShareFormat, 0)
    }

    // MARK: - Track Renderer Assignment

    func testTrackRenderer_assignment() {
        let renderer = MockTrackRenderer()
        subscriber.trackRenderer = renderer
        XCTAssertTrue(subscriber.trackRenderer === renderer)
    }

    func testTrackRenderer_isWeak() {
        var renderer: MockTrackRenderer? = MockTrackRenderer()
        subscriber.trackRenderer = renderer
        XCTAssertNotNil(subscriber.trackRenderer)

        renderer = nil
        XCTAssertNil(subscriber.trackRenderer, "trackRenderer should be weak")
    }

    // MARK: - Detach Safety

    func testDetach_whenNotAttached_doesNotCrash() {
        subscriber.detach()
        // No crash = success
        XCTAssertNil(subscriber.trackRenderer)
    }

    func testDoubleDetach_doesNotCrash() {
        subscriber.detach()
        subscriber.detach()
        // No crash
    }

    // MARK: - Detected Formats

    func testDetectedFormats_initiallyZero() {
        XCTAssertEqual(subscriber.detectedCameraFormat, 0)
        XCTAssertEqual(subscriber.detectedScreenShareFormat, 0)
    }

    // MARK: - No Frame Leaks (Rapid Create/Destroy)

    func testNoFrameLeaks_rapidCreateDestroy() {
        for _ in 0..<100 {
            autoreleasepool {
                let s = InterLiveKitSubscriber()
                let renderer = MockTrackRenderer()
                s.trackRenderer = renderer
                s.detach()
            }
        }
        // No crash / OOM = success
    }

    // MARK: - B2 Bug-Condition Exploration (Property 3, Requirements 1.6, 1.7)
    //
    // Feature: secure-av-pipeline-fixes, Property 3: Bug Condition — Remote share missing
    // from recording.
    //
    // Bug B2: `didSubscribeTrack`'s `.screenShareVideo` RemoteFrameRenderer closure forwards
    // each decoded frame ONLY to `trackRenderer`, never to `recordingFrameDelegate`. The
    // camera branch forwards to BOTH. So while the host records, a remote (candidate) screen
    // share reaches the spotlight UI but never the composed recording — the coordinator's
    // `didReceiveRemoteScreenShareFrame` handler is dead code.
    //
    // The closure can only be built from a live LiveKit Room/Track, so the per-source
    // forwarding is exercised through the seam methods (`forwardRemoteCameraFrame` /
    // `forwardRemoteScreenShareFrame`) extracted verbatim from those closures — driving the
    // REAL production forwarding contract without standing up LiveKit.

    /// Build a tiny BGRA pixel buffer to stand in for a decoded frame.
    private static func makeTestPixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 9,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        precondition(status == kCVReturnSuccess && buffer != nil, "test pixel buffer must allocate")
        return buffer!
    }

    /// Baseline / contrast: the CAMERA branch forwards to BOTH `trackRenderer` and
    /// `recordingFrameDelegate`. This passes on unfixed code and documents the behavior the
    /// screen-share branch should mirror.
    func testRemoteCameraFrame_isForwardedToBothDelegates() {
        let view = MockTrackRenderer()
        let recording = MockTrackRenderer()
        subscriber.trackRenderer = view
        subscriber.recordingFrameDelegate = recording

        let buffer = Self.makeTestPixelBuffer()
        subscriber.forwardRemoteCameraFrame(buffer, fromParticipant: "candidate-1")

        XCTAssertEqual(view.cameraFrameCount, 1,
                       "trackRenderer (spotlight/UI) must receive the remote camera frame")
        XCTAssertEqual(recording.cameraFrameCount, 1,
                       "camera branch forwards to BOTH delegates — the screen-share branch must mirror this")
    }

    /// B2 EXPLORATION — asserts the DESIRED (fixed) behavior: a remote screen-share frame
    /// reaches `recordingFrameDelegate` so the candidate's share is composited into the
    /// host's recording. On UNFIXED code `recordingFrameDelegate.screenShareFrameCount`
    /// stays 0, so this assertion FAILS — which CONFIRMS bug B2 (Requirements 1.6, 1.7).
    /// After the fix lands (task 6) this same test passes.
    func testRemoteScreenShareFrame_isForwardedToRecordingDelegate() {
        let view = MockTrackRenderer()
        let recording = MockTrackRenderer()
        subscriber.trackRenderer = view
        subscriber.recordingFrameDelegate = recording

        let buffer = Self.makeTestPixelBuffer()
        subscriber.forwardRemoteScreenShareFrame(buffer, fromParticipant: "candidate-1")

        // The spotlight/UI delegate gets the frame today — that part already works.
        XCTAssertEqual(view.screenShareFrameCount, 1,
                       "trackRenderer should receive the remote screen-share frame")
        // [B2] DESIRED: the recording delegate must ALSO receive it (mirroring the camera
        // branch) so the candidate's share is recorded. UNFIXED: count == 0 → bug confirmed.
        XCTAssertEqual(recording.screenShareFrameCount, 1,
                       "[B2] recordingFrameDelegate must receive the remote screen-share frame "
                       + "so the candidate's share is composited into the host's recording. "
                       + "UNFIXED: 0 (the .screenShareVideo branch never forwards to it).")
    }

    // MARK: - B2 Preservation (Property 4, Requirements 3.4, 3.5, 3.6)
    //
    // Feature: secure-av-pipeline-fixes, Property 4: Preservation — B2 other paths unchanged
    //
    // These tests lock in the baselines the B2 fix (task 6) must NOT regress. They PASS on the
    // current (unfixed) code and must keep passing after the fix lands. Property 4 covers the
    // inputs where `isBugCondition_B2` does NOT hold (camera frames; the added recording call
    // being a safe no-op when not recording).
    //
    // SCOPE NOTE (Requirements 3.4, 3.5, 3.6): The remaining Property-4 preservation concerns —
    // the LOCAL host-share recording path (which records via `InterRecordingSink`,
    // Requirement 3.4) and the `_activeScreenShareIdentity` first-come / host-priority,
    // single-feed arbitration that prevents double-feeding the composed screen-share buffer
    // (Requirements 3.5, 3.6) — live in `InterRecordingCoordinator`, NOT in
    // `InterLiveKitSubscriber`. The subscriber's only B2 change is one added forwarding call;
    // the coordinator's existing `shouldAccept` gate (`_activeScreenShareIdentity == nil ||
    // == participantId`) is what guarantees no double-feed once the remote frame is forwarded.
    // Those behaviors are therefore covered by the coordinator's own tests and are out of scope
    // for these subscriber-level seam tests — noted here for traceability.

    /// Property 4 (camera path invariant — randomized, seeded, ≥100 iterations):
    /// For random participant ids and random repeat counts, `forwardRemoteCameraFrame` ALWAYS
    /// forwards to BOTH `trackRenderer` and `recordingFrameDelegate` (the per-delegate counts
    /// equal the number of calls), and the participant id is propagated to both delegates.
    /// This is the camera branch (R3.4-adjacent) the screen-share branch must mirror — it must
    /// stay intact through the B2 fix.
    func testProperty4_cameraForwardsToBothDelegates_randomized() {
        var rng = SeededGenerator(seed: 0xB2_CA_3E_3A)
        let iterations = 200

        for i in 0..<iterations {
            // Fresh subscriber + delegates per iteration so counts are independent.
            let subscriber = InterLiveKitSubscriber()
            let view = MockTrackRenderer()
            let recording = MockTrackRenderer()
            subscriber.trackRenderer = view
            subscriber.recordingFrameDelegate = recording

            let participantId = "candidate-\(UInt64.random(in: 0..<1_000_000, using: &rng))"
            let repeatCount = Int.random(in: 1...8, using: &rng)

            for _ in 0..<repeatCount {
                let buffer = Self.makeTestPixelBuffer()
                subscriber.forwardRemoteCameraFrame(buffer, fromParticipant: participantId)
            }

            XCTAssertEqual(view.cameraFrameCount, repeatCount,
                           "iter \(i): trackRenderer must receive every camera frame")
            XCTAssertEqual(recording.cameraFrameCount, repeatCount,
                           "iter \(i): recordingFrameDelegate must receive every camera frame "
                           + "(camera branch forwards to BOTH — must survive the B2 fix)")
            XCTAssertEqual(view.lastParticipantId, participantId,
                           "iter \(i): participant id must propagate to trackRenderer")
            XCTAssertEqual(recording.lastParticipantId, participantId,
                           "iter \(i): participant id must propagate to recordingFrameDelegate")
            // No screen-share frames should leak onto the camera path.
            XCTAssertEqual(view.screenShareFrameCount, 0, "iter \(i): no screen-share on camera path")
            XCTAssertEqual(recording.screenShareFrameCount, 0, "iter \(i): no screen-share on camera path")

            subscriber.detach()
        }
    }

    /// Property 4 (nil-safety of the recording delegate): `recordingFrameDelegate` is `weak`
    /// and nil when not recording. With it nil, BOTH `forwardRemoteCameraFrame` and
    /// `forwardRemoteScreenShareFrame` must NOT crash, and `trackRenderer` must still receive
    /// the frame. This proves the call the B2 fix ADDS to the screen-share branch is a safe
    /// no-op outside recording (preserving non-bug inputs).
    func testProperty4_recordingDelegateNil_isSafeNoOp() {
        let view = MockTrackRenderer()
        subscriber.trackRenderer = view
        XCTAssertNil(subscriber.recordingFrameDelegate,
                     "recordingFrameDelegate is nil when not recording (the non-bug input)")

        let cameraBuffer = Self.makeTestPixelBuffer()
        // Must not crash with a nil recording delegate.
        subscriber.forwardRemoteCameraFrame(cameraBuffer, fromParticipant: "candidate-1")
        XCTAssertEqual(view.cameraFrameCount, 1,
                       "trackRenderer still receives the camera frame when not recording")

        let shareBuffer = Self.makeTestPixelBuffer()
        // Must not crash with a nil recording delegate (the branch the B2 fix touches).
        subscriber.forwardRemoteScreenShareFrame(shareBuffer, fromParticipant: "candidate-1")
        XCTAssertEqual(view.screenShareFrameCount, 1,
                       "trackRenderer still receives the screen-share frame when not recording")
    }

    /// Property 4 (recording delegate is weak — nil-safe after release): once a strongly-held
    /// recording delegate is released, `recordingFrameDelegate` becomes nil and forwarding
    /// stays a safe no-op (the added B2 call must never resurrect or crash on a dead delegate).
    func testProperty4_recordingDelegateIsWeak_nilSafeAfterRelease() {
        let view = MockTrackRenderer()
        subscriber.trackRenderer = view

        var recording: MockTrackRenderer? = MockTrackRenderer()
        subscriber.recordingFrameDelegate = recording
        XCTAssertNotNil(subscriber.recordingFrameDelegate)

        recording = nil
        XCTAssertNil(subscriber.recordingFrameDelegate, "recordingFrameDelegate must be weak")

        // Forwarding to a released (nil) recording delegate must not crash; UI delegate still gets it.
        subscriber.forwardRemoteCameraFrame(Self.makeTestPixelBuffer(), fromParticipant: "candidate-1")
        subscriber.forwardRemoteScreenShareFrame(Self.makeTestPixelBuffer(), fromParticipant: "candidate-1")
        XCTAssertEqual(view.cameraFrameCount, 1)
        XCTAssertEqual(view.screenShareFrameCount, 1)
    }
}
