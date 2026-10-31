// ============================================================================
// interTests/InterPresenceSessionIsolationTests.swift
//
// PRESENCE MONITORING (provisional, server flag default OFF) — regression
// tests for the per-connection isolation of the presence block.
//
// `InterRoomController` is created once at launch and outlives every session
// (AppDelegate creates it in -applicationDidFinishLaunching, releases it in
// -applicationWillTerminate), but consent and arming are per-ROOM facts. Before
// the fix these tests cover, a candidate who granted monitoring in interview 1
// still read `activePresenceMonitoringGranted == true` in interview 2 — so the
// detector's single start site (SecureWindowController.m, -startLocalMediaFlow)
// started Vision analysis for a session nobody had been asked about — and the
// scheduled-meeting connect path assigned no presence field at all, so a stale
// `activePresenceMonitoringArmed` drove the consent screen and the interviewer
// surface in a room the server never armed.
//
// What each test pins down:
//
//   1. testGrantedConsent_doesNotSurviveIntoTheNextConnect_lobbyAdmittedPath
//      — the consent pair is already cleared by the time the pre-connect consent
//        gate runs on the next connection. The gate is the exact observer whose
//        ordering matters, which is why the assertion is made from inside it.
//   2. testGrantedConsent_doesNotSurviveIntoTheNextConnect_tokenFetchPath
//      — same property for the entry point that fetches a token first, asserted
//        synchronously so it cannot be satisfied by a later main-queue hop.
//   3. testRejectedDoubleConnect_doesNotClearALiveSessionsConsent
//      — the reset sits AFTER the connect guards, so a connect that is refused
//        cannot void the consent of the session already running.
//   4. testScheduledMeetingResponse_disarmsARoomArmedEarlierInTheSameAppSession
//      — the scheduled branch assigns the block, and a response carrying no
//        presence key resolves to armed == false plus the shipped defaults.
//   5. testScheduledMeetingResponse_carriesAnArmedServerAnswer
//      — that assignment is the server's answer, not a hardcoded false.
//
// SEAM NOTE, stated rather than skipped. Tests 4 and 5 call
// `applyPresenceSettingsFromScheduledMeeting(_:)` — the function the scheduled
// branch of `connect(configuration:completion:)` calls — directly, instead of
// driving a whole `connect`. `InterRoomController.tokenService` is a `let` with
// no injection point, so the scheduled branch only runs when a real
// `/meetings/:id/start` answers; with no server reachable the response is nil
// and the branch's assignment block never executes. The function under test is
// the shipping one and nothing else calls it, so this is the closest reachable
// seam to the branch itself.
// ============================================================================

import XCTest
@testable import inter

final class InterPresenceSessionIsolationTests: XCTestCase {

    private var controller: InterRoomController!

    override func setUp() {
        super.setUp()
        controller = InterRoomController()
    }

    override func tearDown() {
        controller.disconnect()
        controller = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// An interview config pointed at a closed port, so nothing connects.
    private func intervieweeConfig() -> InterRoomConfiguration {
        return InterRoomConfiguration(
            serverURL: "ws://127.0.0.1:1",
            tokenServerURL: "http://127.0.0.1:1",
            roomCode: "ABC123",
            participantIdentity: "cand-1",
            participantName: "Candidate",
            isHost: false,
            roomType: "interview"
        )
    }

    /// The presence keys a `/room/join` on an armed room produces, in the shape the
    /// lobby-admitted path receives them.
    private func armedSettingsDict() -> [AnyHashable: Any] {
        return [
            "presenceMonitoringArmed": true,
            "presenceRetentionDays": 30,
            "presenceRegionEU": false,
            "presenceUnder18": false,
            "presenceMultipleFacesEnabled": true,
            "presenceDetectorVersion": "presence-1.0.0",
            "presenceThresholds": "{\"absenceSeconds\":10}",
            "presenceRightsContact": "privacy@example.invalid"
        ]
    }

    /// A `/meetings/:id/start` response built exactly as `startScheduledMeeting`
    /// builds it: no presence argument, because that endpoint returns no presence key.
    private func scheduledResponse() -> InterCreateRoomResponse {
        return InterCreateRoomResponse(
            roomCode: "SCHED1",
            roomName: "inter-SCHED1",
            token: "faketoken",
            serverURL: "ws://127.0.0.1:1",
            roomType: "interview",
            isHost: false,
            roomSettings: ["meetingDisplayName": "Scheduled interview"]
        )
    }

    // MARK: - 1. Consent does not survive into the next connect (lobby-admitted)

    /// Interview 1 granted monitoring. Interview 2 is a different room, so the
    /// consent gate — the first thing that reads the presence state on the new
    /// connection — must see a cleared pair. If the reset were missing, or landed
    /// after the gate, `observedGranted` would be true here and the detector's
    /// start site downstream would run with a consent the candidate never gave.
    func testGrantedConsent_doesNotSurviveIntoTheNextConnect_lobbyAdmittedPath() {
        controller.recordPresenceConsent(granted: true, state: "granted")
        XCTAssertTrue(controller.activePresenceMonitoringGranted)
        XCTAssertEqual(controller.activePresenceConsentState, "granted")

        var observedGranted: Bool?
        var observedState: String?
        // Weak so the stored gate block does not retain the controller it lives on.
        weak var observed = controller
        controller.preConnectConsentGate = { _, _, decide in
            observedGranted = observed?.activePresenceMonitoringGranted
            observedState = observed?.activePresenceConsentState
            decide(false)
        }

        let exp = expectation(description: "declined completion")
        var completionError: NSError?
        controller.connect(withToken: "faketoken",
                           serverURL: "ws://127.0.0.1:1",
                           configuration: intervieweeConfig()) { error in
            completionError = error as NSError?
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)

        XCTAssertEqual(observedGranted, false,
                       "A previous room's consent must not be visible to the next room's gate")
        XCTAssertEqual(observedState, "pending")
        XCTAssertFalse(controller.activePresenceMonitoringGranted)
        XCTAssertEqual(controller.activePresenceConsentState, "pending")
        // The declined gate still produces the clean, unchanged rejection.
        XCTAssertEqual(completionError?.code, InterNetworkErrorCode.consentDeclined.rawValue)
        XCTAssertEqual(controller.connectionState, .disconnected)
    }

    // MARK: - 2. Consent does not survive into the next connect (token-fetch entry point)

    /// The reset is synchronous on the caller's queue, so it has already happened
    /// when `connect` returns — it cannot be a main-queue hop that races the
    /// server's answer or the gate.
    func testGrantedConsent_doesNotSurviveIntoTheNextConnect_tokenFetchPath() {
        controller.recordPresenceConsent(granted: true, state: "granted")
        XCTAssertTrue(controller.activePresenceMonitoringGranted)

        let exp = expectation(description: "failed connect completion")
        controller.connect(configuration: intervieweeConfig()) { _ in
            exp.fulfill()
        }

        // Asserted before the run loop turns again: no callback can have run yet.
        XCTAssertFalse(controller.activePresenceMonitoringGranted,
                       "Consent must be cleared synchronously by connect, before any token response")
        XCTAssertEqual(controller.activePresenceConsentState, "pending")

        waitForExpectations(timeout: 15)
        XCTAssertFalse(controller.activePresenceMonitoringGranted)
        XCTAssertEqual(controller.activePresenceConsentState, "pending")
    }

    // MARK: - 3. A refused connect must not void the live session's consent

    /// The reset is placed after the state and double-connect guards. A stray
    /// second `connect` during a live session is rejected without touching the
    /// consent the running session is monitoring under — otherwise the indicator
    /// and the detector would disagree mid-interview.
    func testRejectedDoubleConnect_doesNotClearALiveSessionsConsent() {
        let first = expectation(description: "first connect settles")
        controller.connect(configuration: intervieweeConfig()) { _ in
            first.fulfill()
        }

        // Same run-loop turn: the controller is now connecting, and the candidate's
        // consent for THIS session is recorded.
        controller.recordPresenceConsent(granted: true, state: "granted")

        let second = expectation(description: "second connect rejected")
        controller.connect(configuration: intervieweeConfig()) { error in
            XCTAssertNotNil(error, "Double-connect must be rejected")
            second.fulfill()
        }

        XCTAssertTrue(controller.activePresenceMonitoringGranted,
                      "A rejected connect must not clear the live session's consent")
        XCTAssertEqual(controller.activePresenceConsentState, "granted")

        waitForExpectations(timeout: 15)
    }

    // MARK: - 4. Scheduled path: a response with no presence key means NOT armed

    /// `/meetings/:id/start` never arms a room. Before the fix the scheduled branch
    /// assigned no presence field, so arming from an earlier room in the same app
    /// session survived into the scheduled interview and drove the consent screen
    /// and the interviewer surface for a room the server never armed.
    func testScheduledMeetingResponse_disarmsARoomArmedEarlierInTheSameAppSession() {
        // An armed room earlier in this app session.
        controller.applyMeetingSettingsFromDict(armedSettingsDict())
        XCTAssertTrue(controller.activePresenceMonitoringArmed)
        XCTAssertEqual(controller.activePresenceRetentionDays, 30)
        XCTAssertTrue(controller.activePresenceMultipleFacesEnabled)
        XCTAssertEqual(controller.activePresenceDetectorVersion, "presence-1.0.0")

        // Next room is a scheduled meeting, whose response carries no presence key.
        controller.applyPresenceSettingsFromScheduledMeeting(scheduledResponse())

        XCTAssertFalse(controller.activePresenceMonitoringArmed,
                       "A scheduled room the server never armed must not inherit arming")
        XCTAssertEqual(controller.activePresenceRetentionDays, 90)
        XCTAssertFalse(controller.activePresenceRegionEU)
        XCTAssertFalse(controller.activePresenceUnder18)
        XCTAssertFalse(controller.activePresenceMultipleFacesEnabled)
        XCTAssertEqual(controller.activePresenceDetectorVersion, "")
        XCTAssertEqual(controller.activePresenceThresholds, "")
        XCTAssertEqual(controller.activePresenceRightsContact, "")
    }

    // MARK: - 5. Scheduled path: the value is the server's answer, not a constant

    /// The scheduled branch assigns `response.presenceMonitoringArmed` rather than
    /// hardcoding false, so if that endpoint ever starts arming rooms the client
    /// follows the server instead of silently ignoring it.
    func testScheduledMeetingResponse_carriesAnArmedServerAnswer() {
        let armed = InterCreateRoomResponse(
            roomCode: "SCHED2",
            roomName: "inter-SCHED2",
            token: "faketoken",
            serverURL: "ws://127.0.0.1:1",
            roomType: "interview",
            isHost: false,
            roomSettings: nil,
            presenceMonitoringArmed: true
        )

        controller.applyPresenceSettingsFromScheduledMeeting(armed)
        XCTAssertTrue(controller.activePresenceMonitoringArmed)
    }
}
