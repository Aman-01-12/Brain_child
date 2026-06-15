//
//  TeamChatViewModelTests.swift
//  interTests
//
//  Tests the view model's pure presentation helpers (initials, relative time).
//  Data flow is covered by InterTeamsChatServiceTests; here we lock the
//  formatting that the chat UI depends on.
//

import XCTest
@testable import inter

final class TeamChatViewModelTests: XCTestCase {

    func testInitialsFromName() {
        XCTAssertEqual(TeamChatViewModel.initials(from: "Alice Chen"), "AC")
        XCTAssertEqual(TeamChatViewModel.initials(from: "Bob"), "B")
        XCTAssertEqual(TeamChatViewModel.initials(from: "mary jane watson"), "MJ", "only first two words")
        XCTAssertEqual(TeamChatViewModel.initials(from: "  spaced   out  "), "SO")
        XCTAssertEqual(TeamChatViewModel.initials(from: ""), "?", "empty name yields a placeholder")
    }

    func testRelativeTimeBuckets() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(TeamChatViewModel.relativeTime(from: now.addingTimeInterval(-10), reference: now), "now")
        XCTAssertEqual(TeamChatViewModel.relativeTime(from: now.addingTimeInterval(-5 * 60), reference: now), "5m")
        XCTAssertEqual(TeamChatViewModel.relativeTime(from: now.addingTimeInterval(-3 * 3600), reference: now), "3h")
        XCTAssertEqual(TeamChatViewModel.relativeTime(from: now.addingTimeInterval(-2 * 86400), reference: now), "2d")
        // >= 7 days falls back to an absolute "MMM d" date (not a relative bucket).
        let old = TeamChatViewModel.relativeTime(from: now.addingTimeInterval(-30 * 86400), reference: now)
        XCTAssertFalse(old.hasSuffix("d"), "old messages show an absolute date, not Nd")
    }
}
