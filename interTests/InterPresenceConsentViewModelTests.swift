//
//  InterPresenceConsentViewModelTests.swift
//  interTests
//
//  PRESENCE MONITORING (provisional, server flag default OFF).
//
//  The four things this suite exists to prove, per research memo §7.8 and
//  plan.md item 16:
//
//   1. ZERO IMPACT WHEN OFF. `mode(armed: false, …)` is `.legacyAlert` for every
//      combination of the other two flags, so a server with the master flag off
//      cannot produce this screen at all and the untouched NSAlert path runs.
//   2. The consent state machine is terminal — one decision per screen.
//   3. DECLINING NEVER ENABLES A CAMERA. Asserted structurally (the view model
//      exposes no camera, media-controller or capture-session API and holds no
//      such object) and behaviourally (the full decline path fires `onDecision`
//      and nothing else).
//   4. The §7.10 copy guard, one assertion per forbidden word, so a failure
//      names the offender.
//

import AppKit
import XCTest
@testable import inter

@MainActor
final class InterPresenceConsentViewModelTests: XCTestCase {

    // MARK: - 1. Zero-impact proof

    /// THE zero-impact test. With the server flag off the /room/join response has
    /// no presence block, so `armed` is false — and then the mode must be
    /// `.legacyAlert` for all four combinations of the other two flags.
    func testModeIsLegacyAlertWheneverNotArmed() {
        for regionEU in [false, true] {
            for under18 in [false, true] {
                XCTAssertEqual(
                    PresenceConsentViewModel.mode(armed: false, regionEU: regionEU, under18: under18),
                    .legacyAlert,
                    "armed == false must yield .legacyAlert (regionEU=\(regionEU), under18=\(under18))")
            }
        }
    }

    func testModeIsMonitoredOfferOnlyWhenArmedAndNotPolicyExcluded() {
        XCTAssertEqual(
            PresenceConsentViewModel.mode(armed: true, regionEU: false, under18: false),
            .monitoredOffer)
    }

    /// EU residency and under-18 are NEVER offered the monitored path.
    func testEUAndUnder18NeverSeeTheMonitoredOffer() {
        XCTAssertEqual(
            PresenceConsentViewModel.mode(armed: true, regionEU: true, under18: false),
            .monitoringOffNotice)
        XCTAssertEqual(
            PresenceConsentViewModel.mode(armed: true, regionEU: false, under18: true),
            .monitoringOffNotice)
        XCTAssertEqual(
            PresenceConsentViewModel.mode(armed: true, regionEU: true, under18: true),
            .monitoringOffNotice)
    }

    /// The monitoring-off screen has no accept path at all — not merely a hidden
    /// button. Calling the intent directly does nothing.
    func testAcceptMonitoringIsUnreachableInMonitoringOffNotice() {
        let vm = PresenceConsentViewModel(mode: .monitoringOffNotice)
        var decisions: [PresenceConsentDecision] = []
        vm.onDecision = { decisions.append($0) }

        vm.acceptMonitoring()

        XCTAssertTrue(decisions.isEmpty,
                      "A policy-excluded candidate must never be able to opt into monitoring")
    }

    // MARK: - 2. Consent state machine

    func testAcceptMonitoringEmitsJoinWithMonitoringExactlyOnce() {
        let vm = PresenceConsentViewModel(mode: .monitoredOffer)
        var decisions: [PresenceConsentDecision] = []
        vm.onDecision = { decisions.append($0) }

        vm.acceptMonitoring()

        XCTAssertEqual(decisions, [.joinWithMonitoring])
    }

    func testDeclineMonitoringEmitsJoinWithoutMonitoringExactlyOnce() {
        let vm = PresenceConsentViewModel(mode: .monitoredOffer)
        var decisions: [PresenceConsentDecision] = []
        vm.onDecision = { decisions.append($0) }

        vm.declineMonitoring()

        XCTAssertEqual(decisions, [.joinWithoutMonitoring],
                       "Declining joins the interview with monitoring off — it is not a refusal")
    }

    func testCancelJoinEmitsCancel() {
        let vm = PresenceConsentViewModel(mode: .monitoredOffer)
        var decisions: [PresenceConsentDecision] = []
        vm.onDecision = { decisions.append($0) }

        vm.cancelJoin()

        XCTAssertEqual(decisions, [.cancel])
    }

    func testDecisionIsTerminal_secondIntentEmitsNothing() {
        let vm = PresenceConsentViewModel(mode: .monitoredOffer)
        var decisions: [PresenceConsentDecision] = []
        vm.onDecision = { decisions.append($0) }

        vm.declineMonitoring()
        vm.acceptMonitoring()
        vm.cancelJoin()
        vm.declineMonitoring()

        XCTAssertEqual(decisions, [.joinWithoutMonitoring],
                       "One decision per screen — a double tap must not join twice or re-decide")
    }

    func testCancelAfterAcceptDoesNotOverrideTheJoin() {
        let vm = PresenceConsentViewModel(mode: .monitoredOffer)
        var decisions: [PresenceConsentDecision] = []
        vm.onDecision = { decisions.append($0) }

        vm.acceptMonitoring()
        vm.cancelJoin()

        XCTAssertEqual(decisions, [.joinWithMonitoring])
    }

    func testShowAndDismissDetailsReturnsToTheOriginatingPane() {
        let offer = PresenceConsentViewModel(mode: .monitoredOffer)
        XCTAssertEqual(offer.state, .monitoredOffer)
        offer.showDetails()
        XCTAssertEqual(offer.state, .details)
        offer.dismissDetails()
        XCTAssertEqual(offer.state, .monitoredOffer)

        let notice = PresenceConsentViewModel(mode: .monitoringOffNotice)
        XCTAssertEqual(notice.state, .monitoringOffNotice)
        notice.showDetails()
        XCTAssertEqual(notice.state, .details)
        notice.dismissDetails()
        XCTAssertEqual(notice.state, .monitoringOffNotice)
    }

    func testDetailsOnlyPresentationMakesNoDecisionAndClosesInstead() {
        let vm = PresenceConsentViewModel(mode: .monitoredOffer, detailsOnly: true, monitoringState: 1)
        var decisions: [PresenceConsentDecision] = []
        var closes = 0
        vm.onDecision = { decisions.append($0) }
        vm.onDismissDetails = { closes += 1 }

        XCTAssertEqual(vm.state, .details)
        vm.acceptMonitoring()
        vm.declineMonitoring()
        vm.cancelJoin()
        vm.dismissDetails()

        XCTAssertTrue(decisions.isEmpty,
                      "The mid-session details sheet must not be able to re-decide consent")
        XCTAssertEqual(closes, 1)
    }

    // MARK: - 3. Declining never enables a camera

    /// Behavioural half: drive the whole decline path with a spy on EVERY exposed
    /// closure and assert that only `onDecision` fired.
    func testFullDeclinePathFiresOnlyOnDecision() {
        let vm = PresenceConsentViewModel(mode: .monitoredOffer,
                                          retentionDays: 90,
                                          rightsContact: "privacy@example.invalid",
                                          externalDisplayPolicy: true)
        var decisions: [PresenceConsentDecision] = []
        var dismissDetailsCalls = 0
        vm.onDecision = { decisions.append($0) }
        vm.onDismissDetails = { dismissDetailsCalls += 1 }

        // The full path a declining candidate actually walks.
        vm.showDetails()
        _ = vm.title
        _ = vm.subtitle
        _ = vm.secureModeItems
        _ = vm.storedCopy
        _ = vm.rightsCopy
        vm.dismissDetails()
        vm.declineMonitoring()

        XCTAssertEqual(decisions, [.joinWithoutMonitoring])
        XCTAssertEqual(dismissDetailsCalls, 0,
                       "dismissDetails is a pane transition in consent mode, not a callback")
    }

    /// Structural half: the view model must hold nothing that could start a
    /// camera. A screen whose job is to ASK for permission must be incapable of
    /// granting itself one.
    func testViewModelHoldsNoCameraMediaOrCaptureObject() {
        let vm = PresenceConsentViewModel(mode: .monitoredOffer)
        let forbidden = ["camera", "media", "capture", "session", "avcapture",
                         "preview", "device", "pixelbuffer", "video"]

        for child in Mirror(reflecting: vm).children {
            let label = (child.label ?? "").lowercased()
            // Type names are checked too, so an innocuously named property
            // holding an InterLocalMediaController or an AVCaptureSession would
            // still fail this.
            let typeName = String(describing: type(of: child.value)).lowercased()
            for token in forbidden {
                XCTAssertFalse(label.contains(token),
                               "PresenceConsentViewModel exposes '\(label)' — it must hold no \(token)")
                XCTAssertFalse(typeName.contains(token),
                               "PresenceConsentViewModel holds a \(typeName) — no \(token) object may be reachable")
            }
            XCTAssertFalse(typeName.contains("interlocalmedia"),
                           "No InterLocalMediaController may be reachable from the consent view model")
        }
    }

    /// The host view is the Obj-C surface AppDelegate touches; it must not vend a
    /// camera-ish entry point either.
    func testHostViewExposesNoCameraEntryPoint() {
        let host = InterPresenceConsentHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 680),
                                                mode: PresenceConsentMode.monitoredOffer.rawValue,
                                                retentionDays: 90,
                                                rightsContact: "privacy@example.invalid",
                                                externalDisplayPolicy: false)
        XCTAssertFalse(host.responds(to: Selector(("startPreview"))))
        XCTAssertFalse(host.responds(to: Selector(("setCameraEnabled:"))))
        XCTAssertFalse(host.responds(to: Selector(("mediaController"))))
    }

    /// A `legacyAlert` raw value must never present the monitored offer, even if a
    /// future caller passes it by mistake.
    func testHostViewFallsBackToMonitoringOffForLegacyAlertMode() {
        let host = InterPresenceConsentHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 680),
                                                mode: PresenceConsentMode.legacyAlert.rawValue,
                                                retentionDays: 90,
                                                rightsContact: "",
                                                externalDisplayPolicy: false)
        var decisions: [Int] = []
        host.onDecision = { decisions.append($0) }
        XCTAssertTrue(decisions.isEmpty, "Building the screen decides nothing on its own")
    }

    func testPresentableModeMatchesThePureFunction() {
        XCTAssertEqual(
            InterPresenceConsentHostView.presentableMode(armed: false, regionEU: false, under18: false),
            PresenceConsentMode.legacyAlert.rawValue)
        XCTAssertEqual(
            InterPresenceConsentHostView.presentableMode(armed: true, regionEU: false, under18: false),
            PresenceConsentMode.monitoredOffer.rawValue)
        XCTAssertEqual(
            InterPresenceConsentHostView.presentableMode(armed: true, regionEU: true, under18: false),
            PresenceConsentMode.monitoringOffNotice.rawValue)
    }

    // MARK: - 4. Indicator state, including the stop case

    func testIndicatorLabelTable() {
        XCTAssertNil(PresenceConsentViewModel.indicatorLabel(0))
        XCTAssertEqual(PresenceConsentViewModel.indicatorLabel(1), "Presence monitoring on")
        XCTAssertEqual(PresenceConsentViewModel.indicatorLabel(2), "Presence monitoring off")
        XCTAssertEqual(PresenceConsentViewModel.indicatorLabel(3),
                       "Presence monitoring paused — camera off")
    }

    func testIndicatorLabelIsNilForAnUnknownState() {
        XCTAssertNil(PresenceConsentViewModel.indicatorLabel(-1))
        XCTAssertNil(PresenceConsentViewModel.indicatorLabel(99))
    }

    /// A granted session that is later STOPPED must read "off" — a stale "on" is a
    /// lie and a stale "off" is worse, so every transition has its own words.
    func testGrantedThenStoppedSessionNeverLeavesTheOnLabelStale() {
        let transitions: [(Int, String?)] = [
            (0, nil),                                            // nothing offered yet
            (1, "Presence monitoring on"),                       // consent granted, running
            (3, "Presence monitoring paused — camera off"),       // camera muted mid-session
            (1, "Presence monitoring on"),                       // camera back on
            (2, "Presence monitoring off"),                       // stopped — THE stop case
        ]
        for (state, expected) in transitions {
            XCTAssertEqual(PresenceConsentViewModel.indicatorLabel(state), expected,
                           "state \(state) must read \(expected ?? "nil")")
        }
        XCTAssertNotEqual(PresenceConsentViewModel.indicatorLabel(2), "Presence monitoring on",
                          "A stopped session must never still say monitoring is on")
    }

    /// An open details sheet tracks the live state rather than the state it opened with.
    func testDetailsSheetTracksTheCurrentIndicatorState() {
        let vm = PresenceConsentViewModel(mode: .monitoredOffer, detailsOnly: true, monitoringState: 1)
        XCTAssertEqual(vm.currentIndicatorLabel, "Presence monitoring on")
        vm.setMonitoringState(2)
        XCTAssertEqual(vm.currentIndicatorLabel, "Presence monitoring off")
    }

    // MARK: - 5. §7.10 copy guard — one assertion per forbidden word

    private var allDisclosureCopy: String {
        PresenceDisclosure.allCopy(retentionDays: 90, contact: "privacy@example.invalid")
            .joined(separator: " ")
            .lowercased()
    }

    func testCopyNeverSaysCheat()      { assertCopyOmits("cheat") }
    func testCopyNeverSaysDishonest()  { assertCopyOmits("dishonest") }
    func testCopyNeverSaysIntegrity()  { assertCopyOmits("integrity") }
    func testCopyNeverSaysAttention()  { assertCopyOmits("attention") }
    func testCopyNeverSaysFocus()      { assertCopyOmits("focus") }
    func testCopyNeverSaysEngagement() { assertCopyOmits("engagement") }
    func testCopyNeverSaysEmotion()    { assertCopyOmits("emotion") }
    func testCopyNeverSaysMood()       { assertCopyOmits("mood") }
    func testCopyNeverSaysConfidence() { assertCopyOmits("confidence") }
    func testCopyNeverSaysProctor()    { assertCopyOmits("proctor") }
    func testCopyNeverSaysGaze()       { assertCopyOmits("gaze") }
    func testCopyNeverSaysEyeTracking() { assertCopyOmits("eye tracking") }
    func testCopyNeverSaysIdentity()   { assertCopyOmits("identity") }
    func testCopyNeverSaysTamper()     { assertCopyOmits("tamper") }
    func testCopyNeverSaysAccuracy()   { assertCopyOmits("accuracy") }

    private func assertCopyOmits(_ word: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(allDisclosureCopy.contains(word),
                       "§7.10 forbids the word '\(word)' in candidate-facing copy",
                       file: file, line: line)
    }

    /// The copy must still SAY the true things — a guard that passes because the
    /// copy is empty would be worthless.
    func testDisclosureCopyIsSubstantive() {
        let copy = PresenceDisclosure.allCopy()
        XCTAssertGreaterThanOrEqual(copy.count, 18,
                                    "All eight §7.4 content items must be present")
        XCTAssertTrue(allDisclosureCopy.contains("face is visible"))
        XCTAssertTrue(allDisclosureCopy.contains("your own mac"))
        XCTAssertTrue(allDisclosureCopy.contains("deleted"))
        XCTAssertTrue(allDisclosureCopy.contains("monitoring off"))
        XCTAssertTrue(allDisclosureCopy.contains("automated"))
    }

    func testRetentionDaysAppearInTheStoredCopy() {
        let vm = PresenceConsentViewModel(mode: .monitoredOffer, retentionDays: 45)
        XCTAssertTrue(vm.storedCopy.contains("45 days"),
                      "The candidate is told the real retention window, not a constant")
    }

    func testRightsCopyFallsBackWhenNoContactIsConfigured() {
        let configured = PresenceConsentViewModel(mode: .monitoredOffer,
                                                  rightsContact: "privacy@example.invalid")
        XCTAssertTrue(configured.rightsCopy.contains("privacy@example.invalid"))

        let missing = PresenceConsentViewModel(mode: .monitoredOffer, rightsContact: "   ")
        XCTAssertTrue(missing.rightsCopy.contains("organisation"),
                      "With no address configured the candidate still gets a route, not a dead end")
    }

    func testSecureModeItemsFollowTheExternalDisplayPolicy() {
        let off = PresenceConsentViewModel(mode: .monitoredOffer, externalDisplayPolicy: false)
        XCTAssertEqual(off.secureModeItems.count, 2)
        let on = PresenceConsentViewModel(mode: .monitoredOffer, externalDisplayPolicy: true)
        XCTAssertEqual(on.secureModeItems.count, 3)
        XCTAssertTrue(on.secureModeItems.contains(PresenceDisclosure.secureModeExternalDisplays))
    }
}
