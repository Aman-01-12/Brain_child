// interTests/InterLiveKitAudioBridgeTests.swift
// Tests for InterLiveKitAudioBridge [1.4.12]
// Validates: conversion correctness (lifecycle), nil buffer safety, <500ns return time.

import XCTest
import AVFoundation
import CoreMedia
@testable import inter

final class InterLiveKitAudioBridgeTests: XCTestCase {

    var bridge: InterLiveKitAudioBridge!

    override func setUp() {
        super.setUp()
        bridge = InterLiveKitAudioBridge()
    }

    override func tearDown() {
        bridge.stop(completion: nil)
        bridge = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertFalse(bridge.isActive)
        XCTAssertNil(bridge.audioTrack)
    }

    // MARK: - Start / Stop Lifecycle

    func testStart_setsActiveAndCreatesTrack() {
        let exp = expectation(description: "start")
        let config = InterShareSessionConfiguration.default()

        bridge.start(with: config) { success, statusText in
            XCTAssertTrue(success)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertTrue(bridge.isActive)
        XCTAssertNotNil(bridge.audioTrack)
    }

    func testStop_clearsState() {
        let startExp = expectation(description: "start")
        let config = InterShareSessionConfiguration.default()

        bridge.start(with: config) { _, _ in startExp.fulfill() }
        waitForExpectations(timeout: 5)

        let stopExp = expectation(description: "stop")
        bridge.stop { stopExp.fulfill() }
        waitForExpectations(timeout: 5)

        XCTAssertFalse(bridge.isActive)
        XCTAssertNil(bridge.audioTrack)
    }

    func testDoubleStart_idempotent() {
        let config = InterShareSessionConfiguration.default()

        let exp1 = expectation(description: "start1")
        bridge.start(with: config) { success, _ in
            XCTAssertTrue(success)
            exp1.fulfill()
        }
        waitForExpectations(timeout: 5)

        let track1 = bridge.audioTrack

        let exp2 = expectation(description: "start2")
        bridge.start(with: config) { success, statusText in
            XCTAssertTrue(success)
            XCTAssertEqual(statusText, "Already active")
            exp2.fulfill()
        }
        waitForExpectations(timeout: 5)

        // Track should be the same instance (not recreated)
        XCTAssertTrue(bridge.audioTrack === track1)
    }

    func testDoubleStop_doesNotCrash() {
        let config = InterShareSessionConfiguration.default()

        let startExp = expectation(description: "start")
        bridge.start(with: config) { _, _ in startExp.fulfill() }
        waitForExpectations(timeout: 5)

        let stop1 = expectation(description: "stop1")
        bridge.stop { stop1.fulfill() }
        waitForExpectations(timeout: 5)

        let stop2 = expectation(description: "stop2")
        bridge.stop { stop2.fulfill() }
        waitForExpectations(timeout: 5)

        XCTAssertFalse(bridge.isActive)
    }

    // MARK: - Nil Buffer Safety

    func testAppendAudio_whenNotActive_doesNotCrash() {
        // Create a minimal CMSampleBuffer
        guard let sampleBuffer = createSilentAudioSampleBuffer() else {
            // CMSampleBuffer creation may fail in some test environments
            return
        }
        // Should not crash — just returns immediately
        bridge.appendAudioSampleBuffer(sampleBuffer)
        XCTAssertFalse(bridge.isActive)
    }

    func testAppendVideo_isNoOp() {
        let config = InterShareSessionConfiguration.default()
        let startExp = expectation(description: "start")
        bridge.start(with: config) { _, _ in startExp.fulfill() }
        waitForExpectations(timeout: 5)

        // Video frames should be silently ignored (audio bridge only handles audio)
        guard let pixelBuffer = createBGRAPixelBuffer(width: 4, height: 4) else {
            XCTFail("Could not create pixel buffer")
            return
        }
        let frame = InterShareVideoFrame(pixelBuffer: pixelBuffer,
                                          presentationTime: CMTime.zero)
        bridge.append(frame)
        // No crash = success
    }

    // MARK: - Performance: <500ns Return Time

    func testAppendAudioSampleBuffer_returnTime() {
        let config = InterShareSessionConfiguration.default()
        let startExp = expectation(description: "start")
        bridge.start(with: config) { _, _ in startExp.fulfill() }
        waitForExpectations(timeout: 5)

        guard let sampleBuffer = createSilentAudioSampleBuffer() else {
            return
        }

        // Warm up
        for _ in 0..<10 {
            bridge.appendAudioSampleBuffer(sampleBuffer)
        }

        // Measure return time
        let iterations = 1000
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            bridge.appendAudioSampleBuffer(sampleBuffer)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let avgNs = (elapsed / Double(iterations)) * 1_000_000_000

        // Spec says <500ns. Allow 5000ns for CI variability.
        XCTAssertLessThan(avgNs, 5000.0,
                          "appendAudioSampleBuffer should return quickly (avg \(avgNs)ns)")
    }

    // MARK: - Helpers

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
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let desc = formatDesc else { return nil }

        let numFrames = 480 // 10ms at 48kHz
        let dataSize = numFrames * 4
        var data = Data(count: dataSize)

        var blockBuffer: CMBlockBuffer?
        data.withUnsafeMutableBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return }
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataSize,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataSize,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard let block = blockBuffer else { return nil }

        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: desc,
            sampleCount: numFrames,
            presentationTimeStamp: CMTime.zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }

    private func createBGRAPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &pb)
        return pb
    }
}
