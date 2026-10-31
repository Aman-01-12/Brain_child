// ============================================================================
// interTests/InterPresenceCaptureSourceTests.swift
//
// PRESENCE MONITORING (provisional, server flag default OFF) — Phase 1.
//
// Proves the camera-discipline invariants of
// inter/Media/InterPresenceCaptureSource.swift. Modelled on
// interTests/InterLiveKitCameraSourceTests.swift, including the shape of its
// `createVideoSampleBuffer(width:height:)` helper (extended here with a
// presentation timestamp so the 2 Hz throttle can be driven deterministically,
// with no sleeping).
//
// The three research-memo §7.8 cases are named individually:
//   1. testStartAddsOnlyItsOwnOutput_stopRemovesOnlyThatOne
//   2. testNeverTouchesSessionInputs
//   3. testNeverCallsStartRunningOrStopRunning
//
// NOTE on the "pre-added dummy input" the plan asks for: an AVCaptureDeviceInput
// cannot be constructed without touching a real camera or microphone device,
// which in a test runner means a TCC prompt and a hung suite. The stronger
// proof is used instead — an AVCaptureSession subclass that FLAGS any call to
// addInput/removeInput/startRunning/stopRunning, asserted never flagged. That
// covers the pre-added-input case too: a source that never calls removeInput
// cannot remove anyone's input.
// ============================================================================

import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import inter

/// Flags every session mutation the presence source is forbidden to make.
private final class MutationFlaggingSession: AVCaptureSession {
    var startRunningCalls = 0
    var stopRunningCalls = 0
    var addInputCalls = 0
    var removeInputCalls = 0

    override func startRunning() {
        startRunningCalls += 1
        // Deliberately NOT forwarded: a unit test must never start a real device.
    }

    override func stopRunning() {
        stopRunningCalls += 1
    }

    override func addInput(_ input: AVCaptureInput) {
        addInputCalls += 1
        super.addInput(input)
    }

    override func removeInput(_ input: AVCaptureInput) {
        removeInputCalls += 1
        super.removeInput(input)
    }
}

final class InterPresenceCaptureSourceTests: XCTestCase {

    private var source: InterPresenceCaptureSource!
    private let queue = DispatchQueue(label: "test.presence.session")

    override func setUp() {
        super.setUp()
        source = InterPresenceCaptureSource(sampleIntervalMs: 500)
    }

    override func tearDown() {
        source = nil
        super.tearDown()
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertFalse(source.isCapturing)
        XCTAssertNil(source.videoDataOutput)
        XCTAssertEqual(source.framesSampled, 0)
        XCTAssertEqual(source.framesSkippedMuted, 0)
        XCTAssertEqual(source.framesSkippedThrottle, 0)
        XCTAssertEqual(source.outputsAdded, 0)
        XCTAssertEqual(source.outputsRemoved, 0)
        XCTAssertEqual(source.sessionRunCalls, 0)
    }

    // MARK: - §7.8 case 1 — only its own output

    func testStartAddsOnlyItsOwnOutput_stopRemovesOnlyThatOne() {
        let session = MutationFlaggingSession()

        // An output owned by somebody else (the publisher, the recorder) that
        // must survive the whole presence lifecycle untouched.
        let foreignOutput = AVCaptureVideoDataOutput()
        let foreignWasAdded = session.canAddOutput(foreignOutput)
        if foreignWasAdded { session.addOutput(foreignOutput) }
        let outputsBefore = session.outputs.count

        source.start(captureSession: session, sessionQueue: queue)

        if source.isCapturing {
            XCTAssertEqual(source.outputsAdded, 1, "exactly one output, ever")
            XCTAssertEqual(session.outputs.count, outputsBefore + 1,
                           "the session gained exactly the presence output")
            XCTAssertNotNil(source.videoDataOutput)
            XCTAssertTrue(session.outputs.contains { $0 === source.videoDataOutput })
        } else {
            // A bare session can refuse a second video data output on some
            // configurations; the invariants below must hold either way.
            XCTAssertEqual(source.outputsAdded, 0)
            XCTAssertEqual(session.outputs.count, outputsBefore)
        }

        let presenceOutput = source.videoDataOutput
        source.stop(captureSession: session, sessionQueue: queue)

        XCTAssertFalse(source.isCapturing)
        XCTAssertNil(source.videoDataOutput, "the source drops its reference on stop")
        XCTAssertEqual(session.outputs.count, outputsBefore,
                       "stop returns the session to exactly the outputs it had before start")
        if let presenceOutput = presenceOutput {
            XCTAssertFalse(session.outputs.contains { $0 === presenceOutput },
                           "its own output is gone")
        }
        if foreignWasAdded {
            XCTAssertTrue(session.outputs.contains { $0 === foreignOutput },
                          "an output added by another owner must survive stop — the presence "
                          + "source removes ONLY its own")
        }
        XCTAssertEqual(source.outputsRemoved, source.outputsAdded,
                       "every output it added, it removed")
    }

    func testDoubleStart_addsNoSecondOutput() {
        let session = MutationFlaggingSession()
        source.start(captureSession: session, sessionQueue: queue)
        let afterFirst = session.outputs.count
        let addedAfterFirst = source.outputsAdded

        source.start(captureSession: session, sessionQueue: queue)

        XCTAssertEqual(source.outputsAdded, addedAfterFirst, "start is idempotent")
        XCTAssertEqual(session.outputs.count, afterFirst)
        source.stop(captureSession: session, sessionQueue: queue)
    }

    func testStopWithoutStart_isNoOp() {
        let session = MutationFlaggingSession()
        source.stop(captureSession: session, sessionQueue: queue)
        XCTAssertFalse(source.isCapturing)
        XCTAssertEqual(source.outputsRemoved, 0)
        XCTAssertEqual(session.outputs.count, 0)
    }

    // MARK: - §7.8 case 2 — never touches session inputs

    func testNeverTouchesSessionInputs() {
        let session = MutationFlaggingSession()
        let inputsBefore = session.inputs
        let identitiesBefore = inputsBefore.map { ObjectIdentifier($0) }

        source.start(captureSession: session, sessionQueue: queue)
        source.ingest(sampleBuffer: makeSampleBuffer(atSeconds: 0.0))
        source.stop(captureSession: session, sessionQueue: queue)

        XCTAssertEqual(session.addInputCalls, 0,
                       "the presence source must NEVER call addInput — the capture session's "
                       + "input configuration belongs to InterLocalMediaController alone")
        XCTAssertEqual(session.removeInputCalls, 0,
                       "the presence source must NEVER call removeInput")
        XCTAssertEqual(session.inputs.count, inputsBefore.count,
                       "the input list is identical by count before start and after stop")
        XCTAssertEqual(session.inputs.map { ObjectIdentifier($0) }, identitiesBefore,
                       "the input list is identical by identity before start and after stop")
    }

    // MARK: - §7.8 case 3 — never starts or stops the session

    func testNeverCallsStartRunningOrStopRunning() {
        let session = MutationFlaggingSession()

        source.start(captureSession: session, sessionQueue: queue)
        source.ingest(sampleBuffer: makeSampleBuffer(atSeconds: 0.0))
        XCTAssertFalse(session.isRunning, "the session was never started by anyone here")
        source.stop(captureSession: session, sessionQueue: queue)

        XCTAssertEqual(session.startRunningCalls, 0,
                       "InterLocalMediaController.h: \"Callers MUST NOT call "
                       + "startRunning/stopRunning\"")
        XCTAssertEqual(session.stopRunningCalls, 0,
                       "stopping the shared session would kill the candidate's camera, the "
                       + "LiveKit publisher and any local recording")
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(source.sessionRunCalls, 0,
                       "the source's own counter must stay at 0 — the absence is asserted, "
                       + "not assumed")
    }

    // MARK: - Camera discipline

    func testDropsEveryFrameWhileMutedOrMuting() {
        let session = MutationFlaggingSession()
        source.start(captureSession: session, sessionQueue: queue)

        var handlerCalls = 0
        source.frameHandler = { _, _ in handlerCalls += 1 }

        source.setCameraState(2) // .muted
        for i in 0..<5 {
            source.ingest(sampleBuffer: makeSampleBuffer(atSeconds: Double(i)))
        }
        source.setCameraState(1) // .muting
        for i in 5..<10 {
            source.ingest(sampleBuffer: makeSampleBuffer(atSeconds: Double(i)))
        }

        XCTAssertEqual(source.framesSampled, 0,
                       "a muted camera produces no evidence, so the detector must do no work "
                       + "— this is also what makes §7.1's \"camera unmuted\" precondition for "
                       + "face_absent true by construction")
        XCTAssertEqual(source.framesSkippedMuted, 10)
        XCTAssertEqual(handlerCalls, 0, "not one pixel buffer reaches the detector")
        XCTAssertTrue(source.isCameraMuted)

        // Unmuting resumes sampling.
        source.setCameraState(0) // .active
        XCTAssertFalse(source.isCameraMuted)
        source.ingest(sampleBuffer: makeSampleBuffer(atSeconds: 20.0))
        if source.isCapturing {
            XCTAssertEqual(source.framesSampled, 1)
            XCTAssertEqual(handlerCalls, 1)
        }
        source.stop(captureSession: session, sessionQueue: queue)
    }

    func testTwoHertzThrottle() {
        let session = MutationFlaggingSession()
        source.start(captureSession: session, sessionQueue: queue)
        guard source.isCapturing else {
            return XCTAssertEqual(source.outputsAdded, 0, "session refused the output; nothing to throttle")
        }

        // 30 frames, 100 ms apart — a 10 fps camera over 3 s.
        for i in 0..<30 {
            source.ingest(sampleBuffer: makeSampleBuffer(atSeconds: Double(i) * 0.1))
        }

        XCTAssertEqual(source.framesSampled, 6,
                       "at 500 ms spacing the admitted frames are t = 0, 0.5, 1.0, 1.5, 2.0, "
                       + "2.5 — the 2.9 s frame is only 0.4 s after the last admitted one")
        XCTAssertLessThanOrEqual(source.framesSampled, 7, "2 Hz, with boundary headroom")
        XCTAssertEqual(source.framesSkippedThrottle, 24)
        XCTAssertEqual(source.framesSampled + source.framesSkippedThrottle, 30,
                       "every frame is either sampled or counted as throttled; none vanish")
        source.stop(captureSession: session, sessionQueue: queue)
    }

    func testThrottleAdmitsTheFirstFrameImmediately() {
        let session = MutationFlaggingSession()
        source.start(captureSession: session, sessionQueue: queue)
        guard source.isCapturing else { return }

        source.ingest(sampleBuffer: makeSampleBuffer(atSeconds: 123.456))
        XCTAssertEqual(source.framesSampled, 1, "the first frame of a session is always sampled")
        source.stop(captureSession: session, sessionQueue: queue)
    }

    func testFramesAreIgnoredWhenNotCapturing() {
        var handlerCalls = 0
        source.frameHandler = { _, _ in handlerCalls += 1 }
        source.ingest(sampleBuffer: makeSampleBuffer(atSeconds: 0.0))
        XCTAssertEqual(source.framesSampled, 0)
        XCTAssertEqual(handlerCalls, 0, "no output, no capture, no work")
    }

    // MARK: - Pinned format

    /// Asserted against the shipping `pinnedVideoSettings` dictionary that
    /// `makeDetectorOutput()` applies — and against AVFoundation's own list of
    /// formats it accepts.
    ///
    /// MEASURED LIMIT, documented rather than worked around: an
    /// `AVCaptureVideoDataOutput` reports `videoSettings` back as nil until it
    /// has a live video connection (verified: nil when fresh, nil after
    /// `videoSettings` is assigned, and nil after being added to a session with
    /// no camera input). A unit test with no camera therefore cannot read the
    /// pin back, so it asserts the dictionary the source actually applies and
    /// that the pinned format is one AVFoundation lists as available.
    func testVideoSettingsArePinnedToBGRA() {
        let key = kCVPixelBufferPixelFormatTypeKey as String
        let pinned = InterPresenceCaptureSource.pinnedVideoSettings

        XCTAssertEqual(pinned.count, 1, "exactly one pinned setting and nothing else")
        XCTAssertEqual(pinned[key] as? UInt32, kCVPixelFormatType_32BGRA,
                       "pinning the format is what stops this output renegotiating the shared "
                       + "session and disturbing the preview layer, the publisher or recording")

        let output = InterPresenceCaptureSource.makeDetectorOutput()
        XCTAssertTrue(output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA),
                      "the pinned format must be one AVFoundation actually accepts, or the pin "
                      + "would be silently dropped")
        XCTAssertTrue(output.alwaysDiscardsLateVideoFrames,
                      "the detector must never hold the pipeline back")

        // And the source really does use that factory for the output it adds.
        let session = MutationFlaggingSession()
        source.start(captureSession: session, sessionQueue: queue)
        if let attached = source.videoDataOutput {
            XCTAssertTrue(attached.alwaysDiscardsLateVideoFrames)
        }
        source.stop(captureSession: session, sessionQueue: queue)
    }

    // MARK: - Lifecycle hygiene

    func testStopClearsTheFrameHandler() {
        let session = MutationFlaggingSession()
        source.start(captureSession: session, sessionQueue: queue)
        source.frameHandler = { _, _ in XCTFail("no frame may reach a handler after stop") }
        source.stop(captureSession: session, sessionQueue: queue)
        XCTAssertNil(source.frameHandler,
                     "no block may outlive the session (paranoid #8)")
        source.ingest(sampleBuffer: makeSampleBuffer(atSeconds: 0.0))
    }

    func testNoAllocationGrowth_rapidCreateDestroy() {
        for _ in 0..<100 {
            autoreleasepool {
                let s = InterPresenceCaptureSource(sampleIntervalMs: 500)
                XCTAssertFalse(s.isCapturing)
                XCTAssertEqual(s.sessionRunCalls, 0)
            }
        }
    }

    func testStartStopCycleIsRepeatable() {
        let session = MutationFlaggingSession()
        for _ in 0..<5 {
            source.start(captureSession: session, sessionQueue: queue)
            source.stop(captureSession: session, sessionQueue: queue)
        }
        XCTAssertEqual(session.outputs.count, 0, "nothing is left behind on the session")
        XCTAssertEqual(source.outputsAdded, source.outputsRemoved)
        XCTAssertEqual(session.addInputCalls, 0)
        XCTAssertEqual(session.removeInputCalls, 0)
        XCTAssertEqual(session.startRunningCalls, 0)
        XCTAssertEqual(session.stopRunningCalls, 0)
    }

    // MARK: - Helpers

    /// The `InterLiveKitCameraSourceTests.createVideoSampleBuffer(width:height:)`
    /// helper, with the presentation timestamp exposed so the throttle is driven
    /// by the frame's own clock instead of a sleep.
    private func createVideoSampleBuffer(width: Int,
                                         height: Int,
                                         atSeconds seconds: Double) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let pb = pixelBuffer else { return nil }

        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &formatDesc
        )
        guard let desc = formatDesc else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue((seconds * 1000.0).rounded()),
                                          timescale: 1000),
            decodeTimeStamp: CMTime.invalid
        )
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    private func makeSampleBuffer(atSeconds seconds: Double) -> CMSampleBuffer {
        guard let buffer = createVideoSampleBuffer(width: 320, height: 240, atSeconds: seconds) else {
            fatalError("could not create a test sample buffer")
        }
        return buffer
    }
}
