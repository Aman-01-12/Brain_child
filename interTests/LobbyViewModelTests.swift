//
//  LobbyViewModelTests.swift
//  interTests
//
//  Logic tests for the lobby view models: host queue mutations + relative wait labels +
//  toggle callback semantics, and the participant state machine's per-state presentation.
//

import XCTest
@testable import inter

final class LobbyHostViewModelTests: XCTestCase {

    func testAddDeduplicatesByIdentity() {
        let vm = LobbyHostViewModel()
        vm.add(identity: "u1", displayName: "Alice")
        vm.add(identity: "u1", displayName: "Alice Again")
        XCTAssertEqual(vm.count, 1)
        XCTAssertEqual(vm.waiting.first?.displayName, "Alice")
    }

    func testRemoveAndClear() {
        let vm = LobbyHostViewModel()
        vm.add(identity: "u1", displayName: "Alice")
        vm.add(identity: "u2", displayName: "Bob")
        vm.remove(identity: "u1")
        XCTAssertEqual(vm.count, 1)
        XCTAssertEqual(vm.waiting.first?.id, "u2")
        vm.clear()
        XCTAssertTrue(vm.isEmpty)
    }

    func testInitialsDerivation() {
        XCTAssertEqual(LobbyWaitingEntry(id: "1", displayName: "Alice Chen", joinDate: Date()).initials, "AC")
        XCTAssertEqual(LobbyWaitingEntry(id: "2", displayName: "Bob", joinDate: Date()).initials, "B")
        XCTAssertEqual(LobbyWaitingEntry(id: "3", displayName: "  ", joinDate: Date()).initials, "?")
        XCTAssertEqual(LobbyWaitingEntry(id: "4", displayName: "diana prince smith", joinDate: Date()).initials, "DP")
    }

    func testWaitLabelJustNowThenMinutes() {
        let vm = LobbyHostViewModel()
        let now = LobbyWaitingEntry(id: "1", displayName: "A", joinDate: Date())
        XCTAssertEqual(vm.waitLabel(for: now), "Just now")
        let twoMin = LobbyWaitingEntry(id: "2", displayName: "B", joinDate: Date(timeIntervalSinceNow: -120))
        XCTAssertEqual(vm.waitLabel(for: twoMin), "2 min ago")
        let twoHr = LobbyWaitingEntry(id: "3", displayName: "C", joinDate: Date(timeIntervalSinceNow: -7200))
        XCTAssertEqual(vm.waitLabel(for: twoHr), "2 hr ago")
    }

    func testSetLobbyEnabledFiresCallbackOnlyOnChange() {
        let vm = LobbyHostViewModel()
        var fires: [Bool] = []
        vm.onToggleLobby = { fires.append($0) }
        vm.setLobbyEnabled(true)
        vm.setLobbyEnabled(true)   // no change → no callback
        vm.setLobbyEnabled(false)
        XCTAssertEqual(fires, [true, false])
    }

    func testAdmitDenyAdmitAllCallbacks() {
        let vm = LobbyHostViewModel()
        vm.add(identity: "u1", displayName: "Alice")
        var admitted: (String, String)?
        var denied: String?
        var admitAll = false
        vm.onAdmit = { admitted = ($0, $1) }
        vm.onDeny = { denied = $0 }
        vm.onAdmitAll = { admitAll = true }
        let entry = vm.waiting[0]
        vm.admit(entry); vm.deny(entry); vm.admitAll()
        XCTAssertEqual(admitted?.0, "u1")
        XCTAssertEqual(admitted?.1, "Alice")
        XCTAssertEqual(denied, "u1")
        XCTAssertTrue(admitAll)
    }
}

final class LobbyWaitingViewModelTests: XCTestCase {

    func testJoiningPresentation() {
        let vm = LobbyWaitingViewModel(); vm.state = .joining
        XCTAssertEqual(vm.title, "Joining Meeting")
        XCTAssertEqual(vm.iconSystemName, "video.fill")
        XCTAssertTrue(vm.showsSpinner)
        XCTAssertEqual(vm.buttonTitle, "Cancel")
        XCTAssertFalse(vm.buttonIsPrimary)
    }

    func testWaitingWithAndWithoutPosition() {
        let vm = LobbyWaitingViewModel(); vm.state = .waiting
        XCTAssertEqual(vm.buttonTitle, "Leave")
        XCTAssertFalse(vm.showsPosition)
        vm.position = 2
        XCTAssertTrue(vm.showsPosition)
    }

    func testDeniedIsPrimaryNoSpinner() {
        let vm = LobbyWaitingViewModel(); vm.state = .denied
        XCTAssertEqual(vm.title, "Access Denied")
        XCTAssertEqual(vm.accent, .danger)
        XCTAssertFalse(vm.showsSpinner)
        XCTAssertEqual(vm.buttonTitle, "OK")
        XCTAssertTrue(vm.buttonIsPrimary)
    }

    func testAdmittedHasNoButton() {
        let vm = LobbyWaitingViewModel(); vm.state = .admitted
        XCTAssertEqual(vm.title, "You're In!")
        XCTAssertEqual(vm.accent, .success)
        XCTAssertNil(vm.buttonTitle)
    }

    func testCustomMessageOverridesDefault() {
        let vm = LobbyWaitingViewModel(); vm.state = .waiting
        XCTAssertEqual(vm.message, "Please wait, the host will let you in shortly.")
        vm.customMessage = "Almost there…"
        XCTAssertEqual(vm.message, "Almost there…")
    }

    func testPositionOnlyShowsInWaiting() {
        let vm = LobbyWaitingViewModel()
        vm.position = 3
        vm.state = .joining
        XCTAssertFalse(vm.showsPosition)
        vm.state = .waiting
        XCTAssertTrue(vm.showsPosition)
    }
}
