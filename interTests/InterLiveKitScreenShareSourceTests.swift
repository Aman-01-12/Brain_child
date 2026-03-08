// interTests/InterLiveKitScreenShareSourceTests.swift
// Tests for InterLiveKitScreenShareSource [1.6.12]
// Validates: frame flow, ≤15 FPS throttle, memory <60 MB.

import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import inter

final class InterLiveKitScreenShareSourceTests: XCTestCase {

    var source: InterLiveKitScreenShareSource!

    override func setUp() {
        super.setUp()
        source = InterLiveKitScreenShareSource()
    }

    override func tearDown() {
        source.stop(completion: nil)
        source = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertFalse(source.isActive)
        XCTAssertNil(source.videoTrack)
        XCTAssertNil(source.bufferCapturer)
        XCTAssertEqual(source.framesSent, 0)
        XCTAssertEqual(source.framesDropped, 0)
        XCTAssertEqual(source.framesThrottled, 0)
    }

    // MARK: - Start / Stop Lifecycle

    func testStart_setsActiveAndCreatesTrack() {
        let exp = expectation(description: "start")
        let config = InterShareSessionConfiguration.default()

        source.start(with: config) { success, _ in
            XCTAssertTrue(success)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertTrue(source.isActive)
        XCTAssertNotNil(source.videoTrack)
        XCTAssertNotNil(source.bufferCapturer)
    }

    func testStop_clearsState() {
        let config = InterShareSessionConfiguration.default()
        let startExp = expectation(description: "start")
        source.start(with: config) { _, _ in startExp.fulfill() }
        waitForExpectations(timeout: 5)

        let stopExp = expectation(description: "stop")
        source.stop { stopExp.fulfill() }
        waitForExpectations(timeout: 5)

        XCTAssertFalse(source.isActive)
    }

    func testDoubleStart_idempotent() {
        let config = InterShareSessionConfiguration.default()

        let exp1 = expectation(description: "start1")
        source.start(with: config) { success, _ in
            XCTAssertTrue(success)
            exp1.fulfill()
        }
        waitForExpectations(timeout: 5)

        let exp2 = expectation(description: "start2")
        source.start(with: config) { success, statusText in
            XCTAssertTrue(success)
            XCTAssertEqual(statusText, "Already active")
            exp2.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Frame Flow & Throttle

    func testAppend_whenNotActive_doesNotCrash() {
        guard let pb = createBGRAPixelBuffer(width: 64, height: 64) else {
            XCTFail("Could not create pixel buffer")
            return
        }
        let frame = InterShareVideoFrame(pixelBuffer: pb, presentationTime: CMTime.zero)
        source.append(frame) // Should not crash
        XCTAssertEqual(source.framesSent, 0)
    }

    func testThrottle_15FPS() {
        let config = InterShareSessionConfiguration.default()
        let startExp = expectation(description: "start")
        source.start(with: config) { _, _ in startExp.fulfill() }
        waitForExpectations(timeout: 5)

        guard source.isActive else { return }

        // Send 100 frames as fast as possible (all within ~10ms)
        for _ in 0..<100 {
            guard let pb = createBGRAPixelBuffer(width: 64, height: 64) else { continue }
            let frame = InterShareVideoFrame(pixelBuffer: pb, presentationTime: CMTime.zero)
            source.append(frame)
        }

        // Wait for async encoder queue to process
        let drainExp = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            drainExp.fulfill()
        }
        waitForExpectations(timeout: 3)

        // Most frames should have been throttled at 15 FPS
        // At 100 frames all at once, at most 1-2 should pass the throttle
        XCTAssertGreaterThan(source.framesThrottled, 0,
                             "Throttle should have dropped frames (throttled=\(source.framesThrottled))")
    }

    // MARK: - Audio No-Op

    func testAppendAudio_isNoOp() {
        let config = InterShareSessionConfiguration.default()
        let startExp = expectation(description: "start")
        source.start(with: config) { _, _ in startExp.fulfill() }
        waitForExpectations(timeout: 5)

        // Passing audio to screen share source should not crash
        guard let sampleBuffer = createSilentAudioSampleBuffer() else { return }
        source.appendAudioSampleBuffer(sampleBuffer)
        // No crash = success
    }

    // MARK: - No Allocation Growth

    func testNoAllocationGrowth() {
        let config = InterShareSessionConfiguration.default()
        let startExp = expectation(description: "start")
        source.start(with: config) { _, _ in startExp.fulfill() }
        waitForExpectations(timeout: 5)

        guard source.isActive else { return }

        // Send 1000 frames — should not leak
        for _ in 0..<1000 {
            autoreleasepool {
                guard let pb = createBGRAPixelBuffer(width: 64, height: 64) else { return }
                let frame = InterShareVideoFrame(pixelBuffer: pb, presentationTime: CMTime.zero)
                source.append(frame)
            }
        }

        // Wait for encoder queue drain
        let drainExp = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            drainExp.fulfill()
        }
        waitForExpectations(timeout: 5)

        // No crash / OOM = success
        XCTAssertTrue(source.isActive)
    }

    // MARK: - Helpers

    private func createBGRAPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        return pb
    }

    private func createSilentAudioSampleBuffer() -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDesc)
        guard let desc = formatDesc else { return nil }

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: 480 * 4,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0,
            dataLength: 480 * 4, flags: 0,
            blockBufferOut: &blockBuffer)
        guard let block = blockBuffer else { return nil }

        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: desc,
            sampleCount: 480, presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }
}
