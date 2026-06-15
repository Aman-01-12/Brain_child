//
//  TeamMembersViewModelTests.swift
//  interTests
//
//  Tests the members sheet view model: pure helpers (email shape, error copy,
//  role label), role-based gating (canManage / canRemove), and the
//  load / add / remove flows via a fake provider — no live server.
//

import XCTest
@testable import inter

private final class FakeMembersProvider: InterTeamMembersProviding {
    var loadResult: Result<(members: [InterTeamMember], callerRole: String), Error>?
    var addResult: Result<InterTeamMember, InterAddMemberError>?
    var removeResult: Result<Void, Error> = .success(())
    private(set) var addedEmails: [String] = []
    private(set) var removedIds: [String] = []

    func loadMembers(teamId: String,
                     completion: @escaping (Result<(members: [InterTeamMember], callerRole: String), Error>) -> Void) {
        completion(loadResult ?? .success((members: [], callerRole: "member")))
    }
    func addMember(teamId: String, email: String,
                   completion: @escaping (Result<InterTeamMember, InterAddMemberError>) -> Void) {
        addedEmails.append(email)
        if let r = addResult { completion(r) }
    }
    func removeMember(teamId: String, memberId: String,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        removedIds.append(memberId)
        completion(removeResult)
    }
}

private func member(_ id: String, _ name: String, email: String, role: String = "member",
                    status: String = "active", userId: String? = nil) -> InterTeamMember {
    InterTeamMember(id: id, teamId: "team-1", userId: userId ?? id, email: email,
                    displayName: name, role: role, status: status)
}

@MainActor
final class TeamMembersViewModelTests: XCTestCase {

    private func makeVM(_ provider: FakeMembersProvider, currentUserId: String? = "me") -> TeamMembersViewModel {
        TeamMembersViewModel(teamId: "team-1", teamName: "Platform",
                             currentUserId: currentUserId, provider: provider)
    }

    // MARK: - Pure helpers

    func testIsPlausibleEmail() {
        XCTAssertTrue(TeamMembersViewModel.isPlausibleEmail("a@b.co"))
        XCTAssertTrue(TeamMembersViewModel.isPlausibleEmail("  Person@Example.com "))
        XCTAssertFalse(TeamMembersViewModel.isPlausibleEmail("noatsign"))
        XCTAssertFalse(TeamMembersViewModel.isPlausibleEmail("a@b"), "needs a dot in the domain")
        XCTAssertFalse(TeamMembersViewModel.isPlausibleEmail("@b.co"))
        XCTAssertFalse(TeamMembersViewModel.isPlausibleEmail("a@.co"))
        XCTAssertFalse(TeamMembersViewModel.isPlausibleEmail(""))
    }

    func testErrorMessages() {
        XCTAssertTrue(TeamMembersViewModel.message(for: .noInterAccount).localizedCaseInsensitiveContains("registered"))
        XCTAssertTrue(TeamMembersViewModel.message(for: .notAuthorized).localizedCaseInsensitiveContains("owner"))
        XCTAssertEqual(TeamMembersViewModel.message(for: .other("boom")), "boom")
        XCTAssertFalse(TeamMembersViewModel.message(for: .other("")).isEmpty, "empty falls back to a generic line")
    }

    func testRoleLabel() {
        XCTAssertEqual(TeamMembersViewModel.roleLabel("owner"), "Owner")
        XCTAssertEqual(TeamMembersViewModel.roleLabel("admin"), "Admin")
        XCTAssertEqual(TeamMembersViewModel.roleLabel("member"), "Member")
    }

    // MARK: - Gating

    func testCanRemoveRules() async throws {
        let provider = FakeMembersProvider()
        provider.loadResult = .success((
            members: [
                member("owner-1", "Owner", email: "o@x.co", role: "owner", userId: "owner-uid"),
                member("m-1", "Mate", email: "m@x.co", role: "member", userId: "mate-uid"),
                member("me-1", "Me", email: "me@x.co", role: "member", userId: "me"),
            ],
            callerRole: "admin"
        ))
        let vm = makeVM(provider, currentUserId: "me")
        vm.load()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(vm.canManage, "admin can manage")
        XCTAssertFalse(vm.canRemove(vm.members.first { $0.role == "owner" }!), "owner is never removable")
        XCTAssertTrue(vm.canRemove(vm.members.first { $0.id == "m-1" }!), "admin can remove a member")
    }

    func testPlainMemberCanOnlyRemoveSelf() async throws {
        let provider = FakeMembersProvider()
        provider.loadResult = .success((
            members: [
                member("m-1", "Mate", email: "m@x.co", role: "member", userId: "mate-uid"),
                member("me-1", "Me", email: "me@x.co", role: "member", userId: "me"),
            ],
            callerRole: "member"
        ))
        let vm = makeVM(provider, currentUserId: "me")
        vm.load()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(vm.canManage)
        XCTAssertFalse(vm.canRemove(vm.members.first { $0.id == "m-1" }!), "can't remove others")
        XCTAssertTrue(vm.canRemove(vm.members.first { $0.id == "me-1" }!), "can leave (remove self)")
    }

    // MARK: - Load / add / remove

    func testLoadFiltersToActiveMembers() async throws {
        let provider = FakeMembersProvider()
        provider.loadResult = .success((
            members: [
                member("a", "Active", email: "a@x.co", status: "active"),
                member("r", "Removed", email: "r@x.co", status: "removed"),
            ],
            callerRole: "owner"
        ))
        let vm = makeVM(provider)
        vm.load()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(vm.members.map { $0.id }, ["a"], "removed members are hidden")
        XCTAssertEqual(vm.callerRole, "owner")
    }

    func testAddMemberSuccessInsertsAndClearsDraft() async throws {
        let provider = FakeMembersProvider()
        provider.addResult = .success(member("new", "Newbie", email: "new@x.co"))
        let vm = makeVM(provider)
        vm.draftEmail = "new@x.co"

        vm.addMember()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(provider.addedEmails, ["new@x.co"])
        XCTAssertEqual(vm.members.map { $0.id }, ["new"])
        XCTAssertTrue(vm.draftEmail.isEmpty, "draft clears on success")
        XCTAssertNil(vm.errorMessage)
        XCTAssertNotNil(vm.infoMessage)
    }

    func testAddMemberNoAccountShowsErrorAndDoesNotInsert() async throws {
        let provider = FakeMembersProvider()
        provider.addResult = .failure(.noInterAccount)
        let vm = makeVM(provider)
        vm.draftEmail = "ghost@x.co"

        vm.addMember()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(vm.members.isEmpty)
        XCTAssertEqual(vm.errorMessage, TeamMembersViewModel.message(for: .noInterAccount))
        XCTAssertEqual(vm.draftEmail, "ghost@x.co", "draft preserved so the user can correct it")
    }

    func testAddMemberRejectsInvalidEmailLocally() {
        let provider = FakeMembersProvider()
        let vm = makeVM(provider)
        vm.draftEmail = "not-an-email"

        vm.addMember()

        XCTAssertTrue(provider.addedEmails.isEmpty, "invalid email never hits the network")
        XCTAssertNotNil(vm.errorMessage)
    }

    func testRemoveMemberDropsFromList() async throws {
        let provider = FakeMembersProvider()
        provider.loadResult = .success((
            members: [member("m-1", "Mate", email: "m@x.co")],
            callerRole: "owner"
        ))
        let vm = makeVM(provider)
        vm.load()
        try await Task.sleep(nanoseconds: 30_000_000)

        vm.removeMember(vm.members[0])
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(provider.removedIds, ["m-1"])
        XCTAssertTrue(vm.members.isEmpty)
    }
}
