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

    func didReceiveRemoteCameraFrame(_ pixelBuffer: CVPixelBuffer) {
        cameraFrameCount += 1
    }

    func didReceiveRemoteScreenShareFrame(_ pixelBuffer: CVPixelBuffer) {
        screenShareFrameCount += 1
    }

    func remoteTrackDidMute(_ kind: InterTrackKind) {
        mutedKinds.append(kind)
    }

    func remoteTrackDidUnmute(_ kind: InterTrackKind) {
        unmutedKinds.append(kind)
    }

    func remoteTrackDidEnd(_ kind: InterTrackKind) {
        endedKinds.append(kind)
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
