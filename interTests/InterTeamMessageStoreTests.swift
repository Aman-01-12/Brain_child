//
//  InterTeamMessageStoreTests.swift
//  interTests
//
//  Tests for the team chat message store — the reconciliation core (design spec
//  §11, paranoid H10). Each test fails if the dedup / ordering / echo logic regresses.
//

import XCTest
@testable import inter

final class InterTeamMessageStoreTests: XCTestCase {

    private func msg(_ id: String, _ secondsFromNow: TimeInterval, body: String = "m",
                     status: InterTeamMessageStatus = .confirmed, clientKey: String? = nil) -> InterTeamMessage {
        InterTeamMessage(id: id, teamId: "t", senderUserId: "u", senderName: "U",
                         kind: "text", body: body, file: nil,
                         createdAt: Date(timeIntervalSince1970: 1_000_000 + secondsFromNow),
                         status: status, clientKey: clientKey)
    }

    func testIngestDedupsByServerId() {
        let store = InterTeamMessageStore()
        store.ingest(msg("1", 0, body: "first"))
        store.ingest(msg("1", 0, body: "edited-or-redelivered"))   // same id again

        XCTAssertEqual(store.confirmedCount, 1, "same id must not duplicate")
        XCTAssertEqual(store.messages.first?.body, "edited-or-redelivered")
    }

    func testMessagesSortedByCreatedAtThenId() {
        let store = InterTeamMessageStore()
        // Insert out of order; ids and timestamps both ascending.
        store.ingest(msg("3", 30))
        store.ingest(msg("1", 10))
        store.ingest(msg("2", 20))

        XCTAssertEqual(store.messages.map { $0.id }, ["1", "2", "3"])
    }

    func testSameTimestampFallsBackToNumericId() {
        let store = InterTeamMessageStore()
        // Identical createdAt — must order by numeric id, not string ("10" > "9").
        store.ingest(msg("9", 0))
        store.ingest(msg("10", 0))

        XCTAssertEqual(store.messages.map { $0.id }, ["9", "10"],
                       "ordering must be numeric, not lexicographic")
    }

    func testHistoryAndLiveMergeDedupById() {
        let store = InterTeamMessageStore()
        // Live fan-out delivered id 2 first; history page then returns 1 and 2.
        store.ingest(msg("2", 20))
        store.ingestHistory([msg("1", 10), msg("2", 20)])

        XCTAssertEqual(store.confirmedCount, 2)
        XCTAssertEqual(store.messages.map { $0.id }, ["1", "2"])
    }

    func testPendingEchoAppearsThenConfirms() {
        let store = InterTeamMessageStore()
        let key = "ck-1"
        store.addPending(msg("pending:\(key)", 100, body: "hi", status: .pending, clientKey: key))

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.status, .pending)

        // REST 201 returns the persisted row with the real id.
        store.confirmPending(clientKey: key, with: msg("5", 100, body: "hi"))

        XCTAssertEqual(store.messages.count, 1, "echo must be replaced, not duplicated")
        XCTAssertEqual(store.messages.first?.id, "5")
        XCTAssertEqual(store.messages.first?.status, .confirmed)
    }

    /// Race: the fan-out frame (carrying our clientKey) arrives BEFORE our own
    /// REST response. The pending echo must be dropped and no duplicate remain.
    func testFanoutBeforeRestResponseDoesNotDuplicate() {
        let store = InterTeamMessageStore()
        let key = "ck-2"
        store.addPending(msg("pending:\(key)", 100, body: "race", status: .pending, clientKey: key))

        // Fan-out arrives first, echoing our clientKey on the persisted row.
        store.ingest(msg("7", 100, body: "race", clientKey: key))
        // Then our REST response confirms the same id.
        store.confirmPending(clientKey: key, with: msg("7", 100, body: "race"))

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.id, "7")
        XCTAssertEqual(store.messages.first?.status, .confirmed)
    }

    func testFailedPendingIsRetained() {
        let store = InterTeamMessageStore()
        let key = "ck-3"
        store.addPending(msg("pending:\(key)", 100, status: .pending, clientKey: key))
        store.failPending(clientKey: key)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.status, .failed, "failed send stays visible for retry")
    }

    func testHighestConfirmedIdForUnreadMath() {
        let store = InterTeamMessageStore()
        store.ingestHistory([msg("4", 10), msg("12", 20), msg("7", 15)])
        XCTAssertEqual(store.highestConfirmedId, 12, "must be numeric max, not string max")
    }

    func testRemoveAllClears() {
        let store = InterTeamMessageStore()
        store.ingest(msg("1", 0))
        store.addPending(msg("pending:k", 1, status: .pending, clientKey: "k"))
        store.removeAll()
        XCTAssertEqual(store.messages.count, 0)
        XCTAssertEqual(store.highestConfirmedId, 0)
    }
}
