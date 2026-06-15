//
//  InterTeamsChatServiceTests.swift
//  interTests
//
//  Tests the service's orchestration (optimistic echo → confirm/fail, live
//  fan-out ingestion, read-cursor advance) with a fake transport + fake realtime
//  client — no live server.
//

import XCTest
import Combine
@testable import inter

// MARK: - Fakes

private final class FakeRealtimeClient: InterRealtimeClient {
    weak var stateDelegate: InterRealtimeClientStateDelegate?
    var state: InterRealtimeConnectionState = .disconnected
    var joinedRooms: [String] = []
    private var handlers: [String: (Data) -> Void] = [:]

    func connect(tokenProvider: @escaping () -> String?) { state = .connected }
    func join(room: String) { joinedRooms.append(room) }
    func leave(room: String) { joinedRooms.removeAll { $0 == room } }
    func on(_ event: String, handler: @escaping (Data) -> Void) { handlers[event] = handler }
    func disconnect() { handlers.removeAll() }

    /// Simulate a server fan-out frame.
    func emit(_ event: String, _ json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        handlers[event]?(data)
    }
}

private final class FakeTransport: InterTeamsChatTransport {
    var history: [InterTeamMessage] = []
    var sendResult: Result<InterTeamMessage, Error>?
    var markReadCalls: [String] = []
    private(set) var sentBodies: [String] = []

    func loadMessages(teamId: String, before: String?,
                      completion: @escaping (Result<[InterTeamMessage], Error>) -> Void) {
        completion(.success(history))
    }
    func sendMessage(teamId: String, body: String, idempotencyKey: String,
                     completion: @escaping (Result<InterTeamMessage, Error>) -> Void) {
        sentBodies.append(body)
        if let r = sendResult { completion(r) }
    }
    func markRead(teamId: String, messageId: String,
                  completion: @escaping (Result<Void, Error>) -> Void) {
        markReadCalls.append(messageId)
        completion(.success(()))
    }
}

private func serverMessageJSON(id: String, body: String, secondsFromNow: TimeInterval = 0) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return [
        "id": id, "teamId": "team-1", "senderUserId": "u1", "senderName": "Alice",
        "kind": "text", "body": body,
        "createdAt": iso.string(from: Date(timeIntervalSince1970: 1_000_000 + secondsFromNow)),
    ]
}

private func serverMessage(id: String, body: String, secondsFromNow: TimeInterval = 0) -> InterTeamMessage {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return InterTeamMessage(serverJSON: serverMessageJSON(id: id, body: body, secondsFromNow: secondsFromNow), iso: iso)!
}

// MARK: - Tests

@MainActor
final class InterTeamsChatServiceTests: XCTestCase {

    private func makeService(_ transport: FakeTransport, _ realtime: FakeRealtimeClient) -> InterTeamsChatService {
        InterTeamsChatService(teamId: "team-1", transport: transport, realtime: realtime,
                              tokenProvider: { "fake-jwt" })
    }

    func testStartJoinsRoomAndLoadsHistory() async throws {
        let transport = FakeTransport()
        transport.history = [serverMessage(id: "1", body: "old", secondsFromNow: 0)]
        let realtime = FakeRealtimeClient()
        let service = makeService(transport, realtime)

        service.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(realtime.joinedRooms, ["team-1"])
        XCTAssertEqual(service.messages.map { $0.id }, ["1"])
    }

    func testServerJSONDecodeRoundTrips() {
        let m = serverMessage(id: "42", body: "hello")
        XCTAssertEqual(m.id, "42")
        XCTAssertEqual(m.body, "hello")
        XCTAssertEqual(m.kind, "text")
        XCTAssertEqual(m.status, .confirmed)
    }

    func testSendTextShowsPendingThenConfirms() async throws {
        let transport = FakeTransport()
        transport.sendResult = .success(serverMessage(id: "5", body: "hi", secondsFromNow: 10))
        let realtime = FakeRealtimeClient()
        let service = makeService(transport, realtime)
        service.start()

        service.sendText("hi", senderUserId: "me", senderName: "Me")
        // Echo is synchronous.
        XCTAssertEqual(service.messages.count, 1)
        XCTAssertEqual(service.messages.first?.status, .pending)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.messages.count, 1, "confirm must replace the echo, not add")
        XCTAssertEqual(service.messages.first?.id, "5")
        XCTAssertEqual(service.messages.first?.status, .confirmed)
        XCTAssertEqual(transport.sentBodies, ["hi"])
    }

    func testSendTextFailureMarksFailed() async throws {
        let transport = FakeTransport()
        transport.sendResult = .failure(NSError(domain: "x", code: 1))
        let realtime = FakeRealtimeClient()
        let service = makeService(transport, realtime)
        service.start()

        service.sendText("oops", senderUserId: "me", senderName: "Me")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(service.messages.count, 1)
        XCTAssertEqual(service.messages.first?.status, .failed, "failed send stays for retry")
    }

    func testEmptyMessageIsNotSent() {
        let transport = FakeTransport()
        let realtime = FakeRealtimeClient()
        let service = makeService(transport, realtime)
        service.start()

        service.sendText("   \n ", senderUserId: "me", senderName: "Me")
        XCTAssertTrue(transport.sentBodies.isEmpty)
        XCTAssertEqual(service.messages.count, 0)
    }

    func testLiveFanoutIsIngestedAndDeduped() async throws {
        let transport = FakeTransport()
        let realtime = FakeRealtimeClient()
        let service = makeService(transport, realtime)
        service.start()

        realtime.emit("team:message", serverMessageJSON(id: "9", body: "live", secondsFromNow: 5))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.messages.map { $0.id }, ["9"])

        // Same id again (redelivery) must not duplicate.
        realtime.emit("team:message", serverMessageJSON(id: "9", body: "live", secondsFromNow: 5))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.messages.count, 1)
    }

    func testMarkReadAdvancesToHighestId() async throws {
        let transport = FakeTransport()
        transport.history = [serverMessage(id: "3", body: "a"), serverMessage(id: "8", body: "b", secondsFromNow: 1)]
        let realtime = FakeRealtimeClient()
        let service = makeService(transport, realtime)

        service.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(transport.markReadCalls.last, "8", "read cursor advances to the numeric max id")
    }
}
