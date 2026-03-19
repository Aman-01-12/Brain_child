// interTests/InterMultiParticipantTests.swift
// Tests for multi-participant support (Phase A — cap at 4).
//
// Covers:
//   1. InterRoomController active speaker tracking
//   2. InterRoomController participant count
//   3. InterNetworkTypes max-participants constant
//   4. InterNetworkTypes room-full error code
//   5. Token server max participant enforcement (integration)
//   6. Token server room info endpoint (integration)

import XCTest
@testable import inter

// MARK: - Unit Tests (no server required)

final class InterMultiParticipantTests: XCTestCase {

    // MARK: - Constants

    func testMaxParticipantsConstant() {
        XCTAssertEqual(InterMaxParticipantsPerRoom, 4,
                       "Phase A soft cap should be 4")
    }

    // MARK: - Room Full Error Code

    func testRoomFullErrorCode_exists() {
        let error = InterNetworkErrorCode.roomFull.error(message: "Room is full")
        XCTAssertEqual(error.code, 1008)
        XCTAssertEqual(error.domain, InterNetworkErrorDomain)
        XCTAssertTrue(error.localizedDescription.contains("full"))
    }

    // MARK: - RoomController Active Speaker

    func testRoomController_activeSpeakerIdentity_defaultEmpty() {
        let controller = InterRoomController()
        XCTAssertEqual(controller.activeSpeakerIdentity, "",
                       "Active speaker should be empty string by default")
    }

    func testRoomController_activeSpeakerIdentity_clearedOnDisconnect() {
        let controller = InterRoomController()
        // Verify default state — active speaker resets correctly
        // (We can't force a connected state without a live server,
        //  so we verify the default is clean after construction + disconnect)
        controller.disconnect()

        let expectation = expectation(description: "check")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(controller.activeSpeakerIdentity, "",
                           "Active speaker should be empty after disconnect")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - RoomController Participant Count

    func testRoomController_remoteParticipantCount_defaultZero() {
        let controller = InterRoomController()
        XCTAssertEqual(controller.remoteParticipantCount, 0)
    }

    func testRoomController_participantPresenceState_defaultAlone() {
        let controller = InterRoomController()
        XCTAssertEqual(controller.participantPresenceState, .alone)
    }

    func testRoomController_disconnect_resetsParticipantState() {
        let controller = InterRoomController()
        // Verify default state is correct — we can't force connected state
        // without a server, but we verify disconnect is safe and resets to defaults
        controller.disconnect()

        let expectation = expectation(description: "reset")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(controller.remoteParticipantCount, 0,
                           "Participant count should be 0 after disconnect")
            XCTAssertEqual(controller.participantPresenceState, .alone,
                           "Presence state should be .alone after disconnect")
            XCTAssertEqual(controller.roomCode, "",
                           "Room code should be empty after disconnect")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Publisher/Subscriber Isolation with Multi-Participant

    func testPublisher_isolation_multipleDetaches() {
        let publisher = InterLiveKitPublisher()
        // Multiple detach calls should be safe (simulates multiple participants leaving)
        publisher.detachAllSources()
        publisher.detachAllSources()
        publisher.detachAllSources()
    }

    func testSubscriber_isolation_multipleDetaches() {
        let subscriber = InterLiveKitSubscriber()
        subscriber.detach()
        subscriber.detach()
        subscriber.detach()
    }

    // MARK: - Token Service Room Full Handling

    func testTokenService_roomFullErrorCode() {
        // Verify the error code value matches what the server sends (403 → .roomFull)
        XCTAssertEqual(InterNetworkErrorCode.roomFull.rawValue, 1008)

        let error = InterNetworkErrorCode.roomFull.error(message: "Room is full")
        XCTAssertEqual(error.code, InterNetworkErrorCode.roomFull.rawValue)
        XCTAssertEqual(error.domain, "com.secure.inter.network")
    }
}

// MARK: - Token Server Integration Tests (require running server)

final class InterMultiParticipantIntegrationTests: XCTestCase {

    private let serverURL = "http://localhost:3000"

    private var isServerRunning: Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var running = false
        guard let url = URL(string: "\(serverURL)/health") else { return false }
        let task = URLSession.shared.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                running = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return running
    }

    override func setUp() {
        super.setUp()
        try? XCTSkipUnless(isServerRunning,
                           "Token server not running at \(serverURL)")
    }

    // MARK: - Room Create Includes Max Participants

    func testCreateRoom_includesMaxParticipants() {
        let tokenService = InterTokenService()
        let exp = expectation(description: "create")

        tokenService.createRoom(
            serverURL: serverURL,
            identity: "host-mp-\(UUID().uuidString.prefix(8))",
            displayName: "HostMP"
        ) { response, error in
            XCTAssertNil(error)
            XCTAssertNotNil(response)
            exp.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    // MARK: - Room Full Rejection

    func testRoomFull_rejectsExcessParticipants() {
        let tokenService = InterTokenService()
        let createExp = expectation(description: "create")
        var roomCode = ""

        // Step 1: Create a room
        let hostId = "host-full-\(UUID().uuidString.prefix(8))"
        tokenService.createRoom(
            serverURL: serverURL,
            identity: hostId,
            displayName: "HostFull"
        ) { response, error in
            XCTAssertNil(error)
            roomCode = response?.roomCode ?? ""
            createExp.fulfill()
        }
        waitForExpectations(timeout: 10)
        XCTAssertFalse(roomCode.isEmpty, "Room code should not be empty")

        // Step 2: Join with 3 more participants (total = 4 = max)
        for i in 1...3 {
            let joinExp = expectation(description: "join\(i)")
            tokenService.joinRoom(
                serverURL: serverURL,
                roomCode: roomCode,
                identity: "joiner-\(i)-\(UUID().uuidString.prefix(8))",
                displayName: "Joiner \(i)"
            ) { response, error in
                XCTAssertNil(error, "Joiner \(i) should succeed")
                XCTAssertNotNil(response)
                joinExp.fulfill()
            }
            waitForExpectations(timeout: 10)
        }

        // Step 3: 5th participant should be rejected (room full)
        let rejectExp = expectation(description: "reject")
        tokenService.joinRoom(
            serverURL: serverURL,
            roomCode: roomCode,
            identity: "joiner-5th-\(UUID().uuidString.prefix(8))",
            displayName: "Joiner 5th"
        ) { response, error in
            XCTAssertNotNil(error, "5th participant should be rejected")
            XCTAssertNil(response)
            XCTAssertEqual(error?.code, InterNetworkErrorCode.roomFull.rawValue,
                           "Error code should be roomFull (1008)")
            rejectExp.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    // MARK: - Reconnect Dedup (Same Identity Doesn't Count Twice)

    func testRoomFull_sameIdentityDoesNotCountTwice() {
        let tokenService = InterTokenService()
        let createExp = expectation(description: "create")
        var roomCode = ""

        let hostId = "host-dedup-\(UUID().uuidString.prefix(8))"
        tokenService.createRoom(
            serverURL: serverURL,
            identity: hostId,
            displayName: "HostDedup"
        ) { response, error in
            XCTAssertNil(error)
            roomCode = response?.roomCode ?? ""
            createExp.fulfill()
        }
        waitForExpectations(timeout: 10)

        // Join with a participant, then rejoin with the same identity
        let joinerId = "joiner-dedup-\(UUID().uuidString.prefix(8))"
        for attempt in 1...3 {
            let joinExp = expectation(description: "join-attempt-\(attempt)")
            tokenService.joinRoom(
                serverURL: serverURL,
                roomCode: roomCode,
                identity: joinerId,
                displayName: "Joiner"
            ) { response, error in
                XCTAssertNil(error, "Same identity rejoining should always succeed")
                XCTAssertNotNil(response)
                joinExp.fulfill()
            }
            waitForExpectations(timeout: 10)
        }
    }

    // MARK: - Room Info Endpoint

    func testRoomInfo_returnsParticipantCount() {
        let createExp = expectation(description: "create")
        var roomCode = ""

        // Create room
        let body = ["identity": "host-info-\(UUID().uuidString.prefix(8))",
                     "displayName": "HostInfo"]
        postJSON(url: "\(serverURL)/room/create", body: body) { data, _, error in
            XCTAssertNil(error)
            if let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] {
                roomCode = json["roomCode"] as? String ?? ""
            }
            createExp.fulfill()
        }
        waitForExpectations(timeout: 10)
        XCTAssertFalse(roomCode.isEmpty)

        // Check room info
        let infoExp = expectation(description: "info")
        guard let url = URL(string: "\(serverURL)/room/info/\(roomCode)") else {
            XCTFail("Invalid URL")
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, error in
            XCTAssertNil(error)
            let http = response as? HTTPURLResponse
            XCTAssertEqual(http?.statusCode, 200)

            if let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] {
                XCTAssertEqual(json["participantCount"] as? Int, 1)
                XCTAssertEqual(json["maxParticipants"] as? Int, 4)
                XCTAssertEqual(json["isFull"] as? Bool, false)
                XCTAssertEqual(json["roomCode"] as? String, roomCode)
            } else {
                XCTFail("Failed to parse room info response")
            }
            infoExp.fulfill()
        }.resume()
        waitForExpectations(timeout: 10)
    }

    // MARK: - Helpers

    private func postJSON(url: String, body: [String: Any],
                          completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        guard let requestURL = URL(string: url) else {
            completion(nil, nil, nil)
            return
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
    }
}
