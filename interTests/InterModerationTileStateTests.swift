// interTests/InterModerationTileStateTests.swift
// Unit tests for InterModerationTileState.deriveMic / deriveCamera — the
// cause-derived host per-tile state matrix. This matrix is the verification lever
// that substitutes for a live 2-client call (spec §7).
//
// PRODUCT CHANGE (host-side "Ask to Unmute" / "Ask to Turn On Camera" removed):
// For a participant who is self-muted / camera-off (and NOT host-blocked, NOT under
// a global mute/lock-all), the host's primary action is now an enforce-BLOCK
// (`.mute` rendered as "Block mic" / `.stopVideo` rendered as "Lock camera")
// instead of the consent "ask" nudge. The host keeps direct Mute/Block and the
// host-block lift (Remove Mute / Remove Lock) and mute-all "Allow to Speak".

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
        XCTAssertEqual(s.primaryActionTitle, "Mute Mic")
        XCTAssertEqual(s.secondaryAction, .none)
    }

    // MARK: - Self-mute → enforce-block (ask flow removed)

    func test_genuineSelfMute_isSelfMuted_offersBlock() {
        let s = derive(reallyMuted: true, hostBlocked: false, globalMute: false,
                       pendingSelfAction: false)
        XCTAssertEqual(s.cause, .selfMuted)
        XCTAssertEqual(s.captionText, "Self-muted")
        // Host-side "Ask to Unmute" removed: the host's direct control is enforce-block.
        XCTAssertEqual(s.primaryAction, .mute)
        XCTAssertEqual(s.primaryActionTitle, "Block mic")
        XCTAssertEqual(s.secondaryAction, .none)
    }

    func test_blockLiftedAwaitingTap_isOffCanUnmute_notSelfMuted() {
        // Finding A: after a block lift while still off, must NOT read "Self-muted".
        let s = derive(reallyMuted: true, hostBlocked: false, globalMute: false,
                       pendingSelfAction: true, askPending: false)
        XCTAssertEqual(s.cause, .offCanUnmute)
        XCTAssertEqual(s.captionText, "Off — can unmute")
        XCTAssertNotEqual(s.cause, .selfMuted)
        XCTAssertEqual(s.primaryAction, .mute)
        XCTAssertEqual(s.primaryActionTitle, "Block mic")
    }

    func test_askPending_noLongerChangesCause_afterAskRemoved() {
        // The host-side "Ask to Unmute" flow was removed, so askPending no longer
        // refines the caption to "Asked to unmute" — a pending tap stays "Off — can unmute".
        let s = derive(reallyMuted: true, hostBlocked: false, globalMute: false,
                       pendingSelfAction: true, askPending: true)
        XCTAssertEqual(s.cause, .offCanUnmute)
        XCTAssertEqual(s.primaryAction, .mute)
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
        XCTAssertNotEqual(s.primaryAction, .mute, "Mute/Block must never appear beside a mute-all caption")
        XCTAssertEqual(s.secondaryAction, .blockMic)
    }

    // MARK: - Precedence lock

    func test_precedence_hostBlockWinsOverMuteAll() {
        let s = derive(reallyMuted: true, hostBlocked: true, globalMute: true)
        XCTAssertEqual(s.cause, .mutedByHost, "host block must win over mute-all")
        XCTAssertEqual(s.captionText, "Muted by you")
        XCTAssertEqual(s.primaryAction, .removeMute)
    }

    // MARK: - Enforce-block availability

    func test_blockMic_isPrimaryForSelfMute_secondaryOnlyForMuteAll() {
        // Self-muted: block is now the PRIMARY action (ask removed), no secondary.
        let selfMuted = derive(reallyMuted: true, hostBlocked: false, globalMute: false)
        XCTAssertEqual(selfMuted.primaryAction, .mute)
        XCTAssertEqual(selfMuted.secondaryAction, .none)
        // Mute-all: primary is Allow to Speak, with the enforce-block secondary.
        XCTAssertEqual(derive(reallyMuted: true, hostBlocked: false, globalMute: true).secondaryAction, .blockMic)
        // Absent for mic-on and host-muted.
        XCTAssertEqual(derive(reallyMuted: false, hostBlocked: false, globalMute: false).secondaryAction, .none)
        XCTAssertEqual(derive(reallyMuted: true, hostBlocked: true, globalMute: false).secondaryAction, .none)
    }

    // MARK: - Interview mode

    func test_interviewMode_forcesActivationActions() {
        // Self-muted interviewee: primary is now Block (a restriction) → never forced.
        let self_ = derive(reallyMuted: true, hostBlocked: false, globalMute: false, interview: true)
        XCTAssertEqual(self_.primaryAction, .mute)
        XCTAssertFalse(self_.activationForcesDevice)

        // Host-muted: removeMute is an activation → forces in interview.
        let hostMuted = derive(reallyMuted: true, hostBlocked: true, globalMute: false, interview: true)
        XCTAssertTrue(hostMuted.activationForcesDevice)

        // Mic-on: primary is Mute (a restriction) → never a forced activation.
        let live = derive(reallyMuted: false, hostBlocked: false, globalMute: false, interview: true)
        XCTAssertEqual(live.primaryAction, .mute)
        XCTAssertFalse(live.activationForcesDevice)
    }

    func test_interviewMode_primaryReadsDirectUnmuteForActivationOnly() {
        // Host-muted (removeMute) force-turns the mic on in interview → direct "Unmute".
        let hostMuted = derive(reallyMuted: true, hostBlocked: true, globalMute: false, interview: true)
        XCTAssertEqual(hostMuted.primaryActionTitle, "Unmute")

        // Mute-all (allowToSpeak) force-grants in interview → "Unmute".
        let muteAll = derive(reallyMuted: true, hostBlocked: false, globalMute: true, interview: true)
        XCTAssertEqual(muteAll.primaryActionTitle, "Unmute")

        // The restriction action keeps its own label even in interview mode.
        let live = derive(reallyMuted: false, hostBlocked: false, globalMute: false, interview: true)
        XCTAssertEqual(live.primaryActionTitle, "Mute Mic")

        // Self-muted now offers an enforce-block ("Block mic") in BOTH modes — no ask.
        let selfMutedInterview = derive(reallyMuted: true, hostBlocked: false, globalMute: false, interview: true)
        XCTAssertEqual(selfMutedInterview.primaryActionTitle, "Block mic")
        let selfMutedNormal = derive(reallyMuted: true, hostBlocked: false, globalMute: false, interview: false)
        XCTAssertEqual(selfMutedNormal.primaryActionTitle, "Block mic")
    }

    func test_interviewMode_blockSecondaryOnlyForMuteAll() {
        // Self-muted's block is now the PRIMARY (no secondary) in interview too.
        let selfMuted = derive(reallyMuted: true, hostBlocked: false, globalMute: false, interview: true)
        XCTAssertEqual(selfMuted.secondaryAction, .none)

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

    func test_invariant_muteLabelMatchesCause_acrossAllInputs() {
        for reallyMuted in [true, false] {
            for hostBlocked in [true, false] {
                for globalMute in [true, false] {
                    for pending in [true, false] {
                        for askPending in [true, false] {
                            for interview in [true, false] {
                                let s = derive(reallyMuted: reallyMuted, hostBlocked: hostBlocked,
                                               globalMute: globalMute, pendingSelfAction: pending,
                                               askPending: askPending, interview: interview)
                                // `.mute` is offered when live (Mute) AND for an un-blocked
                                // muted participant (enforce Block). It must NEVER appear for
                                // host-block or mute-all causes (those offer removeMute /
                                // allowToSpeak), so the action can't contradict the caption.
                                if s.primaryAction == .mute {
                                    XCTAssertTrue(s.cause == .micOn || s.cause == .selfMuted || s.cause == .offCanUnmute,
                                                  "Mute/Block only from live/self-muted/off-can-unmute")
                                    if s.cause == .micOn {
                                        XCTAssertEqual(s.primaryActionTitle, "Mute Mic")
                                    } else {
                                        XCTAssertEqual(s.primaryActionTitle, "Block mic")
                                    }
                                }
                                // A live mic always offers Mute.
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

    // MARK: - Camera (mirror of the mic matrix)

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
        XCTAssertEqual(s.primaryActionTitle, "Stop Video")
        XCTAssertEqual(s.secondaryAction, .none)
    }

    func test_cam_selfOff_offersLock() {
        let s = deriveCam(cameraReallyOff: true, hostLocked: false, globalLock: false)
        XCTAssertEqual(s.cause, .selfOff)
        XCTAssertEqual(s.captionText, "Camera off")
        // Host-side "Ask to Turn On Camera" removed: the host's direct control is enforce-lock.
        XCTAssertEqual(s.primaryAction, .stopVideo)
        XCTAssertEqual(s.primaryActionTitle, "Lock camera")
        XCTAssertEqual(s.secondaryAction, .none)
    }

    func test_cam_lockLifted_isOffCanTurnOn_notSelfOff() {
        let s = deriveCam(cameraReallyOff: true, hostLocked: false, globalLock: false,
                          pendingSelfAction: true)
        XCTAssertEqual(s.cause, .offCanTurnOn)
        XCTAssertEqual(s.captionText, "Off — can turn on")
        XCTAssertEqual(s.primaryAction, .stopVideo)
        XCTAssertEqual(s.primaryActionTitle, "Lock camera")
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

    func test_cam_interviewMode_forceLabelOnlyForWiredLiftPath() {
        // Self-off interviewee: primary is now Lock (a restriction), never forced.
        let selfOff = deriveCam(cameraReallyOff: true, hostLocked: false, globalLock: false, interview: true)
        XCTAssertFalse(selfOff.activationForcesDevice)
        XCTAssertEqual(selfOff.primaryActionTitle, "Lock camera")
        XCTAssertEqual(selfOff.secondaryAction, .none)

        // Host-locked interviewee: the lift path DOES force-restore in interview, so this is
        // the one camera action that legitimately reads the direct "Turn On Camera".
        let locked = deriveCam(cameraReallyOff: true, hostLocked: true, globalLock: false, interview: true)
        XCTAssertTrue(locked.activationForcesDevice)
        XCTAssertEqual(locked.primaryActionTitle, "Turn On Camera")

        // Lock-all: "Allow Camera" is a slot grant, never a force.
        let lockAll = deriveCam(cameraReallyOff: true, hostLocked: false, globalLock: true, interview: true)
        XCTAssertFalse(lockAll.activationForcesDevice)
        XCTAssertEqual(lockAll.primaryActionTitle, "Allow Camera")

        // Camera-on interviewee: Stop Video is a restriction, never a forced activation.
        let live = deriveCam(cameraReallyOff: false, hostLocked: false, globalLock: false, interview: true)
        XCTAssertEqual(live.primaryAction, .stopVideo)
        XCTAssertFalse(live.activationForcesDevice)
    }

    func test_cam_invariant_stopVideoLabelMatchesCause_acrossAllInputs() {
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
                                    XCTAssertTrue(s.cause == .camOn || s.cause == .selfOff || s.cause == .offCanTurnOn,
                                                  "Stop/Lock only from live/self-off/off-can-turn-on")
                                    if s.cause == .camOn {
                                        XCTAssertEqual(s.primaryActionTitle, "Stop Video")
                                    } else {
                                        XCTAssertEqual(s.primaryActionTitle, "Lock camera")
                                    }
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
