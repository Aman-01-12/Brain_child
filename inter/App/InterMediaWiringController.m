// ============================================================================
// InterMediaWiringController.m
// inter
//
// Shared media/network wiring logic extracted from AppDelegate.m and
// SecureWindowController.m. See InterMediaWiringController.h for API.
// ============================================================================

#import "InterMediaWiringController.h"
#import "InterLocalMediaController.h"
#import "InterLocalCallControlPanel.h"
#import "InterSurfaceShareController.h"
#import "InterRemoteVideoLayoutManager.h"
#import "InterParticipantOverlayView.h"
#import "InterNetworkStatusView.h"
#import "MetalSurfaceView.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// KVO context pointers — unique per controller instance isn't needed;
// these are module-private sentinels for this file only.
static void *InterWiringConnectionStateContext = &InterWiringConnectionStateContext;
static void *InterWiringPresenceStateContext   = &InterWiringPresenceStateContext;
static void *InterWiringActiveSpeakerContext   = &InterWiringActiveSpeakerContext;
static void *InterWiringParticipantCountContext = &InterWiringParticipantCountContext;

@interface InterMediaWiringController ()
@property (nonatomic, assign) BOOL isObservingRoomController;
/// Timer that fires after 30 seconds of continuous reconnection.
@property (nonatomic, strong, nullable) dispatch_source_t reconnectionTimeoutTimer;
/// Whether the connection-lost alert is currently visible.
@property (nonatomic, assign) BOOL isShowingConnectionLostAlert;
/// Tracks whether the mic LiveKit track is muted while connected.
/// Used by twoPhaseToggleMicrophone to avoid AVCaptureSession reconfiguration.
@property (nonatomic, assign, readwrite) BOOL isMicNetworkMuted;
/// Per-tile host mute (requestMuteOne). NEVER set by Mute All.
/// When YES: participant sees "Muted by host" and button is disabled.
@property (nonatomic, assign, readwrite) BOOL hostMuted;
/// Global Mute All is active. NEVER set by per-tile actions.
/// When YES without speakPermissionGranted: raise-hand gate.
@property (nonatomic, assign, readwrite) BOOL globalMuteActive;
/// Host granted permission to speak during a Mute All session.
/// ONE-TIME USE: cleared on self-mute while globalMuteActive (§8.2 revised).
@property (nonatomic, assign, readwrite) BOOL speakPermissionGranted;
/// Monotonically increasing counter incremented on every authoritative state
/// change. Async completion blocks capture this before their async call and
/// discard their update if the value has advanced (Bug 2 stale-update guard).
@property (nonatomic, assign, readwrite) NSInteger stateSequenceNumber;
/// Records whether the camera was active at the moment applyHostCameraMuteForParticipant
/// ran. Used by applyHostCameraLiftForParticipant to restore camera only when the host
/// lock was the reason it went off, not a pre-existing user choice to be camera-off.
@property (nonatomic, assign) BOOL cameraWasEnabledBeforeHostLock;
/// Set when the participant has sent a camera unlock request and is waiting for approval.
/// Shows "Request Sent…" on the camera button (non-interactive).
@property (nonatomic, assign, readwrite) BOOL cameraUnlockRequestPending;
/// Set when the host has approved the participant's unlock request.
/// The Redis lock remains — participant may turn camera on once;
/// turning it back off reverts to the "Ask to Unlock" state.
@property (nonatomic, assign, readwrite) BOOL cameraUnlockApproved;
/// Guards the revoke-on-camera-off branch in deriveCameraButton.
/// Set to YES only after the camera actually turns on during an approved window,
/// so the revoke does not fire the moment approval arrives with camera still off.
@property (nonatomic, assign) BOOL cameraWasEnabledWhileApproved;
@property (nonatomic, assign, readwrite) BOOL micUnlockRequestPending;
@property (nonatomic, assign, readwrite) BOOL micUnlockApproved;
@property (nonatomic, assign) BOOL micWasUnmutedWhileApproved;
@property (nonatomic, strong, nullable) NSTimer *micUnlockRequestTimer;
@end

@implementation InterMediaWiringController

// Custom setter: when the layout manager is (re-)assigned, immediately push
// current state so that any KVO changes that arrived while remoteLayout was
// nil are not silently dropped.  This fixes two races in the normal-call path
// where setupRoomControllerKVO runs at launch but remoteLayout is only wired
// when the call window is created later:
//   • "missing green border on first speaker" — activeSpeakerIdentity
//   • "badge/toggle missing for late joiners" — remoteParticipantCount
- (void)setRemoteLayout:(InterRemoteVideoLayoutManager *)remoteLayout {
    _remoteLayout = remoteLayout;

    if (remoteLayout) {
        // Push active speaker so the first speaker highlight is correct.
        NSString *currentSpeaker = self.roomController.activeSpeakerIdentity;
        if (currentSpeaker.length > 0) {
            [remoteLayout setActiveSpeakerIdentity:currentSpeaker];
        }

        // Push participant count so the badge and toggle show immediately.
        // Without this, a participant joining a room that already has 2+ people
        // (so remoteParticipantCount > 0 when KVO first fires) would see an
        // empty badge because handleParticipantCountChanged: found remoteLayout=nil.
        NSInteger currentCount = self.roomController.remoteParticipantCount;
        if (currentCount > 0) {
            [remoteLayout setRemoteParticipantCount:(NSUInteger)currentCount];
        }
    }
}

- (void)dealloc {
    [self teardownRoomControllerKVO];
    [self cancelReconnectionTimeout];
}

#pragma mark - Simple Device Toggles

- (void)toggleCamera {
    InterLocalMediaController *media = self.mediaController;
    if (!media) return;

    BOOL shouldEnable = !media.isCameraEnabled;
    __weak typeof(self) weakSelf = self;
    [media setCameraEnabled:shouldEnable completion:^(BOOL success) {
        if (!success) {
            [weakSelf.controlPanel setMediaStatusText:@"Unable to change camera state."];
            return;
        }
        [weakSelf.controlPanel setCameraEnabled:weakSelf.mediaController.isCameraEnabled];
        NSString *summary = weakSelf.mediaStateSummaryBlock ? weakSelf.mediaStateSummaryBlock() : nil;
        if (summary) {
            [weakSelf.controlPanel setMediaStatusText:summary];
        }
        // [G9] When camera was just enabled, force the local self-tile's preview layer to
        // redisplay. AVSampleBufferDisplayLayer (backing AVCaptureVideoPreviewLayer) can
        // get stuck after a disable→enable cycle and needs an explicit session re-attach
        // or a CALayer property change to resume rendering.  The control-panel preview
        // (_previewLayer) works because updatePreviewMirroringPolicyOnMainThread sets its
        // affineTransform; localPreviewLayer in the layout has no such trigger, so we
        // kick the layout manager here.
        if (weakSelf.mediaController.isCameraEnabled) {
            [weakSelf.remoteLayout refreshLocalPreviewLayout];
        }
    }];
}

- (void)toggleMicrophone {
    InterLocalMediaController *media = self.mediaController;
    if (!media) return;

    BOOL shouldEnable = !media.isMicrophoneEnabled;
    __weak typeof(self) weakSelf = self;
    [media setMicrophoneEnabled:shouldEnable completion:^(BOOL success) {
        if (!success) {
            [weakSelf.controlPanel setMediaStatusText:@"Unable to change microphone state."];
            return;
        }
        [weakSelf.controlPanel setMicrophoneEnabled:weakSelf.mediaController.isMicrophoneEnabled];
        NSString *summary = weakSelf.mediaStateSummaryBlock ? weakSelf.mediaStateSummaryBlock() : nil;
        if (summary) {
            [weakSelf.controlPanel setMediaStatusText:summary];
        }
    }];
}

#pragma mark - G2 Two-Phase Toggles

- (void)twoPhaseToggleCamera {
    // Safety net: if camera is locked by host (per-participant or global) AND the
    // participant has not been individually approved via the unlock-request flow, ignore.
    if ((self.isHostCameraLocked || self.globalCameraLockActive) && !self.cameraUnlockApproved) { return; }
    InterLocalMediaController *media = self.mediaController;
    InterRoomController *rc = self.roomController;
    BOOL shouldEnable = !media.isCameraEnabled;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;

    // Track that the camera was turned on during an approved-unlock window so
    // deriveCameraButton's revoke branch can distinguish "still off at approval
    // time" from "participant voluntarily turned it back off".
    if (shouldEnable && self.cameraUnlockApproved) {
        self.cameraWasEnabledWhileApproved = YES;
    }

    __weak typeof(self) weakSelf = self;

    if (!shouldEnable) {
        // DISABLE: [G2] Mute LiveKit track FIRST → then stop capture device.
        //
        // [R6] Guard against nil cameraSource: if the camera was never published
        // (e.g. activeCameraOffOnJoin was YES and wireNetworkPublish skipped it),
        // muteCameraTrackWithCompletion: is a nil-safe no-op whose completion block
        // is never called. Fall back to a direct toggleCamera so the button and
        // isCameraEnabled always reflect reality.
        if (isConnected && rc.publisher.cameraSource != nil) {
            [rc.publisher muteCameraTrackWithCompletion:^{
                [weakSelf toggleCamera];
            }];
        } else {
            // No published camera source — disable the local device directly.
            [self toggleCamera];
        }
    } else {
        // ENABLE: [G2] Start capture device FIRST → first frame → unmute LiveKit track.
        //
        // [R6] If no camera track has been published yet (cameraSource is nil), we cannot
        // just unmute — there is nothing to unmute. Publish fresh so the remote side gets
        // video. Both toggleCamera and publishCamera dispatch onto the same serial
        // sessionQueue, so publishCamera's source.start() runs after the device input is
        // already added, guaranteeing correct ordering without additional synchronisation.
        [self toggleCamera];
        if (isConnected) {
            if (rc.publisher.cameraSource != nil) {
                // Track exists but is muted — first real frame will auto-unmute via the
                // cameraSource state machine (beginEnable → captureOutput → unmute).
                [rc.publisher unmuteCameraTrack];
            } else {
                // No track yet — publish from scratch using the existing capture session.
                AVCaptureSession *session = media.captureSession;
                dispatch_queue_t sessionQueue = media.sessionQueue;
                if (session && sessionQueue) {
                    [rc.publisher publishCameraWithCaptureSession:session
                                                    sessionQueue:sessionQueue
                                                      completion:^(NSError * _Nullable error) {
                        if (error) {
                            NSLog(@"[R6] Camera re-publish on enable failed: %@",
                                  error.localizedDescription);
                        }
                    }];
                }
            }
        }
    }
}

- (void)twoPhaseToggleMicrophone {
    InterLocalMediaController *media = self.mediaController;
    InterRoomController *rc = self.roomController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;

    if (isConnected) {
        // ── Connected path ──────────────────────────────────────────────
        // Only mute/unmute the LiveKit audio track. Do NOT touch
        // InterLocalMediaController / AVCaptureSession — modifying the
        // shared session's audio inputs calls beginConfiguration /
        // commitConfiguration, which momentarily interrupts ALL session
        // outputs including the camera video preview.
        // Guard: cannot freely toggle while restricted unless the host approved it.
        // AppDelegate's mic button handler drives the request-flow path.
        if ((self.hostMuted || self.globalMuteActive) && !self.micUnlockApproved) {
            return;
        }
        // Track that participant used their approved unmute (for revoke detection).
        if (self.micUnlockApproved && !self.isMicNetworkMuted) {
            // User is currently mic-on while approved — about to mute themselves.
            self.micWasUnmutedWhileApproved = YES;
        }
        BOOL shouldMute = !self.isMicNetworkMuted;
        __weak typeof(self) weakSelf = self;

        if (shouldMute) {
            [rc.publisher muteMicrophoneTrackWithCompletion:^{
                weakSelf.isMicNetworkMuted = YES;
                // Bug 1 fix: speak permission is one-time use. Self-muting while
                // globalMuteActive revokes the grant — the participant must raise
                // their hand again for a new approval (§8.2 revised).
                if (weakSelf.globalMuteActive) {
                    weakSelf.speakPermissionGranted = NO;
                }
                weakSelf.stateSequenceNumber++;
                [weakSelf deriveParticipantMicButton];
                NSString *summary = weakSelf.mediaStateSummaryBlock ? weakSelf.mediaStateSummaryBlock() : nil;
                if (summary) {
                    [weakSelf.controlPanel setMediaStatusText:summary];
                }
            }];
        } else {
            // [R7] If no mic track was published yet (activeMuteOnJoin suppressed it in
            // wireNetworkPublish), unmuteMicrophoneTrack is a silent no-op — microphoneTrack
            // is nil and the remote side hears nothing. Publish from scratch instead.
            if (rc.publisher.isMicrophonePublished) {
                [rc.publisher unmuteMicrophoneTrack];
            } else {
                [rc.publisher publishMicrophoneWithCompletion:^(NSError * _Nullable error) {
                    if (error) {
                        NSLog(@"[R7] Mic re-publish on unmute failed: %@",
                              error.localizedDescription);
                    }
                }];
            }
            self.isMicNetworkMuted = NO;
            self.stateSequenceNumber++;
            [self deriveParticipantMicButton];
            NSString *summary = self.mediaStateSummaryBlock ? self.mediaStateSummaryBlock() : nil;
            if (summary) {
                [self.controlPanel setMediaStatusText:summary];
            }
        }
    } else {
        // ── Offline / pre-connect path ──────────────────────────────────
        // No LiveKit track exists yet. Toggle the local capture device
        // through the AVCaptureSession as before.
        [self toggleMicrophone];
    }
}

#pragma mark - Remote Mic Mute/Unmute

/// Single source of truth for mic button state. Derives button title and
/// enabled state from the four mic state flags. Priority-ordered per
/// mic_mute_unmute.md §6.2. Called after every authoritative state
/// transition as the single derivation point (Bug 2 fix).
/// Single source of truth for mic button state.
/// Priority: restricted → approval path → normal toggle.
- (void)deriveParticipantMicButton {
    BOOL restricted = self.hostMuted || self.globalMuteActive;

    if (restricted) {
        if (self.micUnlockApproved) {
            // Host approved — detect revoke: participant unmuted then muted again.
            if (self.micWasUnmutedWhileApproved && self.isMicNetworkMuted) {
                self.micUnlockApproved = NO;
                self.micWasUnmutedWhileApproved = NO;
                [self.controlPanel setMicrophoneEnabled:YES];
                [self.controlPanel setMicrophoneButtonTitle:@"Ask to Unmute"];
            } else {
                // Approved — normal toggle available.
                [self.controlPanel setMicrophoneEnabled:YES];
                NSString *title = self.isMicNetworkMuted ? @"Turn Mic On" : @"Turn Mic Off";
                [self.controlPanel setMicrophoneButtonTitle:title];
            }
        } else if (self.micUnlockRequestPending) {
            // F6: timer running — show pending state.
            [self.controlPanel setMicrophoneEnabled:NO];
            [self.controlPanel setMicrophoneButtonTitle:@"Request Sent…"];
        } else {
            [self.controlPanel setMicrophoneEnabled:YES];
            [self.controlPanel setMicrophoneButtonTitle:@"Ask to Unmute"];
        }
    } else {
        // Restriction lifted — clear all unlock-flow state.
        self.micUnlockApproved = NO;
        self.micUnlockRequestPending = NO;
        self.micWasUnmutedWhileApproved = NO;
        [self invalidateMicUnlockRequestTimer];
        [self.controlPanel setMicrophoneEnabled:!self.isMicNetworkMuted];
        [self.controlPanel setMicrophoneButtonTitle:nil];
    }
}

/// F6 mitigation: cancel the pending-approval safety-net timer.
- (void)invalidateMicUnlockRequestTimer {
    [self.micUnlockRequestTimer invalidate];
    self.micUnlockRequestTimer = nil;
}

- (void)applyMicUnlockRequestPending {
    self.micUnlockRequestPending = YES;
    [self deriveParticipantMicButton];
    // F6: start 30-second safety-net timer.
    [self invalidateMicUnlockRequestTimer];
    __weak typeof(self) weakSelf = self;
    self.micUnlockRequestTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                                  repeats:NO
                                                                    block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (self.micUnlockRequestPending) {
            self.micUnlockRequestPending = NO;
            [self deriveParticipantMicButton];
        }
    }];
}

- (void)applyMicUnlockApproved {
    // F16 mitigation: if restriction was already lifted, approval is moot.
    if (!self.hostMuted && !self.globalMuteActive) { return; }
    self.micUnlockApproved = YES;
    self.micUnlockRequestPending = NO;
    self.micWasUnmutedWhileApproved = NO;
    [self invalidateMicUnlockRequestTimer];
    [self deriveParticipantMicButton];
}

- (void)resetMicUnlockFlowState {
    self.micUnlockApproved = NO;
    self.micUnlockRequestPending = NO;
    self.micWasUnmutedWhileApproved = NO;
    [self invalidateMicUnlockRequestTimer];
    [self deriveParticipantMicButton];
}

- (void)applyRemoteMicMute {
    // Clear any pending unlock flow — Mute All supersedes any pending request.
    self.micUnlockApproved = NO;
    self.micUnlockRequestPending = NO;
    self.micWasUnmutedWhileApproved = NO;
    [self invalidateMicUnlockRequestTimer];
    InterRoomController *rc = self.roomController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
    if (!isConnected) return;

    // Global Mute All: set the global flag only — NEVER hostMuted.
    // Clears any prior speak permission (new mute supersedes it).
    self.isMicNetworkMuted = YES;
    self.globalMuteActive = YES;
    self.speakPermissionGranted = NO;
    self.stateSequenceNumber++;
    [self deriveParticipantMicButton];  // → "✋ Raise Hand to Speak"
    NSString *summary = self.mediaStateSummaryBlock ? self.mediaStateSummaryBlock() : nil;
    if (summary) {
        [self.controlPanel setMediaStatusText:summary];
    }
}

- (void)applyRemoteMicMuteOne {
    // Clear any pending unlock flow — new mute supersedes it.
    self.micUnlockApproved = NO;
    self.micUnlockRequestPending = NO;
    self.micWasUnmutedWhileApproved = NO;
    [self invalidateMicUnlockRequestTimer];
    InterRoomController *rc = self.roomController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
    if (!isConnected) return;

    // Per-tile host mute: set hostMuted only — NEVER globalMuteActive.
    // Participant sees "Muted by host" with the button disabled.
    self.isMicNetworkMuted = YES;
    self.hostMuted = YES;
    self.stateSequenceNumber++;
    [self deriveParticipantMicButton];  // → "Muted by host" (disabled)
    NSString *summary = self.mediaStateSummaryBlock ? self.mediaStateSummaryBlock() : nil;
    if (summary) {
        [self.controlPanel setMediaStatusText:summary];
    }
}

- (void)applyAllowToSpeak {
    // Raise-hand approval: lower the visual hand indicator only.
    // Mic unlock is now handled exclusively by the approveMicUnlock DataChannel
    // signal path. This method no longer touches mic state.
    NSLog(@"[MediaWiring] allowToSpeak received — hand lowered (mic state unchanged)");
}

- (void)applyUnmuteAll {
    InterRoomController *rc = self.roomController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
    if (!isConnected) return;

    // Clears global mute flag and speak permission only.
    // Does NOT clear hostMuted — individual per-tile mutes persist (§8.1).
    // Does NOT auto-unmute the track — participant chooses when to turn on.
    self.globalMuteActive = NO;
    self.speakPermissionGranted = NO;
    self.stateSequenceNumber++;
    [self deriveParticipantMicButton];
    NSString *summary = self.mediaStateSummaryBlock ? self.mediaStateSummaryBlock() : nil;
    if (summary) {
        [self.controlPanel setMediaStatusText:summary];
    }
}

- (void)applyRemoteMicUnmute {
    self.micUnlockApproved = NO;
    self.micUnlockRequestPending = NO;
    self.micWasUnmutedWhileApproved = NO;
    [self invalidateMicUnlockRequestTimer];
    InterRoomController *rc = self.roomController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
    if (!isConnected) return;

    // Host explicitly lifted the per-tile mute restriction.
    // Clear hostMuted and force-unmute the track so mic is immediately active.
    self.hostMuted = NO;

    if (self.isMicNetworkMuted) {
        __weak typeof(self) weakSelf = self;
        [rc.publisher forceUnmuteMicrophoneTrackWithCompletion:^{
            weakSelf.isMicNetworkMuted = NO;
            weakSelf.stateSequenceNumber++;
            [weakSelf deriveParticipantMicButton];
            NSString *summary = weakSelf.mediaStateSummaryBlock ? weakSelf.mediaStateSummaryBlock() : nil;
            if (summary) {
                [weakSelf.controlPanel setMediaStatusText:summary];
            }
        }];
    } else {
        self.stateSequenceNumber++;
        [self deriveParticipantMicButton];
        NSString *summary = self.mediaStateSummaryBlock ? self.mediaStateSummaryBlock() : nil;
        if (summary) {
            [self.controlPanel setMediaStatusText:summary];
        }
    }
}

#pragma mark - Host Camera Lock

- (void)deriveCameraButton {
    if (self.isHostCameraLocked || self.globalCameraLockActive) {
        if (self.cameraUnlockApproved) {
            // Host approved — only revoke if the camera was previously turned on
            // during this approved window and has now gone back off. We must NOT
            // revoke at the moment approval arrives while the camera is still off
            // (it was locked off — participant hasn't tapped yet).
            if (self.cameraWasEnabledWhileApproved && !self.mediaController.isCameraEnabled) {
                // Camera was on, participant voluntarily turned it off → revoke.
                self.cameraUnlockApproved = NO;
                self.cameraWasEnabledWhileApproved = NO;
                // cameraWasEnabledBeforeHostLock is now stale — clear it so that
                // an eventual explicit host lift doesn't auto-restore.
                self.cameraWasEnabledBeforeHostLock = NO;
                [self.controlPanel setCameraEnabled:NO];
                [self.controlPanel setCameraButtonTitle:@"Ask to Unlock Camera"];
                [self.controlPanel setCameraInteractive:YES];
            } else {
                // Approved and camera is not yet on (or is on) — reflect the actual
                // camera state so the button title is correct in both cases.
                [self.controlPanel setCameraInteractive:YES];
                [self.controlPanel setCameraButtonTitle:nil]; // default: "Turn Camera On" / "Turn Camera Off"
                [self.controlPanel setCameraEnabled:self.mediaController.isCameraEnabled];
            }
        } else if (self.cameraUnlockRequestPending) {
            // Request in flight — disable the button.
            [self.controlPanel setCameraEnabled:NO];
            [self.controlPanel setCameraButtonTitle:@"Request Sent…"];
            [self.controlPanel setCameraInteractive:NO];
        } else {
            // Locked, no pending request — show "Ask to Unlock Camera" (interactive).
            [self.controlPanel setCameraEnabled:NO];
            [self.controlPanel setCameraButtonTitle:@"Ask to Unlock Camera"];
            [self.controlPanel setCameraInteractive:YES];
        }
    } else {
        // Lock fully lifted — clear any residual unlock-flow state.
        self.cameraUnlockApproved = NO;
        self.cameraUnlockRequestPending = NO;
        [self.controlPanel setCameraInteractive:YES];
        [self.controlPanel setCameraButtonTitle:nil]; // restore default title
        [self.controlPanel setCameraEnabled:self.mediaController.isCameraEnabled];
    }
}

- (void)applyHostCameraMuteForParticipant {
    self.isHostCameraLocked = YES;
    // Clear any prior unlock-request flow state so a re-lock forces the
    // participant back through "Ask to Unlock Camera".
    self.cameraUnlockApproved = NO;
    self.cameraUnlockRequestPending = NO;
    self.cameraWasEnabledWhileApproved = NO;
    InterLocalMediaController *media = self.mediaController;
    if (!media) { [self deriveCameraButton]; return; }
    // Capture before setCameraEnabled:NO changes it so the lift can restore accurately.
    self.cameraWasEnabledBeforeHostLock = media.isCameraEnabled;
    __weak typeof(self) weakSelf = self;
    if (media.isCameraEnabled) {
        [media setCameraEnabled:NO completion:^(BOOL success) {
#pragma unused(success)
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf deriveCameraButton];
            });
        }];
    } else {
        [self deriveCameraButton];
    }
}

- (void)applyHostCameraLiftForParticipant {
    self.isHostCameraLocked = NO;
    self.cameraUnlockApproved = NO;
    self.cameraUnlockRequestPending = NO;
    self.cameraWasEnabledWhileApproved = NO;
    InterLocalMediaController *media = self.mediaController;
    if (media && self.cameraWasEnabledBeforeHostLock) {
        // The host lock was the reason the camera went off — restore it.
        self.cameraWasEnabledBeforeHostLock = NO;
        __weak typeof(self) weakSelf = self;
        [media setCameraEnabled:YES completion:^(BOOL success) {
#pragma unused(success)
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf deriveCameraButton];
            });
        }];
    } else {
        // Camera was already off before the lock; don't second-guess the user.
        self.cameraWasEnabledBeforeHostLock = NO;
        [self deriveCameraButton];
    }
}

/// Host approved this participant's camera unlock request.
/// The Redis lock stays — participant may now turn camera on once.
- (void)applyHostCameraApprovalForParticipant {
    self.cameraUnlockApproved = YES;
    self.cameraUnlockRequestPending = NO;
    self.cameraWasEnabledWhileApproved = NO; // camera hasn't been turned on yet in this window
    [self deriveCameraButton];
}

/// Participant has sent a camera unlock request — update button to "Request Sent…".
- (void)applyHostCameraUnlockRequestPending {
    self.cameraUnlockRequestPending = YES;
    [self deriveCameraButton];
}

/// Reset the unlock-request flow state without touching lock flags or camera enable state.
/// Called on reconnect to clear any stale pending/approved unlock state from the prior session.
- (void)resetCameraUnlockFlowState {
    self.cameraUnlockApproved = NO;
    self.cameraUnlockRequestPending = NO;
    self.cameraWasEnabledWhileApproved = NO;
    [self deriveCameraButton];
}

- (void)applyHostCameraMuteForAll {
    // Use the global flag — independent of the per-participant flag so that
    // liftCameraLockAll does NOT accidentally clear individual per-participant locks.
    self.globalCameraLockActive = YES;
    InterLocalMediaController *media = self.mediaController;
    if (!media) { [self deriveCameraButton]; return; }
    __weak typeof(self) weakSelf = self;
    if (media.isCameraEnabled) {
        [media setCameraEnabled:NO completion:^(BOOL success) {
#pragma unused(success)
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf deriveCameraButton];
            });
        }];
    } else {
        [self deriveCameraButton];
    }
}

- (void)applyHostCameraLiftForAll {
    // Clear ONLY the global flag — per-participant isHostCameraLocked is untouched.
    self.globalCameraLockActive = NO;
    [self deriveCameraButton];
}

#pragma mark - Network Wiring

- (void)wireNetworkPublish {
    InterRoomController *rc = self.roomController;
    if (!rc || rc.connectionState != InterRoomConnectionStateConnected) {
        return;
    }

    InterLocalMediaController *media = self.mediaController;
    if (!media) {
        return;
    }

    // Initialise network-level mic mute state from the current AVCaptureSession state.
    // If isMicrophoneEnabled is NO (e.g. activeMuteOnJoin suppressed it), the mic track
    // will not be published below, so isMicNetworkMuted must be YES to ensure the first
    // user toggle goes to the unmute (publish) path, not the mute path.
    self.isMicNetworkMuted = !media.isMicrophoneEnabled;

    AVCaptureSession *session = media.captureSession;
    dispatch_queue_t sessionQueue = media.sessionQueue;
    if (!session || !sessionQueue) {
        return;
    }

    // Publish camera
    if (media.isCameraEnabled) {
        [rc.publisher publishCameraWithCaptureSession:session
                                         sessionQueue:sessionQueue
                                           completion:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"[G8] Camera publish error: %@", error.localizedDescription);
            }
        }];
    }

    // Publish microphone
    if (media.isMicrophoneEnabled) {
        [rc.publisher publishMicrophoneWithCompletion:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"[G8] Microphone publish error: %@", error.localizedDescription);
            }
        }];
    }
}

- (void)wireNetworkSinkOnSurfaceShareController:(InterSurfaceShareController *)controller {
    InterRoomController *rc = self.roomController;
    if (!rc || rc.connectionState != InterRoomConnectionStateConnected) {
        controller.networkPublishSink = nil;
        return;
    }

    // Create a screen share sink from the publisher
    InterLiveKitScreenShareSource *source = [rc.publisher createScreenShareSink];
    controller.networkPublishSink = source;
}

#pragma mark - KVO Lifecycle

- (void)setupRoomControllerKVO {
    InterRoomController *rc = self.roomController;
    if (!rc || self.isObservingRoomController) {
        return;
    }

    // NSKeyValueObservingOptionInitial fires the callback immediately with the
    // current value. This prevents a race where the room controller already has
    // state set (e.g. remoteParticipantCount = 2) before KVO is registered —
    // without Initial, the handler would never fire and late-joining participants
    // would miss the badge / presence overlay entirely.
    NSKeyValueObservingOptions opts = NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial;

    [rc addObserver:self forKeyPath:@"connectionState"
            options:opts
            context:InterWiringConnectionStateContext];
    [rc addObserver:self forKeyPath:@"participantPresenceState"
            options:opts
            context:InterWiringPresenceStateContext];
    [rc addObserver:self forKeyPath:@"activeSpeakerIdentity"
            options:opts
            context:InterWiringActiveSpeakerContext];
    [rc addObserver:self forKeyPath:@"remoteParticipantCount"
            options:opts
            context:InterWiringParticipantCountContext];
    self.isObservingRoomController = YES;
}

- (void)teardownRoomControllerKVO {
    if (!self.isObservingRoomController || !self.roomController) {
        self.isObservingRoomController = NO;
        return;
    }

    [self.roomController removeObserver:self forKeyPath:@"connectionState"
                                context:InterWiringConnectionStateContext];
    [self.roomController removeObserver:self forKeyPath:@"participantPresenceState"
                                context:InterWiringPresenceStateContext];
    [self.roomController removeObserver:self forKeyPath:@"activeSpeakerIdentity"
                                context:InterWiringActiveSpeakerContext];
    [self.roomController removeObserver:self forKeyPath:@"remoteParticipantCount"
                                context:InterWiringParticipantCountContext];
    self.isObservingRoomController = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context == InterWiringConnectionStateContext) {
        InterRoomController *rc = (InterRoomController *)object;
        [self handleConnectionStateChanged:rc.connectionState];
    } else if (context == InterWiringPresenceStateContext) {
        InterRoomController *rc = (InterRoomController *)object;
        [self handlePresenceStateChanged:rc.participantPresenceState];
    } else if (context == InterWiringActiveSpeakerContext) {
        InterRoomController *rc = (InterRoomController *)object;
        [self handleActiveSpeakerChanged:rc.activeSpeakerIdentity];
    } else if (context == InterWiringParticipantCountContext) {
        InterRoomController *rc = (InterRoomController *)object;
        [self handleParticipantCountChanged:rc.remoteParticipantCount];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Connection State Handling

- (void)handleConnectionStateChanged:(InterRoomConnectionState)state {
    NSString *label = [[self class] connectionLabelForState:state];
    InterNetworkQualityLevel quality = [[self class] qualityLevelForConnectionState:state];

    if (label && self.controlPanel) {
        [self.controlPanel setMediaStatusText:label];
        [self.controlPanel setConnectionStatusText:label];
    }

    if (self.networkStatusView) {
        [self.networkStatusView setQualityLevel:quality];
    }

    // Reconnection timeout management [4.1 row 5]
    switch (state) {
        case InterRoomConnectionStateReconnecting:
            [self startReconnectionTimeout];
            break;
        case InterRoomConnectionStateConnected:
            [self cancelReconnectionTimeout];
            break;
        case InterRoomConnectionStateDisconnectedWithError:
            [self cancelReconnectionTimeout];
            [self showConnectionLostAlert];
            break;
        case InterRoomConnectionStateDisconnected:
        case InterRoomConnectionStateConnecting:
            [self cancelReconnectionTimeout];
            break;
    }

    // Notify delegate for mode-specific follow-up actions
    if ([self.delegate respondsToSelector:@selector(mediaWiringControllerDidChangeConnectionState:)]) {
        [self.delegate mediaWiringControllerDidChangeConnectionState:(NSInteger)state];
    }
}

#pragma mark - Reconnection Timeout [4.1 row 5]

- (void)startReconnectionTimeout {
    // Don't restart if already counting down
    if (self.reconnectionTimeoutTimer) return;

    __weak typeof(self) weakSelf = self;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf handleReconnectionTimeout];
    });
    dispatch_resume(timer);
    self.reconnectionTimeoutTimer = timer;
}

- (void)cancelReconnectionTimeout {
    if (self.reconnectionTimeoutTimer) {
        dispatch_source_cancel(self.reconnectionTimeoutTimer);
        self.reconnectionTimeoutTimer = nil;
    }
}

- (void)handleReconnectionTimeout {
    [self cancelReconnectionTimeout];
    [self showConnectionLostAlert];
}

- (void)showConnectionLostAlert {
    if (self.isShowingConnectionLostAlert) return;
    self.isShowingConnectionLostAlert = YES;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Connection Lost";
    alert.informativeText = @"The call connection could not be restored. "
                            @"You can retry the connection or continue working offline.";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Retry"];
    [alert addButtonWithTitle:@"Continue Offline"];

    NSModalResponse response = [alert runModal];
    self.isShowingConnectionLostAlert = NO;

    if (response == NSAlertFirstButtonReturn) {
        // Retry
        if ([self.delegate respondsToSelector:@selector(mediaWiringControllerDidRequestReconnect)]) {
            [self.delegate mediaWiringControllerDidRequestReconnect];
        }
    } else {
        // Continue Offline
        if ([self.delegate respondsToSelector:@selector(mediaWiringControllerDidRequestContinueOffline)]) {
            [self.delegate mediaWiringControllerDidRequestContinueOffline];
        }
    }
}

#pragma mark - Presence State Handling

- (void)handlePresenceStateChanged:(InterParticipantPresenceState)state {
    InterRoomController *rc = self.roomController;
    NSInteger count = rc ? rc.remoteParticipantCount : 0;

    switch (state) {
        case InterParticipantPresenceStateAlone:
            // [3.2.4] Show waiting overlay when connected and alone
            if (rc && rc.connectionState == InterRoomConnectionStateConnected) {
                [self.remoteLayout.participantOverlay setOverlayState:InterParticipantOverlayStateWaiting];
            }
            break;
        case InterParticipantPresenceStateParticipantJoined:
            if (self.controlPanel) {
                if (count == 1) {
                    [self.controlPanel setMediaStatusText:@"Participant joined"];
                } else {
                    NSString *msg = [NSString stringWithFormat:@"%ld participants in call", (long)count];
                    [self.controlPanel setMediaStatusText:msg];
                }
            }
            // Hide overlay when someone joins
            [self.remoteLayout.participantOverlay setOverlayState:InterParticipantOverlayStateHidden];
            break;
        case InterParticipantPresenceStateParticipantLeft:
            if (self.controlPanel) {
                if (count == 0) {
                    [self.controlPanel setMediaStatusText:@"All participants left"];
                } else {
                    NSString *msg = [NSString stringWithFormat:@"A participant left · %ld remaining", (long)count];
                    [self.controlPanel setMediaStatusText:msg];
                }
            }
            // Show "Participant left." overlay only when ALL participants are gone
            if (count == 0) {
                [self.remoteLayout.participantOverlay setOverlayState:InterParticipantOverlayStateParticipantLeft];
            }
            break;
    }

    // Notify delegate for mode-specific follow-up actions
    if ([self.delegate respondsToSelector:@selector(mediaWiringControllerDidChangePresenceState:)]) {
        [self.delegate mediaWiringControllerDidChangePresenceState:(NSInteger)state];
    }
}

#pragma mark - Active Speaker Handling

- (void)handleActiveSpeakerChanged:(NSString *)speakerIdentity {
    // Forward active speaker identity to the layout manager for visual highlighting
    InterRemoteVideoLayoutManager *layout = self.remoteLayout;
    if (layout) {
        [layout setActiveSpeakerIdentity:speakerIdentity];
    }
}

#pragma mark - Participant Count Handling

- (void)handleParticipantCountChanged:(NSInteger)count {
    // Update participant count display on the layout manager
    InterRemoteVideoLayoutManager *layout = self.remoteLayout;
    if (layout) {
        [layout setRemoteParticipantCount:(NSUInteger)count];
    }
}

#pragma mark - Diagnostics

- (void)handleDiagnosticTripleClick {
    InterRoomController *rc = self.roomController;
    if (!rc || !rc.statsCollector) return;

    NSString *snapshot = [rc.statsCollector captureDiagnosticSnapshot];
    if (snapshot.length == 0) return;

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:snapshot forType:NSPasteboardTypeString];

    if (self.controlPanel) {
        [self.controlPanel setConnectionStatusText:@"Diagnostic copied!"];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            InterRoomController *r = weakSelf.roomController;
            if (r) {
                NSString *label = [[weakSelf class] connectionLabelForState:r.connectionState];
                [weakSelf.controlPanel setConnectionStatusText:label];
            }
        });
    }
}

#pragma mark - Utility (Class Methods)

+ (NSString *)connectionLabelForState:(NSInteger)state {
    switch ((InterRoomConnectionState)state) {
        case InterRoomConnectionStateDisconnected:          return @"Disconnected";
        case InterRoomConnectionStateConnecting:            return @"Connecting…";
        case InterRoomConnectionStateConnected:             return @"Connected";
        case InterRoomConnectionStateReconnecting:          return @"Reconnecting…";
        case InterRoomConnectionStateDisconnectedWithError: return @"Connection error — Continue offline or retry";
    }
    return @"Unknown";
}

+ (InterNetworkQualityLevel)qualityLevelForConnectionState:(NSInteger)state {
    switch ((InterRoomConnectionState)state) {
        case InterRoomConnectionStateConnected:             return InterNetworkQualityLevelExcellent;
        case InterRoomConnectionStateReconnecting:          return InterNetworkQualityLevelPoor;
        case InterRoomConnectionStateConnecting:            return InterNetworkQualityLevelGood;
        case InterRoomConnectionStateDisconnectedWithError: return InterNetworkQualityLevelLost;
        case InterRoomConnectionStateDisconnected:          return InterNetworkQualityLevelUnknown;
    }
    return InterNetworkQualityLevelUnknown;
}

@end
