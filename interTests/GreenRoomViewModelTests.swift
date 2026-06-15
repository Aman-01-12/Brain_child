//
//  GreenRoomViewModelTests.swift
//  interTests
//
//  Tests the green room view model: role-driven presentation (CTA titles,
//  session section, Meeting Settings visibility), device toggles + selection
//  routing, the join-without-video path, submit validation (name + password),
//  the host-OR-user join-state rule, and the pure helpers.
//

import XCTest
@testable import inter

@MainActor
final class GreenRoomViewModelTests: XCTestCase {

    // MARK: - Role presentation

    func testPrimaryTitlesByRole() {
        XCTAssertEqual(GreenRoomViewModel(role: .hostCreate).primaryTitle, "Start Meeting")
        XCTAssertEqual(GreenRoomViewModel(role: .join(roomCode: "A92K1Z")).primaryTitle, "Join Now")
        XCTAssertEqual(GreenRoomViewModel(role: .scheduledStart(roomCode: "A92K1Z")).primaryTitle, "Start Meeting")
        XCTAssertEqual(GreenRoomViewModel(role: .hostInterview).primaryTitle, "Start Interview")
    }

    func testWithoutVideoTitles() {
        XCTAssertEqual(GreenRoomViewModel(role: .join(roomCode: "X")).withoutVideoTitle, "Join without video")
        XCTAssertEqual(GreenRoomViewModel(role: .hostCreate).withoutVideoTitle, "Start without video")
        XCTAssertEqual(GreenRoomViewModel(role: .scheduledStart(roomCode: "X")).withoutVideoTitle, "Start without video")
        XCTAssertEqual(GreenRoomViewModel(role: .hostInterview).withoutVideoTitle, "Start without video")
    }

    func testMeetingSettingsButtonForHostCreateAndScheduledStart() {
        XCTAssertTrue(GreenRoomViewModel(role: .hostCreate).showsMeetingSettings)
        XCTAssertFalse(GreenRoomViewModel(role: .join(roomCode: "X")).showsMeetingSettings)
        // The scheduled host may re-open Meeting Settings to override the
        // schedule-time snapshot at start; the server applies the green-room edit
        // over the snapshot (InterTokenService settingsOverride → scheduling.js).
        XCTAssertTrue(GreenRoomViewModel(role: .scheduledStart(roomCode: "X")).showsMeetingSettings,
                      "scheduled host can override schedule-time settings in the green room")
        XCTAssertFalse(GreenRoomViewModel(role: .hostInterview).showsMeetingSettings)
    }

    func testRoomCodeOnlyForCodeBackedRoles() {
        XCTAssertEqual(GreenRoomViewModel(role: .join(roomCode: "A92K1Z")).roomCode, "A92K1Z")
        XCTAssertEqual(GreenRoomViewModel(role: .scheduledStart(roomCode: "B41Q7T")).roomCode, "B41Q7T")
        XCTAssertNil(GreenRoomViewModel(role: .hostCreate).roomCode)
        XCTAssertNil(GreenRoomViewModel(role: .hostInterview).roomCode)
    }

    // MARK: - Device toggles + selection

    func testTogglesFlipStateAndRoute() {
        let vm = GreenRoomViewModel(role: .join(roomCode: "X"))
        var micEvents: [Bool] = [], camEvents: [Bool] = []
        vm.onToggleMic = { micEvents.append($0) }
        vm.onToggleCam = { camEvents.append($0) }

        vm.toggleMic()
        vm.toggleCam()
        vm.toggleCam()

        XCTAssertFalse(vm.micOn)
        XCTAssertTrue(vm.camOn)
        XCTAssertEqual(micEvents, [false])
        XCTAssertEqual(camEvents, [false, true])
    }

    func testDeviceSelectionRoutesOnlyOnChange() {
        let vm = GreenRoomViewModel(role: .hostCreate)
        vm.setDevices(microphones: [.init(id: "m1", name: "Mic 1"), .init(id: "m2", name: "Mic 2")],
                      cameras: [.init(id: "c1", name: "Cam 1")],
                      selectedMicID: "m1", selectedCameraID: "c1")
        var mics: [String] = [], cams: [String] = []
        vm.onSelectMic = { mics.append($0) }
        vm.onSelectCamera = { cams.append($0) }

        vm.selectMic("m1")        // no-op (already selected)
        vm.selectMic("m2")
        vm.selectCamera("c1")     // no-op

        XCTAssertEqual(mics, ["m2"])
        XCTAssertTrue(cams.isEmpty)
        XCTAssertEqual(vm.selectedMicID, "m2")
    }

    // MARK: - Submit validation

    func testSubmitRequiresDisplayName() {
        let vm = GreenRoomViewModel(role: .join(roomCode: "X"))
        var fired = 0
        vm.onPrimaryAction = { fired += 1 }

        vm.displayName = "   "
        XCTAssertFalse(vm.canSubmit)
        vm.submitPrimary()
        XCTAssertEqual(fired, 0)

        vm.displayName = "Aman"
        XCTAssertTrue(vm.canSubmit)
        vm.submitPrimary()
        XCTAssertEqual(fired, 1)
    }

    func testHostCreatePasswordRuleBlocksSubmit() {
        let vm = GreenRoomViewModel(role: .hostCreate)
        vm.displayName = "Aman"
        var fired = 0
        vm.onPrimaryAction = { fired += 1 }

        vm.requirePassword = true
        vm.password = "  "
        XCTAssertTrue(vm.passwordInvalid)
        vm.submitPrimary()
        XCTAssertEqual(fired, 0, "empty required password blocks")

        vm.password = "pw"
        vm.submitPrimary()
        XCTAssertEqual(fired, 1)

        vm.requirePassword = false
        XCTAssertEqual(vm.password, "", "turning password off clears it")
    }

    func testPasswordRuleIsHostCreateOnly() {
        let vm = GreenRoomViewModel(role: .join(roomCode: "X"))
        vm.displayName = "Aman"
        vm.requirePassword = true // not rendered for joiners; must not block
        XCTAssertFalse(vm.passwordInvalid)
        XCTAssertTrue(vm.canSubmit)
    }

    // MARK: - Join without video

    func testJoinWithoutVideoForcesCamOffThenRoutes() {
        let vm = GreenRoomViewModel(role: .join(roomCode: "X"))
        vm.displayName = "Aman"
        var camEvents: [Bool] = []
        var joined = 0
        vm.onToggleCam = { camEvents.append($0) }
        vm.onJoinWithoutVideo = { joined += 1 }

        vm.joinWithoutVideo()

        XCTAssertFalse(vm.camOn)
        XCTAssertEqual(camEvents, [false])
        XCTAssertEqual(joined, 1)

        // Already off — no duplicate toggle event.
        vm.joinWithoutVideo()
        XCTAssertEqual(camEvents, [false])
        XCTAssertEqual(joined, 2)
    }

    // MARK: - Blur (UI-only until infra exists)

    func testBlurShowsUnavailableNote() {
        let vm = GreenRoomViewModel(role: .hostCreate)
        XCTAssertNil(vm.unavailableNote)
        vm.blurBackgroundTapped()
        XCTAssertEqual(vm.unavailableNote, "Background blur isn't available yet.")
    }

    // MARK: - Network caption

    func testNetworkCaptions() {
        let vm = GreenRoomViewModel(role: .hostCreate)
        vm.networkState = .checking
        XCTAssertEqual(vm.networkCaption, "Checking network…")
        vm.networkState = .reachable(latencyMillis: 40)
        XCTAssertEqual(vm.networkCaption, "Network quality: Excellent")
        vm.networkState = .reachable(latencyMillis: 250)
        XCTAssertEqual(vm.networkCaption, "Network quality: Good")
        vm.networkState = .reachable(latencyMillis: 900)
        XCTAssertEqual(vm.networkCaption, "Network quality: Poor")
        vm.networkState = .unreachable
        XCTAssertEqual(vm.networkCaption, "Server unreachable")
    }

    // MARK: - Pure helpers

    func testEffectiveDeviceOnHostEnforcementWins() {
        // Host forces off → always off, regardless of the user's wish.
        XCTAssertFalse(GreenRoomViewModel.effectiveDeviceOn(hostForcesOff: true, userWantsOn: true))
        XCTAssertFalse(GreenRoomViewModel.effectiveDeviceOn(hostForcesOff: true, userWantsOn: false))
        // No enforcement → the user's choice applies.
        XCTAssertTrue(GreenRoomViewModel.effectiveDeviceOn(hostForcesOff: false, userWantsOn: true))
        XCTAssertFalse(GreenRoomViewModel.effectiveDeviceOn(hostForcesOff: false, userWantsOn: false))
    }

    func testInitials() {
        XCTAssertEqual(GreenRoomViewModel.initials(for: "Aman Mehra"), "AM")
        XCTAssertEqual(GreenRoomViewModel.initials(for: "aman"), "A")
        XCTAssertEqual(GreenRoomViewModel.initials(for: "  "), "?")
        XCTAssertEqual(GreenRoomViewModel.initials(for: "Mary Jane Watson"), "MW")
    }

    func testDeviceNameLookupFallsBack() {
        let devices = [MediaDeviceOption(id: "a", name: "Mic A")]
        XCTAssertEqual(GreenRoomViewModel.deviceName(for: "a", in: devices), "Mic A")
        XCTAssertEqual(GreenRoomViewModel.deviceName(for: "missing", in: devices), "System default")
    }

    func testSpacedCode() {
        XCTAssertEqual(GreenRoomViewModel.spacedCode("a92k1z"), "A 9 2 K 1 Z")
        XCTAssertEqual(GreenRoomViewModel.spacedCode(""), "")
    }
}
