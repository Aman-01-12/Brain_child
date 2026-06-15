//
//  CallControlBarViewModelTests.swift
//  interTests
//
//  Tests the in-call bar view model (labels, gating, react coming-soon,
//  badges) and the consolidated requests panel (sectioning, approve/deny
//  routing, sort order).
//

import XCTest
@testable import inter

@MainActor
final class CallControlBarViewModelTests: XCTestCase {

    // MARK: - Labels

    func testMicLabelOverrideWins() {
        let vm = CallControlBarViewModel()
        vm.micEnabled = true
        XCTAssertEqual(vm.micLabel, "Mute")
        vm.micEnabled = false
        XCTAssertEqual(vm.micLabel, "Unmute")
        vm.micTitleOverride = "Request Sent…"
        XCTAssertEqual(vm.micLabel, "Request Sent…", "wiring-controller override wins")
        vm.micTitleOverride = nil
        XCTAssertEqual(vm.micLabel, "Unmute")
    }

    func testShareLabelStates() {
        let vm = CallControlBarViewModel()
        XCTAssertEqual(vm.shareLabel, "Share")
        vm.sharePending = true
        XCTAssertEqual(vm.shareLabel, "Requested…", "participant request-pending state")
        XCTAssertFalse(vm.canShare, "pending blocks re-clicks")
        vm.sharePending = false
        vm.sharingActive = true
        XCTAssertEqual(vm.shareLabel, "Stop Share")
    }

    // MARK: - Audio input selection

    func testSelectAudioInputRoutesAndUpdates() {
        let vm = CallControlBarViewModel()
        var selected: [String?] = []
        vm.onSelectAudioInput = { selected.append($0) }
        vm.selectAudioInput("dev-1")
        vm.selectAudioInput(nil)
        XCTAssertEqual(vm.selectedAudioInputID, nil)
        XCTAssertEqual(selected.count, 2)
        XCTAssertEqual(selected[0], "dev-1")
    }

    // MARK: - React coming-soon

    func testReactShowsComingSoon() {
        let vm = CallControlBarViewModel()
        XCTAssertFalse(vm.showReactComingSoon)
        vm.react()
        XCTAssertTrue(vm.showReactComingSoon, "no backing feature → graceful message")
    }

    func testSpeakerLabelReflectsMuteState() {
        let vm = CallControlBarViewModel()
        XCTAssertFalse(vm.speakerMuted)
        XCTAssertEqual(vm.speakerLabel, "Mute Audio")
        vm.speakerMuted = true
        XCTAssertEqual(vm.speakerLabel, "Unmute Audio")
    }

    // MARK: - Pure helpers

    func testSharePermissionLabels() {
        XCTAssertEqual(CallControlBarViewModel.sharePermissionLabel("everyone"), "Everyone")
        XCTAssertEqual(CallControlBarViewModel.sharePermissionLabel("request"), "Request to Share")
        XCTAssertEqual(CallControlBarViewModel.sharePermissionLabel("hostOnly"), "Host Only")
        XCTAssertEqual(CallControlBarViewModel.sharePermissionLabel("garbage"), "Host Only", "unknown → safest")
    }

    func testBadgeText() {
        XCTAssertNil(CallControlBarViewModel.badgeText(0))
        XCTAssertEqual(CallControlBarViewModel.badgeText(4), "4")
        XCTAssertEqual(CallControlBarViewModel.badgeText(12), "9+")
    }

    // MARK: - Combined More badge (requests + lobby waiters)

    func testMoreBadgeCountCombinesRequestsAndLobby() {
        let vm = CallControlBarViewModel()
        vm.lobbyVisible = true            // host/co-host can see/admit waiters
        vm.pendingRequestCount = 2
        vm.lobbyWaitingCount = 3
        XCTAssertEqual(vm.moreBadgeCount, 5, "both sources sum into one badge")
        XCTAssertEqual(CallControlBarViewModel.badgeText(vm.moreBadgeCount), "5")
    }

    func testMoreBadgeIgnoresLobbyWhenNotVisible() {
        let vm = CallControlBarViewModel()
        vm.lobbyVisible = false           // non-moderator: never sees lobby waiters
        vm.pendingRequestCount = 1
        vm.lobbyWaitingCount = 4
        XCTAssertEqual(vm.moreBadgeCount, 1,
                       "lobby waiters are gated out for participants who can't admit")
    }

    func testMoreBadgeZeroProducesNoBadge() {
        let vm = CallControlBarViewModel()
        vm.lobbyVisible = true
        XCTAssertEqual(vm.moreBadgeCount, 0)
        XCTAssertNil(CallControlBarViewModel.badgeText(vm.moreBadgeCount))
    }
}

@MainActor
final class RequestsPanelViewModelTests: XCTestCase {

    private func req(_ kind: CallRequestKind, _ identity: String, at t: TimeInterval) -> CallRequest {
        CallRequest(kind: kind, identity: identity, displayName: "User-\(identity)",
                    timestamp: Date(timeIntervalSince1970: t))
    }

    func testSetRequestsReplacesOnlyThatKind() {
        let vm = RequestsPanelViewModel()
        vm.setRequests([req(.raisedHand, "a", at: 1)], for: .raisedHand)
        vm.setRequests([req(.screenShare, "b", at: 2)], for: .screenShare)
        XCTAssertEqual(vm.totalCount, 2)

        // Re-push raised hands with a different set — screen share untouched.
        vm.setRequests([req(.raisedHand, "c", at: 3)], for: .raisedHand)
        XCTAssertEqual(vm.totalCount, 2)
        XCTAssertEqual(vm.rows(for: .raisedHand).map { $0.identity }, ["c"])
        XCTAssertEqual(vm.rows(for: .screenShare).map { $0.identity }, ["b"])
    }

    func testSortKindOrderThenOldestFirst() {
        let rows = [
            req(.cameraUnlock, "x", at: 5),
            req(.raisedHand, "b", at: 2),
            req(.raisedHand, "a", at: 1),
            req(.micUnlock, "m", at: 3),
        ]
        let sorted = RequestsPanelViewModel.sorted(rows)
        XCTAssertEqual(sorted.map { $0.identity }, ["a", "b", "m", "x"],
                       "kind order (hands→share→mic→camera), oldest first within a kind")
    }

    func testApproveRoutesAndRemoves() {
        let vm = RequestsPanelViewModel()
        var approved: [(CallRequestKind, String)] = []
        vm.onApprove = { approved.append(($0, $1)) }
        vm.setRequests([req(.micUnlock, "m1", at: 1)], for: .micUnlock)

        vm.approve(vm.requests[0])

        XCTAssertEqual(approved.count, 1)
        XCTAssertEqual(approved[0].1, "m1")
        XCTAssertTrue(vm.requests.isEmpty, "approved row leaves the panel")
    }

    func testDenyBlockedForRaisedHands() {
        let vm = RequestsPanelViewModel()
        var denied: [(CallRequestKind, String)] = []
        vm.onDeny = { denied.append(($0, $1)) }
        vm.setRequests([req(.raisedHand, "h1", at: 1)], for: .raisedHand)
        vm.setRequests([req(.screenShare, "s1", at: 2)], for: .screenShare)

        vm.deny(vm.rows(for: .raisedHand)[0])
        XCTAssertTrue(denied.isEmpty, "raised hands can't be denied")
        XCTAssertEqual(vm.totalCount, 2, "row stays")

        vm.deny(vm.rows(for: .screenShare)[0])
        XCTAssertEqual(denied.count, 1)
        XCTAssertEqual(vm.totalCount, 1)
    }

    func testActiveKindsAndApproveLabels() {
        let vm = RequestsPanelViewModel()
        vm.setRequests([req(.cameraUnlock, "c", at: 1)], for: .cameraUnlock)
        XCTAssertEqual(vm.activeKinds, [.cameraUnlock])
        XCTAssertEqual(RequestsPanelViewModel.approveLabel(for: .raisedHand), "Lower Hand")
        XCTAssertEqual(RequestsPanelViewModel.approveLabel(for: .screenShare), "Allow")
    }
}
