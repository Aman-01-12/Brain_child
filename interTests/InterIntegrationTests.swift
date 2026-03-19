// interTests/InterIntegrationTests.swift
// Integration tests for bidirectional call lifecycle [4.7.2].
//
// These tests spin up two InterRoomController instances (host + joiner)
// against a local LiveKit server + token server, and verify:
//   - Host creates room, gets a room code
//   - Joiner joins with that code, both reach .connected
//   - Participant presence state fires correctly (G6)
//   - Mic publish + mute propagation works
//   - Disconnect one → presence state fires on the other
//
// REQUIREMENTS:
//   - livekit-server running on ws://localhost:7880 (livekit-server --dev)
//   - token-server running on http://localhost:3000 (node index.js)
//
// If either server is unreachable, these tests are SKIPPED (not failed).

import XCTest
@testable import inter

final class InterIntegrationTests: XCTestCase {

    static let serverURL = "ws://localhost:7880"
    static let tokenServerURL = "http://localhost:3000"

    var host: InterRoomController!
    var joiner: InterRoomController!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Check that both servers are reachable
        try await checkInfrastructure()

        host = InterRoomController()
        joiner = InterRoomController()
    }

    override func tearDown() {
        host?.disconnect()
        joiner?.disconnect()
        host = nil
        joiner = nil
        super.tearDown()
    }

    /// Verify local infrastructure is running. Skip the test if not.
    private func checkInfrastructure() async throws {
        let url = URL(string: "\(Self.tokenServerURL)/health")!
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw XCTSkip("Token server not healthy (status \((response as? HTTPURLResponse)?.statusCode ?? 0))")
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["status"] as? String == "ok" {
                // Token server is up
            } else {
                throw XCTSkip("Token server returned unexpected health response")
            }
        } catch let error where !(error is XCTSkip) {
            throw XCTSkip("Token server unreachable: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func hostConfig(roomType: String = "call") -> InterRoomConfiguration {
        return InterRoomConfiguration(
            serverURL: Self.serverURL,
            tokenServerURL: Self.tokenServerURL,
            roomCode: "",
            participantIdentity: "host-\(UUID().uuidString.prefix(8))",
            participantName: "Host",
            isHost: true,
            roomType: roomType
        )
    }

    private func joinerConfig(roomCode: String) -> InterRoomConfiguration {
        return InterRoomConfiguration(
            serverURL: Self.serverURL,
            tokenServerURL: Self.tokenServerURL,
            roomCode: roomCode,
            participantIdentity: "joiner-\(UUID().uuidString.prefix(8))",
            participantName: "Joiner",
            isHost: false
        )
    }

    /// Connect and wait for completion.
    private func connect(_ controller: InterRoomController, config: InterRoomConfiguration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                controller.connect(configuration: config) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Wait for a KVO property to reach a target value, with timeout.
    private func waitForState<T: Equatable>(
        on controller: InterRoomController,
        keyPath: KeyPath<InterRoomController, T>,
        target: T,
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            let value = await MainActor.run { controller[keyPath: keyPath] }
            if value == target { return }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        let finalValue = await MainActor.run { controller[keyPath: keyPath] }
        XCTFail("Timed out waiting for \(keyPath) to reach \(target), current: \(finalValue)")
    }

    // MARK: - Test: Host Creates Room

    func testHostCreatesRoom_getsRoomCode() async throws {
        let config = hostConfig()
        try await connect(host, config: config)

        // Wait for connected state to settle
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        let roomCode = await MainActor.run { host.roomCode }
        XCTAssertEqual(roomCode.count, 6, "Room code should be 6 characters")
        XCTAssertTrue(roomCode.allSatisfy { $0.isUppercase || $0.isNumber },
                      "Room code should be alphanumeric uppercase")
    }

    // MARK: - Test: Bidirectional Connect

    func testBidirectionalConnect_bothReachConnected() async throws {
        // Host creates room
        let config = hostConfig()
        try await connect(host, config: config)
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        let roomCode = await MainActor.run { host.roomCode }
        XCTAssertFalse(roomCode.isEmpty, "Host should have a room code")

        // Joiner joins the room
        let joinConfig = joinerConfig(roomCode: roomCode)
        try await connect(joiner, config: joinConfig)
        try await waitForState(on: joiner, keyPath: \.connectionState, target: .connected, timeout: 15)

        // Both should be connected
        let hostState = await MainActor.run { host.connectionState }
        let joinerState = await MainActor.run { joiner.connectionState }
        XCTAssertEqual(hostState, .connected)
        XCTAssertEqual(joinerState, .connected)
    }

    // MARK: - Test: G6 Participant Presence

    func testParticipantPresence_joinerJoins_hostSeesParticipant() async throws {
        // Host creates room
        try await connect(host, config: hostConfig())
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        let roomCode = await MainActor.run { host.roomCode }

        // Host should be alone initially
        let hostPresenceBefore = await MainActor.run { host.participantPresenceState }
        XCTAssertEqual(hostPresenceBefore, .alone)

        // Joiner joins
        try await connect(joiner, config: joinerConfig(roomCode: roomCode))
        try await waitForState(on: joiner, keyPath: \.connectionState, target: .connected, timeout: 15)

        // Host should see participant joined
        try await waitForState(on: host, keyPath: \.participantPresenceState, target: .participantJoined, timeout: 10)

        let hostCount = await MainActor.run { host.remoteParticipantCount }
        XCTAssertEqual(hostCount, 1, "Host should see 1 remote participant")

        // Joiner should also see the host
        try await waitForState(on: joiner, keyPath: \.participantPresenceState, target: .participantJoined, timeout: 10)

        let joinerCount = await MainActor.run { joiner.remoteParticipantCount }
        XCTAssertEqual(joinerCount, 1, "Joiner should see 1 remote participant (host)")
    }

    // MARK: - Test: G6 Participant Leave Detection

    func testParticipantPresence_joinerDisconnects_hostSeesLeft() async throws {
        // Both connect
        try await connect(host, config: hostConfig())
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        let roomCode = await MainActor.run { host.roomCode }

        try await connect(joiner, config: joinerConfig(roomCode: roomCode))
        try await waitForState(on: joiner, keyPath: \.connectionState, target: .connected, timeout: 15)

        // Wait for presence
        try await waitForState(on: host, keyPath: \.participantPresenceState, target: .participantJoined, timeout: 10)

        // Joiner disconnects
        await MainActor.run { joiner.disconnect() }

        // Host should detect participant left (after 3s grace period)
        try await waitForState(on: host, keyPath: \.participantPresenceState, target: .participantLeft, timeout: 10)

        let hostCount = await MainActor.run { host.remoteParticipantCount }
        XCTAssertEqual(hostCount, 0, "Host should see 0 remote participants after joiner leaves")
    }

    // MARK: - Test: Interview Room Type

    func testInterviewRoomType_propagatedToJoiner() async throws {
        // Host creates interview room
        try await connect(host, config: hostConfig(roomType: "interview"))
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        let roomCode = await MainActor.run { host.roomCode }
        let hostType = await MainActor.run { host.roomType }
        XCTAssertEqual(hostType, "interview")

        // Joiner joins
        try await connect(joiner, config: joinerConfig(roomCode: roomCode))
        try await waitForState(on: joiner, keyPath: \.connectionState, target: .connected, timeout: 15)

        let joinerType = await MainActor.run { joiner.roomType }
        XCTAssertEqual(joinerType, "interview", "Room type should propagate from host to joiner via token server")
    }

    // MARK: - Test: Mic Publish

    func testMicPublish_hostPublishes_noError() async throws {
        try await connect(host, config: hostConfig())
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        // Publish mic
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                self.host.publisher.publishMicrophone { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        // Verify publication exists
        let hasMicPub = await MainActor.run { host.publisher.microphonePublication != nil }
        XCTAssertTrue(hasMicPub, "Host should have a microphone publication after publish")
    }

    // MARK: - Test: Stats Collector Active During Call

    func testStatsCollector_createdOnConnect() async throws {
        try await connect(host, config: hostConfig())
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        let hasCollector = await MainActor.run { host.statsCollector != nil }
        XCTAssertTrue(hasCollector, "Stats collector should be created after connect")
    }

    func testStatsCollector_destroyedOnDisconnect() async throws {
        try await connect(host, config: hostConfig())
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        await MainActor.run { host.disconnect() }

        // Wait for state to settle
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        let hasCollector = await MainActor.run { host.statsCollector }
        XCTAssertNil(hasCollector, "Stats collector should be nil after disconnect")
    }

    // MARK: - Test: Token Service Cache Populated

    func testTokenService_cachePopulatedAfterConnect() async throws {
        let config = hostConfig()
        try await connect(host, config: config)
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        let roomCode = await MainActor.run { host.roomCode }
        let ttl = host.tokenService.cachedTokenTTL(forRoom: roomCode, identity: config.participantIdentity)
        XCTAssertGreaterThan(ttl, 0, "Token TTL should be positive after connect (cached token exists)")
    }

    // MARK: - Test: Disconnect Resets State

    func testDisconnect_resetsAllState() async throws {
        try await connect(host, config: hostConfig())
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        let roomCodeBefore = await MainActor.run { host.roomCode }
        XCTAssertFalse(roomCodeBefore.isEmpty)

        await MainActor.run { host.disconnect() }

        // Wait for state to settle
        try await Task.sleep(nanoseconds: 500_000_000)

        let state = await MainActor.run { host.connectionState }
        let roomCode = await MainActor.run { host.roomCode }
        let presence = await MainActor.run { host.participantPresenceState }

        XCTAssertEqual(state, .disconnected)
        XCTAssertEqual(roomCode, "")
        XCTAssertEqual(presence, .alone)
    }

    // MARK: - Test: Invalid Room Code

    func testJoinInvalidRoomCode_returnsError() async throws {
        let config = joinerConfig(roomCode: "ZZZZZZ")

        do {
            try await connect(joiner, config: config)
            // If we get here, wait a moment for the state to settle
            try await Task.sleep(nanoseconds: 500_000_000)
            let state = await MainActor.run { joiner.connectionState }
            // It should be in an error state or disconnected
            XCTAssertTrue(state == .disconnectedWithError || state == .disconnected,
                          "Should fail with invalid room code, got state \(state.rawValue)")
        } catch {
            // Expected — invalid room code
            XCTAssertTrue(true, "Connect correctly failed with error: \(error.localizedDescription)")
        }
    }

    // MARK: - Test: Mode Transition While Connected

    func testModeTransition_whileConnected_keepsRoom() async throws {
        try await connect(host, config: hostConfig())
        try await waitForState(on: host, keyPath: \.connectionState, target: .connected, timeout: 15)

        // Perform mode transition
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.host.transitionMode {
                    continuation.resume()
                }
            }
        }

        // Should still be connected after transition
        let state = await MainActor.run { host.connectionState }
        XCTAssertEqual(state, .connected, "Room should stay connected after mode transition")
    }
}
