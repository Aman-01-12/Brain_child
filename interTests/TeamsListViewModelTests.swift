//
//  TeamsListViewModelTests.swift
//  interTests
//
//  Tests the sidebar view model: pure presentation helpers (avatar initials,
//  unread badge text) and the selection / unread-clear / create flows via a
//  fake teams-list provider — no live server.
//

import XCTest
@testable import inter

private final class FakeTeamsListProvider: InterTeamsListProviding {
    var teams: [InterTeamSummary] = []
    var loadResult: Result<[InterTeamSummary], Error>?
    var createResult: Result<InterTeamSummary, Error>?
    private(set) var createdNames: [String] = []

    func loadTeams(completion: @escaping (Result<[InterTeamSummary], Error>) -> Void) {
        completion(loadResult ?? .success(teams))
    }
    func createTeam(name: String, description: String?,
                    completion: @escaping (Result<InterTeamSummary, Error>) -> Void) {
        createdNames.append(name)
        if let r = createResult { completion(r) }
    }
}

private func team(_ id: String, _ name: String, unread: Int = 0, members: Int = 1) -> InterTeamSummary {
    InterTeamSummary(id: id, name: name, description: nil, ownerUserId: "owner",
                     memberCount: members, unreadCount: unread)
}

@MainActor
final class TeamsListViewModelTests: XCTestCase {

    // MARK: - Pure helpers

    func testAvatarInitials() {
        XCTAssertEqual(TeamsListViewModel.avatarInitials(for: "Platform"), "PL")
        XCTAssertEqual(TeamsListViewModel.avatarInitials(for: "Design Ops"), "DO", "two words → first letter of each")
        XCTAssertEqual(TeamsListViewModel.avatarInitials(for: "x"), "X")
        XCTAssertEqual(TeamsListViewModel.avatarInitials(for: "   "), "?")
    }

    func testUnreadBadgeText() {
        XCTAssertNil(TeamsListViewModel.unreadBadgeText(0), "no badge when nothing unread")
        XCTAssertNil(TeamsListViewModel.unreadBadgeText(-3))
        XCTAssertEqual(TeamsListViewModel.unreadBadgeText(1), "1")
        XCTAssertEqual(TeamsListViewModel.unreadBadgeText(9), "9")
        XCTAssertEqual(TeamsListViewModel.unreadBadgeText(10), "9+", "caps at 9+")
        XCTAssertEqual(TeamsListViewModel.unreadBadgeText(250), "9+")
    }

    // MARK: - Load + selection

    func testLoadTeamsSelectsFirstWhenNoneSelected() async throws {
        let provider = FakeTeamsListProvider()
        provider.teams = [team("a", "Alpha"), team("b", "Beta")]
        let vm = TeamsListViewModel(provider: provider)

        vm.loadTeams()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(vm.teams.map { $0.id }, ["a", "b"])
        XCTAssertEqual(vm.selectedTeamId, "a", "first team auto-selected")
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadTeamsPreservesExistingSelection() async throws {
        let provider = FakeTeamsListProvider()
        provider.teams = [team("a", "Alpha"), team("b", "Beta")]
        let vm = TeamsListViewModel(provider: provider)

        vm.selectTeam("b")
        vm.loadTeams()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(vm.selectedTeamId, "b", "reload keeps the user's current selection")
    }

    func testSelectTeamClearsItsUnreadBadge() async throws {
        let provider = FakeTeamsListProvider()
        provider.teams = [team("a", "Alpha", unread: 7), team("b", "Beta", unread: 3)]
        let vm = TeamsListViewModel(provider: provider)
        vm.loadTeams()
        try await Task.sleep(nanoseconds: 30_000_000)

        vm.selectTeam("a")
        XCTAssertEqual(vm.teams.first { $0.id == "a" }?.unreadCount, 0, "opening a team zeroes its badge")
        XCTAssertEqual(vm.teams.first { $0.id == "b" }?.unreadCount, 3, "other badges untouched")
    }

    func testCreateTeamInsertsAtFrontAndSelects() async throws {
        let provider = FakeTeamsListProvider()
        provider.teams = [team("a", "Alpha")]
        provider.createResult = .success(team("new", "New Squad"))
        let vm = TeamsListViewModel(provider: provider)
        vm.loadTeams()
        try await Task.sleep(nanoseconds: 30_000_000)

        vm.createTeam(name: "  New Squad  ")
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(provider.createdNames, ["New Squad"], "name is trimmed before send")
        XCTAssertEqual(vm.teams.first?.id, "new", "new team goes to the front")
        XCTAssertEqual(vm.selectedTeamId, "new", "new team is selected")
    }

    func testCreateTeamIgnoresBlankName() {
        let provider = FakeTeamsListProvider()
        let vm = TeamsListViewModel(provider: provider)
        vm.createTeam(name: "   ")
        XCTAssertTrue(provider.createdNames.isEmpty, "blank names are not sent")
    }
}
