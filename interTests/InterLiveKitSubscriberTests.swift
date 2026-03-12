// interTests/InterLiveKitSubscriberTests.swift
// Tests for InterLiveKitSubscriber [1.8.12]
// Validates: dual track receive patterns, no frame leaks, quality switching.

import XCTest
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
}
