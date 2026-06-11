// interTests/InterModerationTileStateTests.swift
// Unit tests for InterModerationTileState.deriveMic — the cause-derived host
// per-tile mic state. This matrix is the verification lever that substitutes for
// a live 2-client call (spec §7).

import XCTest
@testable import inter

final class InterModerationTileStateTests: XCTestCase {

    // Convenience wrapper.
    private func derive(reallyMuted: Bool,
                        hostBlocked: Bool,
                        globalMute: Bool,
                        pendingSelfAction: Bool = false,
                        askPending: Bool = false,
                        interview: Bool = false) -> InterMicTileState {
        InterModerationTileState.deriveMic(reallyMuted: reallyMuted,
                                           hostBlocked: hostBlocked,
                                           globalMute: globalMute,
                                           pendingSelfAction: pendingSelfAction,
                                           askPending: askPending,
                                           isInterviewMode: interview)
    }

    // MARK: - Live state

    func test_micOn_offersMuteOnly() {
        let s = derive(reallyMuted: false, hostBlocked: false, globalMute: false)
        XCTAssertEqual(s.cause, .micOn)
        XCTAssertEqual(s.captionText, "Mic on")
        XCTAssertEqual(s.primaryAction, .mute)
        XCTAssertEqual(s.secondaryAction, .none)
    }

    // MARK: - Self-mute vs block-lift (Finding A)

    func test_genuineSelfMute_isSelfMuted_withBlockSecondary() {
        let s = derive(reallyMuted: true, hostBlocked: false, globalMute: false,
                       pendingSelfAction: false)
        XCTAssertEqual(s.cause, .selfMuted)
        XCTAssertEqual(s.captionText, "Self-muted")
        XCTAssertEqual(s.primaryAction, .askToUnmute)
        XCTAssertEqual(s.secondaryAction, .blockMic)
    }

    func test_blockLiftedAwaitingTap_isOffCanUnmute_notSelfMuted() {
        // Finding A: after a block lift while still off, must NOT read "Self-muted".
        let s = derive(reallyMuted: true, hostBlocked: false, globalMute: false,
                       pendingSelfAction: true, askPending: false)
        XCTAssertEqual(s.cause, .offCanUnmute)
        XCTAssertEqual(s.captionText, "Off — can unmute")
        XCTAssertNotEqual(s.cause, .selfMuted)
        XCTAssertEqual(s.primaryAction, .askToUnmute)
    }

    func test_askPending_refinesCaptionToAskedToUnmute() {
        let s = derive(reallyMuted: true, hostBlocked: false, globalMute: false,
                       pendingSelfAction: true, askPending: true)
        XCTAssertEqual(s.cause, .askedToUnmute)
        XCTAssertEqual(s.captionText, "Asked to unmute")
        XCTAssertEqual(s.primaryAction, .askToUnmute)
    }

    // MARK: - Host block

    func test_hostMuted_offersRemoveMute() {
        let s = derive(reallyMuted: true, hostBlocked: true, globalMute: false)
        XCTAssertEqual(s.cause, .mutedByHost)
        XCTAssertEqual(s.captionText, "Muted by you")
        XCTAssertEqual(s.primaryAction, .removeMute)
        XCTAssertEqual(s.primaryActionTitle, "Remove Mute")
        XCTAssertEqual(s.secondaryAction, .none)
    }

    func test_hostMuted_normalMode_doesNotForce() {
        let s = derive(reallyMuted: true, hostBlocked: true, globalMute: false, interview: false)
        XCTAssertFalse(s.activationForcesDevice)
    }

    // MARK: - Mute-All (the mismatch fix)

    func test_muteAll_offersAllowToSpeak_neverMute() {
        let s = derive(reallyMuted: true, hostBlocked: false, globalMute: true)
        XCTAssertEqual(s.cause, .mutedByMuteAll)
        XCTAssertEqual(s.captionText, "Muted (mute-all)")
        XCTAssertEqual(s.primaryAction, .allowToSpeak)
        XCTAssertNotEqual(s.primaryAction, .mute, "Mute must never appear beside a muted caption")
        XCTAssertEqual(s.secondaryAction, .blockMic)
    }

    // MARK: - Precedence lock

    func test_precedence_hostBlockWinsOverMuteAll() {
        let s = derive(reallyMuted: true, hostBlocked: true, globalMute: true)
        XCTAssertEqual(s.cause, .mutedByHost, "host block must win over mute-all")
        XCTAssertEqual(s.captionText, "Muted by you")
        XCTAssertEqual(s.primaryAction, .removeMute)
    }

    // MARK: - Enforce-block secondary availability

    func test_blockMicSecondary_presentWhereExpected() {
        // Present for self-muted and mute-all.
        XCTAssertEqual(derive(reallyMuted: true, hostBlocked: false, globalMute: false).secondaryAction, .blockMic)
        XCTAssertEqual(derive(reallyMuted: true, hostBlocked: false, globalMute: true).secondaryAction, .blockMic)
        // Absent for mic-on and host-muted.
        XCTAssertEqual(derive(reallyMuted: false, hostBlocked: false, globalMute: false).secondaryAction, .none)
        XCTAssertEqual(derive(reallyMuted: true, hostBlocked: true, globalMute: false).secondaryAction, .none)
    }

    // MARK: - Interview mode

    func test_interviewMode_forcesActivationActions() {
        // Self-muted interviewee: activation action force-executes (+ indicator).
        let self_ = derive(reallyMuted: true, hostBlocked: false, globalMute: false, interview: true)
        XCTAssertEqual(self_.primaryAction, .askToUnmute)
        XCTAssertTrue(self_.activationForcesDevice)

        // Host-muted: removeMute is an activation → forces in interview.
        let hostMuted = derive(reallyMuted: true, hostBlocked: true, globalMute: false, interview: true)
        XCTAssertTrue(hostMuted.activationForcesDevice)

        // Mic-on: primary is Mute (a restriction) → never a forced activation.
        let live = derive(reallyMuted: false, hostBlocked: false, globalMute: false, interview: true)
        XCTAssertEqual(live.primaryAction, .mute)
        XCTAssertFalse(live.activationForcesDevice)
    }

    func test_interviewMode_primaryReadsDirectUnmute() {
        // Every activation action in interview mode shows a direct "Unmute" label,
        // because it force-turns the mic on (user decision 2026-06-11).
        let selfMuted = derive(reallyMuted: true, hostBlocked: false, globalMute: false, interview: true)
        XCTAssertEqual(selfMuted.primaryActionTitle, "Unmute")

        let hostMuted = derive(reallyMuted: true, hostBlocked: true, globalMute: false, interview: true)
        XCTAssertEqual(hostMuted.primaryActionTitle, "Unmute")

        let muteAll = derive(reallyMuted: true, hostBlocked: false, globalMute: true, interview: true)
        XCTAssertEqual(muteAll.primaryActionTitle, "Unmute")

        // The restriction action keeps its own label even in interview mode.
        let live = derive(reallyMuted: false, hostBlocked: false, globalMute: false, interview: true)
        XCTAssertEqual(live.primaryActionTitle, "Mute Mic")

        // Normal mode keeps the consent-flow wording (NOT "Unmute").
        let selfMutedNormal = derive(reallyMuted: true, hostBlocked: false, globalMute: false, interview: false)
        XCTAssertEqual(selfMutedNormal.primaryActionTitle, "Ask to Unmute")
    }

    func test_interviewMode_keepsBlockSecondary() {
        // Block stays available in interview mode (superset of host control).
        let selfMuted = derive(reallyMuted: true, hostBlocked: false, globalMute: false, interview: true)
        XCTAssertEqual(selfMuted.secondaryAction, .blockMic)
        XCTAssertEqual(selfMuted.secondaryActionTitle, "Block mic")

        let muteAll = derive(reallyMuted: true, hostBlocked: false, globalMute: true, interview: true)
        XCTAssertEqual(muteAll.secondaryAction, .blockMic)
    }

    func test_interviewMode_doesNotChangeCauseOrAction() {
        // The caption + which action is offered are mode-INDEPENDENT; only execution differs.
        for reallyMuted in [true, false] {
            for hostBlocked in [true, false] {
                for globalMute in [true, false] {
                    for pending in [true, false] {
                        let normal = derive(reallyMuted: reallyMuted, hostBlocked: hostBlocked,
                                            globalMute: globalMute, pendingSelfAction: pending, interview: false)
                        let interview = derive(reallyMuted: reallyMuted, hostBlocked: hostBlocked,
                                               globalMute: globalMute, pendingSelfAction: pending, interview: true)
                        XCTAssertEqual(normal.cause, interview.cause)
                        XCTAssertEqual(normal.primaryAction, interview.primaryAction)
                        XCTAssertEqual(normal.secondaryAction, interview.secondaryAction)
                        XCTAssertEqual(normal.captionText, interview.captionText)
                    }
                }
            }
        }
    }

    // MARK: - Full enumeration: the no-contradiction invariant

    func test_invariant_muteOnlyWhenLive_acrossAllInputs() {
        for reallyMuted in [true, false] {
            for hostBlocked in [true, false] {
                for globalMute in [true, false] {
                    for pending in [true, false] {
                        for askPending in [true, false] {
                            for interview in [true, false] {
                                let s = derive(reallyMuted: reallyMuted, hostBlocked: hostBlocked,
                                               globalMute: globalMute, pendingSelfAction: pending,
                                               askPending: askPending, interview: interview)
                                // The core guarantee: "Mute" is offered IFF the mic is live,
                                // so the action can never contradict a muted caption.
                                if s.primaryAction == .mute {
                                    XCTAssertEqual(s.cause, .micOn)
                                    XCTAssertFalse(s.cause.isMuted)
                                }
                                // And conversely, a live mic always offers Mute.
                                if s.cause == .micOn {
                                    XCTAssertEqual(s.primaryAction, .mute)
                                }
                                // Force only ever applies to activation actions, only in interview.
                                if s.activationForcesDevice {
                                    XCTAssertTrue(interview)
                                    XCTAssertTrue(s.primaryAction.isActivation)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Camera (PR #2 — mirror of the mic matrix)

    private func deriveCam(cameraReallyOff: Bool,
                           hostLocked: Bool,
                           globalLock: Bool,
                           pendingSelfAction: Bool = false,
                           askPending: Bool = false,
                           interview: Bool = false) -> InterCamTileState {
        InterModerationTileState.deriveCamera(cameraReallyOff: cameraReallyOff,
                                              hostLocked: hostLocked,
                                              globalLock: globalLock,
                                              pendingSelfAction: pendingSelfAction,
                                              askPending: askPending,
                                              isInterviewMode: interview)
    }

    func test_cam_on_offersStopVideoOnly() {
        let s = deriveCam(cameraReallyOff: false, hostLocked: false, globalLock: false)
        XCTAssertEqual(s.cause, .camOn)
        XCTAssertEqual(s.captionText, "Camera on")
        XCTAssertEqual(s.primaryAction, .stopVideo)
        XCTAssertEqual(s.secondaryAction, .none)
    }

    func test_cam_selfOff_offersAskToTurnOn_withLockSecondary() {
        let s = deriveCam(cameraReallyOff: true, hostLocked: false, globalLock: false)
        XCTAssertEqual(s.cause, .selfOff)
        XCTAssertEqual(s.captionText, "Camera off")
        XCTAssertEqual(s.primaryAction, .askToTurnOn)
        XCTAssertEqual(s.secondaryAction, .lockCamera)
    }

    func test_cam_lockLifted_isOffCanTurnOn_notSelfOff() {
        let s = deriveCam(cameraReallyOff: true, hostLocked: false, globalLock: false,
                          pendingSelfAction: true)
        XCTAssertEqual(s.cause, .offCanTurnOn)
        XCTAssertEqual(s.captionText, "Off — can turn on")
        XCTAssertEqual(s.primaryAction, .askToTurnOn)
    }

    func test_cam_lockedByHost_offersRemoveLock_noAsk() {
        let s = deriveCam(cameraReallyOff: true, hostLocked: true, globalLock: false)
        XCTAssertEqual(s.cause, .lockedByHost)
        XCTAssertEqual(s.captionText, "Locked by you")
        XCTAssertEqual(s.primaryAction, .removeLock)
        XCTAssertEqual(s.primaryActionTitle, "Remove Lock")
        XCTAssertEqual(s.secondaryAction, .none)
    }

    func test_cam_lockAll_offersAllowCamera_neverStopVideo() {
        let s = deriveCam(cameraReallyOff: true, hostLocked: false, globalLock: true)
        XCTAssertEqual(s.cause, .lockedByLockAll)
        XCTAssertEqual(s.captionText, "Locked (lock-all)")
        XCTAssertEqual(s.primaryAction, .allowCamera)
        XCTAssertNotEqual(s.primaryAction, .stopVideo)
        XCTAssertEqual(s.secondaryAction, .lockCamera)
    }

    func test_cam_precedence_hostLockWinsOverLockAll() {
        let s = deriveCam(cameraReallyOff: true, hostLocked: true, globalLock: true)
        XCTAssertEqual(s.cause, .lockedByHost)
        XCTAssertEqual(s.primaryAction, .removeLock)
    }

    func test_cam_interviewMode_directTurnOnLabel_keepsLockSecondary() {
        // Self-off interviewee in interview mode: activation force-restores → direct label.
        let selfOff = deriveCam(cameraReallyOff: true, hostLocked: false, globalLock: false, interview: true)
        XCTAssertTrue(selfOff.activationForcesDevice)
        XCTAssertEqual(selfOff.primaryActionTitle, "Turn On Camera")
        XCTAssertEqual(selfOff.secondaryAction, .lockCamera)
        // Camera-on interviewee: Stop Video is a restriction, never a forced activation.
        let live = deriveCam(cameraReallyOff: false, hostLocked: false, globalLock: false, interview: true)
        XCTAssertEqual(live.primaryAction, .stopVideo)
        XCTAssertFalse(live.activationForcesDevice)
    }

    func test_cam_invariant_stopVideoOnlyWhenLive_acrossAllInputs() {
        for reallyOff in [true, false] {
            for hostLocked in [true, false] {
                for globalLock in [true, false] {
                    for pending in [true, false] {
                        for askPending in [true, false] {
                            for interview in [true, false] {
                                let s = deriveCam(cameraReallyOff: reallyOff, hostLocked: hostLocked,
                                                  globalLock: globalLock, pendingSelfAction: pending,
                                                  askPending: askPending, interview: interview)
                                if s.primaryAction == .stopVideo {
                                    XCTAssertEqual(s.cause, .camOn)
                                    XCTAssertFalse(s.cause.isOff)
                                }
                                if s.cause == .camOn {
                                    XCTAssertEqual(s.primaryAction, .stopVideo)
                                }
                                if s.activationForcesDevice {
                                    XCTAssertTrue(interview)
                                    XCTAssertTrue(s.primaryAction.isActivation)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
