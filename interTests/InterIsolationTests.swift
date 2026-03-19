// interTests/InterIsolationTests.swift
// Tests for G8 isolation invariant.
// Validates: app-critical paths work identically when roomController is nil,
//            and that setting roomController = nil mid-session is safe.

import XCTest
@testable import inter

final class InterIsolationTests: XCTestCase {

    // MARK: - G8: Room Controller Lifecycle

    /// Creating and immediately destroying a room controller should be clean.
    func testRoomController_createAndDestroy() {
        var controller: InterRoomController? = InterRoomController()
        XCTAssertNotNil(controller)
        XCTAssertEqual(controller!.connectionState, .disconnected)

        // Nil it out — should clean up without crash
        controller = nil
        // If we get here, no crash occurred
    }

    /// Disconnect on a never-connected controller should be safe.
    func testRoomController_disconnectWithoutConnect() {
        let controller = InterRoomController()
        controller.disconnect()
        XCTAssertEqual(controller.connectionState, .disconnected)
    }

    /// Multiple disconnects in a row should be safe.
    func testRoomController_multipleDisconnects() {
        let controller = InterRoomController()
        controller.disconnect()
        controller.disconnect()
        controller.disconnect()
        XCTAssertEqual(controller.connectionState, .disconnected)
    }

    /// Mode transition when disconnected should complete immediately.
    func testRoomController_transitionMode_whenDisconnected() {
        let controller = InterRoomController()
        let exp = expectation(description: "transition")
        controller.transitionMode {
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - G8: Publisher Isolation

    /// Publisher should tolerate operations when localParticipant is nil.
    func testPublisher_noLocalParticipant_publishMicReturnsError() {
        let publisher = InterLiveKitPublisher()
        XCTAssertNil(publisher.localParticipant)

        let exp = expectation(description: "mic publish")
        publisher.publishMicrophone { error in
            XCTAssertNotNil(error, "Publish with no participant should error")
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    /// Publisher screen share publish with no participant returns error.
    func testPublisher_noLocalParticipant_publishScreenShareReturnsError() {
        let publisher = InterLiveKitPublisher()
        let exp = expectation(description: "screenshare publish")
        publisher.publishScreenShare { error in
            XCTAssertNotNil(error, "Screen share publish with no participant should error")
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    /// Unpublish all tracks when nothing is published should be a safe no-op.
    func testPublisher_unpublishAll_whenNothingPublished() {
        let publisher = InterLiveKitPublisher()
        let exp = expectation(description: "unpublish all")
        publisher.unpublishAll(captureSession: nil, sessionQueue: nil) {
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    /// Detach all sources when nothing is attached should be safe.
    func testPublisher_detachAllSources_whenNothingAttached() {
        let publisher = InterLiveKitPublisher()
        publisher.detachAllSources() // Should not crash
    }

    // MARK: - G8: Subscriber Isolation

    /// Subscriber detach when never attached should be safe.
    func testSubscriber_detach_whenNeverAttached() {
        let subscriber = InterLiveKitSubscriber()
        subscriber.detach() // Should not crash
    }

    // MARK: - G8: Stats Collector Isolation

    /// Stats collector should work independently of room controller lifecycle.
    func testStatsCollector_stopWithoutStart() {
        let collector = InterCallStatsCollector()
        // Stop without start should be safe
        collector.stop()
    }

    /// Diagnostic snapshot on empty collector should report zero samples.
    func testStatsCollector_diagnosticSnapshot_empty() {
        let collector = InterCallStatsCollector()
        let snapshot = collector.captureDiagnosticSnapshot()
        XCTAssertTrue(snapshot.contains("Total samples: 0"))
    }

    /// Latest entry on empty collector returns nil.
    func testStatsCollector_latestEntry_empty() {
        let collector = InterCallStatsCollector()
        XCTAssertNil(collector.latestEntry())
    }

    /// JSON export on empty collector returns nil.
    func testStatsCollector_exportToJSON_empty() {
        let collector = InterCallStatsCollector()
        XCTAssertNil(collector.exportToJSON())
    }

    // MARK: - G8: Token Service Isolation

    /// Invalidating an empty cache should be safe.
    func testTokenService_invalidateEmptyCache() {
        let service = InterTokenService()
        service.invalidateCache() // Should not crash
    }

    /// Querying TTL for non-existent cache entry returns negative.
    func testTokenService_cachedTokenTTL_noEntry() {
        let service = InterTokenService()
        let ttl = service.cachedTokenTTL(forRoom: "ABCDEF", identity: "bob")
        XCTAssertLessThan(ttl, 0, "TTL for missing entry should be negative")
    }

    /// Double invalidation should be safe.
    func testTokenService_doubleInvalidate() {
        let service = InterTokenService()
        service.invalidateCache()
        service.invalidateCache()
        // Should not crash
    }

    // MARK: - G8: Full Lifecycle — Create, Connect (fail), Disconnect, Nil

    /// Simulate a full lifecycle: create controller → attempt connect (fails with
    /// unreachable server) → disconnect → nil the controller. No crash at any step.
    func testRoomController_fullFailedLifecycle() {
        var controller: InterRoomController? = InterRoomController()

        let config = InterRoomConfiguration(
            serverURL: "ws://invalid:9999",
            tokenServerURL: "http://invalid:9999",
            roomCode: "",
            participantIdentity: "test-user",
            participantName: "Test",
            isHost: true
        )

        let connectExp = expectation(description: "connect")
        controller?.connect(configuration: config) { error in
            // Expected to fail — unreachable server
            connectExp.fulfill()
        }
        waitForExpectations(timeout: 15)

        // Disconnect after failure
        controller?.disconnect()

        // Wait for state to settle
        let settleExp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            settleExp.fulfill()
        }
        waitForExpectations(timeout: 3)

        let state = controller?.connectionState
        XCTAssertTrue(state == .disconnected,
                      "After disconnect, state should be .disconnected, got \(state?.rawValue ?? -1)")

        // Nil the controller — should clean up
        controller = nil
    }
}
