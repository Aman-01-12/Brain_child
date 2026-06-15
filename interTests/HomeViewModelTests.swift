//
//  HomeViewModelTests.swift
//  interTests
//
//  Tests the home screen view model: room-code sanitization, the four-state
//  auth model (especially offline-with-session), greeting/initials/time
//  labels, join gating for guests vs signed-in users, and history parsing.
//

import XCTest
@testable import inter

private let utcCal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    utcCal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

@MainActor
final class HomeViewModelTests: XCTestCase {

    // MARK: - Room code sanitization (G7)

    func testSanitizeRoomCode() {
        XCTAssertEqual(HomeViewModel.sanitizeRoomCode("a92k1z"), "A92KZ", "lowercase upped, confusable 1 stripped")
        XCTAssertEqual(HomeViewModel.sanitizeRoomCode("0OI1Lx"), "LX", "0/O/I/1 stripped; L preserved (server uses it)")
        XCTAssertEqual(HomeViewModel.sanitizeRoomCode("AB-CD EF!G"), "ABCDEF", "non-alphanumerics stripped, capped at 6")
        XCTAssertEqual(HomeViewModel.sanitizeRoomCode(""), "")
    }

    func testSanitizePreservesLInServerGeneratedCode() {
        // Server room-code alphabet includes L (e.g. "5XZ7L9"); stripping it made
        // such codes un-typable (5 chars → Join button never enabled).
        XCTAssertEqual(HomeViewModel.sanitizeRoomCode("5xz7l9"), "5XZ7L9")
        XCTAssertEqual(HomeViewModel.sanitizeRoomCode("5XZ7L9").count, 6)
    }

    func testJoinCodeFieldAutoSanitizes() {
        let vm = HomeViewModel()
        vm.joinCode = "x7k29m!!"
        XCTAssertEqual(vm.joinCode, "X7K29M")
    }

    // MARK: - Auth states

    func testOfflineWithSessionKeepsIdentityAndDisablesAuthActions() {
        let vm = HomeViewModel()
        vm.authState = .offlineWithSession
        vm.displayName = "Aman Verma"

        XCTAssertEqual(vm.effectiveDisplayName, "Aman Verma", "identity survives offline")
        XCTAssertFalse(vm.canUseAuthenticatedActions, "host/schedule disabled offline")
        XCTAssertEqual(vm.identitySubtitle, "Offline — reconnecting…")
        XCTAssertTrue(vm.greeting.contains("Aman"), "greeting still personal offline")
    }

    func testSignedOutUsesGuestNameAndGatesHosting() {
        let vm = HomeViewModel()
        vm.authState = .signedOut
        vm.displayName = "Stale Account"   // must NOT leak into guest identity
        vm.guestName = "  Visitor  "

        XCTAssertEqual(vm.effectiveDisplayName, "Visitor", "guest name trimmed, account name ignored")
        XCTAssertFalse(vm.canUseAuthenticatedActions)
        XCTAssertEqual(vm.identitySubtitle, "Sign in to host meetings")
    }

    func testSignedInUsesAccountName() {
        let vm = HomeViewModel()
        vm.authState = .signedIn
        vm.displayName = "Aman Verma"
        vm.tier = "pro"

        XCTAssertEqual(vm.effectiveDisplayName, "Aman Verma")
        XCTAssertTrue(vm.canUseAuthenticatedActions)
        XCTAssertTrue(vm.isPaidTier)
        XCTAssertEqual(vm.identitySubtitle, "Pro plan")
    }

    // MARK: - Join gating

    func testCanJoinRequiresFullCodeAndName() {
        let vm = HomeViewModel()
        vm.authState = .signedOut
        vm.joinCode = "X7K29M"
        XCTAssertFalse(vm.canJoin, "guest without a name can't join")
        vm.guestName = "Visitor"
        XCTAssertTrue(vm.canJoin)
        vm.joinCode = "X7K"
        XCTAssertFalse(vm.canJoin, "partial code blocks")
        vm.joinCode = "X7K29M"
        vm.actionsEnabled = false
        XCTAssertFalse(vm.canJoin, "in-flight operations block")
    }

    func testSubmitJoinOnlyFiresWhenAllowed() {
        let vm = HomeViewModel()
        var fired = 0
        vm.onJoin = { fired += 1 }
        vm.authState = .signedIn
        vm.displayName = "Aman"
        vm.joinCode = "X7K"
        vm.submitJoin()
        XCTAssertEqual(fired, 0)
        vm.joinCode = "X7K29M"
        vm.submitJoin()
        XCTAssertEqual(fired, 1)
    }

    // MARK: - Pure helpers

    func testGreetingBuckets() {
        XCTAssertEqual(HomeViewModel.greeting(for: utcDate(2026, 6, 12, 8), name: "Aman Verma", calendar: utcCal),
                       "Good morning, Aman")
        XCTAssertEqual(HomeViewModel.greeting(for: utcDate(2026, 6, 12, 14), name: "", calendar: utcCal),
                       "Good afternoon")
        XCTAssertEqual(HomeViewModel.greeting(for: utcDate(2026, 6, 12, 22), name: "Bo", calendar: utcCal),
                       "Good evening, Bo")
        XCTAssertEqual(HomeViewModel.greeting(for: utcDate(2026, 6, 12, 2), name: "X", calendar: utcCal),
                       "Good evening, X", "small hours read as evening")
    }

    func testInitials() {
        XCTAssertEqual(HomeViewModel.initials(from: "Aman Verma"), "AV")
        XCTAssertEqual(HomeViewModel.initials(from: "Cher"), "C")
        XCTAssertEqual(HomeViewModel.initials(from: ""), "?")
    }

    func testHistoryTimeLabels() {
        let now = utcDate(2026, 6, 12, 18)
        XCTAssertEqual(HomeViewModel.historyTimeLabel(utcDate(2026, 6, 12, 10), now: now, calendar: utcCal),
                       "Today, 10:00 AM")
        XCTAssertEqual(HomeViewModel.historyTimeLabel(utcDate(2026, 6, 11, 14), now: now, calendar: utcCal),
                       "Yesterday, 2:00 PM")
        XCTAssertEqual(HomeViewModel.historyTimeLabel(utcDate(2026, 6, 6, 16, 30), now: now, calendar: utcCal),
                       "Jun 6, 4:30 PM")
    }

    // MARK: - History parsing

    func testParseHistoryDecodesServerShape() {
        let json = """
        {"meetings":[
          {"id":"m1","roomCode":"A92K2Z","roomName":"Sprint Planning","roomType":"call",
           "status":"ended","startedAt":"2026-06-12T10:00:00.000Z","endedAt":"2026-06-12T10:45:00.000Z",
           "durationMinutes":45,"participantCount":8,"role":"host"},
          {"id":"m2","roomCode":"B74X9P","roomName":"Live Now","roomType":"interview",
           "status":"active","startedAt":"2026-06-12T12:00:00Z","endedAt":null,
           "durationMinutes":null,"participantCount":2,"role":"participant"},
          {"id":"bad","roomName":"missing code + date"}
        ]}
        """.data(using: .utf8)!

        let items = HomeViewModel.parseHistory(json)
        XCTAssertEqual(items.count, 2, "malformed row dropped")
        XCTAssertEqual(items[0].roomCode, "A92K2Z")
        XCTAssertEqual(items[0].durationMinutes, 45)
        XCTAssertEqual(items[0].role, "host")
        XCTAssertEqual(items[1].status, "active")
        XCTAssertNil(items[1].durationMinutes, "no fabricated duration")
        XCTAssertEqual(items[1].roomType, "interview")
    }

    func testParseHistoryMalformedPayload() {
        XCTAssertEqual(HomeViewModel.parseHistory(Data("not json".utf8)), [])
        XCTAssertEqual(HomeViewModel.parseHistory(Data("{}".utf8)), [])
    }

    func testHistorySetAndClear() {
        let vm = HomeViewModel()
        XCTAssertFalse(vm.historyLoaded)
        vm.setHistory([HomeMeetingHistoryItem(
            id: "1", roomCode: "ABCDEF", roomName: "X", roomType: "call", status: "ended",
            startedAt: Date(), durationMinutes: nil, participantCount: 1, role: "host")])
        XCTAssertTrue(vm.historyLoaded)
        XCTAssertEqual(vm.history.count, 1)
        vm.clearHistory()
        XCTAssertFalse(vm.historyLoaded)
        XCTAssertTrue(vm.history.isEmpty)
    }
}
