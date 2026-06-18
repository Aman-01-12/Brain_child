//
//  PreMeetingViewModelTests.swift
//  interTests
//
//  Tests the pre-meeting sheet view model: mode-driven presentation (titles,
//  per-meeting field visibility, compact summary), the empty-password submit
//  block, pro gating, display-name prefill, the compact→advanced reveal, and
//  the pure title/password helpers.
//

import XCTest
@testable import inter

@MainActor
final class PreMeetingViewModelTests: XCTestCase {

    // MARK: - Mode presentation

    func testModeTitlesAndButtons() {
        let full = PreMeetingViewModel(mode: .fullSetup)
        XCTAssertEqual(full.titleText, "Meeting Settings")
        // The green room follows the sheet in the host flow ("Save & Next");
        // the meeting itself starts from the green room.
        XCTAssertEqual(full.submitTitle, "Save & Next")
        XCTAssertEqual(full.cancelTitle, "Cancel")

        let compact = PreMeetingViewModel(mode: .compact)
        XCTAssertEqual(compact.titleText, "Starting your meeting…")
        XCTAssertEqual(compact.submitTitle, "Start Meeting")

        let editor = PreMeetingViewModel(mode: .defaultsEditor)
        XCTAssertEqual(editor.titleText, "Default Meeting Settings")
        XCTAssertEqual(editor.submitTitle, "Save")
        XCTAssertEqual(editor.cancelTitle, "Close")
    }

    func testPerMeetingFieldsHiddenOnlyInDefaultsEditor() {
        XCTAssertTrue(PreMeetingViewModel(mode: .fullSetup).showsPerMeetingFields)
        XCTAssertTrue(PreMeetingViewModel(mode: .compact).showsPerMeetingFields)
        XCTAssertFalse(PreMeetingViewModel(mode: .defaultsEditor).showsPerMeetingFields)
    }

    func testCompactSummaryShowsUntilExpanded() {
        let vm = PreMeetingViewModel(mode: .compact)
        XCTAssertTrue(vm.showsCompactSummary)

        var expandRequests = 0
        vm.onRequestExpand = { expandRequests += 1 }

        vm.expandAdvanced()
        XCTAssertFalse(vm.showsCompactSummary, "full controls reveal")
        XCTAssertTrue(vm.advancedExpanded)
        XCTAssertEqual(expandRequests, 1)

        vm.expandAdvanced()
        XCTAssertEqual(expandRequests, 1, "second expand is a no-op")
    }

    func testExpandAdvancedIsCompactOnly() {
        let vm = PreMeetingViewModel(mode: .fullSetup)
        var called = false
        vm.onRequestExpand = { called = true }
        vm.expandAdvanced()
        XCTAssertFalse(called)
    }

    // MARK: - Display name + tier

    func testSetDisplayNamePrefillsMeetingName() {
        let vm = PreMeetingViewModel(mode: .fullSetup)
        vm.setDisplayName("Aman")
        XCTAssertEqual(vm.meetingName, "Aman's Meeting")
        vm.setDisplayName("")
        XCTAssertEqual(vm.meetingName, "Aman's Meeting", "empty name ignored")
    }

    func testProTiersUnlockAndFreeTierClearsToggles() {
        let vm = PreMeetingViewModel(mode: .fullSetup)
        for tier in ["pro", "hiring"] {
            vm.setUserTier(tier)
            XCTAssertTrue(vm.isPro, tier)
        }
        vm.autoRecord = true
        vm.autoTranscript = true
        vm.allowCoHostLocalRecording = true

        vm.setUserTier("free")

        XCTAssertFalse(vm.isPro)
        XCTAssertFalse(vm.autoRecord, "pro toggles reset for free tier")
        XCTAssertFalse(vm.autoTranscript)
        XCTAssertFalse(vm.allowCoHostLocalRecording)
    }

    // MARK: - Password rule (legacy block)

    func testSubmitBlockedWhenPasswordRequiredButEmpty() {
        let vm = PreMeetingViewModel(mode: .fullSetup)
        var started = 0
        vm.onStart = { started += 1 }

        vm.requirePassword = true
        vm.password = "   "
        XCTAssertTrue(vm.passwordInvalid)

        vm.submit()
        XCTAssertEqual(started, 0, "blocked")
        XCTAssertEqual(vm.passwordErrorTick, 1)

        vm.password = "hunter2"
        XCTAssertFalse(vm.passwordInvalid)
        vm.submit()
        XCTAssertEqual(started, 1)
    }

    func testPasswordRuleIgnoredInDefaultsEditor() {
        let vm = PreMeetingViewModel(mode: .defaultsEditor)
        var saved = 0
        vm.onSaveDefaults = { saved += 1 }
        vm.requirePassword = true // not rendered in this mode; must not block

        vm.submit()

        XCTAssertEqual(saved, 1)
        XCTAssertEqual(vm.passwordErrorTick, 0)
    }

    func testTurningPasswordOffClearsIt() {
        let vm = PreMeetingViewModel(mode: .fullSetup)
        vm.requirePassword = true
        vm.password = "secret"
        vm.requirePassword = false
        XCTAssertEqual(vm.password, "")
        XCTAssertFalse(vm.passwordInvalid)
    }

    // MARK: - Submit routing

    func testSubmitRoutesByMode() {
        let full = PreMeetingViewModel(mode: .fullSetup)
        var started = 0, savedDefaults = 0
        full.onStart = { started += 1 }
        full.onSaveDefaults = { savedDefaults += 1 }
        full.submit()
        XCTAssertEqual(started, 1)
        XCTAssertEqual(savedDefaults, 0)

        let editor = PreMeetingViewModel(mode: .defaultsEditor)
        editor.onStart = { started += 1 }
        editor.onSaveDefaults = { savedDefaults += 1 }
        editor.submit()
        XCTAssertEqual(started, 1, "editor never starts a meeting")
        XCTAssertEqual(savedDefaults, 1)
    }

    func testCancelRoutes() {
        let vm = PreMeetingViewModel(mode: .compact)
        var cancels = 0
        vm.onCancel = { cancels += 1 }
        vm.cancel()
        XCTAssertEqual(cancels, 1)
    }

    // MARK: - Defaults seeding + summary

    func testLoadDefaultsPopulatesFieldsAndSummary() {
        let vm = PreMeetingViewModel(mode: .compact)
        vm.loadDefaults(muteOnJoin: true, cameraOffOnJoin: false, allowUnmuting: false,
                        lobbyEnabled: true, joinBeforeHost: true,
                        chatPermissions: InterChatPermissionsHostOnly,
                        sharingPermissions: InterSharingPermissionsRequest,
                        shareConflictPolicy: InterSharingConflictAnyCanPreempt,
                        autoRecord: true, autoTranscript: false,
                        allowCoHostLocalRecording: false)

        XCTAssertTrue(vm.muteOnJoin)
        XCTAssertFalse(vm.allowUnmuting)
        XCTAssertEqual(vm.chatPermissions, InterChatPermissionsHostOnly)

        let rows = vm.summaryRows
        XCTAssertEqual(rows.first(where: { $0.label == "Waiting room" })?.value, "Enabled")
        XCTAssertEqual(rows.first(where: { $0.label == "Waiting room" })?.positive, true)
        XCTAssertEqual(rows.first(where: { $0.label == "Mic on join" })?.value, "Muted")
        XCTAssertEqual(rows.first(where: { $0.label == "Chat" })?.value, "Host Only")
        XCTAssertEqual(rows.first(where: { $0.label == "Screen sharing" })?.value, "Request to Share")
    }

    // MARK: - Pure helpers

    func testTitleMappingsMatchLegacyPopups() {
        XCTAssertEqual(PreMeetingViewModel.chatTitle(InterChatPermissionsEveryone), "Everyone")
        XCTAssertEqual(PreMeetingViewModel.chatTitle(InterChatPermissionsDisabled), "Disabled")
        XCTAssertEqual(PreMeetingViewModel.chatTitle("garbage"), "Everyone", "fallback")
        XCTAssertEqual(PreMeetingViewModel.sharingTitle(InterSharingPermissionsRequest), "Request to Share")
        XCTAssertEqual(PreMeetingViewModel.sharingTitle("garbage"), "Host Only", "fallback")
        XCTAssertEqual(PreMeetingViewModel.conflictTitle(InterSharingConflictHostCanPreempt), "Host Can Take Over")
        XCTAssertEqual(PreMeetingViewModel.conflictTitle("garbage"), "One at a Time", "fallback")
    }

    func testEffectivePasswordCollectRule() {
        XCTAssertEqual(PreMeetingViewModel.effectivePassword(requirePassword: false, password: "x"), "",
                       "toggle off → no password even if typed")
        XCTAssertEqual(PreMeetingViewModel.effectivePassword(requirePassword: true, password: "  "), "",
                       "blank → empty")
        XCTAssertEqual(PreMeetingViewModel.effectivePassword(requirePassword: true, password: "pw 1"), "pw 1",
                       "kept verbatim when non-blank")
    }
}
