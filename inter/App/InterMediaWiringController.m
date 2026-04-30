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
/// Whether the mic is locked by the host (hard mute).
@property (nonatomic, assign, readwrite) BOOL isHostMuted;
/// Whether the host has temporarily allowed us to speak.
@property (nonatomic, assign, readwrite) BOOL isAllowedToSpeak;
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
    InterLocalMediaController *media = self.mediaController;
    InterRoomController *rc = self.roomController;
    BOOL shouldEnable = !media.isCameraEnabled;

    __weak typeof(self) weakSelf = self;

    if (!shouldEnable) {
        // DISABLE: [G2] Mute LiveKit track FIRST → then stop capture device
        if (rc && rc.connectionState == InterRoomConnectionStateConnected) {
            [rc.publisher muteCameraTrackWithCompletion:^{
                [weakSelf toggleCamera];
            }];
        } else {
            // [G8] No network — just toggle locally
            [self toggleCamera];
        }
    } else {
        // ENABLE: [G2] Start capture device FIRST → first frame → unmute LiveKit track
        [self toggleCamera];
        if (rc && rc.connectionState == InterRoomConnectionStateConnected) {
            [rc.publisher unmuteCameraTrack];
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
        BOOL shouldMute = !self.isMicNetworkMuted;
        __weak typeof(self) weakSelf = self;

        if (shouldMute) {
            [rc.publisher muteMicrophoneTrackWithCompletion:^{
                weakSelf.isMicNetworkMuted = YES;
                [weakSelf.controlPanel setMicrophoneEnabled:NO];
                if (weakSelf.isHostMuted) {
                    // Revoke the one-time speak permission (no-op if already NO)
                    // and show raise-hand title.
                    [weakSelf revokeAllowToSpeak];
                }
                NSString *summary = weakSelf.mediaStateSummaryBlock ? weakSelf.mediaStateSummaryBlock() : nil;
                if (summary) {
                    [weakSelf.controlPanel setMediaStatusText:summary];
                }
            }];
        } else {
            [rc.publisher unmuteMicrophoneTrack];
            self.isMicNetworkMuted = NO;
            [self.controlPanel setMicrophoneEnabled:YES];
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

- (void)applyRemoteMicMute {
    InterRoomController *rc = self.roomController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
    if (!isConnected) return;

    // The server already muted the LiveKit track. Just update local state + UI.
    self.isMicNetworkMuted = YES;
    self.isHostMuted = YES;
    self.isAllowedToSpeak = NO;
    [self.controlPanel setMicrophoneEnabled:NO];
    [self.controlPanel setMicrophoneButtonTitle:@"✋ Raise Hand to Speak"];
    NSString *summary = self.mediaStateSummaryBlock ? self.mediaStateSummaryBlock() : nil;
    if (summary) {
        [self.controlPanel setMediaStatusText:summary];
    }
}

- (void)applyAllowToSpeak {
    InterRoomController *rc = self.roomController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
    if (!isConnected) return;

    // Host allowed us to speak — unmute mic but keep isHostMuted=YES.
    // The "allow" is a one-time grant: if the participant turns mic off,
    // they go back to raise-hand mode.
    self.isAllowedToSpeak = YES;

    if (self.isMicNetworkMuted) {
        // Use force-unmute: the server muted the track via
        // mutePublishedTrack, but the LiveKit SDK may not have
        // processed the WebSocket mute notification yet. A plain
        // track.unmute() would be a no-op in that case.
        // DO NOT update isMicNetworkMuted or the button until the
        // async unmute actually completes — this avoids the state
        // desync where the UI says "Turn Mic Off" but audio is
        // still blocked.
        __weak typeof(self) weakSelf = self;
        [rc.publisher forceUnmuteMicrophoneTrackWithCompletion:^{
            // Guard: if a new requestMuteAll arrived while the async
            // unmute was in flight, isAllowedToSpeak was reset to NO
            // by applyRemoteMicMute. Honour the newer mute — do NOT
            // flip state back to unmuted.
            if (!weakSelf.isAllowedToSpeak) return;
            weakSelf.isMicNetworkMuted = NO;
            [weakSelf.controlPanel setMicrophoneEnabled:YES];
            NSString *summary = weakSelf.mediaStateSummaryBlock ? weakSelf.mediaStateSummaryBlock() : nil;
            if (summary) {
                [weakSelf.controlPanel setMediaStatusText:summary];
            }
        }];
    } else {
        // Track wasn't network-muted (edge case: allowed before
        // requestMuteAll arrived, or re-allowed). Just update UI.
        [self.controlPanel setMicrophoneEnabled:YES];
        NSString *summary = self.mediaStateSummaryBlock ? self.mediaStateSummaryBlock() : nil;
        if (summary) {
            [self.controlPanel setMediaStatusText:summary];
        }
    }
}

- (void)applyUnmuteAll {
    InterRoomController *rc = self.roomController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
    if (!isConnected) return;

    // Clear the host-mute lock — participants can now freely toggle.
    // Do NOT auto-unmute. The participant chooses when to turn mic on.
    self.isHostMuted = NO;
    self.isAllowedToSpeak = NO;

    // Show the button matching the ACTUAL mic track state.
    // The track is still muted from the host's mute-all unless the
    // participant was individually allowed to speak and turned it on.
    [self.controlPanel setMicrophoneEnabled:!self.isMicNetworkMuted];
    NSString *summary = self.mediaStateSummaryBlock ? self.mediaStateSummaryBlock() : nil;
    if (summary) {
        [self.controlPanel setMediaStatusText:summary];
    }
}

/// Called after the participant turns mic OFF while isHostMuted is still YES.
/// Revokes the one-time speak permission and puts them back in raise-hand mode.
- (void)revokeAllowToSpeak {
    self.isAllowedToSpeak = NO;
    [self.controlPanel setMicrophoneButtonTitle:@"✋ Raise Hand to Speak"];
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

    // Reset network-level mic mute state when (re-)wiring tracks.
    self.isMicNetworkMuted = NO;

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
