//
//  SecureCandidateChromeViewModelTests.swift
//  interTests
//
//  Tests for the secure candidate chrome VM — including the security-relevant
//  semantics from the paranoid analysis:
//   #7 tool selection must NEVER trigger share publishing.
//   #6 REC badge state comes only from the pushed value (no inference).
//

import XCTest
@testable import inter

@MainActor
final class SecureCandidateChromeViewModelTests: XCTestCase {

    // MARK: - Finding #7: selection-only semantics

    func testSelectToolFiresSelectionOnlyNeverShare() {
        let vm = SecureCandidateChromeViewModel()
        var selected: [Int] = []
        var shareToggles = 0
        vm.onSelectTool = { selected.append($0) }
        vm.onToggleShare = { shareToggles += 1 }

        vm.selectTool(1)
        vm.selectTool(2)
        vm.selectTool(0)

        XCTAssertEqual(selected, [1, 2, 0])
        XCTAssertEqual(shareToggles, 0,
                       "Selecting a tool must never start/stop publishing (consent contract)")
    }

    func testSelectToolIgnoresReselection() {
        let vm = SecureCandidateChromeViewModel()
        var selected: [Int] = []
        vm.onSelectTool = { selected.append($0) }

        vm.selectTool(1)
        vm.selectTool(1)

        XCTAssertEqual(selected, [1], "Re-selecting the active tool is a no-op")
    }

    func testSelectingToolWhileSharingDoesNotStopShare() {
        let vm = SecureCandidateChromeViewModel()
        vm.sharingActive = true
        var shareToggles = 0
        vm.onToggleShare = { shareToggles += 1 }

        vm.selectTool(2)

        XCTAssertEqual(shareToggles, 0)
        XCTAssertTrue(vm.sharingActive, "VM never mutates share state locally")
    }

    // MARK: - Share button state

    func testShareButtonLabels() {
        let vm = SecureCandidateChromeViewModel()
        XCTAssertEqual(vm.shareButtonLabel, "Share")
        vm.sharePending = true
        XCTAssertEqual(vm.shareButtonLabel, "Starting…")
        vm.sharePending = false
        vm.sharingActive = true
        XCTAssertEqual(vm.shareButtonLabel, "Stop Share")
    }

    func testCanToggleShareRequiresToolUnlessAlreadySharing() {
        let vm = SecureCandidateChromeViewModel()
        XCTAssertFalse(vm.canToggleShare, "No tool selected → Share disabled")
        vm.selectedTool = 1
        XCTAssertTrue(vm.canToggleShare)
        vm.selectedTool = 0
        vm.sharingActive = true
        XCTAssertTrue(vm.canToggleShare, "Stop Share must always be available while sharing")
    }

    // MARK: - Status copy (consent clarity)

    func testShareStatusStatesExactlyWhatIsShared() {
        XCTAssertEqual(SecureCandidateChromeViewModel.shareStatus(toolKind: 0, sharing: false, pending: false),
                       "Nothing is shared. Select Code or Board, then press Share.")
        XCTAssertEqual(SecureCandidateChromeViewModel.shareStatus(toolKind: 1, sharing: false, pending: false),
                       "Code editor selected — not shared yet. Press Share to publish it.")
        XCTAssertEqual(SecureCandidateChromeViewModel.shareStatus(toolKind: 2, sharing: true, pending: false),
                       "Whiteboard is visible to the interviewer.")
        XCTAssertEqual(SecureCandidateChromeViewModel.shareStatus(toolKind: 1, sharing: false, pending: true),
                       "Starting secure tool share…")
    }

    func testToolNames() {
        XCTAssertEqual(SecureCandidateChromeViewModel.toolName(0), "No tool")
        XCTAssertEqual(SecureCandidateChromeViewModel.toolName(1), "Code editor")
        XCTAssertEqual(SecureCandidateChromeViewModel.toolName(2), "Whiteboard")
        XCTAssertEqual(SecureCandidateChromeViewModel.toolName(99), "No tool")
    }

    // MARK: - Finding #6: REC badge is push-driven only

    func testRecordingBadgeDefaultsHiddenAndFollowsPushedState() {
        let vm = SecureCandidateChromeViewModel()
        XCTAssertFalse(vm.recordingActive, "Never claim recording without a signal")
        vm.recordingActive = true
        XCTAssertTrue(vm.recordingActive)
        vm.recordingActive = false
        XCTAssertFalse(vm.recordingActive)
    }

    // MARK: - Media labels (override contract shared with the normal bar)

    func testMicAndCameraLabelOverridesWin() {
        let vm = SecureCandidateChromeViewModel()
        vm.micEnabled = true
        XCTAssertEqual(vm.micLabel, "Mute")
        vm.micTitleOverride = "Request Sent…"
        XCTAssertEqual(vm.micLabel, "Request Sent…")
        vm.cameraEnabled = false
        XCTAssertEqual(vm.cameraLabel, "Start Video")
        vm.cameraTitleOverride = "Ask to Unlock Camera"
        XCTAssertEqual(vm.cameraLabel, "Ask to Unlock Camera")
    }

    func testAudioInputSelectionRoutesAndStores() {
        let vm = SecureCandidateChromeViewModel()
        var routed: [String?] = []
        vm.onSelectAudioInput = { routed.append($0) }
        vm.selectAudioInput("dev-1")
        XCTAssertEqual(vm.selectedAudioInputID, "dev-1")
        XCTAssertEqual(routed.count, 1)
        XCTAssertEqual(routed.first ?? nil, "dev-1")
    }

    // MARK: - Finding #5: the Leave/Chat handlers must route (kiosk escape path)

    func testLeaveAndChatRouteThroughBridgeHandlers() {
        let bridge = InterSecureChromeBridge()
        var leaves = 0
        var chatToggles = 0
        bridge.leaveHandler = { leaves += 1 }
        bridge.chatToggleHandler = { chatToggles += 1 }

        // Drive the VM the way the buttons do (the bridge wires VM → handlers).
        let mirror = Mirror(reflecting: bridge)
        let vm = mirror.children.first { $0.label == "viewModel" }?.value as? SecureCandidateChromeViewModel
        XCTAssertNotNil(vm, "bridge must own the chrome view model")
        vm?.onLeave?()
        vm?.onToggleChat?()

        XCTAssertEqual(leaves, 1, "Leave (the only kiosk escape) must reach the controller")
        XCTAssertEqual(chatToggles, 1)
    }

    func testInvalidateHandlersDropsEveryRoute() {
        let bridge = InterSecureChromeBridge()
        var fired = 0
        bridge.leaveHandler = { fired += 1 }
        bridge.shareToggleHandler = { fired += 1 }
        bridge.invalidateHandlers()

        let mirror = Mirror(reflecting: bridge)
        let vm = mirror.children.first { $0.label == "viewModel" }?.value as? SecureCandidateChromeViewModel
        vm?.onLeave?()
        vm?.onToggleShare?()

        XCTAssertEqual(fired, 0, "After teardown no block may fire (paranoid #8)")
    }
}
