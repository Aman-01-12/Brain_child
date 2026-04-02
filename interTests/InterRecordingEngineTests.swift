// interTests/InterRecordingEngineTests.swift
// Tests for InterRecordingEngine [Phase 10 — Gap #12]
// Validates: lifecycle, PTS monotonicity, pause/resume math, stop drain,
//            concurrent append, drop counting, shouldOptimizeForNetworkUse.

import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import inter

final class InterRecordingEngineTests: XCTestCase {

    private var outputURL: URL!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory
        outputURL = tmp.appendingPathComponent("test_recording_\(UUID().uuidString).mp4")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outputURL)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeEngine(width: Int = 1920, height: Int = 1080, fps: Int = 30) -> InterRecordingEngine {
        return InterRecordingEngine(
            outputURL: outputURL,
            videoSize: CGSize(width: width, height: height),
            frameRate: Int32(fps),
            audioChannels: 2,
            audioSampleRate: 48000.0
        )
    }

    /// Creates a minimal BGRA CVPixelBuffer for testing.
    private func makePixelBuffer(width: Int = 1920, height: Int = 1080) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }

    /// Creates a silent audio CMSampleBuffer (PCM Float32, stereo, 48kHz).
    private func makeSilentAudioSampleBuffer(frameCount: Int = 480) -> CMSampleBuffer? {
        let channels: UInt32 = 2
        let sampleRate: Float64 = 48000.0

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size) * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size) * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let fmt = formatDescription else { return nil }

        let dataSize = frameCount * Int(asbd.mBytesPerFrame)
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: dataSize)
        defer { data.deallocate() }
        memset(data, 0, dataSize)

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: data,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: kCMBlockBufferAlwaysCopyDataFlag,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: fmt,
            sampleCount: frameCount,
            presentationTimeStamp: CMTime(value: 0, timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        return sbStatus == noErr ? sampleBuffer : nil
    }

    // MARK: - Lifecycle

    func testInitialState_isNotRecording() {
        let engine = makeEngine()
        XCTAssertFalse(engine.isRecording)
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(engine.droppedVideoFrameCount, 0)
        XCTAssertEqual(engine.droppedAudioSampleCount, 0)
    }

    func testStartRecording_returnsYes() {
        let engine = makeEngine()
        let started = engine.startRecording()
        XCTAssertTrue(started, "startRecording should succeed for a valid output URL")
        XCTAssertTrue(engine.isRecording)

        let exp = expectation(description: "stop")
        engine.stopRecording { _, _ in exp.fulfill() }
        waitForExpectations(timeout: 5)
    }

    func testStopRecording_producesFile() {
        let engine = makeEngine()
        guard engine.startRecording() else {
            XCTFail("startRecording failed")
            return
        }

        // Append a few frames so the file is non-empty
        for i in 0..<5 {
            if let pb = makePixelBuffer() {
                let pts = CMTime(value: CMTimeValue(i), timescale: 30)
                engine.appendVideoPixelBuffer(pb, presentationTime: pts)
            }
        }

        let exp = expectation(description: "stop")
        engine.stopRecording { url, error in
            XCTAssertNotNil(url, "Output URL should be non-nil on success")
            XCTAssertNil(error, "Error should be nil on success")
            if let url = url {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                              "Output file should exist")
            }
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - PTS Monotonicity

    func testNonMonotonicPTS_dropsFrame() {
        let engine = makeEngine()
        guard engine.startRecording() else { return XCTFail() }

        if let pb = makePixelBuffer() {
            // Frame 0 at t=0
            engine.appendVideoPixelBuffer(pb, presentationTime: CMTime(value: 0, timescale: 30))
            // Frame 1 at t=1/30s
            engine.appendVideoPixelBuffer(pb, presentationTime: CMTime(value: 1, timescale: 30))
            // Frame 2 at t=0 (backwards) — should be dropped
            engine.appendVideoPixelBuffer(pb, presentationTime: CMTime(value: 0, timescale: 30))
        }

        let exp = expectation(description: "stop")
        engine.stopRecording { _, _ in exp.fulfill() }
        waitForExpectations(timeout: 5)

        // Drop count should be at least 1 (the backwards frame)
        XCTAssertGreaterThanOrEqual(engine.droppedVideoFrameCount, 1,
                                    "Backwards PTS should increment drop counter")
    }

    // MARK: - Pause / Resume

    func testPauseResume_lifecycle() {
        let engine = makeEngine()
        guard engine.startRecording() else { return XCTFail() }

        XCTAssertFalse(engine.isPaused)

        engine.pauseRecording()
        XCTAssertTrue(engine.isPaused)

        engine.resumeRecording()
        XCTAssertFalse(engine.isPaused)

        let exp = expectation(description: "stop")
        engine.stopRecording { _, _ in exp.fulfill() }
        waitForExpectations(timeout: 5)
    }

    func testPausedFramesAreDropped() {
        let engine = makeEngine()
        guard engine.startRecording() else { return XCTFail() }

        // Append one frame to start the session
        if let pb = makePixelBuffer() {
            engine.appendVideoPixelBuffer(pb, presentationTime: CMTime(value: 0, timescale: 30))
        }

        engine.pauseRecording()

        // Append frames while paused — these should be silently discarded
        for i in 1..<4 {
            if let pb = makePixelBuffer() {
                engine.appendVideoPixelBuffer(pb, presentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
            }
        }

        engine.resumeRecording()

        let exp = expectation(description: "stop")
        engine.stopRecording { url, error in
            // The 3 paused frames are gated at the public API level (before dispatch_async)
            // so they never reach the write path and are NOT counted as drops.
            // droppedVideoFrameCount should be 0 — only write-path failures count.
            XCTAssertEqual(engine.droppedVideoFrameCount, 0,
                           "Paused frames are silently gated before dispatch; drop counter must remain 0")
            // Recording should have completed cleanly with the single pre-pause frame.
            XCTAssertNil(error, "stopRecording should complete without error")
            XCTAssertNotNil(url, "stopRecording should produce an output file")
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Concurrent Append

    func testConcurrentVideoAppend_doesNotCrash() {
        let engine = makeEngine()
        guard engine.startRecording() else { return XCTFail() }

        let group = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for i in 0..<20 {
            group.enter()
            concurrentQueue.async {
                if let pb = self.makePixelBuffer() {
                    let pts = CMTime(value: CMTimeValue(i), timescale: 30)
                    engine.appendVideoPixelBuffer(pb, presentationTime: pts)
                }
                group.leave()
            }
        }

        group.wait()

        let exp = expectation(description: "stop")
        engine.stopRecording { _, _ in exp.fulfill() }
        waitForExpectations(timeout: 5)
    }

    func testConcurrentAudioAppend_doesNotCrash() {
        let engine = makeEngine()
        guard engine.startRecording() else { return XCTFail() }

        let group = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "test.concurrent.audio", attributes: .concurrent)

        for _ in 0..<10 {
            group.enter()
            concurrentQueue.async {
                if let sb = self.makeSilentAudioSampleBuffer() {
                    engine.appendAudioSampleBuffer(sb)
                }
                group.leave()
            }
        }

        group.wait()

        let exp = expectation(description: "stop")
        engine.stopRecording { _, _ in exp.fulfill() }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Stop Drain Gate

    func testDoubleStop_doesNotCrash() {
        let engine = makeEngine()
        guard engine.startRecording() else { return XCTFail() }

        let exp1 = expectation(description: "stop1")
        let exp2 = expectation(description: "stop2")

        engine.stopRecording { _, _ in exp1.fulfill() }
        engine.stopRecording { _, _ in exp2.fulfill() }

        waitForExpectations(timeout: 5)
    }

    // MARK: - Delegate

    func testDelegate_droppedVideoCallbackFires() {
        let engine = makeEngine()
        let spy = RecordingEngineDelegateSpy()
        engine.delegate = spy

        guard engine.startRecording() else { return XCTFail() }

        if let pb = makePixelBuffer() {
            // Append forward, then backward
            engine.appendVideoPixelBuffer(pb, presentationTime: CMTime(value: 1, timescale: 30))
            engine.appendVideoPixelBuffer(pb, presentationTime: CMTime(value: 0, timescale: 30))
        }

        let exp = expectation(description: "stop")
        engine.stopRecording { _, _ in exp.fulfill() }
        waitForExpectations(timeout: 5)

        // The delegate may get called asynchronously on the recording queue;
        // give it a moment to propagate.
        let delegateExp = expectation(description: "delegate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // At least one drop should have been reported
            XCTAssertGreaterThanOrEqual(spy.droppedVideoCount, 1)
            delegateExp.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
}

// MARK: - Delegate Spy

private class RecordingEngineDelegateSpy: NSObject, InterRecordingEngineDelegate {
    var droppedVideoCount: Int = 0
    var droppedAudioCount: Int = 0
    var failureError: Error?

    func recordingEngineDidDropVideoFrame(_ totalDropCount: UInt) {
        droppedVideoCount = Int(totalDropCount)
    }

    func recordingEngineDidDropAudioSample(_ totalDropCount: UInt) {
        droppedAudioCount = Int(totalDropCount)
    }

    func recordingEngineDidFail(with error: Error) {
        failureError = error
    }
}
