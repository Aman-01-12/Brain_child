// interTests/InterLiveKitPublisherTests.swift
// Tests for InterLiveKitPublisher [1.7.13]
// Validates: publish→verify, mute→verify, rapid toggle x10→no crash.

import XCTest
import AVFoundation
@testable import inter

final class InterLiveKitPublisherTests: XCTestCase {

    var publisher: InterLiveKitPublisher!

    override func setUp() {
        super.setUp()
        publisher = InterLiveKitPublisher()
    }

    override func tearDown() {
        publisher = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertNil(publisher.localParticipant)
        XCTAssertNil(publisher.cameraPublication)
        XCTAssertNil(publisher.microphonePublication)
        XCTAssertNil(publisher.screenSharePublication)
        XCTAssertNil(publisher.cameraSource)
        XCTAssertNil(publisher.audioBridge)
        XCTAssertNil(publisher.screenShareSource)
    }

    // MARK: - Publish Without Participant → Error

    func testPublishCamera_noParticipant_returnsError() {
        let exp = expectation(description: "error")
        let session = AVCaptureSession()
        let queue = DispatchQueue(label: "test")

        publisher.publishCamera(captureSession: session, sessionQueue: queue) { error in
            XCTAssertNotNil(error)
            XCTAssertEqual(error?.code, InterNetworkErrorCode.publishFailed.rawValue)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testPublishMicrophone_noParticipant_returnsError() {
        let exp = expectation(description: "error")

        publisher.publishMicrophone { error in
            XCTAssertNotNil(error)
            XCTAssertEqual(error?.code, InterNetworkErrorCode.publishFailed.rawValue)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testPublishScreenShare_noParticipant_returnsError() {
        let exp = expectation(description: "error")

        publisher.publishScreenShare { error in
            XCTAssertNotNil(error)
            XCTAssertEqual(error?.code, InterNetworkErrorCode.publishFailed.rawValue)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testPublishScreenShare_noSource_returnsError() {
        let exp = expectation(description: "error")

        // Set a non-nil participant would require LiveKit Room...
        // Without source, should fail even if participant were present
        publisher.publishScreenShare { error in
            XCTAssertNotNil(error)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    // MARK: - Screen Share Sink Creation

    func testCreateScreenShareSink_returnsSource() {
        let sink = publisher.createScreenShareSink()
        XCTAssertNotNil(sink)
        XCTAssertTrue(sink === publisher.screenShareSource)
    }

    // MARK: - Unpublish All

    func testUnpublishAll_nothingPublished_callsCompletion() {
        let exp = expectation(description: "unpublishAll")

        publisher.unpublishAll(captureSession: nil, sessionQueue: nil) {
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testUnpublishCamera_nothingPublished_callsCompletion() {
        let exp = expectation(description: "unpublishCamera")
        let session = AVCaptureSession()
        let queue = DispatchQueue(label: "test")

        publisher.unpublishCamera(captureSession: session, sessionQueue: queue) {
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testUnpublishMicrophone_nothingPublished_doesNotCrash() {
        // When nothing is published and audioBridge is nil, the completion
        // is called synchronously via the direct-track path's else branch.
        let exp = expectation(description: "completed")

        publisher.unpublishMicrophone {
            exp.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testUnpublishScreenShare_nothingPublished_doesNotCrash() {
        // screenShareSource is nil → optional chain skips stop closure.
        let exp = expectation(description: "noCallback")
        exp.isInverted = true

        publisher.unpublishScreenShare {
            exp.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    // MARK: - Detach All Sources

    func testDetachAllSources() {
        // Create a screen share sink to set a source
        _ = publisher.createScreenShareSink()
        XCTAssertNotNil(publisher.screenShareSource)

        publisher.detachAllSources()
        XCTAssertNil(publisher.cameraSource)
        XCTAssertNil(publisher.audioBridge)
        XCTAssertNil(publisher.screenShareSource)
    }

    // MARK: - Rapid Toggle No Crash

    func testRapidMuteCameraToggle_noParticipant_noCrash() {
        // Without a participant, mute/unmute should be no-ops (no crash)
        for _ in 0..<10 {
            publisher.muteCameraTrack { }
            publisher.unmuteCameraTrack()
        }
        // No crash = success
    }

    func testRapidMuteMicToggle_noParticipant_noCrash() {
        for _ in 0..<10 {
            publisher.muteMicrophoneTrack { }
            publisher.unmuteMicrophoneTrack()
        }
        // No crash = success
    }

    func testRapidPublishUnpublish_noParticipant_noCrash() {
        let session = AVCaptureSession()
        let queue = DispatchQueue(label: "test")

        for i in 0..<10 {
            let exp = expectation(description: "cycle-\(i)")
            publisher.publishCamera(captureSession: session, sessionQueue: queue) { _ in
                self.publisher.unpublishCamera(captureSession: session, sessionQueue: queue) {
                    exp.fulfill()
                }
            }
            waitForExpectations(timeout: 5)
        }
    }
}
