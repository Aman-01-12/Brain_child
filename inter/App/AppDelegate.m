#import "AppDelegate.h"
#import "CapWindow.h"
#import "InterCallSessionCoordinator.h"
#import "InterLocalMediaController.h"
#import "InterLocalCallControlPanel.h"
#import "InterMediaWiringController.h"
#import "InterSurfaceShareController.h"
#import "InterScreenCaptureVideoSource.h"
#import "InterWindowPickerPanel.h"
#import "MetalSurfaceView.h"
#import "SecureWindowController.h"
#import "InterWindowSecurity.h"
#import "InterConnectionSetupPanel.h"
#import "InterLoginPanel.h"
#import "InterRemoteVideoLayoutManager.h"
#import "InterTrackRendererBridge.h"
#import "InterParticipantOverlayView.h"
#import "InterChatPanel.h"
#import "InterPollPanel.h"
#import "InterQAPanel.h"
#import "InterLobbyPanel.h"
#import "InterLobbyWaitingView.h"
#import "InterRecordingIndicatorView.h"
#import "InterRecordingListPanel.h"
#import "InterRecordingConsentPanel.h"
#import "InterSchedulePanel.h"
#import "InterFeatureGate.h"
#import "InterPreMeetingPanel.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AuthenticationServices/AuthenticationServices.h>

// [2.5.1] Swift module import for networking layer
#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

@interface AppDelegate () <NSWindowDelegate, InterConnectionSetupPanelDelegate, InterLoginPanelDelegate, InterAuthSessionDelegate, InterParticipantOverlayDelegate, InterChatPanelDelegate, InterPollPanelDelegate, InterQAPanelDelegate, InterMediaWiringDelegate, InterModerationDelegate, InterLobbyPanelDelegate, InterRecordingCoordinatorDelegate, InterRecordingSignalDelegate, InterRecordingListPanelDelegate, InterRecordingConsentPanelDelegate, InterSchedulePanelDelegate, InterLobbyWaitingViewDelegate, ASWebAuthenticationPresentationContextProviding, InterPreMeetingPanelDelegate>
@property (nonatomic, strong) NSMutableArray<CapWindow *> *capWindows;
@property (nonatomic, strong) SecureWindowController *secureController;
@property (nonatomic, strong) NSWindow *setupWindow;
@property (nonatomic, strong) NSView *setupRenderView;
@property (nonatomic, strong) NSWindow *settingsWindow;
@property (nonatomic, strong) NSWindow *normalCallWindow;
@property (nonatomic, strong) NSView *normalRenderView;
@property (nonatomic, strong) InterLocalMediaController *normalMediaController;
@property (nonatomic, strong) InterSurfaceShareController *normalSurfaceShareController;
@property (nonatomic, strong) InterCallControlBarBridge *normalControlPanel;
@property (nonatomic, strong) InterCallSessionCoordinator *sessionCoordinator;
@property (nonatomic, strong, nullable) InterConnectionSetupPanel *connectionPanel;
@property (nonatomic, strong, nullable) InterRemoteVideoLayoutManager *normalRemoteLayout;
@property (nonatomic, strong, nullable) InterTrackRendererBridge *normalTrackRendererBridge;
@property (nonatomic, strong, nullable) InterMediaWiringController *normalMediaWiring;
/// Transient bottom-left toast that alerts the host to new waiting-room arrivals.
@property (nonatomic, strong, nullable) InterLobbyToastPresenter *normalLobbyToast;
/// Transient toast that alerts the host/co-host to new in-call requests
/// (raise hand, screen share, unlock). Stacked just above the lobby toast.
@property (nonatomic, strong, nullable) InterLobbyToastPresenter *normalRequestToast;

// [Phase 8] In-meeting communication
@property (nonatomic, strong, nullable) InterChatController *chatController;
@property (nonatomic, strong, nullable) InterChatPanel *normalChatPanel;
@property (nonatomic, strong, nullable) InterSpeakerQueue *speakerQueue;
@property (nonatomic, strong, nullable) InterScreenShareQueue *screenShareQueue;
@property (nonatomic, strong, nullable) InterCameraUnlockQueue *cameraUnlockQueue;
@property (nonatomic, strong, nonnull) InterMicUnlockQueue *micUnlockQueue;
/// Identities of participants individually muted by the host via the tile three-dot menu.
/// Used to show the "Allow" button in the speaker queue for those participants' raise-hand entries.
@property (nonatomic, strong, nonnull) NSMutableSet<NSString *> *hostMutedParticipants;
/// YES while the local participant is individually host-muted (per-participant mute, not Mute All).
/// Tracked separately because localIdentity is never stored in hostMutedParticipants (remote-only set).
@property (nonatomic) BOOL localMicHostMuted;

// [Phase 8.5] Live polls
@property (nonatomic, strong, nullable) InterPollController *pollController;
@property (nonatomic, strong, nullable) InterPollPanel *normalPollPanel;
@property (nonatomic, strong, nullable) NSWindow *normalPollWindow;

// [Phase 8.6] Q&A
@property (nonatomic, strong, nullable) InterQAController *qaController;
@property (nonatomic, strong, nullable) InterQAPanel *normalQAPanel;
@property (nonatomic, strong, nullable) NSWindow *normalQAWindow;

// [Phase 9] Meeting management
@property (nonatomic, strong, nullable) InterModerationController *moderationController;
@property (nonatomic, strong, nullable) InterLobbyPanel *normalLobbyPanel;
@property (nonatomic, strong, nullable) NSWindow *normalLobbyWindow;
@property (nonatomic, strong, nullable) NSTimer *lobbyPollTimer;
@property (nonatomic, assign) BOOL coHostLocalRecordingAllowed;

// Participant-side lobby waiting state
@property (nonatomic, strong, nullable) NSWindow *lobbyWaitingWindow;
@property (nonatomic, strong, nullable) InterLobbyWaitingView *lobbyWaitingView;
@property (nonatomic, strong, nullable) NSTimer *lobbyStatusPollTimer;
@property (nonatomic, copy, nullable) NSString *lobbyPollToken;
@property (nonatomic, copy, nullable) NSString *lobbyRoomCode;
@property (nonatomic, copy, nullable) NSString *lobbyIdentity;
@property (nonatomic, copy, nullable) NSString *lobbyTokenServerURL;
@property (nonatomic, copy, nullable) NSString *lobbyServerURL;
@property (nonatomic, copy, nullable) NSString *lobbyDisplayName;
@property (nonatomic, copy, nullable) NSString *normalChatSelectedRecipient;
@property (nonatomic, assign) BOOL normalShareSystemAudioEnabled;
@property (nonatomic, assign) BOOL isScreenObserverRegistered;
@property (nonatomic, assign) BOOL isShowingExternalDisplayAlert;
/// Guards the forced-exit flow (host removed us / ended the meeting) so the
/// LiveKit-disconnect path and the DataChannel-signal path cannot both show the
/// message, and so the host's own end-for-all does not show itself a "meeting
/// ended" dialog. Reset when a new call is entered.
@property (nonatomic, assign) BOOL isHandlingForcedExit;
@property (nonatomic, weak) NSWindow *fullScreenExitPendingWindow;
/// [R4] Tracks an outstanding screen share request awaiting host approval.
@property (nonatomic, assign) BOOL normalShareRequestPending;
/// [R4] Stores the identity of the participant whose screen share request we (as host) are reviewing.
@property (nonatomic, copy, nullable) NSString *normalPendingShareRequestIdentity;

// [Phase 10] Recording
@property (nonatomic, strong, nullable) InterRecordingCoordinator *normalRecordingCoordinator;
@property (nonatomic, strong, nullable) InterRecordingIndicatorView *normalRecordingIndicatorView;
@property (nonatomic, strong, nullable) InterRecordingListPanel *normalRecordingListPanel;
@property (nonatomic, strong, nullable) NSWindow *normalRecordingListWindow;
@property (nonatomic, strong, nullable) InterRecordingConsentPanel *normalRecordingConsentPanel;
/// YES once recording consent has been shown/handled for the CURRENT recording session,
/// so it is not re-prompted on reconnect. Reset when recording stops or a new call starts.
@property (nonatomic, assign) BOOL normalRecordingConsentHandled;

// [Phase 11] Scheduling
@property (nonatomic, strong, nullable) InterSchedulePanel *normalSchedulePanel;
@property (nonatomic, strong, nullable) NSWindow *normalScheduleWindow;

// [Phase 11.1] Calendar service
@property (nonatomic, strong, nullable) InterCalendarService *calendarService;

// [Phase 11.4] Teams
@property (nonatomic, strong, nullable) InterTeamsPanelBridge *teamsPanel;
@property (nonatomic, strong, nullable) NSWindow *teamsWindow;

// [Phase 11.5] Account management
// [Settings] Unified settings window (SwiftUI) — account + meetings + devices.
@property (nonatomic, strong, nullable) InterSettingsHostView *settingsHostView;

// [2.5.2] Room controller — persists across mode transitions [G4]
@property (nonatomic, strong, nullable) InterRoomController *roomController;

// [Phase B.4d] Auth — login/register panel and window
@property (nonatomic, strong, nullable) NSWindow *loginWindow;
@property (nonatomic, strong, nullable) InterLoginPanel *loginPanel;

// Container view for auth-dependent controls (Sign In/Out, Settings, Billing)
// on the setup screen. Rebuilt in-place when auth state changes without
// tearing down the setup window or losing the connection panel’s field values.
@property (nonatomic, strong, nullable) NSView *setupChromeView;

// Billing — upgrade/manage buttons on setup overlay
@property (nonatomic, assign) BOOL isBillingPollInProgress;
@property (nonatomic, assign) NSUInteger billingPollGeneration;

// [G3] Idle timeout — reauthentication after 30 min inactivity
@property (nonatomic, strong, nullable) NSDate *lastUserActivityAt;
@property (nonatomic, strong, nullable) NSTimer *idleCheckTimer;
@property (nonatomic, assign) BOOL isIdleLocked;
@property (nonatomic, strong, nullable) id globalEventMonitor;
@property (nonatomic, strong, nullable) id localEventMonitor;

// [Phase F] OAuth — ASWebAuthenticationSession retained during flow
@property (nonatomic, strong, nullable) ASWebAuthenticationSession *oauthSession;

// Pre-meeting settings panel — shown to host before creating the room
@property (nonatomic, strong, nullable) NSWindow *preMeetingWindow;
@property (nonatomic, strong, nullable) InterPreMeetingPanel *preMeetingPanel;
/// Standalone editor for the host's default meeting settings (opened from Settings).
@property (nonatomic, strong, nullable) NSWindow *meetingDefaultsWindow; // legacy — always nil now
@property (nonatomic, strong, nullable) InterPreMeetingPanel *meetingDefaultsPanel; // legacy — always nil now
/// Host-configured settings gathered from the pre-meeting panel. Consumed once
/// in connectAndEnterMode: and cleared after launch.
@property (nonatomic, strong, nullable) InterPreMeetingSettings *pendingMeetingSettings;
/// The current meeting password (plaintext) as known to THIS host this session. Set from
/// the pre-meeting settings at launch and updated when the host sets/changes/removes it.
/// Lets the moderation menu reflect whether a password is set and offer view/copy/change.
@property (nonatomic, copy, nullable) NSString *currentMeetingPassword;
/// The connection panel whose host-call action was intercepted. Kept alive while
/// the pre-meeting panel is open so we can hand control back on cancel.
@property (nonatomic, weak, nullable) InterConnectionSetupPanel *pendingConnectionPanel;

// [Green room] Pre-join device check — every connect path passes through it.
@property (nonatomic, strong, nullable) NSWindow *greenRoomWindow;
@property (nonatomic, strong, nullable) InterGreenRoomHostView *greenRoomHost;
/// User's green-room device choices. "WantsOff" semantics so the BOOL default
/// (NO = device on) is safe; they can only ADD restriction on top of the
/// host's muteOnJoin / cameraOffOnJoin enforcement, never lift it. Consumed
/// and reset by startNormalLocalMediaFlow.
@property (nonatomic, assign) BOOL greenRoomWantsMicOff;
@property (nonatomic, assign) BOOL greenRoomWantsCamOff;
/// Display name edited in the green room; overrides panel.displayName for the
/// next connect/join, then clears.
@property (nonatomic, copy, nullable) NSString *pendingDisplayNameOverride;
/// Scheduled meeting flowing through the green room: the meeting to start when
/// the green room submits (nil = plain code join). Set by the schedule panel
/// delegate, consumed in greenRoomDidSubmitWithRole:, cleared on cancel.
@property (nonatomic, copy, nullable) NSString *pendingScheduledMeetingId;
/// IDs of upcoming meetings the signed-in user HOSTS (from the last schedule
/// fetch). Decides the green room's CTA: Start Meeting vs Join Now.
@property (nonatomic, copy, nullable) NSSet<NSString *> *hostedScheduledMeetingIds;

@end

@implementation AppDelegate

static NSString *const InterScreenCaptureStartupPromptedKey = @"InterScreenCaptureStartupPrompted";

static BOOL InterShouldEnforceInterviewExternalDisplayPolicy(void) {
    // Temporary testing bypass:
    // Secure interview mode normally blocks multiple displays for the interviewee path.
    // We are intentionally disabling only that enforcement while validating the new
    // secure tool-surface workflow. Re-enable this by returning YES once the refined
    // policy is ready.
    return NO;
}

static void InterTeardownSetupWindow(NSWindow *__strong *windowRef,
                                     NSView *__strong *renderViewRef,
                                     InterConnectionSetupPanel *__strong *connectionPanelRef) {
    NSView *renderView = *renderViewRef;
    if (renderView != nil) {
        [renderView removeFromSuperview];
        *renderViewRef = nil;
    }

    NSWindow *window = *windowRef;
    if (window != nil) {
        [window orderOut:nil];
        *windowRef = nil;
    }

    if (connectionPanelRef != NULL) {
        *connectionPanelRef = nil;
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Register the bundled General Sans faces before any UI mounts so the design-system
    // typography resolves (NSFont(name:"General Sans",…)) instead of falling back to SF.
    [InterDesignTokens registerFonts];

    // Debug-only: open the SwiftUI component gallery when launched with
    // `--component-gallery` (or INTER_COMPONENT_GALLERY=1). No-op in normal runs.
    [ComponentGallery presentIfLaunchFlagPresent];

    // [Finding 11] Register InterAudioEngineAccess as the head of LiveKit's engine-observer
    // chain BEFORE any room connects so engineWillStart fires and the engine ref is captured.
    [InterAudioEngineAccess register];

    self.sessionCoordinator = [[InterCallSessionCoordinator alloc] init];

    // [2.5.2] Create room controller. [G8] If this fails, app continues as local-only
    @try {
        self.roomController = [[InterRoomController alloc] init];
    } @catch (NSException *exception) {
        NSLog(@"[G8] InterRoomController creation failed: %@. Continuing local-only.", exception.reason);
        self.roomController = nil;
    }

    // [B1] Create shared media wiring controller for KVO + toggle logic
    self.normalMediaWiring = [[InterMediaWiringController alloc] init];
    self.normalMediaWiring.roomController = self.roomController;
    self.normalMediaWiring.delegate = self;
    [self.normalMediaWiring setupRoomControllerKVO];

    // [Phase 8] Create chat controller and speaker queue
    self.chatController = [[InterChatController alloc] init];
    self.speakerQueue = [[InterSpeakerQueue alloc] init];
    self.screenShareQueue = [[InterScreenShareQueue alloc] init];
    self.cameraUnlockQueue = [[InterCameraUnlockQueue alloc] init];
    self.micUnlockQueue = [[InterMicUnlockQueue alloc] init];
    self.hostMutedParticipants = [NSMutableSet set];

    // [Phase 8.5] Create poll controller
    self.pollController = [[InterPollController alloc] init];

    // [Phase 8.6] Create Q&A controller
    self.qaController = [[InterQAController alloc] init];

    // [Phase 9] Create moderation controller
    self.moderationController = [[InterModerationController alloc] init];
    self.moderationController.delegate = self;

    // [Phase 10] Create recording coordinator
    self.normalRecordingCoordinator = [[InterRecordingCoordinator alloc] init];
    self.normalRecordingCoordinator.delegate = self;

    // [Phase 11.1] Create calendar service for EventKit integration
    self.calendarService = [[InterCalendarService alloc] init];

    if (self.roomController) {
        self.roomController.chatController = self.chatController;
        self.roomController.pollController = self.pollController;
        self.roomController.qaController = self.qaController;
        // [Phase 10] Wire recording coordinator for room disconnect auto-stop
        self.roomController.recordingCoordinator = self.normalRecordingCoordinator;
        // Wire moderation controller into chat controller for Phase 9 signal forwarding
        self.chatController.moderationController = self.moderationController;
    }

    // [Phase B.4d] Wire auth delegate and attempt session restore before showing setup UI.
    // If a valid refresh token exists in Keychain, silently restore the session.
    // Otherwise, show the login window.
    if (self.roomController) {
        self.roomController.tokenService.authDelegate = self;
        NSString *tokenServerURL = [[NSUserDefaults standardUserDefaults]
            stringForKey:@"InterDefaultTokenServerURL"];
        if (!tokenServerURL.length) {
            tokenServerURL = @"http://localhost:3000";
        }
        __weak typeof(self) weakSelf = self;
        [self.roomController.tokenService attemptSessionRestoreWithServerURL:tokenServerURL
                                                                  completion:^(InterSessionRestoreResult result) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { return; }
            switch (result) {
                case InterSessionRestoreResultRestored:
                    NSLog(@"[Auth] Session restored — tier=%@",
                          strongSelf.roomController.tokenService.currentTier ?: @"unknown");
                    break;
                case InterSessionRestoreResultOfflineWithPersistedSession:
                    NSLog(@"[Auth] Server unreachable — entering offline mode (cached user=%@)",
                          strongSelf.roomController.tokenService.currentDisplayName ?: @"unknown");
                    break;
                case InterSessionRestoreResultNoSession:
                    NSLog(@"[Auth] No saved session — launching in unauthenticated mode");
                    break;
            }
            [strongSelf launchSetupUI];
            [strongSelf preflightMediaPermissions];
        }];
    } else {
        // No room controller (local-only) — skip auth, launch directly
        [self launchSetupUI];
        [self preflightMediaPermissions];
    }

    // [G3] Idle timeout — track user activity for reauthentication prompt
    [self setupIdleTimeout];
}

- (InterCallMode)currentCallMode {
    return self.sessionCoordinator.currentCallMode;
}

- (InterInterviewRole)currentInterviewRole {
    return self.sessionCoordinator.currentInterviewRole;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
#pragma unused(notification)
    [self stopScreenMonitoring];

    InterTeardownSetupWindow(&_setupWindow, &_setupRenderView, &_connectionPanel);
    if (self.settingsWindow != nil) {
        [self.settingsWindow orderOut:nil];
    }
    [self teardownActiveWindows];

    // [2.5.7] Disconnect room on app terminate
    [self.normalMediaWiring teardownRoomControllerKVO];
    self.normalMediaWiring = nil;

    // [Phase 8] Clean up chat controller
    [self.chatController detach];
    [self.chatController reset];
    self.chatController = nil;
    self.speakerQueue = nil;

    // [Phase 8.5] Clean up poll controller
    [self.pollController detach];
    [self.pollController reset];
    self.pollController = nil;

    // [Phase 8.6] Clean up Q&A controller
    [self.qaController detach];
    [self.qaController reset];
    self.qaController = nil;

    // [Phase 9] Clean up moderation controller
    [self.moderationController detach];
    self.moderationController = nil;

    // [Phase 10] Stop any active recording
    if (self.normalRecordingCoordinator.canStop) {
        [self.normalRecordingCoordinator stopRecording];
    }
    self.normalRecordingCoordinator = nil;

    if (self.roomController) {
        [self.roomController disconnect];
        self.roomController = nil;
    }

    if (self.fullScreenExitPendingWindow) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSWindowDidExitFullScreenNotification
                                                      object:self.fullScreenExitPendingWindow];
        self.fullScreenExitPendingWindow = nil;
    }

    // [G3] Stop idle check timer and remove event monitors
    [self.idleCheckTimer invalidate];
    self.idleCheckTimer = nil;
    if (self.globalEventMonitor) {
        [NSEvent removeMonitor:self.globalEventMonitor];
        self.globalEventMonitor = nil;
    }
    if (self.localEventMonitor) {
        [NSEvent removeMonitor:self.localEventMonitor];
        self.localEventMonitor = nil;
    }
}

- (void)preflightMediaPermissions {
    dispatch_group_t permissionGroup = dispatch_group_create();

    dispatch_group_enter(permissionGroup);
    [InterLocalMediaController preflightCapturePermissionsWithCompletion:^(__unused AVAuthorizationStatus videoStatus,
                                                                           __unused AVAuthorizationStatus audioStatus) {
        dispatch_group_leave(permissionGroup);
    }];

    dispatch_group_enter(permissionGroup);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        BOOL hasAccess = [InterScreenCaptureVideoSource preflightScreenCaptureAccess];
        if (hasAccess) {
            [defaults setBool:YES forKey:InterScreenCaptureStartupPromptedKey];
            dispatch_group_leave(permissionGroup);
            return;
        }

        BOOL hasPromptedBefore = [defaults boolForKey:InterScreenCaptureStartupPromptedKey];
        if (!hasPromptedBefore) {
            [InterScreenCaptureVideoSource requestScreenCaptureAccessIfNeeded];
            [defaults setBool:YES forKey:InterScreenCaptureStartupPromptedKey];
        }

        dispatch_group_leave(permissionGroup);
    });

    dispatch_group_notify(permissionGroup, dispatch_get_main_queue(), ^{
        // Intentionally no UI interruption here. Call flows already handle denied states.
    });
}

#pragma mark - Mode Actions

- (void)startNormalCallMode {
    [self enterMode:InterCallModeNormal role:InterInterviewRoleNone];
}

- (void)createInterviewAsInterviewer {
    [self enterMode:InterCallModeInterview role:InterInterviewRoleInterviewer];
}

- (void)joinInterviewAsInterviewee {
    [self enterMode:InterCallModeInterview role:InterInterviewRoleInterviewee];
}

- (void)enterInterviewMode {
    
    [self joinInterviewAsInterviewee];
}

- (void)exitCurrentMode {
    if (![self.sessionCoordinator beginExit]) {
        return;
    }

    BOOL shouldExitFullScreenFirst =
    self.normalCallWindow != nil &&
    ((self.normalCallWindow.styleMask & NSWindowStyleMaskFullScreen) == NSWindowStyleMaskFullScreen);

    if (shouldExitFullScreenFirst) {
        self.fullScreenExitPendingWindow = self.normalCallWindow;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleNormalWindowDidExitFullScreen:)
                                                     name:NSWindowDidExitFullScreenNotification
                                                   object:self.fullScreenExitPendingWindow];
        [self.fullScreenExitPendingWindow toggleFullScreen:nil];

        // Fallback: avoid getting stuck in exit state if fullscreen callback is missed.
        __weak typeof(self) weakSelf = self;
        NSWindow *pendingWindow = self.fullScreenExitPendingWindow;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf ||
                strongSelf.sessionCoordinator.phase != InterCallSessionPhaseExiting) {
                return;
            }
            if (strongSelf.fullScreenExitPendingWindow != pendingWindow) {
                return;
            }

            [[NSNotificationCenter defaultCenter] removeObserver:strongSelf
                                                            name:NSWindowDidExitFullScreenNotification
                                                          object:pendingWindow];
            strongSelf.fullScreenExitPendingWindow = nil;
            [strongSelf finalizeCurrentModeExit];
        });
        return;
    }

    [self finalizeCurrentModeExit];
}

- (void)exitInterviewMode {
    [self exitCurrentMode];
}

- (void)requestExitCurrentMode {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.currentCallMode == InterCallModeNone) {
            [self exitCurrentMode];
            return;
        }
        // The host gets the choice to end the meeting for everyone or just leave;
        // everyone else simply leaves.
        if (self.roomController.isHost) {
            [self confirmHostEndCall];
        } else {
            [self confirmEndCallWithMessage:@"Leave this call?"
                         confirmButtonTitle:@"Leave"
                                 completion:^{ [self exitCurrentMode]; }];
        }
    });
}

/// Host-only end-call dialog: end the meeting for all participants, or just leave
/// while the meeting continues for others.
- (void)confirmHostEndCall {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"End meeting";
    alert.informativeText = @"End the meeting for everyone, or just leave? "
                            @"If you leave, the meeting continues for the other participants.";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"End for All"];   // NSAlertFirstButtonReturn
    [alert addButtonWithTitle:@"Leave"];          // NSAlertSecondButtonReturn
    [alert addButtonWithTitle:@"Cancel"];         // NSAlertThirdButtonReturn

    void (^handle)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            // End for All — delete the room server-side; suppress our own
            // room-ended alert since this exit is self-initiated.
            self.isHandlingForcedExit = YES;
            if (self.moderationController) {
                [self.moderationController endMeetingForAll:^(BOOL success, NSError * _Nullable error) {
                    if (!success) {
                        NSLog(@"[EndCall] endMeetingForAll failed: %@. Leaving locally.",
                              error.localizedDescription);
                    }
                    [self exitCurrentMode];
                }];
            } else {
                // No moderation channel (e.g. guest host) — fall back to leaving.
                [self exitCurrentMode];
            }
        } else if (response == NSAlertSecondButtonReturn) {
            // Leave — disconnect self only; the meeting continues for others.
            [self exitCurrentMode];
        }
        // NSAlertThirdButtonReturn (Cancel) — do nothing.
    };

    NSWindow *targetWindow = self.normalCallWindow ?: [NSApp keyWindow];
    if (targetWindow) {
        [alert beginSheetModalForWindow:targetWindow completionHandler:handle];
    } else {
        handle([alert runModal]);
    }
}

/// Shared handler for an involuntary exit (the host removed us, or ended the
/// meeting for everyone). Shows a specific message, then tears the call down
/// without the usual "are you sure?" confirmation. Deduplicated so the LiveKit
/// disconnect path and the DataChannel signal path cannot both fire.
- (void)handleForcedExitWithTitle:(NSString *)title message:(NSString *)message {
    if (self.isHandlingForcedExit) return;
    if (self.currentCallMode == InterCallModeNone) return;
    self.isHandlingForcedExit = YES;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];

    [self exitCurrentMode];
}

/// Shared helper: presents an NSAlert on the main queue with a destructive confirm button
/// and a Cancel button. Calls `completion` only if the user confirms.
- (void)confirmEndCallWithMessage:(NSString *)message
               confirmButtonTitle:(NSString *)confirmTitle
                       completion:(dispatch_block_t)completion {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:confirmTitle];
    [alert addButtonWithTitle:@"Cancel"];

    // Run as a sheet anchored to whichever call window is key, so the app doesn't
    // lose focus and the rest of the UI stays visible behind the alert.
    NSWindow *targetWindow = self.normalCallWindow ?: [NSApp keyWindow];
    if (targetWindow) {
        [alert beginSheetModalForWindow:targetWindow completionHandler:^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn) {
                completion();
            }
        }];
    } else {
        // Fallback: no window to attach to (should not happen in practice).
        NSModalResponse response = [alert runModal];
        if (response == NSAlertFirstButtonReturn) {
            completion();
        }
    }
}

- (void)enterMode:(InterCallMode)mode role:(InterInterviewRole)role {
    BOOL isIntervieweeMode = (mode == InterCallModeInterview && role == InterInterviewRoleInterviewee);
    if (isIntervieweeMode &&
        InterShouldEnforceInterviewExternalDisplayPolicy() &&
        [NSScreen screens].count > 1) {
        [self showExternalDisplayAlert];
        return;
    }

    if (![self.sessionCoordinator beginEnteringMode:mode role:role]) {
        return;
    }

    // A new call clears any prior forced-exit guard (removed / meeting ended).
    self.isHandlingForcedExit = NO;
    // A new call resets the recording-consent guard so the overlay can show again.
    self.normalRecordingConsentHandled = NO;

    // Lock the tier for the duration of this meeting so that mid-meeting
    // token refreshes (which may carry a tier change) do not affect the
    // active session.
    [self.roomController.tokenService lockTierForMeeting];

    // teardownActiveWindows nils pendingMeetingSettings, but applyMeetingSettingsAfterLaunch
    // (called later in this same enterMode pass via launchNormalCallWindow) still needs the
    // host's pre-meeting choices — share-takeover policy, co-host recording, meeting title,
    // auto-record. Preserve them across teardown and restore immediately after so the host's
    // in-session state matches the pre-meeting settings modal.
    InterPreMeetingSettings *preservedMeetingSettings = self.pendingMeetingSettings;
    [self teardownActiveWindows];
    self.pendingMeetingSettings = preservedMeetingSettings;
    [self.settingsWindow orderOut:nil];
    InterTeardownSetupWindow(&_setupWindow, &_setupRenderView, &_connectionPanel);

    // [Phase 8] Attach chat controller to room after connect
    if (self.roomController && self.chatController) {
        InterRoomConfiguration *cfg = nil;
        // The configuration is internal to the room controller; use the identity
        // we stored from the connect flow. Fall back to a generated identity.
        NSString *identity = self.roomController.localParticipantIdentity;
        if (identity.length == 0) identity = [[NSUUID UUID] UUIDString];
        NSString *displayName = self.roomController.localParticipantName;
        [self.chatController attachTo:self.roomController identity:identity displayName:displayName];
    }

    // [Phase 8.5] Attach poll controller to room
    if (self.roomController && self.pollController) {
        NSString *identity = self.roomController.localParticipantIdentity;
        if (identity.length == 0) identity = [[NSUUID UUID] UUIDString];
        BOOL isHost = self.roomController.isHost;
        [self.pollController attachTo:self.roomController identity:identity isHost:isHost];
    }

    // [Phase 8.6] Attach Q&A controller to room
    if (self.roomController && self.qaController) {
        NSString *identity = self.roomController.localParticipantIdentity;
        if (identity.length == 0) identity = [[NSUUID UUID] UUIDString];
        NSString *displayName = self.roomController.localParticipantName;
        BOOL isHost = self.roomController.isHost;
        [self.qaController attachTo:self.roomController identity:identity displayName:displayName isHost:isHost];
    }

    // [Phase 9] Attach moderation controller to room
    if (self.roomController && self.moderationController) {
        NSString *identity = self.roomController.localParticipantIdentity;
        if (identity.length == 0) identity = [[NSUUID UUID] UUIDString];
        NSString *displayName = self.roomController.localParticipantName;
        NSString *serverBaseURL = self.roomController.tokenServerURL;
        if (serverBaseURL.length == 0) {
            NSLog(@"[Phase 9] WARNING: roomController.tokenServerURL is empty — serverBaseURL would default to localhost. "
                  @"Moderation controller will not be attached. Check token server configuration.");
            // Do not silently fall back to http://localhost:3000 in a connected room context.
        } else {
            NSString *roomCode = self.roomController.roomCode;
            [self.moderationController attachTo:self.roomController identity:identity displayName:displayName serverURL:serverBaseURL roomCode:roomCode];
        }
    }
    [self.speakerQueue reset];
    [self.screenShareQueue reset];
    [self.cameraUnlockQueue reset];
    [self.micUnlockQueue reset];
    [self.normalMediaWiring resetMicUnlockFlowState];
    // Reconnect clears the camera unlock flow: any in-flight request is lost,
    // so the participant must re-request if still locked after rejoining.
    [self.normalMediaWiring resetCameraUnlockFlowState];
    [self.hostMutedParticipants removeAllObjects];

    if (isIntervieweeMode) {
        [self applyKioskRestrictions];
        [self startScreenMonitoring];
        self.secureController = [[SecureWindowController alloc] init];
        // [2.6.1] Pass room controller reference to secure window
        self.secureController.roomController = self.roomController;
        // [8.1.5] Pass chat controller so the chat overlay can receive/send messages
        self.secureController.chatController = self.chatController;
        // [Green room] Hand the candidate's pre-join mic/cam-off choices to the
        // secure media flow, then consume the flags (the normal flow's consumer,
        // startNormalLocalMediaFlow, never runs in interviewee mode).
        self.secureController.startWithMicrophoneOff = self.greenRoomWantsMicOff;
        self.secureController.startWithCameraOff = self.greenRoomWantsCamOff;
        self.greenRoomWantsMicOff = NO;
        self.greenRoomWantsCamOff = NO;
        __weak typeof(self) weakSelf = self;
        self.secureController.exitSessionHandler = ^{
            [weakSelf requestExitCurrentMode];
        };
        [self.secureController createSecureWindow];
        [self.sessionCoordinator markActive];
        return;
    }

    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
    [self stopScreenMonitoring];
    [self launchNormalCallWindow];
    [self startLobbyPollingIfHost];
    [self.sessionCoordinator markActive];
}

#pragma mark - UI

- (void)launchSetupUI {
    InterTeardownSetupWindow(&_setupWindow, &_setupRenderView, &_connectionPanel);

    self.setupWindow =
    [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 600)
                                styleMask:(NSWindowStyleMaskTitled |
                                           NSWindowStyleMaskClosable |
                                           NSWindowStyleMaskMiniaturizable |
                                           NSWindowStyleMaskResizable)
                                  backing:NSBackingStoreBuffered
                                    defer:NO];

    [self.setupWindow center];
    [self.setupWindow setTitle:@"Secure Call Setup"]; // Mission Control/⌘-Tab label; not drawn
    [self.setupWindow setSharingType:InterWindowSharingType()];
    [self.setupWindow setDelegate:self];
    // Seamless chrome (canonical migrated-screen treatment): the home screen
    // extends to the window top; traffic lights float over its surface.
    [InterWindowChrome applySeamlessChromeTo:self.setupWindow];
    [self.setupWindow setMinSize:NSMakeSize(660.0, 600.0)];
    [self.setupWindow setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

    NSView *view = [[NSView alloc] initWithFrame:self.setupWindow.contentView.bounds];
    [view setWantsLayer:YES];
    view.layer.backgroundColor = [NSColor blackColor].CGColor;
    [self.setupWindow setContentView:view];

    self.setupRenderView = [[NSView alloc] initWithFrame:view.bounds];
    self.setupRenderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.setupRenderView];

    [self launchNativeSetupControlsInContainerView:view];

    // Avatar account menu beside the traffic lights — a real titlebar
    // accessory so the full chip is clickable (content under the titlebar
    // band loses hit-testing to the window drag region).
    NSTitlebarAccessoryViewController *avatarAccessory = [self.connectionPanel makeTitlebarAccessory];
    if (avatarAccessory) {
        [self.setupWindow addTitlebarAccessoryViewController:avatarAccessory];
    }

    [self.setupWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)launchNativeSetupControlsInContainerView:(NSView *)containerView {
    // Reset billing poll state from any previous setup window lifecycle.
    self.isBillingPollInProgress = NO;
    self.billingPollGeneration++;

    // [3.1.1] Home / launch screen (SwiftUI via the thin shell). The screen is
    // self-contained: identity, action tiles, join-by-code, billing status and
    // meeting history all live inside it — the loose chrome buttons that used
    // to be built around a small centered panel are gone.
    self.connectionPanel = [[InterConnectionSetupPanel alloc] initWithFrame:containerView.bounds];
    self.connectionPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.connectionPanel.delegate = self;
    [containerView addSubview:self.connectionPanel];

    // Chrome actions → the same AppDelegate handlers the old buttons targeted.
    __weak typeof(self) weakSelf = self;
    self.connectionPanel.onSignIn = ^{ [weakSelf handleSignIn]; };
    self.connectionPanel.onSignOut = ^{ [weakSelf handleLogout]; };
    self.connectionPanel.onOpenSettings = ^{ [weakSelf openSettingsWindow]; };
    self.connectionPanel.onOpenAccountSettings = ^{ [weakSelf openAccountSettingsWindow]; };
    self.connectionPanel.onViewPlans = ^{ [weakSelf handleViewPlans]; };
    self.connectionPanel.onManageSubscription = ^{ [weakSelf handleManageSubscription]; };
    self.connectionPanel.onOpenSchedule = ^{ [weakSelf handleShowSchedulePanel]; };
    self.connectionPanel.onOpenTeams = ^{ [weakSelf openTeamsPanel:nil]; };
    self.connectionPanel.onJoinScheduledMeeting = ^(NSString *roomCode, NSString *meetingId, BOOL isHosted) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        // The home Today strip knows hosted-vs-invited from /meetings/upcoming;
        // seed the hosted set so the green room shows the host chrome even when
        // the schedule window was never opened this launch.
        if (isHosted) {
            NSMutableSet *ids = [NSMutableSet setWithSet:(s.hostedScheduledMeetingIds ?: [NSSet set])];
            [ids addObject:meetingId];
            s.hostedScheduledMeetingIds = ids;
        }
        [s schedulePanel:nil didRequestJoin:roomCode meetingId:meetingId];
    };

    // Feed the screen its auth/tier/identity source and render the right state
    // (signed out / signed in / offline-with-persisted-session) from the first frame.
    [self.connectionPanel configureWithTokenService:self.roomController.tokenService];

    if (self.roomController && self.roomController.tokenService) {
        NSString *tier = self.roomController.tokenService.currentTier ?: @"free";
        [self.connectionPanel setHostInterviewButtonRequiresPro:
            ![InterFeatureGate isFeature:InterFeatureHostInterview availableForTier:tier]];
    }
}

/// Re-render the auth-dependent chrome in-place without tearing down the setup
/// window. The screen owns the chrome now — this just pushes fresh auth state.
- (void)refreshSetupChrome {
    // Keep the settings window's auth gate live (it may be open during sign-in/out).
    if (self.settingsHostView && self.settingsWindow.isVisible) {
        InterTokenService *ts = self.roomController.tokenService;
        [self.settingsHostView setTier:ts.currentTier ?: @"free"];
        [self.settingsHostView reload];
    }
    if (!self.connectionPanel || !self.connectionPanel.superview) {
        return;
    }
    [self.connectionPanel refreshAuthChrome];
    // Update feature tier badges whenever auth/tier state changes.
    // This runs every time the user signs in, token refreshes, or tier changes.
    if (self.roomController && self.roomController.tokenService) {
        NSString *tier = self.roomController.tokenService.currentTier ?: @"free";
        [self.connectionPanel setHostInterviewButtonRequiresPro:
            ![InterFeatureGate isFeature:InterFeatureHostInterview availableForTier:tier]];
    }
}

#pragma mark - Auth Login Window [Phase B.4d]

/// Show the login window so the user can sign in or create an account.
/// Called from the "Sign In / Sign Up" button on the unauthenticated setup screen.
- (void)handleSignIn {
    [self showLoginWindow];
    [self.loginPanel setRegisterMode:NO];
}

/// Same window, preset to the register form (settings gate "Sign Up" button).
- (void)handleSignUp {
    [self showLoginWindow];
    [self.loginPanel setRegisterMode:YES];
}

/// Auth-gated action: user tapped Settings while not signed in.
- (void)handleSettingsRequiresAuth {
    [self.connectionPanel setStatusText:@"Sign in to access settings."];
}

#pragma mark - Schedule Panel [Phase 11]

/// Show or bring to front the scheduling floating window.
- (void)handleShowSchedulePanel {
    if (![self requireFeature:InterFeatureScheduledMeetings]) return;
    if (self.normalScheduleWindow) {
        // Fresh visit: stale status ("Meeting scheduled!") must not persist.
        [self.normalSchedulePanel setStatusText:@""];
        [self.normalScheduleWindow makeKeyAndOrderFront:nil];
        [self reloadScheduleData];
        return;
    }

    CGFloat panelWidth  = 780;
    CGFloat panelHeight = 700;
    NSRect screenFrame  = [[NSScreen mainScreen] visibleFrame];
    CGFloat x = NSMidX(screenFrame) - panelWidth / 2.0;
    CGFloat y = NSMidY(screenFrame) - panelHeight / 2.0;

    self.normalSchedulePanel = [[InterSchedulePanel alloc] initWithFrame:NSMakeRect(0, 0, panelWidth, panelHeight)];
    self.normalSchedulePanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.normalSchedulePanel.delegate = self;

    self.normalScheduleWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(x, y, panelWidth, panelHeight)
                                                            styleMask:(NSWindowStyleMaskTitled |
                                                                       NSWindowStyleMaskClosable |
                                                                       NSWindowStyleMaskResizable |
                                                                       NSWindowStyleMaskMiniaturizable)
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO];
    self.normalScheduleWindow.title = @"Schedule Meeting"; // Mission Control/⌘-Tab label; not drawn
    self.normalScheduleWindow.minSize = NSMakeSize(680, 560);
    self.normalScheduleWindow.releasedWhenClosed = NO;
    self.normalScheduleWindow.level = NSFloatingWindowLevel;
    [self.normalScheduleWindow setSharingType:InterWindowSharingType()];
    [self.normalScheduleWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    // Seamless chrome (canonical migrated-screen treatment): no title-bar band —
    // content extends to the window top; the calendar rail insets below the
    // floating traffic lights.
    [InterWindowChrome applySeamlessChromeTo:self.normalScheduleWindow];
    self.normalScheduleWindow.contentView = self.normalSchedulePanel;
    [self.normalScheduleWindow makeKeyAndOrderFront:nil];

    [self reloadScheduleData];
}

/// Fetch upcoming meetings from the server and populate the panel.
- (void)reloadScheduleData {
    if (!self.normalSchedulePanel) return;
    InterTokenService *ts = self.roomController.tokenService;
    [ts fetchUpcomingMeetingsWithCompletion:^(NSArray<NSDictionary<NSString *,id> *> * _Nullable hostedArr, NSArray<NSDictionary<NSString *,id> *> * _Nullable invitedArr, NSError * _Nullable error) {
        if (error) {
            NSLog(@"[Schedule] Failed to fetch meetings: %@", error.localizedDescription);
            return;
        }

        NSMutableArray<InterScheduledMeeting *> *hosted  = [NSMutableArray array];
        NSMutableArray<InterScheduledMeeting *> *invited = [NSMutableArray array];

        for (NSDictionary *dict in hostedArr) {
            InterScheduledMeeting *m = [self meetingFromDictionary:dict];
            if (m) [hosted addObject:m];
        }
        for (NSDictionary *dict in invitedArr) {
            InterScheduledMeeting *m = [self meetingFromDictionary:dict];
            if (m) [invited addObject:m];
        }

        // Cache hosted IDs so the green room can label scheduled starts
        // "Start Meeting" (host) vs "Join Now" (invitee).
        NSMutableSet<NSString *> *hostedIds = [NSMutableSet set];
        for (InterScheduledMeeting *m in hosted) {
            if (m.meetingId.length > 0) [hostedIds addObject:m.meetingId];
        }
        self.hostedScheduledMeetingIds = hostedIds;

        [self.normalSchedulePanel setUpcomingMeetings:hosted];
        [self.normalSchedulePanel setInvitedMeetings:invited];
    }];
}

/// Parse a meeting JSON dictionary into an InterScheduledMeeting model.
- (InterScheduledMeeting *)meetingFromDictionary:(NSDictionary *)dict {
    InterScheduledMeeting *m = [[InterScheduledMeeting alloc] init];
    m.meetingId          = dict[@"id"] ?: @"";
    m.title              = dict[@"title"] ?: @"(untitled)";
    m.meetingDescription = dict[@"description"];
    m.durationMinutes    = [dict[@"durationMinutes"] integerValue];
    m.roomType           = dict[@"roomType"] ?: @"call";
    m.roomCode           = dict[@"roomCode"];
    m.lobbyEnabled       = [dict[@"lobbyEnabled"] boolValue];
    m.hostTimezone       = dict[@"hostTimezone"] ?: @"";
    m.status             = dict[@"status"] ?: @"scheduled";
    m.inviteeCount       = [dict[@"inviteeCount"] integerValue];

    NSString *dateStr = dict[@"scheduledAt"];
    if (dateStr) {
        NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
        fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        m.scheduledAt = [fmt dateFromString:dateStr];
        if (!m.scheduledAt) {
            // Retry without fractional seconds
            fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime;
            m.scheduledAt = [fmt dateFromString:dateStr];
        }
    }
    return m;
}

#pragma mark - InterSchedulePanelDelegate

- (void)schedulePanel:(InterSchedulePanel *)panel
   didScheduleMeetingWithTitle:(NSString *)title
                   description:(NSString *)description
                   scheduledAt:(NSDate *)scheduledAt
               durationMinutes:(NSInteger)duration
                      roomType:(NSString *)roomType
                  hostTimezone:(NSString *)timezone
                      password:(NSString *)password
                  lobbyEnabled:(BOOL)lobbyEnabled
             inviteeEmails:(NSArray<NSString *> *)emails {

    InterTokenService *ts = self.roomController.tokenService;
    // Meeting-settings snapshot: the schedule screen persists its settings
    // section to the shared defaults store synchronously before this delegate
    // fires, so reading the defaults here captures exactly what the user just
    // configured. The server stores the snapshot with the meeting and applies
    // it to the room hash at start — honoring the screen's "these settings
    // will be used" promise for whoever arrives first.
    InterPreMeetingSettings *snap = [InterPreMeetingSettings settingsWithDefaults];
    NSDictionary *settingsDict = @{
        @"muteOnJoin":          @(snap.muteOnJoin),
        @"cameraOffOnJoin":     @(snap.cameraOffOnJoin),
        @"joinBeforeHost":      @(snap.joinBeforeHost),
        @"allowUnmuting":       @(snap.allowUnmuting),
        @"chatPermissions":     snap.chatPermissions ?: @"everyone",
        @"sharingPermissions":  snap.sharingPermissions ?: @"hostOnly",
        @"shareConflictPolicy": snap.shareConflictPolicy ?: @"oneattime",
    };
    [ts scheduleMeetingWithTitle:title
                    description:description
                    scheduledAt:scheduledAt
                durationMinutes:duration
                       roomType:roomType
                   hostTimezone:timezone
                       password:password
                   lobbyEnabled:lobbyEnabled
                       settings:settingsDict
                     completion:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
        // The token service reports non-201 responses as (nil, nil) — a nil
        // result is a FAILURE even when no transport error occurred (this was
        // showing "Meeting scheduled!" while the server 500'd).
        if (error || !result) {
            [panel setStatusText:@"Could not schedule meeting. Please try again."];
            [panel setSubmitting:NO];
            return;
        }
        [panel resetForm];
        [panel setSubmitting:NO];
        [self reloadScheduleData];
        // Keep the home screen's "Today" events strip live.
        [self.connectionPanel reloadMeetings];

        NSString *meetingId = result[@"id"];
        NSString *roomCode  = result[@"roomCode"];

        // Send invitations if emails were provided
        if (meetingId && emails.count > 0) {
            [panel setStatusText:[NSString stringWithFormat:@"Meeting scheduled! Sending %lu invite%@…",
                                  (unsigned long)emails.count, emails.count == 1 ? @"" : @"s"]];
            [self schedulePanel:panel didRequestInviteForMeeting:meetingId emails:emails];
        } else {
            [panel setStatusText:@"Meeting scheduled!"];
        }

        // [Phase 11.1] Sync to Apple Calendar — request permission if not yet granted,
        // then create the event. The permission prompt fires contextually (first schedule).
        if (meetingId) {
            NSString *capMeetingId  = meetingId;
            NSString *capTitle      = title;
            NSString *capDesc       = description;
            NSDate   *capStart      = scheduledAt;
            NSInteger capDuration   = duration;
            NSString *capTimezone   = timezone;
            NSString *capRoomCode   = roomCode;
            InterCalendarService *calSvc = self.calendarService;
            void (^createBlock)(void) = ^{
                [calSvc createEventWithMeetingId:capMeetingId
                                          title:capTitle
                                          notes:capDesc
                                      startDate:capStart
                                durationMinutes:capDuration
                                   hostTimezone:capTimezone
                                       roomCode:capRoomCode];
            };
            if (calSvc.isAuthorized) {
                createBlock();
            } else {
                [calSvc requestAccessWithCompletion:^(BOOL granted) {
                    if (granted) { createBlock(); }
                }];
            }
        }

        // [Phase 11.2.4/11.2.5] Fire-and-forget sync to Google + Outlook
        if (meetingId) {
            InterTokenService *syncTs = self.roomController.tokenService;
            [syncTs syncMeetingToCalendarWithProvider:@"google" meetingId:meetingId completion:^(BOOL s, NSError *e) {
                if (!s) NSLog(@"[Calendar] Google sync failed for %@: %@", meetingId, e.localizedDescription);
            }];
            [syncTs syncMeetingToCalendarWithProvider:@"outlook" meetingId:meetingId completion:^(BOOL s, NSError *e) {
                if (!s) NSLog(@"[Calendar] Outlook sync failed for %@: %@", meetingId, e.localizedDescription);
            }];
        }
    }];
}

- (void)schedulePanel:(InterSchedulePanel *)panel didRequestCancel:(NSString *)meetingId {
    InterTokenService *ts = self.roomController.tokenService;
    [ts cancelMeetingWithMeetingId:meetingId completion:^(BOOL success, NSError * _Nullable error) {
        if (error || !success) {
            NSLog(@"[Schedule] Cancel failed: %@", error.localizedDescription);
            return;
        }
        [self reloadScheduleData];
        [self.connectionPanel reloadMeetings];

        // [Phase 11.1] Remove from Apple Calendar
        [self.calendarService removeEventForMeetingId:meetingId];

        // [Phase 11.2.4/11.2.5] No explicit calendar delete API — sync servers
        // handle deletion via the server-side cancellation flag.
    }];
}

- (void)schedulePanel:(InterSchedulePanel *)panel didRequestJoin:(NSString *)roomCode meetingId:(NSString *)meetingId {
    // Close the schedule window and route through the green room (device
    // check + join-without-video), exactly like the other connect paths.
    [self.normalScheduleWindow orderOut:nil];
    [self.connectionPanel setRoomCodeText:roomCode];
    self.pendingScheduledMeetingId = meetingId;
    BOOL hosted = [self.hostedScheduledMeetingIds containsObject:meetingId];
    [self showGreenRoomWithRole:(hosted ? InterGreenRoomRoleScheduledStart
                                        : InterGreenRoomRoleJoin)
                          panel:self.connectionPanel
                       roomCode:roomCode];
}

/// Join a scheduled meeting. Handles the meeting's password prompt and waiting room
/// exactly like the room-code join, reusing the same overlay/poll/admit infrastructure.
/// Pass a non-nil `password` to retry after a password prompt.
- (void)_joinScheduledMeetingWithRoomCode:(NSString *)roomCode
                                meetingId:(NSString *)meetingId
                                 password:(nullable NSString *)password {
    [self.connectionPanel setStatusText:@"Joining scheduled meeting…"];

    InterRoomController *rc = self.roomController;
    if (!rc) {
        [self.connectionPanel setStatusText:@"Network unavailable — cannot join."];
        return;
    }

    NSString *serverURL   = self.connectionPanel.serverURL;
    NSString *tokenURL    = self.connectionPanel.tokenServerURL;
    // Green-room display-name override, read non-destructively (the password
    // retry re-enters this method and must keep the same chosen name; a fresh
    // override is set on every green-room submit, cleared on cancel).
    NSString *displayName = self.pendingDisplayNameOverride.length > 0
        ? self.pendingDisplayNameOverride : self.connectionPanel.displayName;

    if (displayName.length == 0) {
        [self.connectionPanel setStatusText:@"Enter a display name first."];
        return;
    }

    [self.connectionPanel setActionsEnabled:NO];
    [self.connectionPanel setIndicatorState:InterConnectionIndicatorStateConnecting];

    NSString *identity = [[NSUUID UUID] UUIDString];
    InterRoomConfiguration *config =
        [[InterRoomConfiguration alloc] initWithServerURL:serverURL
                                          tokenServerURL:tokenURL
                                                roomCode:roomCode
                                     participantIdentity:identity
                                         participantName:displayName
                                                  isHost:NO
                                                roomType:@""
                                        maxParticipants:50];
    config.scheduledMeetingId = meetingId;
    // Thread the password (if supplied on retry) so the server can validate it.
    config.meetingPassword = password ?: @"";
    // Host-edited settings from the green room's Meeting Settings sheet —
    // pendingMeetingSettings is only non-nil here when the sheet was saved
    // during THIS green-room session (cleared on cancel/host-create consume).
    InterPreMeetingSettings *override = self.pendingMeetingSettings;
    if (override) {
        config.scheduledSettingsOverride = @{
            @"muteOnJoin":          @(override.muteOnJoin),
            @"cameraOffOnJoin":     @(override.cameraOffOnJoin),
            @"joinBeforeHost":      @(override.joinBeforeHost),
            @"allowUnmuting":       @(override.allowUnmuting),
            @"chatPermissions":     override.chatPermissions ?: @"everyone",
            @"sharingPermissions":  override.sharingPermissions ?: @"hostOnly",
            @"shareConflictPolicy": override.shareConflictPolicy ?: @"oneattime",
        };
        self.pendingMeetingSettings = nil;
    }

    // Store the lobby/overlay state up front (no window shown yet — same as the
    // room-code join after the flicker fix) so the waiting-room poll can reuse the
    // existing lobby infrastructure if the server returns a waiting response.
    [self _storeJoiningOverlayStateWithCode:roomCode
                                   identity:identity
                                displayName:displayName
                                  serverURL:serverURL
                             tokenServerURL:tokenURL];

    __weak typeof(self) weakSelf = self;
    [rc connectWithConfiguration:config completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            InterConnectionSetupPanel *p = strongSelf.connectionPanel;

            if (error) {
                // Password required (1011) or incorrect on retry (1015) — prompt + retry.
                if (error.code == 1011 || error.code == 1015) {
                    BOOL wasIncorrect = (error.code == 1015);
                    [p setActionsEnabled:YES];
                    [p setIndicatorState:InterConnectionIndicatorStateIdle];
                    [p setStatusText:@""];

                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText    = wasIncorrect ? @"Incorrect Password" : @"Password Required";
                    alert.informativeText = wasIncorrect
                        ? @"The password you entered is incorrect. Please try again."
                        : @"This meeting requires a password. Please enter it below.";
                    [alert addButtonWithTitle:@"Join"];
                    [alert addButtonWithTitle:@"Cancel"];
                    alert.alertStyle = NSAlertStyleInformational;

                    NSSecureTextField *pwField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
                    pwField.placeholderString = @"Meeting password";
                    alert.accessoryView = pwField;
                    [alert layout];
                    [alert.window makeFirstResponder:pwField];

                    NSWindow *anchor = strongSelf.setupWindow;
                    void (^handlePw)(NSModalResponse) = ^(NSModalResponse resp) {
                        if (resp == NSAlertFirstButtonReturn) {
                            NSString *entered = pwField.stringValue;
                            if (entered.length == 0) {
                                [p setStatusText:@"Password cannot be empty."];
                                return;
                            }
                            [strongSelf _joinScheduledMeetingWithRoomCode:roomCode meetingId:meetingId password:entered];
                        } else {
                            [p setIndicatorState:InterConnectionIndicatorStateIdle];
                            [p setStatusText:@""];
                        }
                    };
                    if (anchor) {
                        [alert beginSheetModalForWindow:anchor completionHandler:handlePw];
                    } else {
                        handlePw([alert runModal]);
                    }
                    return;
                }

                // Waiting room — present the overlay and start polling (reuses the same
                // /room/lobby-status poll + /room/admit flow as the room-code join).
                if (error.code == 1010) {
                    NSString *pollToken = error.userInfo[@"pollToken"];
                    NSInteger position  = [error.userInfo[@"position"] integerValue];
                    if (!pollToken.length) {
                        [p setActionsEnabled:YES];
                        [p setIndicatorState:InterConnectionIndicatorStateError];
                        [p setStatusText:@"Lobby error — please try again."];
                        return;
                    }
                    [strongSelf _presentJoiningOverlayWindow];
                    [strongSelf _transitionOverlayToWaitingRoomWithPollToken:pollToken position:position];
                    [p setActionsEnabled:YES];
                    [p setIndicatorState:InterConnectionIndicatorStateIdle];
                    [p setStatusText:@""];
                    return;
                }

                [p setActionsEnabled:YES];
                [p setIndicatorState:InterConnectionIndicatorStateError];
                [p setStatusText:[strongSelf userFacingMessageForError:error]];
                return;
            }

            [p setIndicatorState:InterConnectionIndicatorStateConnected];
            [p setStatusText:@"Joined"];
            [p setActionsEnabled:YES];
            NSString *roomType = rc.roomType;
            BOOL isInterviewRoom = [roomType isEqualToString:@"interview"];
            if (isInterviewRoom) {
                if (rc.isHost) {
                    // Returning interview host (e.g. rejoining after a network drop or
                    // after ending the meeting on their side). The server restored
                    // interviewer privileges (server-authoritative isHost via the
                    // authenticated userId binding), so re-enter as interviewer directly.
                    // The candidate consent dialog applies only to interviewees.
                    [strongSelf enterMode:InterCallModeInterview role:InterInterviewRoleInterviewer];
                } else {
                    [strongSelf showIntervieweeConfirmationWithCompletion:^(BOOL accepted) {
                        if (accepted) {
                            [strongSelf enterMode:InterCallModeInterview role:InterInterviewRoleInterviewee];
                        } else {
                            [rc disconnect];
                            [p setIndicatorState:InterConnectionIndicatorStateIdle];
                            [p setStatusText:@"Disconnected — declined interview session."];
                        }
                    }];
                }
            } else {
                [strongSelf enterMode:InterCallModeNormal role:InterInterviewRoleNone];
            }
        });
    }];
}

- (void)schedulePanel:(InterSchedulePanel *)panel didRequestInviteForMeeting:(NSString *)meetingId emails:(NSArray<NSString *> *)emails {
    // Convert email strings to invitee dictionaries expected by the API
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *inviteesDicts = [NSMutableArray arrayWithCapacity:emails.count];
    for (NSString *email in emails) {
        [inviteesDicts addObject:@{@"email": email}];
    }

    InterTokenService *ts = self.roomController.tokenService;
    [ts inviteToMeetingWithMeetingId:meetingId invitees:inviteesDicts completion:^(NSDictionary<NSString *,id> * _Nullable result, NSError * _Nullable error) {
        if (error) {
            NSLog(@"[Schedule] Invite failed: %@", error.localizedDescription);
        } else {
            NSLog(@"[Schedule] Invitations sent for meeting %@", meetingId);
            [self reloadScheduleData];
        }
    }];
}

/// Auth-gated action: user tapped View Plans while not signed in.
- (void)handleBillingRequiresAuth {
    [self.connectionPanel setStatusText:@"Sign in to view plans."];
}

- (void)handleLogout {
    NSLog(@"[Auth] User requested sign out");
    // Clear meeting tier lock before teardown
    [self.roomController.tokenService unlockTierFromMeeting];
    // Tear down any active call session first
    if (self.currentCallMode != InterCallModeNone) {
        [NSApp setPresentationOptions:NSApplicationPresentationDefault];
        [self stopScreenMonitoring];
        [self teardownActiveWindows];
        [self.sessionCoordinator finishExit];
    }
    if (self.roomController) {
        [self.roomController disconnect];
    }
    __weak typeof(self) weakSelf = self;
    if (self.roomController && self.roomController.tokenService) {
        [self.roomController.tokenService logoutWithCompletion:^{
            NSLog(@"[Auth] Signed out");
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                if (strongSelf.setupWindow) {
                    [strongSelf refreshSetupChrome];
                } else {
                    [strongSelf launchSetupUI];
                }
            });
        }];
    } else {
        NSLog(@"[Auth] Signed out");
        if (self.setupWindow) {
            [self refreshSetupChrome];
        } else {
            [self launchSetupUI];
        }
    }
}

- (void)showLoginWindow {
    if (self.loginWindow) {
        [self.loginWindow makeKeyAndOrderFront:nil];
        return;
    }

    self.loginWindow =
    [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 680)
                                styleMask:(NSWindowStyleMaskTitled |
                                           NSWindowStyleMaskClosable)
                                  backing:NSBackingStoreBuffered
                                    defer:NO];
    [self.loginWindow center];
    [self.loginWindow setTitle:@"Inter — Sign In"];
    [self.loginWindow setDelegate:self];
    [self.loginWindow setMinSize:NSMakeSize(460.0, 560.0)];
    // Theme the title bar to the app surface so it matches the SwiftUI content in BOTH
    // appearances. The card token is dynamic, so when the in-screen light/dark toggle
    // updates the window's appearance, the title bar re-resolves with it. (Keeps the
    // visible title + close button — unlike utility panels which hide them.)
    [InterWindowChrome applyWindowTitlebarThemeTo:self.loginWindow];

    NSView *contentView = self.loginWindow.contentView;
    contentView.wantsLayer = YES;
    contentView.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:1.0].CGColor;

    // The auth panel now hosts SwiftUI (`AuthView`), which draws its own themed background
    // and a centred card — so it fills the whole content view rather than being a fixed box.
    self.loginPanel = [[InterLoginPanel alloc] initWithFrame:contentView.bounds];
    self.loginPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.loginPanel.delegate = self;
    [contentView addSubview:self.loginPanel];

    [self.loginWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)dismissLoginWindow {
    if (self.loginWindow) {
        [self.loginWindow orderOut:nil];
        self.loginWindow = nil;
        self.loginPanel = nil;
    }
}

#pragma mark - InterLoginPanelDelegate [Phase B.4d]

- (void)loginPanel:(InterLoginPanel *)panel
    didRequestLoginWithEmail:(NSString *)email
                    password:(NSString *)password {
    [panel setActionsEnabled:NO];
    [panel setLoading:YES];
    [panel clearError];

    NSString *tokenServerURL = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"InterDefaultTokenServerURL"];
    if (!tokenServerURL.length) {
        tokenServerURL = @"http://localhost:3000";
    }

    __weak typeof(self) weakSelf = self;
    [self.roomController.tokenService loginWithEmail:email
                                            password:password
                                           serverURL:tokenServerURL
                                          completion:^(InterAuthResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }
        [panel setLoading:NO];
        [panel setActionsEnabled:YES];
        if (error) {
            // Server auth errors (e.g. "Invalid credentials") are safe to display.
            // Transport errors (code 1005) get a generic message (T3).
            NSString *msg = (error.code == 1005)
                ? @"Server unreachable. Check your connection."
                : error.localizedDescription;
            [panel showError:msg];
            return;
        }
        NSLog(@"[Auth] Login successful — user=%@ tier=%@", response.userId, response.tier);
        [strongSelf dismissLoginWindow];
        [strongSelf refreshSetupChrome];
    }];
}

- (void)loginPanel:(InterLoginPanel *)panel
    didRequestRegisterWithEmail:(NSString *)email
                       password:(NSString *)password
                    displayName:(NSString *)displayName {
    [panel setActionsEnabled:NO];
    [panel setLoading:YES];
    [panel clearError];

    NSString *tokenServerURL = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"InterDefaultTokenServerURL"];
    if (!tokenServerURL.length) {
        tokenServerURL = @"http://localhost:3000";
    }

    __weak typeof(self) weakSelf = self;
    [self.roomController.tokenService registerWithEmail:email
                                               password:password
                                            displayName:displayName
                                              serverURL:tokenServerURL
                                             completion:^(InterAuthResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }
        [panel setLoading:NO];
        [panel setActionsEnabled:YES];
        if (error) {
            NSString *msg = (error.code == 1005)
                ? @"Server unreachable. Check your connection."
                : error.localizedDescription;
            [panel showError:msg];
            return;
        }
        NSLog(@"[Auth] Registration successful — user=%@ tier=%@", response.userId, response.tier);
        [strongSelf dismissLoginWindow];
        [strongSelf refreshSetupChrome];
    }];
}

- (void)loginPanel:(InterLoginPanel *)panel
    didRequestOAuthWithProvider:(NSString *)provider {
#pragma unused(panel)
    [self startOAuthSignInWithProvider:provider];
}

- (void)loginPanel:(InterLoginPanel *)panel
    didRequestPasswordResetForEmail:(NSString *)email {
    [panel clearError];

    NSString *tokenServerURL = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"InterDefaultTokenServerURL"];
    if (!tokenServerURL.length) {
        tokenServerURL = @"http://localhost:3000";
    }

    // No global loading state here — that drives the primary CTA's "Signing in…" label,
    // which would be misleading for a reset request. The info/error banner is the feedback.
    [self.roomController.tokenService requestPasswordResetWithEmail:email
                                                          serverURL:tokenServerURL
                                                         completion:^(NSError *error) {
        if (error) {
            NSString *msg = (error.code == 1005)
                ? @"Couldn't reach the server. Check your connection and try again."
                : error.localizedDescription;
            [panel showError:msg];
            return;
        }
        // Persist the EXACT server that issued this link ONLY after the request SUCCEEDS, so
        // a failed / misrouted request never poisons the deep-link redemption target
        // (handlePasswordResetDeepLinkWithToken: prefers this stored value). The server
        // always returns 200 (anti-enumeration), so "no error" confirms tokenServerURL is
        // reachable and behaving like our backend — the only safe moment to record it.
        // Stamp the persist time: the stored issuer is only meaningful while a token from
        // this request could still be live (server reset tokens expire in 1 hour); the
        // redemption side discards it after that window and clears it after a successful
        // reset, so a stale issuer can never steer a future, unrelated redemption.
        NSUserDefaults *resetDefaults = [NSUserDefaults standardUserDefaults];
        [resetDefaults setObject:tokenServerURL forKey:@"InterPasswordResetIssuingServerURL"];
        [resetDefaults setObject:[NSDate date] forKey:@"InterPasswordResetIssuingServerSetAt"];
        // Server always responds generically (anti-enumeration) — never confirm the email
        // exists. The reset is finished via the emailed deep link.
        [panel showInfo:@"If that email is registered, you'll receive a reset link shortly. Check your inbox."];
    }];
}

#pragma mark - InterAuthSessionDelegate [Phase B.4d]

- (void)authSessionDidExpire {
    NSLog(@"[Auth] Session expired — reverting to unauthenticated setup UI");
    // Clear meeting tier lock before teardown
    [self.roomController.tokenService unlockTierFromMeeting];
    // Tear down any active call session first
    if (self.currentCallMode != InterCallModeNone) {
        [NSApp setPresentationOptions:NSApplicationPresentationDefault];
        [self stopScreenMonitoring];
        [self teardownActiveWindows];
        [self.sessionCoordinator finishExit];
    }
    if (self.roomController) {
        [self.roomController disconnect];
    }
    // If the setup window is already visible, refresh the chrome in-place.
    // Otherwise rebuild the full setup window (e.g. session expired while
    // in a call and the call windows were just torn down above).
    if (self.setupWindow) {
        [self refreshSetupChrome];
        [self.connectionPanel setStatusText:@"Session expired — please sign in again."];
    } else {
        [self launchSetupUI];
        [self.connectionPanel setStatusText:@"Session expired — please sign in again."];
    }
}

- (void)authSessionDidAuthenticateWithUserId:(NSString *)userId tier:(NSString *)tier {
    NSLog(@"[Auth] Authenticated — userId=%@ tier=%@", userId, tier);
    // During an active meeting the tier is locked — log the deferred change
    // but do not react to it. The unlock at meeting end will trigger a
    // fresh delegate callback if the tier actually changed.
    if (self.currentCallMode != InterCallModeNone) {
        NSLog(@"[Auth] Tier update deferred — meeting in progress (effective=%@)",
              self.roomController.tokenService.effectiveTier ?: @"nil");
        return;
    }

    // Update billing buttons to reflect the current tier when a proactive
    // token refresh picks up a tier change (e.g. after webhook-driven upgrade).
    // Rebuild the chrome so all auth-dependent controls reflect the new state.
    [self refreshSetupChrome];
}

#pragma mark - Feature Gating

/// Check if a feature is available for the current user's effective tier.
/// If blocked, shows an upsell alert with a "View Plans" option and returns NO.
/// The caller should return immediately when this returns NO.
- (BOOL)requireFeature:(InterFeature)feature {
    NSString *tier = self.roomController.tokenService.effectiveTier ?: @"free";
    if ([InterFeatureGate isFeature:feature availableForTier:tier]) return YES;

    NSString *featureName = [InterFeatureGate displayNameForFeature:feature];
    NSString *minTier     = [InterFeatureGate minimumTierForFeature:feature];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%@ requires the %@ plan",
                         featureName, [minTier capitalizedString]];
    alert.informativeText = [NSString stringWithFormat:
        @"Upgrade to the %@ plan to unlock %@.",
        [minTier capitalizedString], featureName];
    [alert addButtonWithTitle:@"View Plans"];
    [alert addButtonWithTitle:@"Not Now"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [self handleViewPlans];
    }
    return NO;
}

#pragma mark - InterConnectionSetupPanelDelegate [3.1]

- (void)setupPanelDidRequestHostCall:(InterConnectionSetupPanel *)panel {
    if (!self.roomController.tokenService.isAuthenticated) {
        if (self.roomController.tokenService.hasPersistedSession) {
            [panel setStatusText:@"Server unreachable — reconnecting…"];
        } else {
            [panel setStatusText:@"Sign in to host a meeting."];
        }
        return;
    }
    // First-time hosts configure everything once (full sheet → "Save & Next"
    // → green room). Returning hosts go straight to the green room — the old
    // compact sheet is retired; its name/password fields live in the green
    // room's SESSION section and the saved defaults sit behind the
    // "Meeting Settings" button.
    if ([InterPreMeetingSettings hasConfiguredDefaults]) {
        self.pendingConnectionPanel = panel;
        self.pendingMeetingSettings = [InterPreMeetingSettings settingsWithDefaults];
        [self showGreenRoomWithRole:InterGreenRoomRoleHostCreate panel:panel roomCode:@""];
    } else {
        [self showPreMeetingPanelForPanel:panel];
    }
}

- (void)setupPanelDidRequestHostInterview:(InterConnectionSetupPanel *)panel {
    if (!self.roomController.tokenService.isAuthenticated) {
        if (self.roomController.tokenService.hasPersistedSession) {
            [panel setStatusText:@"Server unreachable — reconnecting…"];
        } else {
            [panel setStatusText:@"Sign in to host an interview."];
        }
        return;
    }
    if (![self requireFeature:InterFeatureHostInterview]) return;
    [self showGreenRoomWithRole:InterGreenRoomRoleHostInterview panel:panel roomCode:@""];
}

- (void)setupPanelDidRequestJoin:(InterConnectionSetupPanel *)panel {
    NSString *code = panel.roomCode;
    if (code.length == 0) {
        [panel setStatusText:@"Enter a room code to join."];
        return;
    }

    [self showGreenRoomWithRole:InterGreenRoomRoleJoin panel:panel roomCode:code];
}

/// [Pre-meeting] Show the FULL pre-meeting settings sheet (first-time hosts,
/// and "Meeting Settings" from the green room). The compact mode is retired —
/// returning hosts go straight to the green room.
- (void)showPreMeetingPanelForPanel:(InterConnectionSetupPanel *)panel {
    self.pendingConnectionPanel = panel;

    static const CGFloat kW = 440.0;
    CGFloat kH = [InterPreMeetingPanel fullPanelHeight];

    InterPreMeetingPanel *content =
        [[InterPreMeetingPanel alloc] initWithFrame:NSMakeRect(0, 0, kW, kH)
                                        compactMode:NO];
    content.delegate = self;
    [content setDisplayName:panel.displayName];
    [content setUserTier:self.roomController.tokenService.effectiveTier ?: @"free"];

    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, kW, kH)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskFullSizeContentView
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title = @"";
    win.titlebarAppearsTransparent = YES;
    win.movableByWindowBackground  = YES;
    [win setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    win.contentView = content;
    win.delegate    = self;
    [win center];

    self.preMeetingPanel  = content;
    self.preMeetingWindow = win;

    // When the green room is open, the sheet is its "Meeting Settings" editor:
    // attach it there, seeded with the green room's current per-meeting fields.
    if (self.greenRoomWindow) {
        [content setMeetingName:self.greenRoomHost.meetingNameValue];
        [content setMeetingPassword:self.greenRoomHost.passwordValue];
        [self.greenRoomWindow beginSheet:win completionHandler:nil];
        return;
    }

    // Disable host-call actions on the setup panel while settings panel is open
    [panel setActionsEnabled:NO];

    [self.setupWindow beginSheet:win completionHandler:nil];
}

#pragma mark - InterPreMeetingPanelDelegate

- (void)preMeetingPanel:(InterPreMeetingPanel *)panel
  didStartWithSettings:(InterPreMeetingSettings *)settings {
#pragma unused(panel)
    self.pendingMeetingSettings = settings;

    // "Save & Next" from the green room's Meeting Settings sheet — stay in the
    // green room; refresh its SESSION fields with what the sheet collected.
    if (self.greenRoomWindow) {
        [self dismissPreMeetingPanel];
        [self.greenRoomHost setMeetingName:settings.meetingDisplayName ?: @""];
        [self.greenRoomHost setMeetingPassword:settings.meetingPassword ?: @""];
        [self.greenRoomHost setUsingDefaultsCaption:@"Using custom settings"];
        return;
    }

    // First-time host: "Save & Next" → green room (the meeting starts there).
    [self dismissPreMeetingPanel];
    InterConnectionSetupPanel *setupPanel = self.pendingConnectionPanel;
    if (!setupPanel) return;
    [self showGreenRoomWithRole:InterGreenRoomRoleHostCreate panel:setupPanel roomCode:@""];
}

- (void)preMeetingPanelDidCancel:(InterPreMeetingPanel *)panel {
    if (panel == self.meetingDefaultsPanel) {
        [self _closeMeetingDefaultsEditor];
        return;
    }
    [self dismissPreMeetingPanel];
    // Cancelled from the green room's Meeting Settings sheet — the green room
    // stays up and still owns the pending panel; nothing more to unwind.
    if (self.greenRoomWindow) return;
    [self.pendingConnectionPanel setActionsEnabled:YES];
    self.pendingConnectionPanel = nil;
}

#pragma mark - Meeting Defaults Editor (from Settings)

/// Opens the full pre-meeting panel as a defaults editor (Save instead of Start).
/// Editing here changes the saved defaults used by future host calls / scheduled
/// meetings; it does not start a meeting.
- (void)openMeetingDefaultsEditor {
    // Meeting defaults live in the unified settings window now — deep-link to
    // the Meeting Defaults tab. (Selector preserved for any existing callers.)
    [self openSettingsWindow];
    [self.settingsHostView selectAnchor:InterSettingsTabAnchorMeetingDefaults];
}

- (void)_closeMeetingDefaultsEditor {
    if (self.meetingDefaultsWindow) {
        [self.meetingDefaultsWindow orderOut:nil];
        self.meetingDefaultsWindow = nil;
        self.meetingDefaultsPanel  = nil;
    }
}

- (void)preMeetingPanelDidSaveDefaults:(InterPreMeetingPanel *)panel {
#pragma unused(panel)
    [self _closeMeetingDefaultsEditor];
}

/// Compact panel host tapped "Advanced ▸" — grow the sheet to the full height so
/// all settings are comfortably visible (the panel itself swaps compact→full).
- (void)preMeetingPanel:(InterPreMeetingPanel *)panel
  didRequestExpandToHeight:(CGFloat)height {
    NSWindow *win = self.preMeetingWindow;
    if (!win) return;
    NSRect frame = win.frame;
    if (height <= frame.size.height) return;  // already tall enough
    // The window is presented as a sheet; AppKit keeps it attached to the parent,
    // so only the height needs to change — it repositions automatically.
    frame.size.height = height;
    [win setFrame:frame display:YES animate:YES];
}

- (void)dismissPreMeetingPanel {
    if (self.preMeetingWindow) {
        // The sheet may be attached to the setup window (first-time host) or
        // the green room window (Meeting Settings) — end it on its real parent.
        NSWindow *parent = self.preMeetingWindow.sheetParent ?: self.setupWindow;
        [parent endSheet:self.preMeetingWindow];
        [self.preMeetingWindow orderOut:nil];
        self.preMeetingWindow = nil;
        self.preMeetingPanel  = nil;
    }
}

#pragma mark - Green Room (pre-join device check)

/// Presents the green room for any connect path. The user checks devices,
/// optionally edits per-meeting fields (host create), and proceeds — the
/// actual connect happens from the green room's primary action.
- (void)showGreenRoomWithRole:(InterGreenRoomRole)role
                        panel:(InterConnectionSetupPanel *)panel
                     roomCode:(NSString *)roomCode {
    if (self.greenRoomWindow) return; // already open

    self.pendingConnectionPanel = panel;
    [panel setActionsEnabled:NO];

    static const CGFloat kW = 780.0, kH = 560.0;
    InterGreenRoomHostView *host =
        [[InterGreenRoomHostView alloc] initWithFrame:NSMakeRect(0, 0, kW, kH)
                                                 role:role
                                             roomCode:roomCode];
    [host setDisplayName:panel.displayName];
    [host setTokenServerURL:panel.tokenServerURL];

    if (role == InterGreenRoomRoleHostCreate) {
        InterPreMeetingSettings *settings = self.pendingMeetingSettings;
        NSString *meetingName = settings.meetingDisplayName;
        if (meetingName.length == 0) {
            meetingName = [NSString stringWithFormat:@"%@'s Meeting", panel.displayName];
        }
        [host setMeetingName:meetingName];
        [host setMeetingPassword:settings.meetingPassword ?: @""];
        [host setUsingDefaultsCaption:[InterPreMeetingSettings hasConfiguredDefaults]
                                          ? @"Using default settings"
                                          : @"Using the settings you just saved"];
    }

    __weak typeof(self) weakSelf = self;
    host.onPrimary = ^{
        [weakSelf greenRoomDidSubmitWithRole:role roomCode:roomCode];
    };
    host.onCancel = ^{
        [weakSelf cancelGreenRoom];
    };
    host.onOpenMeetingSettings = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.pendingConnectionPanel) return;
        [strongSelf showPreMeetingPanelForPanel:strongSelf.pendingConnectionPanel];
    };

    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, kW, kH)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title = @"Green Room — Check your camera & mic";
    win.releasedWhenClosed = NO;
    [win setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    win.contentView = host;
    win.delegate = self;
    [win center];

    self.greenRoomHost = host;
    self.greenRoomWindow = win;
    [win makeKeyAndOrderFront:nil];
    [host startPreview];
}

/// Green room primary action — capture the user's choices, close, connect.
/// The host view has already torn down its preview capture session.
- (void)greenRoomDidSubmitWithRole:(InterGreenRoomRole)role
                          roomCode:(NSString *)roomCode {
    InterGreenRoomHostView *host = self.greenRoomHost;
    InterConnectionSetupPanel *panel = self.pendingConnectionPanel;
    if (!host || !panel) { [self cancelGreenRoom]; return; }

    // Join-state rule: host enforcement OR user choice (user can only add OFF).
    self.greenRoomWantsMicOff = !host.micOnChoice;
    self.greenRoomWantsCamOff = !host.camOnChoice;
    self.pendingDisplayNameOverride = host.displayNameValue;

    if (role == InterGreenRoomRoleHostCreate) {
        // Per-meeting fields edited in the green room are authoritative.
        InterPreMeetingSettings *settings =
            self.pendingMeetingSettings ?: [InterPreMeetingSettings settingsWithDefaults];
        settings.meetingDisplayName = host.meetingNameValue;
        settings.meetingPassword = host.passwordValue;
        self.pendingMeetingSettings = settings;
    }

    [self closeGreenRoomWindow];
    self.pendingConnectionPanel = nil;

    // Scheduled meeting flowing through the green room — both the host start
    // and the invitee join use the scheduled endpoint (the server assigns the
    // role from the meeting's host binding).
    NSString *scheduledMeetingId = self.pendingScheduledMeetingId;
    self.pendingScheduledMeetingId = nil;
    if (scheduledMeetingId.length > 0) {
        [self _joinScheduledMeetingWithRoomCode:roomCode
                                      meetingId:scheduledMeetingId
                                       password:nil];
        return;
    }

    switch (role) {
        case InterGreenRoomRoleHostCreate:
            [self connectAndEnterMode:InterCallModeNormal
                                 role:InterInterviewRoleNone
                                panel:panel];
            break;
        case InterGreenRoomRoleJoin:
            [self joinRoomWithCode:roomCode panel:panel password:nil];
            break;
        case InterGreenRoomRoleScheduledStart:
            // Unreachable without pendingScheduledMeetingId (handled above);
            // kept for switch exhaustiveness.
            break;
        case InterGreenRoomRoleHostInterview:
            [self connectAndEnterMode:InterCallModeInterview
                                 role:InterInterviewRoleInterviewer
                                panel:panel];
            break;
    }
}

/// User backed out (close button / Cancel) — unwind to the setup screen.
- (void)cancelGreenRoom {
    [self.greenRoomHost teardown];
    [self closeGreenRoomWindow];
    [self.pendingConnectionPanel setActionsEnabled:YES];
    self.pendingConnectionPanel = nil;
    self.pendingMeetingSettings = nil;
    self.pendingScheduledMeetingId = nil;
    self.greenRoomWantsMicOff = NO;
    self.greenRoomWantsCamOff = NO;
    self.pendingDisplayNameOverride = nil;
}

- (void)closeGreenRoomWindow {
    // Dismiss any Meeting Settings sheet still attached to the green room.
    if (self.preMeetingWindow && self.preMeetingWindow.sheetParent == self.greenRoomWindow) {
        [self dismissPreMeetingPanel];
    }
    if (self.greenRoomWindow) {
        [self.greenRoomWindow orderOut:nil];
        self.greenRoomWindow = nil;
    }
    self.greenRoomHost = nil;
}

/// [3.1.2] Host flow: create room → get code → display it → connect → enter mode.
- (void)connectAndEnterMode:(InterCallMode)mode
                       role:(InterInterviewRole)role
                      panel:(InterConnectionSetupPanel *)panel {
    NSString *serverURL    = panel.serverURL;
    NSString *tokenURL     = panel.tokenServerURL;
    // The green room lets the user edit their display name pre-join. Read
    // non-destructively: every connect path passes through the green room,
    // which sets a fresh override on each submit (cancel clears it), and the
    // password-retry rejoin must keep using the same chosen name.
    NSString *displayName  = self.pendingDisplayNameOverride.length > 0
        ? self.pendingDisplayNameOverride : panel.displayName;

    if (displayName.length == 0) {
        [panel setStatusText:@"Enter a display name."];
        return;
    }

    InterRoomController *rc = self.roomController;
    if (!rc) {
        // [G8] No room controller — fall through to local-only mode
        [panel setStatusText:@"Network unavailable — starting local-only."];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self enterMode:mode role:role];
        });
        return;
    }

    [panel setActionsEnabled:NO];
    [panel setIndicatorState:InterConnectionIndicatorStateConnecting];
    [panel setStatusText:@"Creating room…"];

    NSString *identity = [[NSUUID UUID] UUIDString];
    InterRoomConfiguration *config =
        [[InterRoomConfiguration alloc] initWithServerURL:serverURL
                                          tokenServerURL:tokenURL
                                                roomCode:@""
                                     participantIdentity:identity
                                         participantName:displayName
                                                  isHost:YES
                                                roomType:(mode == InterCallModeInterview) ? @"interview" : @"call"
                                        maxParticipants:50];

    // Bake host-configured pre-meeting settings into the room configuration
    InterPreMeetingSettings *preMeetingSettings = self.pendingMeetingSettings;
    if (preMeetingSettings) {
        // Use host display name as fallback for meeting display name
        NSString *meetingName = preMeetingSettings.meetingDisplayName;
        if (meetingName.length == 0) {
            meetingName = [NSString stringWithFormat:@"%@'s Meeting", displayName];
        }
        config.meetingDisplayName = meetingName;
        config.muteOnJoin         = preMeetingSettings.muteOnJoin;
        config.cameraOffOnJoin    = preMeetingSettings.cameraOffOnJoin;
        config.joinBeforeHost     = preMeetingSettings.joinBeforeHost;
        config.allowUnmuting      = preMeetingSettings.allowUnmuting;
        config.chatPermissions    = preMeetingSettings.chatPermissions;
        config.sharingPermissions = preMeetingSettings.sharingPermissions;
        config.shareConflictPolicy = preMeetingSettings.shareConflictPolicy ?: @"oneattime";
        config.autoRecord         = preMeetingSettings.autoRecord;
        config.autoTranscript     = preMeetingSettings.autoTranscript;
        // [R2] Lobby and password settings were previously missing — wire them in.
        config.lobbyEnabled       = preMeetingSettings.lobbyEnabled;
        config.meetingPassword    = preMeetingSettings.meetingPassword ?: @"";
    }

    __weak typeof(self) weakSelf = self;
    [rc connectWithConfiguration:config completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error) {
                [panel setActionsEnabled:YES];
                [panel setIndicatorState:InterConnectionIndicatorStateError];
                [panel setStatusText:[strongSelf userFacingMessageForError:error]];
                return;
            }

            [panel setIndicatorState:InterConnectionIndicatorStateConnected];
            [panel setStatusText:@"Connected"];

            NSString *roomCode = rc.roomCode;
            if (roomCode.length > 0) {
                [panel showHostedRoomCode:roomCode];
            }

            // Brief delay so user can see the room code before window transitions
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [panel setActionsEnabled:YES];
                [strongSelf enterMode:mode role:role];
            });
        });
    }];
}

/// [3.1.3] Join flow: validate code → show "Joining Meeting..." overlay → connect → enter as guest.
/// Pass a non-nil `password` to supply a meeting password on retry.
- (void)joinRoomWithCode:(NSString *)code
                   panel:(InterConnectionSetupPanel *)panel
                password:(nullable NSString *)password {
    NSString *serverURL    = panel.serverURL;
    NSString *tokenURL     = panel.tokenServerURL;
    // Green-room display-name override, read non-destructively: the password
    // retry re-enters this method and must keep the same chosen name. A fresh
    // override is set on every green-room submit; cancel clears it.
    NSString *displayName  = self.pendingDisplayNameOverride.length > 0
        ? self.pendingDisplayNameOverride : panel.displayName;

    if (displayName.length == 0) {
        [panel setStatusText:@"Enter a display name."];
        return;
    }

    InterRoomController *rc = self.roomController;
    if (!rc) {
        [panel setStatusText:@"Network unavailable — cannot join."];
        return;
    }

    [panel setActionsEnabled:NO];
    [panel setIndicatorState:InterConnectionIndicatorStateConnecting];
    [panel setStatusText:@"Joining room…"];

    NSString *identity = [[NSUUID UUID] UUIDString];
    InterRoomConfiguration *config =
        [[InterRoomConfiguration alloc] initWithServerURL:serverURL
                                          tokenServerURL:tokenURL
                                                roomCode:code
                                     participantIdentity:identity
                                         participantName:displayName
                                                  isHost:NO
                                                roomType:@""
                                        maxParticipants:50];
    // Wire the password so InterTokenService includes it in the /room/join body.
    config.meetingPassword = password ?: @"";

    // Store the lobby/join state needed for admission polling, but DO NOT present the
    // "Joining Meeting" overlay yet. Presenting it up front caused a visible flicker on
    // fast join failures (invalid/expired code, room full, locked, etc.): the window
    // appeared and was dismissed within the same runloop. The panel already shows
    // "Joining room…", and the overlay is now presented only when the join actually
    // reaches the waiting-room (lobby) state below.
    [self _storeJoiningOverlayStateWithCode:code
                                   identity:identity
                                displayName:displayName
                                  serverURL:serverURL
                             tokenServerURL:tokenURL];

    __weak typeof(self) weakSelf = self;
    [rc connectWithConfiguration:config completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error) {
                // Password required (1011) or wrong password on retry (1015) — prompt.
                if (error.code == 1011 || error.code == 1015) {
                    BOOL wasIncorrect = (error.code == 1015);
                    [strongSelf _dismissJoiningOverlay];
                    [panel setActionsEnabled:YES];
                    [panel setIndicatorState:InterConnectionIndicatorStateIdle];
                    [panel setStatusText:@""];

                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText    = wasIncorrect ? @"Incorrect Password" : @"Password Required";
                    alert.informativeText = wasIncorrect
                        ? @"The password you entered is incorrect. Please try again."
                        : @"This meeting requires a password. Please enter it below.";
                    [alert addButtonWithTitle:@"Join"];
                    [alert addButtonWithTitle:@"Cancel"];
                    alert.alertStyle = NSAlertStyleInformational;

                    NSSecureTextField *pwField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
                    pwField.placeholderString = @"Meeting password";
                    alert.accessoryView = pwField;

                    // Force the field to become first responder when the sheet appears.
                    [alert layout];
                    [alert.window makeFirstResponder:pwField];

                    [alert beginSheetModalForWindow:panel.window
                                  completionHandler:^(NSModalResponse resp) {
                        if (resp == NSAlertFirstButtonReturn) {
                            NSString *entered = pwField.stringValue;
                            if (entered.length == 0) {
                                [panel setStatusText:@"Password cannot be empty."];
                                return;
                            }
                            // Retry the join with the supplied password.
                            [strongSelf joinRoomWithCode:code panel:panel password:entered];
                        } else {
                            // User cancelled — leave the panel in a clean state.
                            [panel setIndicatorState:InterConnectionIndicatorStateIdle];
                            [panel setStatusText:@""];
                        }
                    }];
                    return;
                }

                // Phase 9.3 — Lobby waiting: transition overlay to waiting room state
                if (error.code == 1010) {
                    NSString *pollToken = error.userInfo[@"pollToken"];
                    NSInteger position  = [error.userInfo[@"position"] integerValue];
                    if (!pollToken.length) {
                        [strongSelf _dismissJoiningOverlay];
                        [panel setActionsEnabled:YES];
                        [panel setIndicatorState:InterConnectionIndicatorStateError];
                        [panel setStatusText:@"Lobby error — please try again."];
                        return;
                    }
                    // Reuse the existing overlay window — transition it to waiting room.
                    // The overlay is presented here (not up front) so failed joins never
                    // flash a "Joining Meeting" window.
                    [strongSelf _presentJoiningOverlayWindow];
                    [strongSelf _transitionOverlayToWaitingRoomWithPollToken:pollToken position:position];
                    [panel setActionsEnabled:YES];
                    [panel setIndicatorState:InterConnectionIndicatorStateIdle];
                    [panel setStatusText:@""];
                    return;
                }

                [strongSelf _dismissJoiningOverlay];
                [panel setActionsEnabled:YES];
                [panel setIndicatorState:InterConnectionIndicatorStateError];
                [panel setStatusText:[strongSelf userFacingMessageForError:error]];
                return;
            }

            // Joined — dismiss the overlay and enter the call.
            [strongSelf _dismissJoiningOverlay];
            [panel setIndicatorState:InterConnectionIndicatorStateConnected];
            [panel setStatusText:@"Joined"];
            [panel setActionsEnabled:YES];

            // Determine mode from the server-reported room type
            NSString *roomType = rc.roomType;
            BOOL isInterviewRoom = [roomType isEqualToString:@"interview"];

            if (isInterviewRoom) {
                if (rc.isHost) {
                    // Returning interview host (e.g. rejoining after a network drop or
                    // after ending the meeting on their side). The server restored
                    // interviewer privileges (server-authoritative isHost via the
                    // authenticated userId binding), so re-enter as interviewer directly.
                    // The candidate consent dialog applies only to interviewees.
                    [strongSelf enterMode:InterCallModeInterview
                                     role:InterInterviewRoleInterviewer];
                } else {
                    // Show confirmation before entering secure interviewee mode
                    [strongSelf showIntervieweeConfirmationWithCompletion:^(BOOL accepted) {
                        if (accepted) {
                            [strongSelf enterMode:InterCallModeInterview
                                             role:InterInterviewRoleInterviewee];
                        } else {
                            // User declined — disconnect and return to setup
                            [rc disconnect];
                            [panel setIndicatorState:InterConnectionIndicatorStateIdle];
                            [panel setStatusText:@"Disconnected — declined interview session."];
                        }
                    }];
                }
            } else {
                // Normal call
                [strongSelf enterMode:InterCallModeNormal role:InterInterviewRoleNone];
            }
        });
    }];
}

/// Show the "Joining Meeting..." overlay immediately when the participant submits a room code.
/// The same window is later transitioned to the waiting room state (lobby) or dismissed.
- (void)_showJoiningOverlayWithCode:(NSString *)roomCode
                           identity:(NSString *)identity
                        displayName:(NSString *)displayName
                          serverURL:(NSString *)serverURL
                     tokenServerURL:(NSString *)tokenServerURL {
    [self _storeJoiningOverlayStateWithCode:roomCode
                                   identity:identity
                                displayName:displayName
                                  serverURL:serverURL
                             tokenServerURL:tokenServerURL];
    [self _presentJoiningOverlayWindow];
}

/// Store the lobby/join state used by the admission poller, WITHOUT presenting any window.
/// Splitting state-storage from window-presentation lets the join flow defer the overlay
/// until the waiting-room state is actually reached, avoiding a flicker on fast failures.
- (void)_storeJoiningOverlayStateWithCode:(NSString *)roomCode
                                 identity:(NSString *)identity
                              displayName:(NSString *)displayName
                                serverURL:(NSString *)serverURL
                           tokenServerURL:(NSString *)tokenServerURL {
    // Store lobby state — used if the server returns a lobby response
    self.lobbyRoomCode        = roomCode;
    self.lobbyIdentity        = identity;
    self.lobbyDisplayName     = displayName;
    self.lobbyServerURL       = serverURL;
    self.lobbyTokenServerURL  = tokenServerURL;
    self.lobbyPollToken       = nil; // filled in by _transitionOverlayToWaitingRoom
}

/// Create and present the joining/waiting overlay window in its "Joining Meeting..." state.
/// No-op if the overlay window already exists.
- (void)_presentJoiningOverlayWindow {
    if (self.lobbyWaitingWindow) return; // already showing (e.g. reconnect scenario)

    CGFloat w = 400, h = 360;
    NSRect screenFrame = [NSScreen mainScreen].visibleFrame;
    CGFloat x = NSMidX(screenFrame) - w / 2;
    CGFloat y = NSMidY(screenFrame) - h / 2;

    self.lobbyWaitingView = [[InterLobbyWaitingView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    self.lobbyWaitingView.delegate = self;
    [self.lobbyWaitingView showJoining]; // "Joining Meeting..." state

    self.lobbyWaitingWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(x, y, w, h)
                                                          styleMask:(NSWindowStyleMaskTitled)
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
    self.lobbyWaitingWindow.title = @"Joining Meeting";
    self.lobbyWaitingWindow.releasedWhenClosed = NO;
    self.lobbyWaitingWindow.level = NSFloatingWindowLevel;
    [self.lobbyWaitingWindow setSharingType:InterWindowSharingType()];
    [self.lobbyWaitingWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    self.lobbyWaitingWindow.contentView = self.lobbyWaitingView;
    // Theme the title bar to the app surface, and remove the window buttons: the waiting
    // room is a blocking flow — the ONLY way out is the in-content "Leave" button, which
    // tells the server so the host's lobby list updates. (No stray red close button.)
    [InterWindowChrome applyPanelChromeTo:self.lobbyWaitingWindow];
    [InterWindowChrome hideStandardButtons:self.lobbyWaitingWindow];
    [self.lobbyWaitingWindow makeKeyAndOrderFront:nil];
}

/// Transition the joining overlay to the waiting room state when lobby is enabled.
/// Starts the admission-status polling timer.
- (void)_transitionOverlayToWaitingRoomWithPollToken:(NSString *)pollToken
                                            position:(NSInteger)position {
    self.lobbyPollToken = pollToken;
    self.lobbyWaitingWindow.title = @"Waiting Room";
    [self.lobbyWaitingView showWaiting];
    [self.lobbyWaitingView setPosition:position];

    [self.lobbyStatusPollTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.lobbyStatusPollTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                               repeats:YES
                                                                 block:^(NSTimer * __unused t) {
        [weakSelf _pollLobbyStatus];
    }];
    [self _pollLobbyStatus]; // fire immediately
}

/// Dismiss the joining/waiting overlay and reset all lobby state.
- (void)_dismissJoiningOverlay {
    [self.lobbyStatusPollTimer invalidate];
    self.lobbyStatusPollTimer = nil;
    [self.lobbyWaitingWindow orderOut:nil];
    self.lobbyWaitingWindow = nil;
    self.lobbyWaitingView   = nil;
    self.lobbyPollToken     = nil;
    self.lobbyRoomCode      = nil;
    self.lobbyIdentity      = nil;
    self.lobbyDisplayName   = nil;
    self.lobbyServerURL     = nil;
    self.lobbyTokenServerURL = nil;
}

/// [3.1.4] Show confirmation dialog before entering secure interviewee mode.
/// The joiner sees this when the server reports roomType == "interview".
- (void)showIntervieweeConfirmationWithCompletion:(void (^)(BOOL accepted))completion {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"You are joining an Interview Session";
    NSMutableString *informativeText =
        [NSMutableString stringWithString:
            @"This room is an interview. You will enter secure interviewee mode:\n\n"
             @"• Full-screen secure window\n"
             @"• Screen sharing restricted\n"];
    if (InterShouldEnforceInterviewExternalDisplayPolicy()) {
        [informativeText appendString:@"• External displays blocked\n"];
    }
    [informativeText appendString:@"\nClick 'Continue' to proceed or 'Cancel' to disconnect."];
    alert.informativeText = informativeText;
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"Continue"];
    [alert addButtonWithTitle:@"Cancel"];

    NSModalResponse response = [alert runModal];
    BOOL accepted = (response == NSAlertFirstButtonReturn);
    completion(accepted);
}

/// [3.1.3] Map NSError codes to user-facing messages.
- (NSString *)userFacingMessageForError:(NSError *)error {
    if (!error) return @"Unknown error";

    NSInteger code = error.code;
    // InterNetworkErrorCode values from InterNetworkTypes.swift (start at 1000)
    if (code == 1000) return @"Token fetch failed. Check token server URL.";
    if (code == 1001) return @"Connection failed. Check server URL and network.";
    if (code == 1005) return @"Server unreachable. Check your network connection.";
    if (code == 1006) return @"Invalid room code. Check and try again.";
    if (code == 1007) return @"Room has expired. Ask the host for a new code.";
    if (code == 1008) return @"Room is full. Try again later.";
    if (code == 1009) return @"This meeting is locked. Ask the host to unlock it.";
    if (code == 1010) return @"You are in the waiting room. The host will admit you shortly.";
    if (code == 1011) return @"This meeting requires a password.";
    if (code == 1015) return @"Incorrect password. Please try again.";
    if (code == 1016) return @"You have been removed from this meeting.";
    if (code == 1017) return @"The host hasn't started the meeting yet. Please try again shortly.";
    if (code == 1018) return @"The call server is temporarily unavailable. Please try again shortly.";
    if (code == 1019) return @"Too many password attempts. Please wait a few minutes and try again.";

    // T3: Never leak raw NSError descriptions to the user.
    // Log the full error for debugging, return a generic safe string.
    NSLog(@"[AppDelegate] Unmapped error (code=%ld, domain=%@): %@",
          (long)code, error.domain, error.localizedDescription);
    return @"Something went wrong. Please try again.";
}

- (void)launchNormalCallWindow {
    if (self.normalCallWindow == nil) {
        self.normalCallWindow =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 980, 640)
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskMiniaturizable |
                                               NSWindowStyleMaskResizable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];

        // Keep a stable window instance across mode switches to avoid lifecycle races.
        [self.normalCallWindow setReleasedWhenClosed:NO];
    }

    NSString *title = @"Normal Call";
    if (self.currentCallMode == InterCallModeInterview &&
        self.currentInterviewRole == InterInterviewRoleInterviewer) {
        title = @"Interview (Interviewer - Normal Mode)";
    }

    [self.normalCallWindow center];
    [self.normalCallWindow setTitle:title];
    [self.normalCallWindow setSharingType:InterWindowSharingType()];
    [self.normalCallWindow setDelegate:self];

    NSView *view = self.normalCallWindow.contentView;
    if (view == nil) {
        view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 980, 640)];
        [self.normalCallWindow setContentView:view];
    } else {
        NSArray<NSView *> *subviews = [view.subviews copy];
        for (NSView *subview in subviews) {
            [subview removeFromSuperview];
        }
    }
    [view setWantsLayer:YES];
    view.layer.backgroundColor = [NSColor blackColor].CGColor;
    [self.normalCallWindow setBackgroundColor:[NSColor blackColor]];

    self.normalRenderView = [[NSView alloc] initWithFrame:view.bounds];
    self.normalRenderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.normalRenderView];

    // [3.2.1] Remote video layout (camera + screen share views + participant overlay)
    // Reserve the bottom control-bar band so video tiles are never occluded by the
    // leave/mic/cam bar. The layout view sits ABOVE the bar; with width+height
    // flexible and the bottom margin fixed (origin.y = bar height), the grid tracks
    // window resize while always clearing the bar. (Secure/interview mode frames its
    // own layout manager inside InterSecureInterviewStageView and is unaffected.)
    CGFloat callBarInset = [InterDesignTokens callControlBarHeight];
    NSRect remoteLayoutFrame = NSMakeRect(0, callBarInset,
                                          view.bounds.size.width,
                                          MAX(0.0, view.bounds.size.height - callBarInset));
    self.normalRemoteLayout = [[InterRemoteVideoLayoutManager alloc] initWithFrame:remoteLayoutFrame];
    self.normalRemoteLayout.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.normalRemoteLayout];

    // [Per-participant moderation] Enable three-dot hover menus for host/co-host
    if (self.moderationController) {
        BOOL canModerate = [InterPermissionMatrix
                            role:self.moderationController.localRole
                            hasPermission:(InterPermission)InterPermissionCanMuteOthers];
        self.normalRemoteLayout.isHostMode = canModerate;
        // Role assignment (Make/Remove Co-Host) is host-only; co-hosts do not see those items.
        self.normalRemoteLayout.localUserCanAssignCoHost =
            (self.moderationController.localRole == InterParticipantRoleHost);
    }
    // Interview rooms let the host force-activate, so the cause-derived mic menu reads a
    // direct "Unmute" there. Constant for the session — set once at layout creation.
    self.normalRemoteLayout.interviewMode =
        [self.roomController.roomType isEqualToString:@"interview"];
    __weak typeof(self) weakModSelf = self;
    self.normalRemoteLayout.moderationActionHandler = ^(NSString *participantIdentity, NSString *actionType) {
        [weakModSelf handleTileModerationAction:actionType forParticipant:participantIdentity];
    };

    // When a host-pinned participant leaves, the layout manager prunes the pinned
    // list locally and fires this handler so the host can re-broadcast the updated
    // list to all remote clients via the moderation DataChannel.
    __weak typeof(self) weakPinSelf = self;
    self.normalRemoteLayout.hostForcedSpotlightChangedHandler = ^(NSArray<NSString *> *currentPinnedKeys) {
        [weakPinSelf.moderationController broadcastForcedSpotlightList:currentPinnedKeys];
    };

    [self attachNormalCallControlsInView:view];

    // [B1] Wire shared media wiring controller — properties that exist now
    self.normalMediaWiring.controlPanel = self.normalControlPanel;
    self.normalMediaWiring.remoteLayout = self.normalRemoteLayout;
    __weak typeof(self) weakMediaSummarySelf = self;
    self.normalMediaWiring.mediaStateSummaryBlock = ^NSString *{
        return [weakMediaSummarySelf normalMediaStateSummary];
    };

    [self wireNormalRemoteRendering];
    [self startNormalLocalMediaFlow];

    // [B1] Wire media + surface share AFTER startNormalLocalMediaFlow creates them
    self.normalMediaWiring.mediaController = self.normalMediaController;
    self.normalMediaWiring.surfaceShareController = self.normalSurfaceShareController;

    // Pass the capture session so the layout manager can show a self-view tile
    // in grid mode (AVCaptureVideoPreviewLayer — zero CPU, hardware accelerated).
    self.normalRemoteLayout.localCaptureSession = self.normalMediaController.captureSession;

    [self.normalControlPanel setCameraEnabled:self.normalMediaController.isCameraEnabled];
    [self.normalControlPanel setMicrophoneEnabled:self.normalMediaController.isMicrophoneEnabled];
    [self.normalControlPanel setSharingEnabled:self.normalSurfaceShareController.isSharing];
    [self.normalControlPanel setShareStartPending:self.normalSurfaceShareController.isStartPending];

    [self.normalControlPanel setShareStatusText:@"Secure surface share is off. Select a source to begin."];

    // [3.4.2] Carry over connection status + room code from the setup phase
    [self updateNormalConnectionStatus];

    // [Phase 8] Add chat panel (full-height, overlays content from right edge)
    self.normalChatPanel = [[InterChatPanel alloc] initWithFrame:view.bounds];
    self.normalChatPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.normalChatPanel.delegate = self;
    [view addSubview:self.normalChatPanel];

    // [Phase 8] Speaker / screen-share / camera-unlock / mic-unlock request
    // queues are surfaced by the consolidated Requests panel in the control
    // bar's More menu (the bridge observes the queues directly). The legacy
    // per-queue AppKit panels are no longer created in normal mode — their
    // delegate methods below remain the moderation logic, and all setEntries:/
    // showPanel: push sites are harmless no-ops on the nil panel references.

    // [Phase 8] Wire chat controller delegates
    self.chatController.chatDelegate = (id<InterChatControllerDelegate>)self;
    self.chatController.controlDelegate = (id<InterControlSignalDelegate>)self;
    self.chatController.isChatVisible = NO;

    // [Phase 10] Wire recording coordinator to chat controller for consent broadcasts
    self.normalRecordingCoordinator.chatController = self.chatController;
    self.normalRecordingCoordinator.localParticipantIdentity = self.roomController.localParticipantIdentity;
    self.chatController.recordingDelegate = (id<InterRecordingSignalDelegate>)self;

    // [Phase 10] REC indicator badge — shown to ALL participants (host drives it; others get DataChannel signal)
    self.normalRecordingIndicatorView = [[InterRecordingIndicatorView alloc] initWithFrame:
        NSMakeRect(view.bounds.size.width - 210.0, view.bounds.size.height - 40.0, 200.0, 28.0)];
    self.normalRecordingIndicatorView.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    self.normalRecordingIndicatorView.indicatorActive = NO;
    [view addSubview:self.normalRecordingIndicatorView];

    // [Phase 8.5] Poll window (standalone, movable/resizable — Zoom-style)
    {
        CGFloat pollW = 320;
        CGFloat pollH = 480;
        NSRect mainFrame = self.normalCallWindow.frame;
        CGFloat pollX = NSMaxX(mainFrame) + 12;
        CGFloat pollY = NSMaxY(mainFrame) - pollH;
        NSRect pollRect = NSMakeRect(pollX, pollY, pollW, pollH);

        self.normalPollWindow = [[NSWindow alloc] initWithContentRect:pollRect
                                                           styleMask:(NSWindowStyleMaskTitled |
                                                                      NSWindowStyleMaskClosable |
                                                                      NSWindowStyleMaskResizable |
                                                                      NSWindowStyleMaskMiniaturizable)
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
        self.normalPollWindow.title = @"\U0001F4CA Polls";
        self.normalPollWindow.minSize = NSMakeSize(280, 320);
        self.normalPollWindow.releasedWhenClosed = NO;
        self.normalPollWindow.level = NSFloatingWindowLevel;
        [self.normalPollWindow setSharingType:InterWindowSharingType()];
        [self.normalPollWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];

        self.normalPollPanel = [[InterPollPanel alloc] initWithFrame:NSMakeRect(0, 0, pollW, pollH)];
        self.normalPollPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.normalPollPanel.delegate = self;
        self.normalPollPanel.isHost = self.roomController.isHost;
        // setupViews ran showViewMode: during -initWithFrame: before isHost was set,
        // so the create form visibility is wrong. Re-apply now that isHost is correct.
        [self.normalPollPanel resetToCreateForm];
        self.normalPollWindow.contentView = self.normalPollPanel;
    }

    // [Phase 8.5] Wire poll controller delegate
    self.pollController.delegate = (id<InterPollControllerDelegate>)self;

    // [Phase 8.6] Q&A window (standalone, movable/resizable — Zoom-style)
    {
        CGFloat qaW = 320;
        CGFloat qaH = 480;
        NSRect mainFrame = self.normalCallWindow.frame;
        CGFloat qaX = NSMaxX(mainFrame) + 12;
        CGFloat qaY = NSMaxY(mainFrame) - qaH - 40;
        NSRect qaRect = NSMakeRect(qaX, qaY, qaW, qaH);

        self.normalQAWindow = [[NSWindow alloc] initWithContentRect:qaRect
                                                         styleMask:(NSWindowStyleMaskTitled |
                                                                    NSWindowStyleMaskClosable |
                                                                    NSWindowStyleMaskResizable |
                                                                    NSWindowStyleMaskMiniaturizable)
                                                           backing:NSBackingStoreBuffered
                                                             defer:NO];
        self.normalQAWindow.title = @"\u2753 Q&A";
        self.normalQAWindow.minSize = NSMakeSize(280, 320);
        self.normalQAWindow.releasedWhenClosed = NO;
        self.normalQAWindow.level = NSFloatingWindowLevel;
        [self.normalQAWindow setSharingType:InterWindowSharingType()];
        [self.normalQAWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];

        self.normalQAPanel = [[InterQAPanel alloc] initWithFrame:NSMakeRect(0, 0, qaW, qaH)];
        self.normalQAPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.normalQAPanel.delegate = self;
        self.normalQAPanel.isHost = self.roomController.isHost;
        self.normalQAWindow.contentView = self.normalQAPanel;
    }

    // [Phase 8.6] Wire Q&A controller delegate
    self.qaController.delegate = (id<InterQAControllerDelegate>)self;

    // Apply host-configured (or server-returned) meeting settings now that
    // all controllers are wired and the call window is ready.
    [self applyMeetingSettingsAfterLaunch];

    [self.normalCallWindow makeKeyAndOrderFront:nil];
}

/// Applies host-configured (or server-returned) meeting settings after the call
/// window and all controllers have been wired.
///
/// Host path:   reads from `pendingMeetingSettings` then clears it.
/// Joiner path: reads from `roomController.active*` properties (set from join response).
- (void)applyMeetingSettingsAfterLaunch {
    BOOL isHost = self.roomController.isHost;
    // On a fresh host launch we have pendingMeetingSettings (gathered from the pre-meeting
    // panel). On host REJOIN — and for every participant — pendingMeetingSettings is nil, so
    // read the server-returned active* values instead. Keying these off `isHost` alone made
    // a rejoining host revert meeting name / chat permissions / share-takeover policy to
    // defaults, because the host branch read from a nil pendingMeetingSettings.
    InterPreMeetingSettings *pending = self.pendingMeetingSettings;

    // NOTE: muteOnJoin and cameraOffOnJoin are applied inside startNormalLocalMediaFlow's
    // prepareWithCompletion: block — after -start — because the capture session must be
    // running before mute/disable calls take effect. Calling them here would be a no-op.

    // meetingDisplayName → window title
    NSString *meetingName = pending
        ? (pending.meetingDisplayName ?: @"")
        : self.roomController.activeMeetingDisplayName;
    if (meetingName.length > 0) {
        [self.normalCallWindow setTitle:meetingName];
    }

    // allowUnmuting — stored as roomController.activeAllowUnmuting.
    // The moderation controller will consult this when handling raise-hand / unmute requests.

    // Auto-record (host only, pro tier). Guarded on pendingMeetingSettings so it fires only
    // on the fresh host launch, never on a rejoin (the recording would already be running).
    if (isHost && pending && pending.autoRecord) {
        [self handleAutoRecordIfNeeded];
    }

    // Consume the pending settings — they must not outlive this call window session
    [self _updateChatExportVisibility];
    // Broadcast co-host local recording permission to all participants (fresh host only).
    if (isHost && pending) {
        BOOL allow = pending.allowCoHostLocalRecording;
        self.coHostLocalRecordingAllowed = allow;
        [self.moderationController setCoHostRecordingAllowed:allow];
    }

    // Fix: apply the host-configured (or server-returned) chat permissions so the
    // chat input is gated correctly from the very first moment the session opens.
    // applyInitialChatPermissions does NOT broadcast a DataChannel signal —
    // it only sets the local isChatDisabled flag and notifies the delegate.
    NSString *chatPerms = pending
        ? (pending.chatPermissions ?: @"everyone")
        : (self.roomController.activeChatPermissions ?: @"everyone");
    [self.moderationController applyInitialChatPermissions:chatPerms];

    // Apply the share-conflict policy from the pre-meeting settings (fresh host) or the
    // server response (host rejoin / joiner) so the "Share Takeover" menu reflects reality.
    NSString *conflictPolicy = pending
        ? (pending.shareConflictPolicy ?: @"oneattime")
        : (self.roomController.activeShareConflictPolicy ?: @"oneattime");
    [self.moderationController applyInitialShareConflictPolicy:conflictPolicy];

    // Cache the host-configured meeting password (plaintext) for THIS session so the
    // creating host can View/Copy/Change it. Whether a password is *set* is tracked
    // server-authoritatively via roomController.activeHasPassword (which also covers the
    // host-rejoin and co-host cases where the plaintext is not available locally).
    if (isHost) {
        self.currentMeetingPassword = pending.meetingPassword ?: @"";
    }

    self.pendingMeetingSettings = nil;
}

/// Triggers automatic cloud recording when the host has configured autoRecord.
/// Only fires for Pro/Pro+ tier users who have cloud recording enabled.
- (void)handleAutoRecordIfNeeded {
    InterRecordingCoordinator *coordinator = self.normalRecordingCoordinator;
    if (!coordinator) return;

    NSString *tier = self.roomController.tokenService.effectiveTier ?: @"free";
    if (![InterFeatureGate isFeature:InterFeatureCloudRecording availableForTier:tier]) return;

    NSString *serverURL = self.roomController.tokenServerURL;
    NSString *roomCode  = self.roomController.roomCode;
    NSString *identity  = self.roomController.localParticipantIdentity;
    if (serverURL.length == 0 || roomCode.length == 0 || identity.length == 0) return;

    // Dispatch slightly so the call window fully settles before recording starts.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.normalRecordingCoordinator) return;
        [coordinator startCloudRecordingWithServerURL:serverURL
                                            roomCode:roomCode
                                      callerIdentity:identity
                            estimatedDurationMinutes:60
                                                mode:@"cloud_composed"
                                          completion:^(NSString *egressId, NSString *sessionId, NSError *error) {
            if (error) {
                NSLog(@"[AutoRecord] Auto cloud recording start failed: %@", error.localizedDescription);
            } else {
                NSLog(@"[AutoRecord] Cloud recording auto-started: egress=%@ session=%@", egressId, sessionId);
            }
        }];
    });
}

- (void)attachNormalCallControlsInView:(NSView *)view {
    // [Task 8] SwiftUI in-call control bar — single full-width bottom bar that
    // replaces the legacy AppKit panel + loose buttons (the secure/candidate
    // window keeps the AppKit panel; the bridge conforms to the same
    // InterCallMediaControlSurface protocol the wiring controller drives).
    CGFloat barHeight = [InterDesignTokens callControlBarHeight];
    InterCallControlBarBridge *bar = [[InterCallControlBarBridge alloc]
        initWithFrame:NSMakeRect(0, 0, view.bounds.size.width, barHeight)];
    bar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    self.normalControlPanel = bar;
    [view addSubview:bar];

    // Waiting-room arrival toast: floats bottom-left, just above the bar. The
    // "Open" action surfaces the Waiting Room panel so the host can admit.
    self.normalLobbyToast = [[InterLobbyToastPresenter alloc] initWithParentView:view
                                                                        barInset:barHeight];
    __weak typeof(self) weakToastSelf = self;
    self.normalLobbyToast.onOpen = ^{
        __strong typeof(weakToastSelf) strongToastSelf = weakToastSelf;
        if (!strongToastSelf) return;
        // No-op if the panel is already in front; otherwise create/show it.
        if (strongToastSelf.normalLobbyWindow && strongToastSelf.normalLobbyWindow.isVisible) return;
        [strongToastSelf toggleNormalLobbyPanel];
    };

    // In-call request toast (raise hand / screen share / unlock). Stacked above the
    // lobby toast so the two never overlap; "Open" surfaces the Requests panel.
    self.normalRequestToast = [[InterLobbyToastPresenter alloc] initWithParentView:view
                                                                          barInset:(barHeight + 80.0)];
    self.normalRequestToast.onOpen = ^{
        __strong typeof(weakToastSelf) strongToastSelf = weakToastSelf;
        [strongToastSelf.normalControlPanel showRequestsPanel];
    };

    __weak typeof(self) weakSelf = self;
    bar.cameraToggleHandler = ^{
        InterMediaWiringController *wiring = weakSelf.normalMediaWiring;
        // If locked (per-participant or global), intercept and route to unlock-request flow.
        if (wiring.isHostCameraLocked || wiring.globalCameraLockActive) {
            if (wiring.cameraUnlockApproved) {
                // Host approved — allow normal toggle (camera on/off).
                [wiring twoPhaseToggleCamera];
            } else if (!wiring.cameraUnlockRequestPending) {
                // "Ask to Unlock Camera" was tapped — send request and show "Request Sent…".
                [wiring applyHostCameraUnlockRequestPending];
                [weakSelf.moderationController requestCameraUnlock];
            }
            // If pending — button is disabled; tap should not reach here.
            return;
        }
        // [2.5.6] [G2] Normal two-phase camera toggle via shared wiring controller.
        [wiring twoPhaseToggleCamera];
    };
    bar.microphoneToggleHandler = ^{
        // [R3] If the host has disabled unmuting and this participant is muted
        // (i.e. they would be trying to unmute), block the action.
        if (!weakSelf.roomController.isHost
            && !weakSelf.roomController.activeAllowUnmuting
            && weakSelf.normalMediaWiring.isMicNetworkMuted) {
            [weakSelf.normalControlPanel setMediaStatusText:@"The host has disabled unmuting."];
            return;
        }

        // Restricted path: route through "Ask to Unmute" flow.
        if (weakSelf.normalMediaWiring.hostMuted || weakSelf.normalMediaWiring.globalMuteActive) {
            if (weakSelf.normalMediaWiring.micUnlockApproved) {
                // Approved — twoPhaseToggle's internal guard allows this.
                [weakSelf.normalMediaWiring twoPhaseToggleMicrophone];
            } else if (!weakSelf.normalMediaWiring.micUnlockRequestPending) {
                [weakSelf.normalMediaWiring applyMicUnlockRequestPending];
                [weakSelf.moderationController requestMicUnlock];
            }
            // If pending — button is disabled, tap should not reach here.
            return;
        }

        // Normal path: self-toggle (mute ↔ unmute).
        [weakSelf.normalMediaWiring twoPhaseToggleMicrophone];
    };
    bar.speakerToggleHandler = ^{
        // Local "mute speaker": silence incoming meeting audio at the engine output
        // (mic, system volume, and recording are all unaffected). Push the new state
        // back so the button reflects it.
        BOOL newMuted = ![InterAudioEngineAccess isSpeakerMuted];
        [InterAudioEngineAccess setSpeakerMuted:newMuted];
        [weakSelf.normalControlPanel setSpeakerMuted:newMuted];
    };
    bar.shareToggleHandler = ^{
        [weakSelf toggleNormalSurfaceShare];
    };
    bar.audioInputSelectionChangedHandler = ^(NSString * _Nullable deviceID) {
        [weakSelf handleNormalAudioInputSelection:deviceID];
    };

    // Panels + self state (formerly loose AppKit buttons).
    bar.chatToggleHandler = ^{ [weakSelf toggleNormalChatPanel]; };
    bar.pollToggleHandler = ^{ [weakSelf toggleNormalPollPanel]; };
    bar.qaToggleHandler = ^{ [weakSelf toggleNormalQAPanel]; };
    bar.raiseHandToggleHandler = ^{ [weakSelf toggleNormalHandRaise]; };
    bar.leaveHandler = ^{ [weakSelf requestExitCurrentMode]; };

    // More menu routes (the Moderation menu is now SwiftUI — each row routes
    // to the same selectors the legacy NSMenu targeted).
    bar.lobbyHandler = ^{ [weakSelf toggleNormalLobbyPanel]; };
    bar.renameHandler = ^{ [weakSelf selfRenameAction:nil]; };
    bar.moderationMenuWillOpenHandler = ^{ [weakSelf pushModerationStateToBar]; };
    bar.toggleMuteAllHandler = ^{
        if (weakSelf.moderationController.isAllMuted) [weakSelf moderationUnmuteAll];
        else [weakSelf moderationMuteAll];
        [weakSelf pushModerationStateToBar];
    };
    bar.toggleAllCamerasHandler = ^{
        if (weakSelf.moderationController.isAllCameraMuted) [weakSelf moderationLiftCameraAll];
        else [weakSelf moderationMuteCameraAll];
        [weakSelf pushModerationStateToBar];
    };
    bar.stopAllSharesHandler = ^{ [weakSelf moderationStopAllScreenShares]; };
    bar.toggleChatDisabledHandler = ^{
        if (weakSelf.moderationController.isChatDisabled) [weakSelf moderationEnableChat];
        else [weakSelf moderationDisableChat];
        [weakSelf pushModerationStateToBar];
    };
    bar.toggleCoHostRecordingHandler = ^{
        [weakSelf moderationToggleCoHostLocalRecording];
        [weakSelf pushModerationStateToBar];
    };
    bar.toggleLockHandler = ^{
        if (weakSelf.moderationController.isMeetingLocked) [weakSelf moderationUnlockMeeting];
        else [weakSelf moderationLockMeeting];
        [weakSelf pushModerationStateToBar];
    };
    bar.passwordViewHandler = ^{ [weakSelf moderationViewPassword]; };
    bar.passwordChangeHandler = ^{ [weakSelf moderationSetPassword]; };
    bar.passwordRemoveHandler = ^{ [weakSelf moderationRemovePassword]; };
    bar.shareConflictChangedHandler = ^(NSString *policy) {
        if ([policy isEqualToString:@"hostCanPreempt"]) [weakSelf moderationShareConflictHostCanPreempt];
        else if ([policy isEqualToString:@"anyCanPreempt"]) [weakSelf moderationShareConflictAnyCanPreempt];
        else [weakSelf moderationShareConflictOneAtATime];
        [weakSelf pushModerationStateToBar];
    };

    // Participants panel: live list + the same per-participant host-mute the
    // tile three-dot menu performs (mute, not block — they can ask to unmute).
    bar.participantsProvider = ^NSArray<NSDictionary<NSString *, NSString *> *> *{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return @[];
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary<NSString *, NSString *> *p in [s.roomController remoteParticipantList]) {
            NSString *identity = p[@"identity"] ?: @"";
            if (identity.length == 0) continue;
            [rows addObject:@{
                @"identity": identity,
                @"name": p[@"name"] ?: identity,
                @"hostMuted": [s.hostMutedParticipants containsObject:identity] ? @"1" : @"0",
            }];
        }
        return rows;
    };
    bar.participantMuteHandler = ^(NSString *identity) {
        [weakSelf handleTileModerationAction:@"muteMic" forParticipant:identity];
    };
    bar.participantUnmuteHandler = ^(NSString *identity) {
        // Lift the host block (same flow as the tile menu's "Remove Mute").
        [weakSelf handleTileModerationAction:@"removeMute" forParticipant:identity];
    };

    // Consolidated requests panel — the bridge KVO-observes the queues' counts;
    // approve/deny route to the same delegate bodies the legacy queue panels used.
    bar.requestApproveHandler = ^(NSString *kindRaw, NSString *identity) {
        [weakSelf handleRequestForKind:kindRaw identity:identity approved:YES];
    };
    bar.requestDenyHandler = ^(NSString *kindRaw, NSString *identity) {
        [weakSelf handleRequestForKind:kindRaw identity:identity approved:NO];
    };
    [bar attachQueuesWithSpeakerQueue:self.speakerQueue
                     screenShareQueue:self.screenShareQueue
                    cameraUnlockQueue:self.cameraUnlockQueue
                       micUnlockQueue:self.micUnlockQueue];

    // [Phase 10] Record toggle — visible to anyone with canStartRecording (host + co-host)
    BOOL canRecord = [InterPermissionMatrix
                      role:self.moderationController.localRole
                      hasPermission:(InterPermission)InterPermissionCanStartRecording];
    [bar setRecordingButtonHidden:!canRecord];
    bar.recordToggleHandler = ^{
        [weakSelf handleRecordToggle];
    };

    // [Phase 10 R2] View Recordings — visible to authenticated users
    BOOL canViewRecordings = self.roomController.tokenService.isAuthenticated;
    [bar setViewRecordingsButtonHidden:!canViewRecordings];
    bar.viewRecordingsHandler = ^{
        [weakSelf toggleNormalRecordingListPanel];
    };

    // Screen share permission mode selector ("Who can share") — host only
    if (self.roomController.isHost) {
        NSString *initialMode = self.roomController.activeSharingPermissions ?: @"hostOnly";
        [bar setScreenSharePermissionMode:initialMode];
        bar.screenShareModeChangedHandler = ^(NSString *mode) {
            [weakSelf handleScreenShareModeChanged:mode];
        };
    }

    // Moderation / requests / lobby visibility (host + co-host); self-rename for
    // non-moderators (moderators reach rename via the Moderation menu).
    BOOL canModerateUI = [InterPermissionMatrix
                          role:self.moderationController.localRole
                          hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    [bar setModerationVisible:canModerateUI];
    [bar setRenameVisible:(!canModerateUI && [self.moderationController canLocalParticipantSelfRename])];
    [self pushModerationStateToBar];
}

/// Push the moderation controller's current state into the SwiftUI bar so the
/// Moderation menu renders fresh labels (Mute All vs Unmute All, …). Called
/// before the menu opens and after every menu action.
- (void)pushModerationStateToBar {
    InterCallControlBarBridge *bar = self.normalControlPanel;
    if (!bar || !self.moderationController) return;
    BOOL hasPlaintext = (self.currentMeetingPassword.length > 0);
    BOOL hasPassword = self.roomController.activeHasPassword || hasPlaintext;
    [bar setModerationStateWithAllMuted:self.moderationController.isAllMuted
                          allCamerasOff:self.moderationController.isAllCameraMuted
                           chatDisabled:self.moderationController.isChatDisabled
                 coHostRecordingAllowed:self.coHostLocalRecordingAllowed
                          meetingLocked:self.moderationController.isMeetingLocked
                            hasPassword:hasPassword
                   hasPlaintextPassword:hasPlaintext
                    shareConflictPolicy:self.moderationController.shareConflictPolicy ?: @"oneattime"
                             isHostRole:self.roomController.isHost];
}

/// Routes an approve/deny from the consolidated Requests panel to the same
/// delegate bodies the legacy per-queue panels used (panels are gone in normal
/// mode; their delegate methods remain the single source of moderation logic).
/// kindRaw matches CallRequestKind.rawValue.
- (void)handleRequestForKind:(NSString *)kindRaw identity:(NSString *)identity approved:(BOOL)approved {
    if ([kindRaw isEqualToString:@"Raised Hands"]) {
        // Approve = acknowledge/lower the hand. (Allow-to-speak for host-muted
        // participants stays on the participant tile menu, unchanged.)
        [self acknowledgeRaisedHandForParticipant:identity];
        return;
    }
    if ([kindRaw isEqualToString:@"Screen Share"]) {
        if (approved) {
            [self approveScreenShareRequestForParticipant:identity];
        } else {
            [self denyScreenShareRequestForParticipant:identity];
        }
        return;
    }
    if ([kindRaw isEqualToString:@"Camera Unlock"]) {
        if (approved) {
            [self approveCameraUnlockRequestForParticipant:identity];
        } else {
            [self denyCameraUnlockRequestForParticipant:identity];
        }
        return;
    }
    if ([kindRaw isEqualToString:@"Mic Unlock"]) {
        if (approved) {
            [self approveMicUnlockRequestForParticipant:identity];
        } else {
            [self denyMicUnlockRequestForParticipant:identity];
        }
    }
}

- (void)startNormalLocalMediaFlow {
    self.normalShareSystemAudioEnabled = NO;
    self.normalMediaController = [[InterLocalMediaController alloc] init];
    self.normalSurfaceShareController = [[InterSurfaceShareController alloc] init];
    // Default to Window mode; the unified share picker decides the real source
    // (window vs entire screen) per share, so this is just the initial config.
    [self.normalSurfaceShareController configureWithSessionKind:InterShareSessionKindNormal
                                                      shareMode:InterShareModeWindow];
    [self.normalSurfaceShareController setShareSystemAudioEnabled:self.normalShareSystemAudioEnabled];
    __weak typeof(self) weakSelf = self;
    self.normalMediaController.audioInputOptionsChangedHandler = ^{
        [weakSelf refreshNormalAudioInputOptions];
    };
    [self refreshNormalAudioInputOptions];

    self.normalSurfaceShareController.statusHandler = ^(NSString *statusText) {
        [weakSelf.normalControlPanel setShareStatusText:statusText];
        BOOL startPending = weakSelf.normalSurfaceShareController.isStartPending;
        BOOL sharing = weakSelf.normalSurfaceShareController.isSharing;
        [weakSelf.normalControlPanel setShareStartPending:startPending];
        [weakSelf.normalControlPanel setSharingEnabled:sharing];
        // Publish screen share track to LiveKit when sharing starts
        if (sharing && weakSelf.roomController.connectionState == InterRoomConnectionStateConnected) {
            [weakSelf.roomController.publisher publishScreenShareWithCompletion:^(NSError *error) {
                if (error) {
                    NSLog(@"[G8] Screen share publish error: %@", error.localizedDescription);
                }
            }];
        }
    };
    self.normalSurfaceShareController.audioSampleObserverRegistrationBlock =
    ^(InterSurfaceShareAudioSampleHandler _Nullable sampleHandler) {
        weakSelf.normalMediaController.audioSampleBufferHandler = sampleHandler;
    };

    [self.normalControlPanel setMediaStatusText:@"Requesting camera/mic permission..."];

    [self.normalMediaController prepareWithCompletion:^(BOOL success, NSString * _Nullable failureReason) {
        if (!success) {
            NSString *message = failureReason ?: @"Camera/mic initialization failed.";
            [weakSelf.normalControlPanel setMediaStatusText:message];
            [weakSelf.normalControlPanel setCameraEnabled:NO];
            [weakSelf.normalControlPanel setMicrophoneEnabled:NO];
            return;
        }

        [weakSelf.normalMediaController start];
        [weakSelf.normalControlPanel setCameraEnabled:weakSelf.normalMediaController.isCameraEnabled];
        [weakSelf.normalControlPanel setMicrophoneEnabled:weakSelf.normalMediaController.isMicrophoneEnabled];

        NSString *message = [weakSelf normalMediaStateSummary];
        if (failureReason.length > 0) {
            message = failureReason;
        }
        [weakSelf.normalControlPanel setMediaStatusText:message];

        // Apply join-time mute / camera-off settings configured by the host.
        // This must run after -start so the capture session is running and
        // setMicrophoneEnabled: / setCameraEnabled: actually take effect.
        // roomController.activeMuteOnJoin / activeCameraOffOnJoin are populated
        // for both the host path (from InterRoomConfiguration) and the
        // participant path (from the /room/join response) before this callback
        // fires, so reading them here is safe.
        //
        // [R5] wireNetworkPublish must run AFTER these async operations complete.
        // Both setMicrophoneEnabled:completion: and setCameraEnabled:completion:
        // dispatch work to the sessionQueue; isMicrophoneEnabled / isCameraEnabled
        // are only updated on that queue. Running wireNetworkPublish immediately
        // caused it to read the stale (still-enabled) values, publishing a LiveKit
        // WebRTC mic track that captures audio independently of AVCaptureSession —
        // so the LiveKit track stayed active even after AVCaptureSession audio input
        // was removed, leaving audio flowing while the button showed "Turn Mic On".
        dispatch_group_t joinGroup = dispatch_group_create();

        // Join-state rule: the host's enforcement (muteOnJoin/cameraOffOnJoin)
        // OR the user's green-room choice ("join muted" / "join without
        // video"). The user choice can only add OFF — it never overrides a
        // host enforcement. Consumed once per launch, then reset.
        BOOL micOffOnJoin = weakSelf.roomController.activeMuteOnJoin || weakSelf.greenRoomWantsMicOff;
        BOOL camOffOnJoin = weakSelf.roomController.activeCameraOffOnJoin || weakSelf.greenRoomWantsCamOff;
        weakSelf.greenRoomWantsMicOff = NO;
        weakSelf.greenRoomWantsCamOff = NO;

        if (micOffOnJoin) {
            dispatch_group_enter(joinGroup);
            [weakSelf.normalMediaController setMicrophoneEnabled:NO completion:^(BOOL __unused s) {
                [weakSelf.normalControlPanel setMicrophoneEnabled:NO];
                dispatch_group_leave(joinGroup);
            }];
        }
        if (camOffOnJoin) {
            dispatch_group_enter(joinGroup);
            [weakSelf.normalMediaController setCameraEnabled:NO completion:^(BOOL __unused s) {
                [weakSelf.normalControlPanel setCameraEnabled:NO];
                dispatch_group_leave(joinGroup);
            }];
        }

        // [2.5.4] Wire network publishing only after join-time mute/disable operations
        // have fully applied (isMicrophoneEnabled / isCameraEnabled are now correct).
        dispatch_group_notify(joinGroup, dispatch_get_main_queue(), ^{
            // Re-derive the "Camera …, Mic …" summary AFTER join-time settings
            // applied — the earlier push ran before camOffOnJoin/micOffOnJoin
            // and reported stale state ("Camera on" while the camera was off).
            [weakSelf.normalControlPanel setMediaStatusText:[weakSelf normalMediaStateSummary]];
            [weakSelf.normalMediaWiring wireNetworkPublish];
            // Seed the self-tile mic/cam badges from the now-accurate device state.
            // The roster's local entry was seeded at wiring time before the capture
            // session started (mediaController nil / device flags still NO), which left
            // the self-tile mic icon stuck "muted"; this is the first point the true
            // state is known. wireNetworkPublish (above) has set isMicNetworkMuted, so
            // the connected mic truth is also correct here.
            [weakSelf.normalMediaWiring refreshLocalMediaStateInRoster];

            // [Mic preference] Apply the user's selected mic (green-room / persisted
            // choice) to LiveKit's native capture. Without this, LiveKit captures from
            // the system default at join regardless of the picker. No-op when the
            // preferred device already IS the system default (avoids an ADM restart).
            NSString *prefMicID = [weakSelf.normalMediaController selectedAudioInputDeviceID];
            if (prefMicID.length > 0) {
                NSString *prefMicName = [AVCaptureDevice deviceWithUniqueID:prefMicID].localizedName;
                [weakSelf.roomController setNetworkAudioInputWithDeviceID:prefMicID name:prefMicName];
            }
            [weakSelf refreshNormalAudioInputOptions];
        });
    }];
}

- (NSString *)normalMediaStateSummary {
    BOOL cameraOn = self.normalMediaController.isCameraEnabled;
    // Mic truth depends on connection state (F3 — single source of truth):
    //   • Connected: the LiveKit track IS the mic. isMicNetworkMuted is the only
    //     authority. We must NOT AND-in isMicrophoneEnabled (the AVCaptureSession audio
    //     input, which feeds recording/share, not the call). mute-on-join disables that
    //     input at join, so the old `isMicrophoneEnabled && !isMicNetworkMuted` reported
    //     "Mic off" even after the participant unmuted and the LiveKit track went live.
    //   • Offline/pre-connect: no LiveKit track yet, so isMicrophoneEnabled is the truth.
    BOOL connected = (self.roomController.connectionState == InterRoomConnectionStateConnected);
    BOOL microphoneOn = connected
        ? !self.normalMediaWiring.isMicNetworkMuted
        : self.normalMediaController.isMicrophoneEnabled;
    return [NSString stringWithFormat:@"Camera %@, Mic %@.",
            cameraOn ? @"on" : @"off",
            microphoneOn ? @"on" : @"off"];
}

- (void)refreshNormalAudioInputOptions {
    if (!self.normalMediaController || !self.normalControlPanel) {
        return;
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *options = [self.normalMediaController availableAudioInputOptions];

    // The checkmark is derived solely from the AVCapture-validated selection.
    // -selectedAudioInputDeviceID validates against the live discovery list, so it never
    // returns an id missing from the menu (fixes the stale/orphan tick on hot-unplug).
    //
    // We deliberately DO NOT query LiveKit's AudioManager.inputDevice here. That getter is
    // a synchronous WebRTC Thread::BlockingCall; issuing it on the main thread during an
    // audio route change (earphone plug/unplug) blocked the main thread (UI/video freeze)
    // AND poked the AudioDeviceModule on the same WebRTC thread that was tearing down the
    // AVAudioEngine, racing CoreAudio's route-change property listener into an
    // EXC_BAD_ACCESS. See spec: audio-route-change-crash-fix.
    NSString *selectedDeviceID = [self.normalMediaController selectedAudioInputDeviceID];
    [self.normalControlPanel setAudioInputOptions:options selectedDeviceID:selectedDeviceID];
}

- (void)handleNormalAudioInputSelection:(NSString * _Nullable)deviceID {
    if (!self.normalMediaController) {
        return;
    }

    // When connected, modifying the AVCaptureSession's audio input calls
    // beginConfiguration / commitConfiguration which momentarily interrupts ALL
    // session outputs — including the camera video preview. And the AVCaptureSession
    // mic is NOT the network mic: LiveKit captures natively via its audio device
    // module. So instead of reconfiguring the session, we re-point LiveKit's capture
    // device directly (below), which is what actually changes the transmitted audio.
    InterRoomController *rc = self.roomController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
    if (isConnected) {
        // Remember the selection (applied to the AVCapture path on next session setup).
        [self.normalMediaController storePreferredAudioDeviceID:deviceID];

        // Re-point LiveKit's NATIVE capture so the change actually affects the
        // transmitted (and recorded) audio. Previously this was a silent no-op while
        // connected — the picker only touched the AVCaptureSession (which isn't the
        // network mic) and that reconfig is skipped mid-call. Match LiveKit's input
        // device by id/name; a no-op if no match. A switch briefly interrupts audio.
        NSString *deviceName = nil;
        if (deviceID.length > 0) {
            AVCaptureDevice *dev = [AVCaptureDevice deviceWithUniqueID:deviceID];
            deviceName = dev.localizedName;
        }
        BOOL switched = [rc setNetworkAudioInputWithDeviceID:deviceID name:deviceName];
        if (!switched) {
            [self.normalControlPanel setMediaStatusText:@"Couldn't switch microphone for the call."];
        }
        [self refreshNormalAudioInputOptions];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self.normalMediaController selectAudioInputDeviceWithID:deviceID completion:^(BOOL success) {
        [weakSelf refreshNormalAudioInputOptions];
        if (!success) {
            [weakSelf.normalControlPanel setMediaStatusText:@"Unable to switch microphone source."];
            return;
        }

        [weakSelf.normalControlPanel setMediaStatusText:[weakSelf normalMediaStateSummary]];
    }];
}

// [B1] toggleNormalCamera + toggleNormalMicrophone removed — now in InterMediaWiringController.

- (void)toggleNormalSurfaceShare {
    // Sync button state — an async error may have reset sharing behind our back
    BOOL currentlySharing = self.normalSurfaceShareController.isSharing;
    BOOL startPending = self.normalSurfaceShareController.isStartPending;
    [self.normalControlPanel setShareStartPending:startPending];
    [self.normalControlPanel setSharingEnabled:currentlySharing];

    if (currentlySharing || startPending) {
        // Stopping is always permitted regardless of permission settings.
        // Clear any pending approval request.
        self.normalShareRequestPending = NO;
        self.normalPendingShareRequestIdentity = nil;
        // Unpublish screen share track from LiveKit before stopping
        [self.roomController.publisher unpublishScreenShareWithCompletion:nil];
        [self.normalSurfaceShareController stopSharingFromSurfaceView:nil];
        // Clear network sink on stop
        self.normalSurfaceShareController.networkPublishSink = nil;
        [self.normalControlPanel setShareStartPending:self.normalSurfaceShareController.isStartPending];
        [self.normalControlPanel setSharingEnabled:self.normalSurfaceShareController.isSharing];

        // [Phase 10] Notify recording coordinator that screen share stopped.
        [self.normalRecordingCoordinator screenShareDidChangeWithIsActive:NO];
        return;
    }

    // [R4] Enforce sharing permissions before starting a share.
    NSString *sharingPerms = self.roomController.activeSharingPermissions ?: @"hostOnly";
    BOOL isHost = self.roomController.isHost;
    if (!isHost) {
        if ([sharingPerms isEqualToString:@"hostOnly"]) {
            [self.normalControlPanel setShareStatusText:@"Only the host can share their screen."];
            return;
        }
        if ([sharingPerms isEqualToString:@"request"]) {
            if (self.normalShareRequestPending) {
                // Second tap while waiting — cancel the pending request
                self.normalShareRequestPending = NO;
                [self.normalControlPanel setShareStatusText:@"Screen share request cancelled."];
                [self.normalControlPanel setShareStartPending:NO];
            } else {
                // Send request to host and wait for approval
                self.normalShareRequestPending = YES;
                [self.moderationController requestScreenShare];
                [self.normalControlPanel setShareStatusText:@"Waiting for host to approve screen share..."];
                [self.normalControlPanel setShareStartPending:YES];
            }
            return;
        }
        // "everyone" — fall through to normal start path
    }

    // [ShareConflict] Enforce the "who can share when someone is already sharing" policy.
    // Check if any remote participant currently has an active screen share track.
    NSArray<NSString *> *remoteSharers = self.roomController.subscriber.activeScreenShareIdentities;
    if (remoteSharers.count > 0) {
        NSString *currentSharerIdentity = remoteSharers.firstObject;
        NSString *policy = self.moderationController.shareConflictPolicy ?: @"oneattime";

        if ([policy isEqualToString:@"oneattime"]) {
            [self.normalControlPanel setShareStatusText:@"Someone is already sharing. They must stop before you can share."];
            return;
        }

        if ([policy isEqualToString:@"hostCanPreempt"]) {
            if (!self.roomController.isHost) {
                [self.normalControlPanel setShareStatusText:@"Only the host can take over a screen share."];
                return;
            }
            // Host is allowed to preempt — signal the current sharer to stop.
            [self.moderationController sendStopScreenShareToIdentity:currentSharerIdentity];
            // Fall through: start our share immediately (optimistic preemption).
        } else if ([policy isEqualToString:@"anyCanPreempt"]) {
            // Any participant may preempt — signal current sharer to stop.
            [self.moderationController sendStopScreenShareToIdentity:currentSharerIdentity];
            // Fall through: start our share immediately.
        }
        // If no policy matched (unknown value), fall through safely to start share.
    }

    // Both share kinds (window + entire screen) require screen-recording permission.
    if (![InterScreenCaptureVideoSource preflightScreenCaptureAccess]) {
        (void)[InterScreenCaptureVideoSource requestScreenCaptureAccessIfNeeded];
        [self.normalControlPanel setShareStatusText:@"Screen recording permission is required. Enable it in System Settings, then click Share again."];
        [self.normalControlPanel setShareStartPending:NO];
        [self.normalControlPanel setSharingEnabled:NO];
        return;
    }

    [self presentNormalSharePicker];
}

/// Presents the unified share picker (entire-screen tiles + window grid +
/// "Share system audio" toggle) and starts the share with the selection.
- (void)presentNormalSharePicker {
    NSWindow *parent = self.normalCallWindow;
    if (!parent) { return; }

    __weak typeof(self) weakSelf = self;
    [InterWindowPickerPanel showUnifiedPickerRelativeToWindow:parent
                                                systemAudioOn:self.normalShareSystemAudioEnabled
                                                   completion:^(BOOL isDisplay,
                                                                NSString * _Nullable identifier,
                                                                BOOL shareSystemAudio) {
        if (!identifier) { return; }   // cancelled
        weakSelf.normalShareSystemAudioEnabled = shareSystemAudio;
        InterShareMode mode = isDisplay ? InterShareModeEntireScreen : InterShareModeWindow;
        [weakSelf startNormalShareWithMode:mode sourceIdentifier:identifier];
    }];
}

/// Common path for starting a normal surface share with the picker's selection.
/// `sourceIdentifier` is a CGWindowID string (Window mode) or CGDirectDisplayID
/// string (EntireScreen mode).
- (void)startNormalShareWithMode:(InterShareMode)shareMode
                sourceIdentifier:(NSString * _Nullable)sourceIdentifier {
    [self.normalSurfaceShareController configureWithSessionKind:InterShareSessionKindNormal
                                                      shareMode:shareMode];
    [self.normalSurfaceShareController setShareSystemAudioEnabled:self.normalShareSystemAudioEnabled];

    if (sourceIdentifier.length > 0) {
        if (shareMode == InterShareModeEntireScreen) {
            self.normalSurfaceShareController.configuration.selectedDisplayIdentifier = sourceIdentifier;
        } else {
            self.normalSurfaceShareController.configuration.selectedWindowIdentifier = sourceIdentifier;
        }
    }

    // [2.5.5] Wire network sink before starting share
    [self.normalMediaWiring wireNetworkSinkOnSurfaceShareController:self.normalSurfaceShareController];

    [self.normalSurfaceShareController startSharingFromSurfaceView:nil];
    [self.normalControlPanel setShareStartPending:self.normalSurfaceShareController.isStartPending];
    [self.normalControlPanel setSharingEnabled:self.normalSurfaceShareController.isSharing];
    // Don't optimistically read isSharing here — it may be YES momentarily
    // before an async permission error resets it. The statusHandler will
    // sync the button state when the capture actually succeeds or fails.

    // [Phase 10] Notify recording coordinator that screen share started so it
    // can insert its sink into the live pipeline. Without this, screen shares
    // started *during* recording produce no frames in the recording output.
    [self.normalRecordingCoordinator screenShareDidChangeWithIsActive:YES];
}

#pragma mark - Network Wiring [2.5]

// [B1] KVO, connection/presence state handling, network publish, and screen share
// sink wiring are now in InterMediaWiringController (self.normalMediaWiring).

/// [3.2.1] Wire remote video rendering — connect subscriber to layout manager
- (void)wireNormalRemoteRendering {
    InterRoomController *rc = self.roomController;
    if (!rc || !self.normalRemoteLayout) {
        return;
    }

    self.normalTrackRendererBridge = [[InterTrackRendererBridge alloc] initWithLayoutManager:self.normalRemoteLayout];
    rc.subscriber.trackRenderer = (id<InterRemoteTrackRenderer>)self.normalTrackRendererBridge;

    // Re-fire presence join events for any participants already in the room.
    // subscriber.attach() seeds presence before trackRenderer is wired, so the
    // optional-chaining dispatches on the main queue arrive while trackRenderer is
    // still nil and are silently dropped. This matters most when cameraOffOnJoin = YES:
    // with no camera track there are no frames, so the first-frame rescue path never
    // fires, and the participant's tile is never created (they look completely invisible).
    [rc.subscriber reseedPresence];

    // [3.2.4] [G6] Show "Waiting for participant…" overlay when alone + connected
    if (rc.connectionState == InterRoomConnectionStateConnected &&
        rc.participantPresenceState == InterParticipantPresenceStateAlone) {
        [self.normalRemoteLayout.participantOverlay setOverlayState:InterParticipantOverlayStateWaiting];
    }

    // Wire overlay delegate
    __weak typeof(self) weakSelf = self;
    self.normalRemoteLayout.participantOverlay.delegate = (id<InterParticipantOverlayDelegate>)weakSelf;
}

/// [3.4.1] Update connection status on the normal call control panel.
- (void)updateNormalConnectionStatus {
    InterRoomController *rc = self.roomController;
    if (!rc || !self.normalControlPanel) return;

    NSString *text = [InterMediaWiringController connectionLabelForState:rc.connectionState];
    [self.normalControlPanel setConnectionStatusText:text];

    // [3.4.2] Room code
    if (rc.roomCode.length > 0) {
        [self.normalControlPanel setRoomCodeText:rc.roomCode];
    }
}

// [B1] twoPhaseToggleNormalCamera, performLocalCameraToggle:,
// twoPhaseToggleNormalMicrophone, performLocalMicrophoneToggle:
// are now in InterMediaWiringController (self.normalMediaWiring).

// [2.5.3] [G4] Mode transition support
- (void)handleModeTransitionIfNeeded:(void (^)(void))exitWork {
    InterRoomController *rc = self.roomController;
    if (rc && (rc.connectionState == InterRoomConnectionStateConnected ||
               rc.connectionState == InterRoomConnectionStateReconnecting)) {
        // Room is live — transition mode [G4]: detach sources, keep room alive
        [rc transitionModeWithCompletion:^{
            // Network sinks detached. Now it's safe to tear down the old mode
            if (exitWork) {
                exitWork();
            }
        }];
    } else {
        // No active connection — proceed immediately
        if (exitWork) {
            exitWork();
        }
    }
}

#pragma mark - InterParticipantOverlayDelegate [3.2.5]

- (void)overlayDidRequestWait:(InterParticipantOverlayView *)overlay {
    // User chose to wait — hide overlay and stay in call
    [overlay setOverlayState:InterParticipantOverlayStateWaiting];
}

- (void)overlayDidRequestEndCall:(InterParticipantOverlayView *)overlay {
    [overlay setOverlayState:InterParticipantOverlayStateHidden];
    [self requestExitCurrentMode];
}

#pragma mark - Phase 8: In-Meeting Communication

// MARK: Button Actions

- (void)toggleNormalChatPanel {
    if (!self.normalChatPanel) return;
    [self.normalChatPanel togglePanel];
    self.chatController.isChatVisible = self.normalChatPanel.isExpanded;
    if (self.normalChatPanel.isExpanded) {
        [self.normalChatPanel setUnreadBadge:0];
    }
}

- (void)toggleNormalHandRaise {
    if (!self.chatController) return;
    NSString *localIdentity = self.roomController.localParticipantIdentity;
    if (localIdentity.length > 0 && [self.speakerQueue isHandRaisedFor:localIdentity]) {
        [self.chatController lowerHand];
        [self.speakerQueue removeHandFor:localIdentity];
        [self.normalControlPanel setHandRaised:NO];
    } else {
        [self.chatController raiseHand];
        NSString *displayName = self.roomController.localParticipantName;
        [self.speakerQueue addHandWithIdentity:localIdentity displayName:displayName];
        [self.normalControlPanel setHandRaised:YES];
    }
}

// MARK: InterChatControllerDelegate

- (void)chatController:(InterChatController *)controller
      didReceiveMessage:(InterChatMessageInfo *)message {
    [self.normalChatPanel appendMessage:message];
    if (!self.normalChatPanel.isExpanded) {
        [self.normalChatPanel setUnreadBadge:controller.unreadCount];
        [self.normalControlPanel setChatUnread:controller.unreadCount];
    }
}

- (void)chatController:(InterChatController *)controller
   didUpdateUnreadCount:(NSInteger)count {
    if (!self.normalChatPanel.isExpanded) {
        [self.normalChatPanel setUnreadBadge:count];
        [self.normalControlPanel setChatUnread:count];
    }
}

// MARK: InterControlSignalDelegate

- (void)chatController:(InterChatController *)controller
  participantDidRaiseHand:(NSString *)identity
            displayName:(NSString *)displayName {
    [self.speakerQueue addHandWithIdentity:identity displayName:displayName];
    [self.normalRemoteLayout setHandRaised:YES forParticipant:identity];
    [self notifyHostOfInCallRequest:[NSString stringWithFormat:@"%@ raised their hand",
                                     displayName.length ? displayName : @"Someone"]];
}

- (void)chatController:(InterChatController *)controller
  participantDidLowerHand:(NSString *)identity {
    [self.speakerQueue removeHandFor:identity];
    [self.normalRemoteLayout setHandRaised:NO forParticipant:identity];

    // If the dismissed identity is our own (host lowered our hand), reset the
    // raise-hand button. Mic button state is managed exclusively by
    // deriveParticipantMicButton — do NOT override it here.
    NSString *localIdentity = self.roomController.localParticipantIdentity;
    if ([identity isEqualToString:localIdentity]) {
        [self.normalControlPanel setHandRaised:NO];
    }
}

// MARK: InterChatPanelDelegate

- (void)chatPanel:(InterChatPanel *)panel didSubmitMessage:(NSString *)text {
    if (self.normalChatSelectedRecipient.length > 0) {
        [self.chatController sendDirectMessage:text to:self.normalChatSelectedRecipient];
    } else {
        [self.chatController sendPublicMessage:text];
    }
}

- (void)chatPanelDidRequestExport:(InterChatPanel *)panel {
#pragma unused(panel)
    NSURL *exportedURL = [self.chatController exportTranscriptText];
    if (!exportedURL) return;

    NSSavePanel *savePanel = [NSSavePanel savePanel];
    [savePanel setAllowedContentTypes:@[[UTType typeWithIdentifier:@"public.plain-text"]]];
    [savePanel setNameFieldStringValue:exportedURL.lastPathComponent];

    [savePanel beginSheetModalForWindow:self.normalCallWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !savePanel.URL) return;
        NSError *error = nil;
        [[NSFileManager defaultManager] copyItemAtURL:exportedURL toURL:savePanel.URL error:&error];
        if (error) {
            NSLog(@"[Phase 8] Transcript export copy failed: %@", error.localizedDescription);
        }
    }];
}

- (void)chatPanel:(InterChatPanel *)panel didSelectRecipient:(NSString *)recipientIdentity {
#pragma unused(panel)
    self.normalChatSelectedRecipient = recipientIdentity;
}

- (void)chatPanelDidRequestFileAttach:(InterChatPanel *)panel {
#pragma unused(panel)
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.allowsMultipleSelection = NO;
    openPanel.canChooseDirectories    = NO;
    openPanel.canChooseFiles          = YES;
    openPanel.message = @"Select a file to share (max 10 MB)";

    __weak typeof(self) weakSelf = self;
    [openPanel beginSheetModalForWindow:self.normalCallWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !openPanel.URL) return;
        NSURL *fileURL = openPanel.URL;

        // Enforce client-side size guard (server also enforces, but fail fast)
        NSNumber *fileSize = nil;
        [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        if (fileSize && fileSize.longLongValue > 10 * 1024 * 1024) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText   = @"File Too Large";
            alert.informativeText = @"Please select a file smaller than 10 MB.";
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:self.normalCallWindow completionHandler:nil];
            return;
        }

        [weakSelf uploadChatFile:fileURL];
    }];
}

- (void)uploadChatFile:(NSURL *)fileURL {
    NSString *roomCode = self.roomController.roomCode;
    NSString *identity = self.roomController.localParticipantIdentity;
    NSString *serverURL = self.roomController.tokenServerURL;

    if (!roomCode.length || !identity.length || !serverURL.length) {
        NSLog(@"[Chat] File upload skipped — not in an active room");
        return;
    }

    [self.normalChatPanel setUploadInProgress:YES];

    __weak typeof(self) weakSelf = self;
    [self.roomController.tokenService uploadChatFile:fileURL
                                           serverURL:serverURL
                                            roomCode:roomCode
                                            identity:identity
                                          completion:^(NSString *fileId,
                                                       NSString *originalName,
                                                       NSString *mimeType,
                                                       int64_t sizeBytes,
                                                       NSError *error) {
        [weakSelf.normalChatPanel setUploadInProgress:NO];
        if (error || !fileId.length) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText    = @"Upload Failed";
            alert.informativeText = error.localizedDescription ?: @"Could not upload the file.";
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:weakSelf.normalCallWindow completionHandler:nil];
            return;
        }
        [weakSelf.chatController sendFileMessageWithFileId:fileId
                                                  fileName:originalName ?: fileURL.lastPathComponent
                                             fileSizeBytes:sizeBytes
                                                  mimeType:mimeType ?: @"application/octet-stream"];
    }];
}

- (void)chatPanel:(InterChatPanel *)panel didRequestDownloadFileMessage:(InterChatMessageInfo *)message {
#pragma unused(panel)
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    [savePanel setNameFieldStringValue:message.fileName ?: @"file"];

    __weak typeof(self) weakSelf = self;
    [savePanel beginSheetModalForWindow:self.normalCallWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !savePanel.URL) return;
        NSURL *destination = savePanel.URL;

        NSString *roomCode  = weakSelf.roomController.roomCode;
        NSString *identity  = weakSelf.roomController.localParticipantIdentity;
        NSString *serverURL = weakSelf.roomController.tokenServerURL;

        if (!roomCode.length || !identity.length || !serverURL.length) return;

        [weakSelf.roomController.tokenService downloadChatFile:message.fileId
                                                     serverURL:serverURL
                                                      roomCode:roomCode
                                                      identity:identity
                                                   destination:destination
                                                    completion:^(NSError *dlError) {
            if (dlError) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText    = @"Download Failed";
                alert.informativeText = dlError.localizedDescription ?: @"Could not download the file.";
                [alert addButtonWithTitle:@"OK"];
                [alert beginSheetModalForWindow:weakSelf.normalCallWindow completionHandler:nil];
            }
        }];
    }];
}

// MARK: - Requests moderation logic (raised hands)
// Routed from -handleRequestForKind:identity:approved:. The consolidated SwiftUI
// Requests panel (More ▸ Requests) refreshes from the queue MODEL via KVO, so no
// panel push is needed here — we mutate the queue + network + tile state only.

- (void)acknowledgeRaisedHandForParticipant:(NSString *)identity {
    // Lower the hand via network so the participant gets notified.
    [self.chatController lowerHandForParticipant:identity];
    [self.speakerQueue removeHandFor:identity];
    [self.normalRemoteLayout setHandRaised:NO forParticipant:identity];
}

// MARK: Phase 8.5 — Poll Toggle & Delegate

- (void)toggleNormalPollPanel {
    if (!self.normalPollWindow) return;
    if (self.normalPollWindow.isVisible) {
        [self.normalPollWindow orderOut:nil];
    } else {
        [self.normalPollWindow makeKeyAndOrderFront:nil];
    }
}

- (void)pollPanel:(InterPollPanel *)panel
    didLaunchPollWithQuestion:(NSString *)question
              options:(NSArray<NSString *> *)options
          isAnonymous:(BOOL)isAnonymous
     allowMultiSelect:(BOOL)allowMultiSelect {
#pragma unused(panel)
    [self.pollController launchPollWithQuestion:question
                                        options:options
                                    isAnonymous:isAnonymous
                               allowMultiSelect:allowMultiSelect];
}

- (void)pollPanelDidEndPoll:(InterPollPanel *)panel {
#pragma unused(panel)
    [self.pollController endCurrentPoll];
}

- (void)pollPanelDidRequestShareResults:(InterPollPanel *)panel {
#pragma unused(panel)
    [self.pollController shareResults];
}

- (void)pollPanel:(InterPollPanel *)panel didSubmitVoteWithIndices:(NSArray<NSNumber *> *)indices {
#pragma unused(panel)
    NSMutableArray<NSNumber *> *intArray = [NSMutableArray arrayWithCapacity:indices.count];
    for (NSNumber *n in indices) {
        [intArray addObject:@(n.integerValue)];
    }
    [self.pollController submitVoteWithOptionIndices:intArray];
}

// MARK: InterPollControllerDelegate

- (void)pollController:(InterPollController *)controller didLaunchPoll:(InterPollInfo *)poll {
#pragma unused(controller)
    [self.normalPollPanel showActivePoll:poll];
    if (!self.normalPollWindow.isVisible) {
        [self.normalPollWindow makeKeyAndOrderFront:nil];
    }
}

- (void)pollController:(InterPollController *)controller didUpdateResults:(InterPollInfo *)poll {
#pragma unused(controller)
    [self.normalPollPanel updateResults:poll];
}

- (void)pollController:(InterPollController *)controller didEndPoll:(InterPollInfo *)poll {
#pragma unused(controller)
    [self.normalPollPanel showEndedPoll:poll];
}

// MARK: Phase 8.6 — Q&A Toggle & Delegate

- (void)toggleNormalQAPanel {
    if (!self.normalQAWindow) return;
    if (self.normalQAWindow.isVisible) {
        [self.normalQAWindow orderOut:nil];
        self.qaController.isQAVisible = NO;
    } else {
        [self.normalQAWindow makeKeyAndOrderFront:nil];
        self.qaController.isQAVisible = YES;
        [self.normalQAPanel setUnreadBadge:0];
        [self.normalControlPanel setQAUnread:0];
    }
}

- (void)qaPanel:(InterQAPanel *)panel didSubmitQuestion:(NSString *)text isAnonymous:(BOOL)isAnonymous {
#pragma unused(panel)
    [self.qaController submitQuestion:text isAnonymous:isAnonymous];
}

- (void)qaPanel:(InterQAPanel *)panel didUpvoteQuestion:(NSString *)questionId {
#pragma unused(panel)
    [self.qaController upvoteQuestion:questionId];
}

- (void)qaPanel:(InterQAPanel *)panel didMarkAnswered:(NSString *)questionId {
#pragma unused(panel)
    [self.qaController markAnswered:questionId];
}

- (void)qaPanel:(InterQAPanel *)panel didHighlightQuestion:(NSString *)questionId {
#pragma unused(panel)
    [self.qaController highlightQuestion:questionId];
}

- (void)qaPanel:(InterQAPanel *)panel didDismissQuestion:(NSString *)questionId {
#pragma unused(panel)
    [self.qaController dismissQuestion:questionId];
}

// MARK: InterQAControllerDelegate

- (void)qaController:(InterQAController *)controller didUpdateQuestions:(NSArray<InterQuestionInfo *> *)questions {
#pragma unused(controller)
    [self.normalQAPanel setQuestions:questions];
    if (!self.normalQAWindow.isVisible) {
        [self.normalQAPanel setUnreadBadge:controller.unreadCount];
        [self.normalControlPanel setQAUnread:controller.unreadCount];
    }
}

// MARK: InterMediaWiringDelegate (Phase 8 — participant list sync)

- (void)mediaWiringControllerDidChangeConnectionState:(NSInteger)state {
    InterRoomConnectionState cs = (InterRoomConnectionState)state;
    if (cs != InterRoomConnectionStateConnected) return;

    // T6: On (re)connect, fetch any pending screen share requests from Redis ZSET
    [self fetchScreenShareQueueSnapshot];

    // T9: On (re)connect, restore camera-lock state from server
    [self fetchCameraLockedSnapshot];
    // T9b: On (re)connect, restore mic-lock state from server
    [self fetchMicLockedSnapshot];
    // [2A] On (re)connect, ask whether a recording is already in progress so a
    // participant who joined AFTER recording started still sees the consent overlay
    // (the .recordingStarted DataChannel signal is one-time and never reaches them).
    [self fetchRecordingStatus];

    // T7: Sync the screen share permission mode toggle to live value
    if (self.roomController.isHost) {
        NSString *mode = self.roomController.activeSharingPermissions ?: @"hostOnly";
        [self.normalControlPanel setScreenSharePermissionMode:mode];
    }
}

/// [2A] Fetch the room's recording status on (re)connect. If a recording is active
/// and we are not the host, present the consent overlay (once per recording session).
- (void)fetchRecordingStatus {
    if (self.roomController.isHost) return;            // host initiated it; no consent needed
    if (self.normalRecordingConsentHandled) return;     // already handled this session
    NSString *roomCode = self.roomController.roomCode;
    NSString *serverURL = self.roomController.tokenServerURL;
    if (!roomCode.length || !serverURL.length) return;

    NSString *encodedCode = [roomCode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlStr = [NSString stringWithFormat:@"%@/room/record/status/%@", serverURL, encodedCode];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    NSString *token = self.roomController.tokenService.currentAccessToken;
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return;
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode > 299) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) return;
        BOOL recording = [json[@"recording"] boolValue];
        if (!recording) return;
        NSString *mode = [json[@"mode"] isKindOfClass:[NSString class]] ? json[@"mode"] : @"local_composed";
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            // Re-check guards on the main thread (state may have changed during the fetch).
            if (strongSelf.roomController.isHost) return;
            if (strongSelf.normalRecordingConsentHandled) return;
            if (strongSelf.currentCallMode == InterCallModeNone) return;
            [strongSelf showRecordingConsentOverlayForRemoteRecordingWithMode:mode];
            strongSelf.normalRecordingConsentHandled = YES;
        });
    }] resume];
}

/// Fetch pending screen share requests from server on (re)connect.
- (void)fetchScreenShareQueueSnapshot {
    NSString *roomCode = self.roomController.roomCode;
    NSString *identity = self.roomController.localParticipantIdentity;
    NSString *serverURL = self.roomController.tokenServerURL;
    if (!roomCode.length || !identity.length || !serverURL.length) return;

    NSString *urlStr = [NSString stringWithFormat:@"%@/room/screenshare-queue?roomCode=%@&callerIdentity=%@",
                        serverURL,
                        [roomCode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                        [identity stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    NSString *token = self.roomController.tokenService.currentAccessToken;
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return;
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode > 299) return;
        NSError *parseError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        if (parseError || ![json isKindOfClass:[NSDictionary class]]) return;
        NSArray<NSDictionary *> *entries = json[@"entries"];
        if (![entries isKindOfClass:[NSArray class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            // Always reset local queue first so stale requests from a previous
            // session are not left behind when the server returns an empty list.
            [weakSelf.screenShareQueue reset];
            if (entries.count == 0) {
                return;
            }
            for (NSDictionary *entry in entries) {
                NSString *entryIdentity = entry[@"identity"];
                NSString *displayName = entry[@"displayName"] ?: entryIdentity;
                NSTimeInterval timestamp = [entry[@"timestamp"] doubleValue];
                if (entryIdentity.length) {
                    [weakSelf.screenShareQueue addRequestWithIdentity:entryIdentity
                                                         displayName:displayName
                                                           timestamp:timestamp];
                }
            }
        });
    }] resume];
}

/// T9: Fetch camera-locked identities on (re)connect and apply local lock state.
- (void)fetchCameraLockedSnapshot {
    NSString *roomCode = self.roomController.roomCode;
    NSString *identity = self.roomController.localParticipantIdentity;
    NSString *serverURL = self.roomController.tokenServerURL;
    if (!roomCode.length || !identity.length || !serverURL.length) return;

    NSString *urlStr = [NSString stringWithFormat:@"%@/room/camera-locked?roomCode=%@&callerIdentity=%@",
                        serverURL,
                        [roomCode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                        [identity stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    NSString *token = self.roomController.tokenService.currentAccessToken;
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return;
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode > 299) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray<NSString *> *locked = json[@"locked"];
        if (![locked isKindOfClass:[NSArray class]]) return;
        BOOL globalLock = [json[@"globalLock"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            NSString *localIdentity = weakSelf.roomController.localParticipantIdentity;

            // Clear all existing camera-lock state before applying the fresh
            // snapshot. Without this, stale locks survive when participants
            // are unlocked between reconnects and locked.count == 0 would have
            // returned early, leaving stale badges and disabled camera buttons.
            [weakSelf.normalMediaWiring applyHostCameraLiftForParticipant];
            [weakSelf.normalMediaWiring applyHostCameraLiftForAll];
            [weakSelf.normalRemoteLayout clearAllHostCameraLocks];

            // Apply each lock from the snapshot.
            for (NSString *lockedIdentity in locked) {
                if (![lockedIdentity isKindOfClass:[NSString class]] || !lockedIdentity.length) continue;
                if ([lockedIdentity isEqualToString:localIdentity]) {
                    // Use global flag variant if the server said it's a global lock.
                    if (globalLock) {
                        [weakSelf.normalMediaWiring applyHostCameraMuteForAll];
                    } else {
                        [weakSelf.normalMediaWiring applyHostCameraMuteForParticipant];
                    }
                } else {
                    // A remote participant is locked — update their tile badge.
                    [weakSelf.normalRemoteLayout setIsHostCameraLocked:YES forParticipant:lockedIdentity];
                }
            }
        });
    }] resume];
}

/// T9b: Fetch mic-locked identities on (re)connect and apply local host-muted state.
- (void)fetchMicLockedSnapshot {
    NSString *roomCode = self.roomController.roomCode;
    NSString *identity = self.roomController.localParticipantIdentity;
    NSString *serverURL = self.roomController.tokenServerURL;
    if (!roomCode.length || !identity.length || !serverURL.length) return;

    NSString *urlStr = [NSString stringWithFormat:@"%@/room/mic-locked?roomCode=%@&callerIdentity=%@",
                        serverURL,
                        [roomCode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                        [identity stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    NSString *token = self.roomController.tokenService.currentAccessToken;
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return;
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode > 299) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray<NSString *> *locked = json[@"locked"];
        if (![locked isKindOfClass:[NSArray class]]) return;
        // Whether a GLOBAL mute-all is in effect for us. Drives global vs per-tile UI.
        BOOL globalMute = [json[@"globalMute"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            NSString *localIdentity = weakSelf.roomController.localParticipantIdentity;

            // Clear all existing mic-lock state before applying the fresh snapshot,
            // mirroring the clear-then-reapply flow in fetchCameraLockedSnapshot.
            // Without this, identities unlocked between reconnects remain stale.
            // Capture whether local was individually host-muted before this snapshot.
            // localIdentity is never stored in hostMutedParticipants (remote-only set), so
            // this boolean is the only way to detect a stale local host-mute to clear.
            BOOL wasLocalHostMuted = weakSelf.localMicHostMuted;
            weakSelf.localMicHostMuted = NO;

            NSSet<NSString *> *previouslyMuted = [weakSelf.hostMutedParticipants copy];
            [weakSelf.hostMutedParticipants removeAllObjects];
            for (NSString *oldIdentity in previouslyMuted) {
                [weakSelf.normalRemoteLayout setHostMuted:NO forParticipant:oldIdentity];
            }

            // Apply each lock from the snapshot.
            for (NSString *lockedIdentity in locked) {
                if (![lockedIdentity isKindOfClass:[NSString class]] || !lockedIdentity.length) continue;
                if ([lockedIdentity isEqualToString:localIdentity]) {
                    // We are mic-locked. Under a global mute-all, apply the GLOBAL mute
                    // path (“✋ Raise Hand to Speak”) so a participant who joined AFTER the
                    // mute-all sees exactly what everyone else sees; a per-tile mute would
                    // wrongly show “Muted by host” with a disabled button.
                    if (globalMute) {
                        [weakSelf.normalMediaWiring applyRemoteMicMute];
                    } else {
                        [weakSelf.normalMediaWiring applyRemoteMicMuteOne];
                    }
                    weakSelf.localMicHostMuted = YES;
                } else {
                    // A remote participant is mic-locked — update their tile badge.
                    [weakSelf.normalRemoteLayout setHostMuted:YES forParticipant:lockedIdentity];
                    [weakSelf.hostMutedParticipants addObject:lockedIdentity];
                }
            }

            // If local was host-muted before this snapshot but is no longer in the locked list,
            // the restriction was lifted server-side (e.g. removed by host between reconnects).
            if (wasLocalHostMuted && !weakSelf.localMicHostMuted) {
                [weakSelf.normalMediaWiring applyRemoteMicUnmute];
            }
        });
    }] resume];
}

/// Persist a per-participant camera lock/lift to Redis via REST, then call completion(success).
/// Pass a non-nil completion block to chain the DataChannel signal after successful persistence.
- (void)persistCameraLock:(BOOL)lock identity:(NSString *)targetIdentity completion:(void (^)(BOOL success))completion {
    NSString *roomCode = self.roomController.roomCode;
    NSString *callerIdentity = self.roomController.localParticipantIdentity;
    NSString *serverURL = self.roomController.tokenServerURL;
    if (!roomCode.length || !callerIdentity.length || !serverURL.length || !targetIdentity.length) {
        if (completion) completion(NO);
        return;
    }

    NSString *endpoint = lock ? @"/room/camera-lock-one" : @"/room/camera-lift-one";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", serverURL, endpoint]];
    if (!url) { if (completion) completion(NO); return; }
    InterTokenService *tokenService = self.roomController.tokenService;
    if (!tokenService) { if (completion) completion(NO); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 10.0;
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{ @"roomCode": roomCode, @"callerIdentity": callerIdentity, @"targetIdentity": targetIdentity };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    // Route through the token service so an expired host access token is silently
    // refreshed and the request retried (mirrors the moderation HTTP path). Without
    // this, a mid-call token expiry made Stop Video / Lock Camera silently no-op —
    // and because the DataChannel signal is chained inside this success block, the
    // block never reached the participant either.
    [tokenService performAuthenticatedRequest:req completion:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)r;
        BOOL ok = !e && (http.statusCode >= 200 && http.statusCode <= 299);
        if (!ok) NSLog(@"[CameraLock] persistCameraLock failed: %@", e.localizedDescription ?: @"non-2xx");
        if (completion) completion(ok);
    }];
}

/// T7: Host changed screen share permission mid-meeting.
- (void)handleScreenShareModeChanged:(NSString *)mode {
    NSString *roomCode = self.roomController.roomCode;
    NSString *callerIdentity = self.roomController.localParticipantIdentity;
    NSString *serverURL = self.roomController.tokenServerURL;
    if (!roomCode.length || !callerIdentity.length || !serverURL.length) return;

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/room/screen-share-mode", serverURL]];
    if (!url) return;
    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:10.0];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSString *token = self.roomController.tokenService.currentAccessToken;
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    NSDictionary *body = @{ @"roomCode": roomCode, @"callerIdentity": callerIdentity, @"mode": mode };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    // Capture previous mode for revert on failure.
    NSString *previousMode = self.roomController.activeSharingPermissions ?: @"hostOnly";

    // Disable the control while the request is in flight so the host cannot
    // fire a second change before the server has confirmed the first.
    [self.normalControlPanel setScreenSharePermissionEnabled:NO];

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)r;
        BOOL success = !e && (http.statusCode >= 200 && http.statusCode < 300);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.normalControlPanel setScreenSharePermissionEnabled:YES];
            if (!success) {
                // Server rejected the change — revert the segmented control.
                NSLog(@"[ScreenShare] mode change failed: %@",
                      e ? e.localizedDescription : [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]);
                [weakSelf.normalControlPanel setScreenSharePermissionMode:previousMode];
                return;
            }
            // Server confirmed — apply local state and broadcast to co-hosts.
            [weakSelf.moderationController broadcastScreenShareMode:mode];
            [weakSelf.roomController updateSharingPermissions:mode];
            // Moving away from "request" mode: clear the pending share queue.
            if ([mode isEqualToString:@"everyone"] || [mode isEqualToString:@"hostOnly"]) {
                [weakSelf.screenShareQueue reset];
            }
        });
    }] resume];
}

- (void)mediaWiringControllerDidChangePresenceState:(NSInteger)state {
    [self refreshChatParticipantList];

    // [Phase 10 R3] When a participant joins and the host is recording,
    // re-broadcast the recording signal so the late joiner shows consent.
    if (state == (NSInteger)InterParticipantPresenceStateParticipantJoined) {
        if (self.roomController.isHost &&
            self.normalRecordingCoordinator.state == InterRecordingStateRecording) {
            [self.chatController broadcastRecordingSignalWithType:InterControlSignalTypeRecordingStarted];
        }
    }
}

- (void)refreshChatParticipantList {
    if (!self.normalChatPanel || !self.roomController) return;
    NSArray<NSDictionary<NSString *, NSString *> *> *rawList = [self.roomController remoteParticipantList];
    // [2B] Feed the local participant's display name to the recording renderer so its
    // camera-off placeholder shows a name/avatar (not a raw identity or a frozen frame).
    NSString *localId = self.roomController.localParticipantIdentity;
    NSString *localName = self.roomController.localParticipantName;
    if (localId.length > 0 && localName.length > 0) {
        [self.normalRecordingCoordinator setParticipantDisplayName:localName forIdentity:localId];
    }
    // Apply any display-name overrides from the layout manager (covers DataChannel renames
    // which don't update LiveKit metadata and would otherwise show the old name).
    if (!self.normalRemoteLayout) {
        for (NSDictionary<NSString *, NSString *> *p in rawList) {
            NSString *pid = p[@"identity"] ?: @"";
            NSString *pname = p[@"name"] ?: @"";
            if (pid.length > 0 && pname.length > 0) {
                [self.normalRecordingCoordinator setParticipantDisplayName:pname forIdentity:pid];
            }
        }
        [self.normalChatPanel setParticipantList:rawList];
        return;
    }
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *list =
        [NSMutableArray arrayWithCapacity:rawList.count];
    for (NSDictionary<NSString *, NSString *> *p in rawList) {
        NSString *identity = p[@"identity"] ?: @"";
        NSString *overrideName = [self.normalRemoteLayout displayNameForTileKey:identity];
        // displayNameForTileKey: returns the identity itself when no override is registered;
        // fall back to the LiveKit name in that case so we don't regress to raw UUIDs.
        NSString *livekitName = p[@"name"] ?: identity;
        NSString *displayName = (overrideName.length > 0 && ![overrideName isEqualToString:identity])
            ? overrideName : livekitName;
        [list addObject:@{@"identity": identity, @"name": displayName}];
        // [2B] Keep the recording renderer's placeholder names in sync (incl. renames).
        if (identity.length > 0 && displayName.length > 0) {
            [self.normalRecordingCoordinator setParticipantDisplayName:displayName forIdentity:identity];
        }
    }
    [self.normalChatPanel setParticipantList:list];
}

// MARK: - Phase 9 — Lobby Panel

- (void)toggleNormalLobbyPanel {
    if (!self.normalLobbyWindow) {
        // Create lobby panel next to the control bar. Sized to comfortably fit the SwiftUI
        // content (header actions + rows) so labels don't truncate/wrap; minSize keeps it
        // usable when the host resizes it down.
        CGFloat panelWidth = 400;
        CGFloat panelHeight = 480;
        NSRect windowFrame = self.normalCallWindow.frame;
        CGFloat x = NSMaxX(windowFrame) - panelWidth - 12;
        CGFloat y = windowFrame.origin.y + 100;
        self.normalLobbyPanel = [[InterLobbyPanel alloc] initWithFrame:NSMakeRect(0, 0, panelWidth, panelHeight)];
        self.normalLobbyPanel.delegate = self;
        // Co-hosts can admit/deny but cannot toggle the waiting room on/off — host-only.
        [self.normalLobbyPanel setLobbyToggleEnabled:self.roomController.isHost];
        // Initialise the checkbox from the actual lobby state (host-configured in the
        // pre-meeting settings) so it reflects reality — otherwise it starts unchecked
        // and the host's first toggle would DISABLE an already-enabled waiting room.
        self.normalLobbyPanel.lobbyEnabled = self.roomController.activeLobbyEnabled;

        self.normalLobbyWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(x, y, panelWidth, panelHeight)
                                                             styleMask:(NSWindowStyleMaskTitled |
                                                                        NSWindowStyleMaskClosable |
                                                                        NSWindowStyleMaskResizable)
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO];
        self.normalLobbyWindow.title = @"Waiting Room";
        self.normalLobbyWindow.minSize = NSMakeSize(360, 300);
        self.normalLobbyWindow.releasedWhenClosed = NO;
        self.normalLobbyWindow.level = NSFloatingWindowLevel;
        [self.normalLobbyWindow setSharingType:InterWindowSharingType()];
        [self.normalLobbyWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
        self.normalLobbyWindow.contentView = self.normalLobbyPanel;
        // Theme the title bar to the app surface (transparent bar + surface fill) so it
        // matches the panel content instead of the default system gray.
        [InterWindowChrome applyPanelChromeTo:self.normalLobbyWindow];

        // Populate with any participants who joined the lobby before the panel was opened
        NSArray<NSDictionary<NSString *, NSString *> *> *waiting = self.moderationController.lobbyWaitingParticipants;
        for (NSDictionary<NSString *, NSString *> *entry in waiting) {
            NSString *ident = entry[@"identity"];
            NSString *name  = entry[@"displayName"];
            if (ident.length > 0) {
                [self.normalLobbyPanel addWaitingParticipant:ident displayName:(name ?: ident)];
            }
        }

        [self.normalLobbyWindow makeKeyAndOrderFront:nil];
        return;
    }

    if (self.normalLobbyWindow.isVisible) {
        [self.normalLobbyWindow orderOut:nil];
    } else {
        [self.normalLobbyWindow makeKeyAndOrderFront:nil];
    }
}

// MARK: InterLobbyPanelDelegate

- (void)lobbyPanel:(InterLobbyPanel *)panel didAdmitParticipant:(NSString *)identity displayName:(NSString *)displayName {
#pragma unused(panel)
    __weak typeof(self) weakSelf = self;
    [self.moderationController admitFromLobbyWithIdentity:identity displayName:displayName completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            [strongSelf.normalLobbyPanel removeWaitingParticipant:identity];
            [strongSelf refreshLobbyWaitingBadge];
        } else {
            NSLog(@"[Phase 9] Admit failed: %@", error.localizedDescription);
        }
    }];
}

- (void)lobbyPanel:(InterLobbyPanel *)panel didDenyParticipant:(NSString *)identity {
#pragma unused(panel)
    __weak typeof(self) weakSelf = self;
    [self.moderationController denyFromLobbyWithIdentity:identity completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            [strongSelf.normalLobbyPanel removeWaitingParticipant:identity];
            [strongSelf refreshLobbyWaitingBadge];
        } else {
            NSLog(@"[Phase 9] Deny failed: %@", error.localizedDescription);
        }
    }];
}

- (void)lobbyPanelDidAdmitAll:(InterLobbyPanel *)panel {
#pragma unused(panel)
    __weak typeof(self) weakSelf = self;
    [self.moderationController admitAllFromLobbyWithCompletion:^(BOOL success, NSInteger count, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            [strongSelf.normalLobbyPanel clearWaitingList];
            [strongSelf refreshLobbyWaitingBadge];
            NSLog(@"[Phase 9] Admitted all: %ld participants", (long)count);
        } else {
            NSLog(@"[Phase 9] Admit all failed: %@", error.localizedDescription);
        }
    }];
}

- (void)lobbyPanel:(InterLobbyPanel *)panel didToggleLobbyEnabled:(BOOL)enabled {
#pragma unused(panel)
    __weak typeof(self) weakSelf = self;
    if (enabled) {
        [self.moderationController enableLobbyWithCompletion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!success) {
                NSLog(@"[Phase 9] Enable lobby failed: %@", error.localizedDescription);
                strongSelf.normalLobbyPanel.lobbyEnabled = NO;
            }
        }];
    } else {
        [self.moderationController disableLobbyWithCompletion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!success) {
                NSLog(@"[Phase 9] Disable lobby failed: %@", error.localizedDescription);
                strongSelf.normalLobbyPanel.lobbyEnabled = YES;
            }
        }];
    }
}

// MARK: - Phase 9 — Participant-Side Lobby Waiting

/// Show the waiting room window and start polling for admission.
- (void)showLobbyWaitingWithRoomCode:(NSString *)roomCode
                            identity:(NSString *)identity
                         displayName:(NSString *)displayName
                           serverURL:(NSString *)serverURL
                      tokenServerURL:(NSString *)tokenServerURL
                           pollToken:(NSString *)pollToken
                            position:(NSInteger)position {
    // Build the overlay in "joining" state (in case it isn't already showing),
    // then immediately transition it to the waiting room state.
    if (!self.lobbyWaitingWindow) {
        [self _showJoiningOverlayWithCode:roomCode
                                 identity:identity
                              displayName:displayName
                                serverURL:serverURL
                           tokenServerURL:tokenServerURL];
    }
    [self _transitionOverlayToWaitingRoomWithPollToken:pollToken position:position];
}

/// Poll GET /room/lobby-status/:code/:identity for admission status.
- (void)_pollLobbyStatus {
    NSString *code     = self.lobbyRoomCode;
    NSString *identity = self.lobbyIdentity;
    NSString *pollToken = self.lobbyPollToken;
    NSString *tokenURL  = self.lobbyTokenServerURL;

    if (!code || !identity || !pollToken || !tokenURL) return;

    NSString *encodedIdentity = [identity stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlStr = [NSString stringWithFormat:@"%@/room/lobby-status/%@/%@", tokenURL, code, encodedIdentity];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:pollToken forHTTPHeaderField:@"x-poll-token"];
    [request setTimeoutInterval:10.0];

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error || !data) return; // Silently retry next tick

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSDictionary class]]) return;

            NSString *status = json[@"status"];

            if ([status isEqualToString:@"admitted"]) {
                // Admitted! Connect to the room with the token from the server
                [strongSelf.lobbyStatusPollTimer invalidate];
                strongSelf.lobbyStatusPollTimer = nil;

                [strongSelf.lobbyWaitingView showAdmitted];

                NSString *token     = json[@"token"];
                NSString *wsURL     = json[@"serverURL"];
                NSString *roomName  = json[@"roomName"];
                NSString *roomType  = json[@"roomType"] ?: @"call";

                // Brief delay so user sees the "You're In!" message
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [strongSelf lobbyAdmittedWithToken:token
                                            serverURL:wsURL
                                             roomCode:code
                                             roomName:roomName
                                             roomType:roomType
                                            settings:json];
                });

            } else if ([status isEqualToString:@"denied"]) {
                [strongSelf.lobbyStatusPollTimer invalidate];
                strongSelf.lobbyStatusPollTimer = nil;
                [strongSelf.lobbyWaitingView showDenied];

            } else if ([status isEqualToString:@"room_full"]) {
                [strongSelf.lobbyStatusPollTimer invalidate];
                strongSelf.lobbyStatusPollTimer = nil;
                [strongSelf.lobbyWaitingView setStatusMessage:@"The meeting is full. Please try again later."];
                [strongSelf.lobbyWaitingView showDenied];

            } else if ([status isEqualToString:@"not_found"]) {
                [strongSelf.lobbyStatusPollTimer invalidate];
                strongSelf.lobbyStatusPollTimer = nil;
                [strongSelf.lobbyWaitingView setStatusMessage:@"The meeting has ended or your request expired."];
                [strongSelf.lobbyWaitingView showDenied];

            } else if ([status isEqualToString:@"waiting"]) {
                NSInteger position = [json[@"position"] integerValue];
                [strongSelf.lobbyWaitingView setPosition:position];
            }
        });
    }] resume];
}

/// Handle successful admission from the lobby — connect to the room.
- (void)lobbyAdmittedWithToken:(NSString *)token
                     serverURL:(NSString *)wsURL
                      roomCode:(NSString *)roomCode
                      roomName:(NSString *)roomName
                      roomType:(NSString *)roomType
                      settings:(NSDictionary *)settings {
    [self.lobbyWaitingWindow orderOut:nil];
    self.lobbyWaitingWindow = nil;
    self.lobbyWaitingView = nil;

    // Build config and connect through the room controller
    InterRoomController *rc = self.roomController;
    if (!rc || !token.length || !wsURL.length) {
        NSLog(@"[Phase 9] Lobby admitted but missing token/URL — cannot connect");
        return;
    }

    // Apply meeting settings now so they are ready before launchNormalCallWindow runs.
    // The settings dict was returned by /room/lobby-status once the host admitted us.
    if (settings.count > 0) {
        [rc applyMeetingSettingsFromDict:settings];
    }

    InterRoomConfiguration *config =
        [[InterRoomConfiguration alloc] initWithServerURL:wsURL
                                          tokenServerURL:self.lobbyTokenServerURL ?: @""
                                                roomCode:roomCode
                                     participantIdentity:self.lobbyIdentity ?: @""
                                         participantName:self.lobbyDisplayName ?: @""
                                                  isHost:NO
                                                roomType:roomType
                                        maxParticipants:50];

    // The token was already generated server-side during admission,
    // so we connect directly with it.
    __weak typeof(self) weakSelf = self;
    [rc connectWithToken:token serverURL:wsURL configuration:config completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error) {
                NSLog(@"[Phase 9] Lobby admitted but connect failed: %@", error.localizedDescription);
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Connection Failed";
                alert.informativeText = @"You were admitted but the connection failed. Please try joining again.";
                [alert addButtonWithTitle:@"OK"];
                [alert runModal];
                return;
            }

            BOOL isInterview = [roomType isEqualToString:@"interview"];
            if (isInterview) {
                [strongSelf showIntervieweeConfirmationWithCompletion:^(BOOL accepted) {
                    if (accepted) {
                        [strongSelf enterMode:InterCallModeInterview role:InterInterviewRoleInterviewee];
                    } else {
                        [rc disconnect];
                    }
                }];
            } else {
                [strongSelf enterMode:InterCallModeNormal role:InterInterviewRoleNone];
            }
        });
    }];

    // Clear lobby state
    self.lobbyPollToken = nil;
    self.lobbyRoomCode = nil;
    self.lobbyIdentity = nil;
    self.lobbyDisplayName = nil;
}

- (void)lobbyWaitingViewDidCancel:(InterLobbyWaitingView *)view {
#pragma unused(view)
    // Tell the server we're withdrawing so the host's lobby list drops us (best-effort,
    // fire-and-forget — the window closes immediately regardless of the network result).
    // Only meaningful once we're actually queued (waiting state has a pollToken); in the
    // pre-queue "joining" state there's nothing to leave server-side.
    [self _leaveLobbyOnServerBestEffort];
    [self _dismissJoiningOverlay];
}

/// POST /room/lobby/leave with our per-join pollToken. Mirrors the participant-side
/// lobby-status poll (raw URLSession + x-poll-token header; the waiter may be anonymous).
- (void)_leaveLobbyOnServerBestEffort {
    NSString *code      = self.lobbyRoomCode;
    NSString *identity  = self.lobbyIdentity;
    NSString *pollToken = self.lobbyPollToken;
    NSString *tokenURL  = self.lobbyTokenServerURL;
    if (!code || !identity || !pollToken || !tokenURL) return; // not queued yet → nothing to leave

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/room/lobby/leave", tokenURL]];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:pollToken forHTTPHeaderField:@"x-poll-token"];
    [request setTimeoutInterval:10.0];
    NSDictionary *body = @{ @"roomCode": code, @"identity": identity };
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e) NSLog(@"[Lobby] leave best-effort failed: %@", e.localizedDescription);
    }] resume];
}

// MARK: - Phase 9 — Host-Side Lobby Polling

/// Start polling for lobby participants. Called when a host enters a call.
- (void)startLobbyPollingIfHost {
    if (!self.roomController.isHost) return;
    [self.lobbyPollTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.lobbyPollTimer = [NSTimer scheduledTimerWithTimeInterval:4.0
                                                         repeats:YES
                                                           block:^(NSTimer *timer) {
        [weakSelf _pollHostLobbyList];
    }];
    // Fire immediately
    [self _pollHostLobbyList];
}

/// Stop host-side lobby polling (on disconnect).
- (void)stopLobbyPolling {
    [self.lobbyPollTimer invalidate];
    self.lobbyPollTimer = nil;
}

/// Poll GET /room/lobby/list/:code from the server and update the lobby panel.
- (void)_pollHostLobbyList {
    if (!self.moderationController) return;
    __weak typeof(self) weakSelf = self;
    [self.moderationController pollLobbyListWithCompletion:^(BOOL success) {
        if (!success) return;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Update the combined More badge + "Waiting Room (n)…" row from the
        // authoritative count (single source). Toast firing is handled by the
        // join delegate, which the poll invokes for each newly-seen waiter.
        [strongSelf refreshLobbyWaitingBadge];
    }];
}

// MARK: - Self Rename

/// Presents the self-rename dialog and applies the new name via the moderation
/// controller. Available to any participant in a normal call and to the interviewer;
/// a no-op for an interviewee in an interview room (the receive side enforces this too).
- (void)selfRenameAction:(id)sender {
#pragma unused(sender)
    if (![self.moderationController canLocalParticipantSelfRename]) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Change Your Name";
    alert.informativeText = @"Enter a new display name for this session:";
    NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 22)];
    nameField.placeholderString = @"New display name";
    nameField.stringValue = self.roomController.localParticipantName ?: @"";
    alert.accessoryView = nameField;
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert layout];
    [alert.window makeFirstResponder:nameField];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *newName = nameField.stringValue;
        if (newName.length > 0) {
            [self.moderationController renameSelfWithNewDisplayName:newName];
        }
    }
}

// MARK: - Phase 9 — Moderation Menu


- (void)moderationMuteAll {
    [self.moderationController muteAllWithCompletion:^(BOOL success, NSInteger count, NSError *error) {
        if (success) {
            NSLog(@"[Phase 9] Muted %ld participants", (long)count);
            // Show "Allow" buttons in the speaker queue for raised hands
            // Mute-All is a ROOM-WIDE cause, distinct from a per-tile host block. Set the
            // layout's globalMuteActive so the cause-derived menu shows "Allow to Speak" on
            // mute-all'd participants (NOT "Remove Mute & Ask"). We must NOT stamp
            // isHostMuted on every tile — that would mislabel everyone as individually
            // blocked. Individually-blocked tiles keep their own isHostMuted (block wins
            // over mute-all in the precedence), so their menu stays correct too.
            self.normalRemoteLayout.globalMuteActive = YES;
        } else {
            NSLog(@"[Phase 9] Mute all failed: %@", error.localizedDescription);
        }
    }];
}

/// Host turns OFF all participants' cameras. Mirrors `moderationMuteAll` for the
/// camera lane: persist the global lock to Redis FIRST (durability + late-joiner
/// gate), then broadcast the DataChannel signal and mark every remote tile locked.
- (void)moderationMuteCameraAll {
    __weak typeof(self) weakSelf = self;
    [self persistCameraLockAll:YES completion:^(BOOL success) {
        if (!success) {
            NSLog(@"[Moderation] Turn off all cameras failed (server).");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.moderationController muteCameraAll];
            // Lock-All is a ROOM-WIDE cause, distinct from a per-tile camera lock. Set the
            // layout's globalCameraLockActive so the cause-derived camera menu shows
            // "Allow Camera" on lock-all'd participants (NOT "Remove Lock"). Do NOT stamp
            // isHostCameraLocked on every tile — that would mislabel everyone as individually
            // locked. Individually-locked tiles keep their own isHostCameraLocked (lock wins
            // over lock-all in the precedence), so their menu stays correct. (Mirror of the
            // mic moderationMuteAll fix.)
            weakSelf.normalRemoteLayout.globalCameraLockActive = YES;
            // Any pending camera-unlock requests are moot now that all cameras are locked.
            [weakSelf.cameraUnlockQueue reset];
        });
    }];
}

/// Host lifts the camera lock for everyone. Counterpart to `moderationMuteCameraAll`.
- (void)moderationLiftCameraAll {
    __weak typeof(self) weakSelf = self;
    [self persistCameraLockAll:NO completion:^(BOOL success) {
        if (!success) {
            NSLog(@"[Moderation] Allow all cameras failed (server).");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.moderationController liftCameraLockAll];
            // Clear the room-wide lock-all cause; individually-locked tiles keep their own
            // isHostCameraLocked (per-tile lock persists). Mirror of moderationUnmuteAll.
            weakSelf.normalRemoteLayout.globalCameraLockActive = NO;
        });
    }];
}

/// Host stops every active screen share at once. Broadcasts the DataChannel signal
/// to all participants and also stops the host's OWN share locally, since the
/// sender does not receive its own broadcast.
- (void)moderationStopAllScreenShares {
    [self.moderationController stopAllScreenShares];

    // Stop our own share if we are currently sharing.
    BOOL locallySharing = (self.normalSurfaceShareController.isSharing ||
                           self.normalSurfaceShareController.isStartPending);
    if (locallySharing) {
        self.normalShareRequestPending = NO;
        self.normalPendingShareRequestIdentity = nil;
        [self.roomController.publisher unpublishScreenShareWithCompletion:nil];
        [self.normalSurfaceShareController stopSharingFromSurfaceView:nil];
        self.normalSurfaceShareController.networkPublishSink = nil;
        [self.normalControlPanel setShareStartPending:NO];
        [self.normalControlPanel setSharingEnabled:NO];
        [self.normalRecordingCoordinator screenShareDidChangeWithIsActive:NO];
        [self.normalControlPanel setShareStatusText:@"You stopped all screen shares."];
    }
}

/// Persist a global camera lock/lift to Redis. Mirrors `persistCameraLock:identity:`
/// but targets the all-participants endpoints (`/room/camera-lock-all`/`-lift-all`).
- (void)persistCameraLockAll:(BOOL)lock completion:(void (^)(BOOL success))completion {
    NSString *roomCode = self.roomController.roomCode;
    NSString *callerIdentity = self.roomController.localParticipantIdentity;
    NSString *serverURL = self.roomController.tokenServerURL;
    if (!roomCode.length || !callerIdentity.length || !serverURL.length) {
        if (completion) completion(NO);
        return;
    }

    NSString *endpoint = lock ? @"/room/camera-lock-all" : @"/room/camera-lift-all";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", serverURL, endpoint]];
    if (!url) { if (completion) completion(NO); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 10.0;
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSString *token = self.roomController.tokenService.currentAccessToken;
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    NSDictionary *body = @{ @"roomCode": roomCode, @"callerIdentity": callerIdentity };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)r;
        BOOL ok = !e && (http.statusCode >= 200 && http.statusCode <= 299);
        if (!ok) NSLog(@"[CameraLock] persistCameraLockAll failed: %@", e.localizedDescription ?: @"non-2xx");
        if (completion) completion(ok);
    }] resume];
}

/// Dispatches a moderation action triggered from a participant tile's three-dot menu.
- (void)handleTileModerationAction:(NSString *)actionType forParticipant:(NSString *)participantIdentity {
    if (!self.moderationController || participantIdentity.length == 0) return;

    if ([actionType isEqualToString:@"muteMic"] || [actionType isEqualToString:@"blockMic"]) {
        // "Mute Mic" (live participant) and "Block mic" (enforce-mute someone already
        // self/globally muted) are the same host action: apply a per-tile block.
        __weak typeof(self) weakSelf = self;
        [self.moderationController muteParticipantWithIdentity:participantIdentity
                                                   trackSource:@"microphone"
                                                    completion:^(BOOL success, NSError *error) {
            if (!success) { NSLog(@"[Moderation] muteMic failed for %@: %@", participantIdentity, error.localizedDescription); return; }
            // Eagerly update tile state and track as host-muted so the queue
            // shows an "Allow" button if this participant raises their hand.
            [weakSelf.normalRemoteLayout setHostMuted:YES forParticipant:participantIdentity];
            [weakSelf.hostMutedParticipants addObject:participantIdentity];
            // Remove any pending mic unlock request from this participant — it is
            // now stale since they are being re-muted.
            [weakSelf.micUnlockQueue removeRequestWithIdentity:participantIdentity];
        }];

    } else if ([actionType isEqualToString:@"allowToSpeak"]) {
        // Mute-All cause: grant this participant a one-time speak slot (existing approve
        // flow). approveMicUnlock sends the signal; the participant takes the global-mute
        // path (one-time slot with revoke detection). Lower their raised hand if pending.
        [self.moderationController approveMicUnlockWithIdentity:participantIdentity];
        [self.chatController lowerHandForParticipant:participantIdentity];
        [self.speakerQueue removeHandFor:participantIdentity];
        [self.normalRemoteLayout setHandRaised:NO forParticipant:participantIdentity];

    } else if ([actionType isEqualToString:@"askToUnmute"]) {
        // Self-muted participant (no host block). Consent-first: in NORMAL mode send a
        // request — the participant taps their own mic (no force). In INTERVIEW mode the
        // host may force-activate, so directly unmute (requestUnmuteOne; the interviewee
        // side force-turns on and shows the "host enabled" indicator).
        //
        // TODO [Increment 2 — host "Asked ✓" + cooldown + pending]: after sending the ask
        // in normal mode, give the host feedback (a transient "Asked ✓" on the menu item /
        // a short per-(tile,host) cooldown so repeated clicks don't spam the participant),
        // and set the per-tile micAskPending flag (see InterRemoteVideoLayoutManager menu
        // TODO) so the caption reads "Asked to unmute". Clear it when the participant
        // unmutes (isMicMuted→NO) or on re-block / Mute-All. No host UI feedback exists yet.
        if ([self.roomController.roomType isEqualToString:@"interview"]) {
            [self.moderationController unmuteParticipantWithIdentity:participantIdentity];
        } else {
            [self.moderationController askToUnmuteWithIdentity:participantIdentity];
        }

    } else if ([actionType isEqualToString:@"removeMute"]) {
        // Host-muted participant. Lift the host block ONLY (requestUnmuteOne): lift-only in
        // normal mode (participant's button re-enables; they tap to turn on) and force-on in
        // interview mode. We deliberately do NOT auto-send a consent request — removing the
        // block already gives them the ability, and an unsolicited nudge is poor UX. If the
        // host wants to nudge, the cause is now self-muted so the menu offers "Ask to Unmute"
        // as a separate step. Keep the hostMutedParticipants set in sync (P3).
        [self.moderationController unmuteParticipantWithIdentity:participantIdentity];
        [self.normalRemoteLayout setHostMuted:NO forParticipant:participantIdentity];
        [self.hostMutedParticipants removeObject:participantIdentity];

    } else if ([actionType isEqualToString:@"stopCamera"] || [actionType isEqualToString:@"lockCamera"]) {
        // "Stop Video" (camera live) and "Lock camera" (enforce-lock a self/globally-off
        // camera) are the same host action: persist a per-tile lock to Redis FIRST for
        // durability, then send the DataChannel signal. Participant sees "Ask to Unlock".
        __weak typeof(self) weakSelf = self;
        NSString *captured = participantIdentity;
        [self persistCameraLock:YES identity:captured completion:^(BOOL success) {
            if (success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.moderationController muteCameraOneWithIdentity:captured];
                    // Update the tile badge immediately — the DataChannel signal is
                    // filtered on own-send, so we must update the host tile directly.
                    [weakSelf.normalRemoteLayout setIsHostCameraLocked:YES forParticipant:captured];
                    // Remove any pending unlock request for this participant
                    // since the lock is being freshly applied.
                    [weakSelf.cameraUnlockQueue removeRequestWithIdentity:captured];
                });
            }
        }];

    } else if ([actionType isEqualToString:@"removeCameraLock"]) {
        // "Remove Lock" (locked-by-host) — lift the per-tile lock ONLY. The participant can
        // then turn their own camera on; we do NOT auto-send a request (same consent-first
        // refinement as removeMute). The participant-side applyHostCameraLiftForParticipant
        // is lift-only in normal mode / force-restore in interview mode.
        __weak typeof(self) weakSelf = self;
        NSString *captured = participantIdentity;
        [self persistCameraLock:NO identity:captured completion:^(BOOL success) {
            if (success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.moderationController liftCameraLockOneWithIdentity:captured];
                    // Update the tile badge immediately — same reason as the lock path.
                    [weakSelf.normalRemoteLayout setIsHostCameraLocked:NO forParticipant:captured];
                    // Remove any pending unlock request for this participant.
                    [weakSelf.cameraUnlockQueue removeRequestWithIdentity:captured];
                });
            }
        }];

    } else if ([actionType isEqualToString:@"askToTurnOnCamera"]) {
        // Self-off participant (no host lock). Consent-first: send a REQUEST — the
        // participant turns their own camera on (no force; camera frames require their
        // device). The menu reads "Ask to Turn On Camera" in ALL modes for this cause,
        // including interview: deriveCamera only force-labels the wired removeLock path, so
        // there is no label/behavior mismatch here.
        //
        // TODO [migration — interview self-off camera force]: the ratified spec allows the
        // interviewer to force-restore a camera in interview mode (Option 2), but that is
        // intentionally NOT wired for the self-off (never-locked) case yet, because a true
        // force MUST be accompanied by the participant-facing "host enabled your camera"
        // indicator (spec §5 / Finding B) — which is also deferred. Wire BOTH together: a
        // force path that publishes the interviewee's camera + the persistent indicator,
        // then set deriveCamera's `forces` for askToTurnOn in interview and route this branch
        // to the force instead of a request. Until then, this stays a consent request.
        [self.moderationController askToUnmuteCameraWithIdentity:participantIdentity];

    } else if ([actionType isEqualToString:@"allowCamera"]) {
        // Lock-All cause: grant this participant a one-time camera slot (existing approve
        // flow). approveCameraUnlock sends the signal; participant may turn camera on once.
        //
        // TODO [migration — host "Asked ✓" + cooldown, camera; UI work]: like the mic ask,
        // after issuing askToTurnOnCamera / allowCamera the host gets NO delivery feedback and
        // can re-click repeatedly, spamming the participant. Add a transient "Asked ✓" state +
        // a short per-(tile,host) cooldown on these camera actions. Mirror the mic-side TODO;
        // do both together. (Host still sees the live state via the tile caption/badge.)
        [self.moderationController approveCameraUnlockWithIdentity:participantIdentity];
        [self.cameraUnlockQueue removeRequestWithIdentity:participantIdentity];

    } else if ([actionType isEqualToString:@"pinForAll"]) {
        [self.moderationController addPinnedParticipantWithIdentity:participantIdentity];

    } else if ([actionType isEqualToString:@"unpinForAll"]) {
        [self.moderationController removePinnedParticipantWithIdentity:participantIdentity];

    } else if ([actionType isEqualToString:@"remove"]) {
        [self.moderationController removeParticipantWithIdentity:participantIdentity
                                                      completion:^(BOOL success, NSError *error) {
            if (!success) NSLog(@"[Moderation] remove failed for %@: %@", participantIdentity, error.localizedDescription);
        }];

    } else if ([actionType isEqualToString:@"makeCoHost"]) {
        __weak typeof(self) weakSelf = self;
        [self.moderationController promoteParticipantWithIdentity:participantIdentity
                                                           toRole:InterParticipantRoleCoHost
                                                       completion:^(BOOL success, NSError *error) {
            if (!success) {
                NSLog(@"[Moderation] makeCoHost failed for %@: %@", participantIdentity, error.localizedDescription);
                // The server rejects promoting a guest to co-host (TARGET_NOT_AUTHENTICATED):
                // a moderator must have joined signed-in so their identity is bound to an
                // account — the invariant validateModerator relies on (see /room/promote).
                // Surface the server's guidance so the host knows to have them sign in + rejoin.
                // TODO(SwiftUI migration): replace this NSAlert with the in-call toast/banner
                // surface when host-controls UI is migrated (tracked in ui_migration_todos).
                NSAlert *alert = [[NSAlert alloc] init];
                alert.alertStyle = NSAlertStyleInformational;
                alert.messageText = @"Can't make co-host";
                alert.informativeText = error.localizedDescription
                    ?: @"This participant joined as a guest. They need to sign in and rejoin to become a co-host.";
                [alert addButtonWithTitle:@"OK"];
                NSWindow *noticeWindow = weakSelf.normalCallWindow ?: NSApp.keyWindow;
                if (noticeWindow) {
                    [alert beginSheetModalForWindow:noticeWindow completionHandler:nil];
                } else {
                    [alert runModal];
                }
            }
            // Badge update is handled by moderationController:participantRoleChanged: via DataChannel echo.
        }];

    } else if ([actionType isEqualToString:@"removeCoHost"]) {
        [self.moderationController promoteParticipantWithIdentity:participantIdentity
                                                           toRole:InterParticipantRoleParticipant
                                                       completion:^(BOOL success, NSError *error) {
            if (!success) { NSLog(@"[Moderation] removeCoHost failed for %@: %@", participantIdentity, error.localizedDescription); }
            // Badge update is handled by moderationController:participantRoleChanged: via DataChannel echo.
        }];
    } else if ([actionType isEqualToString:@"rename"]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Rename Participant";
        alert.informativeText = @"Enter a new display name for this session:";
        NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 22)];
        nameField.placeholderString = @"New display name";
        alert.accessoryView = nameField;
        [alert addButtonWithTitle:@"Rename"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSString *newName = nameField.stringValue;
            if (newName.length > 0) {
                [self.moderationController renameParticipantWithIdentity:participantIdentity
                                                              newDisplayName:newName];
            }
        }
    }
}

- (void)moderationUnmuteAll {
    [self.moderationController unmuteAllWithCompletion:^(BOOL success, NSInteger count, NSError *error) {
        if (success) {
            NSLog(@"[Phase 9] Broadcast unmute-all request to participants");
            // Global mute session is over — hide the raise-hand gate in the queue.
            // Clear the room-wide mute-all cause so the menu stops showing "Allow to Speak".
            // Individually-blocked tiles keep their isHostMuted (per-tile mute persists, §8.1),
            // so their menu correctly stays "Remove Mute & Ask".
            self.normalRemoteLayout.globalMuteActive = NO;
            // Individual per-tile mutes persist after UnmuteAll (§8.1).
            // hostMutedParticipants retains those identities; update the queue
            // panel so it still shows Allow actions for their hand-raises.
        } else {
            NSLog(@"[Phase 9] Unmute all failed: %@", error.localizedDescription);
        }
    }];
}

- (void)moderationDisableChat {
    [self.moderationController disableChat];
}

- (void)moderationEnableChat {
    [self.moderationController enableChat];
}

- (void)moderationToggleCoHostLocalRecording {
    BOOL newValue = !self.coHostLocalRecordingAllowed;
    self.coHostLocalRecordingAllowed = newValue;
    [self.moderationController setCoHostRecordingAllowed:newValue];
}

- (void)_updateChatExportVisibility {
    if (!self.normalChatPanel) return;
    NSString *tier = self.roomController.tokenService.effectiveTier ?: @"free";
    BOOL tierOk = [InterFeatureGate isFeature:InterFeatureChatExport availableForTier:tier];
    BOOL canModerate = [InterPermissionMatrix
                        role:self.moderationController.localRole
                        hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    [self.normalChatPanel setExportButtonHidden:!(tierOk && canModerate)];
}

- (void)moderationLockMeeting {
    [self.moderationController lockMeetingWithCompletion:^(BOOL success, NSError *error) {
        if (!success) {
            NSLog(@"[Phase 9] Lock meeting failed: %@", error.localizedDescription);
        }
    }];
}

- (void)moderationUnlockMeeting {
    [self.moderationController unlockMeetingWithCompletion:^(BOOL success, NSError *error) {
        if (!success) {
            NSLog(@"[Phase 9] Unlock meeting failed: %@", error.localizedDescription);
        }
    }];
}

- (void)moderationSetPassword {
    BOOL changing = self.roomController.activeHasPassword || (self.currentMeetingPassword.length > 0);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = changing ? @"Change Meeting Password" : @"Set Meeting Password";
    alert.informativeText = changing
        ? @"Enter a new password for this meeting:"
        : @"Enter a password for this meeting:";
    [alert addButtonWithTitle:changing ? @"Change" : @"Set"];
    [alert addButtonWithTitle:@"Cancel"];

    NSSecureTextField *passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    passwordField.placeholderString = @"Password";
    // Prefill only when the plaintext is known locally (the session that set it). A
    // rejoining host / co-host changing a password starts from an empty field.
    if (self.currentMeetingPassword.length > 0) passwordField.stringValue = self.currentMeetingPassword;
    alert.accessoryView = passwordField;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *password = passwordField.stringValue;
        if (password.length > 0) {
            __weak typeof(self) weakSelf = self;
            [self.moderationController setPassword:password completion:^(BOOL success, NSError *error) {
                if (success) {
                    // Remember the plaintext for this session so the host can view/copy/change it.
                    weakSelf.currentMeetingPassword = password;
                    // Keep the server-authoritative "has password" flag in sync.
                    [weakSelf.roomController updateHasMeetingPassword:YES];
                } else {
                    NSLog(@"[Phase 9] Set password failed: %@", error.localizedDescription);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSAlert *err = [[NSAlert alloc] init];
                        err.messageText = @"Couldn't Update Password";
                        err.informativeText = @"The password could not be updated. Please try again.";
                        [err addButtonWithTitle:@"OK"];
                        [err runModal];
                    });
                }
            }];
        }
    }
}

/// Show the current meeting password with an option to copy it to the clipboard,
/// so the host can share it with invitees (Zoom/Teams-style).
- (void)moderationViewPassword {
    if (self.currentMeetingPassword.length == 0) {
        // No known plaintext — fall back to setting one.
        [self moderationSetPassword];
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Meeting Password";
    alert.informativeText = [NSString stringWithFormat:@"Share this password with people you invite:\n\n%@",
                             self.currentMeetingPassword];
    [alert addButtonWithTitle:@"Copy"];
    [alert addButtonWithTitle:@"Done"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:self.currentMeetingPassword forType:NSPasteboardTypeString];
    }
}

/// Remove the meeting password (host/co-host with canManagePassword).
- (void)moderationRemovePassword {
    __weak typeof(self) weakSelf = self;
    [self.moderationController removePasswordWithCompletion:^(BOOL success, NSError *error) {
        if (success) {
            weakSelf.currentMeetingPassword = @"";
            // Keep the server-authoritative "has password" flag in sync.
            [weakSelf.roomController updateHasMeetingPassword:NO];
        } else {
            NSLog(@"[Phase 9] Remove password failed: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *err = [[NSAlert alloc] init];
                err.messageText = @"Couldn't Remove Password";
                err.informativeText = @"The password could not be removed. Please try again.";
                [err addButtonWithTitle:@"OK"];
                [err runModal];
            });
        }
    }];
}

// MARK: - Share-Conflict Policy Actions

- (void)moderationShareConflictOneAtATime {
    [self.moderationController broadcastShareConflictPolicy:@"oneattime"];
    [self.roomController updateShareConflictPolicy:@"oneattime"];
}

- (void)moderationShareConflictHostCanPreempt {
    [self.moderationController broadcastShareConflictPolicy:@"hostCanPreempt"];
    [self.roomController updateShareConflictPolicy:@"hostCanPreempt"];
}

- (void)moderationShareConflictAnyCanPreempt {
    [self.moderationController broadcastShareConflictPolicy:@"anyCanPreempt"];
    [self.roomController updateShareConflictPolicy:@"anyCanPreempt"];
}

- (void)moderationController:(InterModerationController *)controller chatDisabledStateChanged:(BOOL)isDisabled {
#pragma unused(controller)
    if (!self.normalChatPanel) return;
    BOOL isModerator = [InterPermissionMatrix
                        role:self.moderationController.localRole
                        hasPermission:(InterPermission)InterPermissionCanDisableChat];
    [self.normalChatPanel setChatInputEnabled:isModerator || !isDisabled];
    if (isDisabled) {
        if (!isModerator) {
            [self.normalChatPanel displaySystemMessage:@"Chat has been disabled by the host."];
        }
    } else {
        [self.normalChatPanel displaySystemMessage:@"Chat has been re-enabled."];
    }
}

- (void)moderationController:(InterModerationController *)controller receivedUnmuteRequest:(NSString *)fromIdentity displayName:(NSString *)displayName {
#pragma unused(controller)
    // TODO [Increment 2 — persistent affordance]: the spec (§4.3) calls for a NON-modal,
    // PERSISTENT affordance instead of this blocking NSAlert: the participant's OWN mic
    // button pulses + a small "Host asked you to unmute" chip stays until they act, tap
    // their own mic, or dismiss it (dismiss is local-only, no "declined" signal). The
    // modal below is the interim consent prompt — it is non-silent (so it satisfies "never
    // force, always ask") but it interrupts and conflates "declined" with "never saw it".
    // Replace with the persistent chip during the UI redesign; keep "participant makes the
    // final tap" (do NOT auto-unmute beyond their own action).
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Unmute Request";
    alert.informativeText = [NSString stringWithFormat:@"%@ is asking you to unmute your microphone.", displayName];
    [alert addButtonWithTitle:@"Unmute"];
    [alert addButtonWithTitle:@"Decline"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        // User accepted — unmute microphone
        [self.normalMediaWiring toggleMicrophone];
    }
}

- (void)moderationController:(InterModerationController *)controller receivedCameraUnmuteRequest:(NSString *)fromIdentity displayName:(NSString *)displayName {
#pragma unused(controller, fromIdentity)
    // TODO [migration — persistent affordance, camera; UI work]: per spec §4.3 this should be
    // a NON-modal, PERSISTENT affordance — the participant's OWN camera button pulses + a
    // small "Host asked you to turn on your camera" chip stays until they act or dismiss it
    // (dismiss is local-only, no "declined" signal). The modal below is the interim consent
    // prompt: non-silent (satisfies "never force, always ask") but it interrupts and conflates
    // "declined" with "never saw it". Mirror of the mic receivedUnmuteRequest: TODO; do both
    // together in the UI redesign. Keep "participant makes the final tap".
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Camera Request";
    alert.informativeText = [NSString stringWithFormat:@"%@ is asking you to turn your camera on.", displayName];
    [alert addButtonWithTitle:@"Turn On Camera"];
    [alert addButtonWithTitle:@"Decline"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        // User accepted — enable camera
        [self.normalMediaWiring toggleCamera];
    }
}

- (void)moderationControllerReceivedUnmuteAllRequest:(InterModerationController *)controller {
#pragma unused(controller)
    NSLog(@"[Phase 9] Host unmuted all — restoring mic toggle ability");
    [self.normalMediaWiring applyUnmuteAll];
    // Clear the room-wide mute-all cause for ANY moderator (host or co-host) so the
    // cause-derived per-tile menu stops showing "Allow to Speak". Individually-blocked
    // tiles keep their own isHostMuted. (Was previously host-only, leaving standing
    // co-hosts with a stale menu.)
    BOOL canModerate = [InterPermissionMatrix
                        role:controller.localRole
                        hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    if (canModerate) {
        self.normalRemoteLayout.globalMuteActive = NO;
    }
    // Host-specific speaker-queue bookkeeping (the host owns the raise-hand gate UI).
    if (self.roomController.isHost) {
        [self.moderationController applyExternalGlobalMuteChanged:NO];
        // Preserve individual tile-mutes — same §8.1 rule as moderationUnmuteAll.
    }
}

- (void)moderationControllerReceivedMuteAllRequest:(InterModerationController *)controller {
#pragma unused(controller)
    NSLog(@"[Phase 9] Host muted all — updating local mic state");
    [self.normalMediaWiring applyRemoteMicMute];
    // Cancel any pending mic unlock requests — they are invalidated by the new mute.
    [self.micUnlockQueue reset];
    // Set the room-wide mute-all cause for ANY moderator (host or co-host) so the
    // cause-derived per-tile menu shows "Allow to Speak". (Was previously host-only.)
    BOOL canModerate = [InterPermissionMatrix
                        role:controller.localRole
                        hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    if (canModerate) {
        self.normalRemoteLayout.globalMuteActive = YES;
    }
    // Host-specific speaker-queue bookkeeping (the host owns the raise-hand gate UI).
    if (self.roomController.isHost) {
        [self.moderationController applyExternalGlobalMuteChanged:YES];
    }
}

- (void)moderationControllerReceivedMuteOneRequest:(InterModerationController *)controller {
#pragma unused(controller)
    NSLog(@"[Phase 9] Host muted this participant (soft mute) — mic muted, no raise-hand gate");
    [self.normalMediaWiring applyRemoteMicMuteOne];
    self.localMicHostMuted = YES;
}

- (void)moderationControllerReceivedUnmuteOneRequest:(InterModerationController *)controller {
#pragma unused(controller)
    NSLog(@"[Phase 9] Host lifted per-participant mic mute — clearing restriction and unmuting");
    [self.normalMediaWiring applyRemoteMicUnmute];
    self.localMicHostMuted = NO;
}

- (void)moderationController:(InterModerationController *)controller receivedSpeakRequest:(NSString *)fromIdentity displayName:(NSString *)displayName {
#pragma unused(controller, fromIdentity, displayName)
    // No-op: speak requests are now handled via the raise-hand flow.
    // Participants raise their hand when host-muted, and the host sees
    // "Allow" + "Dismiss" buttons in the speaker queue panel.
}

- (void)moderationControllerReceivedAllowToSpeak:(InterModerationController *)controller {
#pragma unused(controller)
    NSLog(@"[Phase 9] Host allowed us to speak — unmuting mic (one-time grant)");
    [self.normalMediaWiring applyAllowToSpeak];

    // Reset hand raise button (our hand was lowered by the host)
    NSString *localIdentity = self.roomController.localParticipantIdentity;
    if (localIdentity.length > 0 && [self.speakerQueue isHandRaisedFor:localIdentity]) {
        [self.speakerQueue removeHandFor:localIdentity];
    }
    [self.normalControlPanel setHandRaised:NO];
}

// [R4] Screen share request flow — participant sends request, host approves/denies.

- (void)moderationController:(InterModerationController *)controller
  receivedScreenShareRequest:(NSString *)fromIdentity
                 displayName:(NSString *)displayName {
#pragma unused(controller)
    BOOL canModerate = [InterPermissionMatrix role:self.moderationController.localRole
                                    hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    if (!canModerate) return;
    [self.screenShareQueue addRequestWithIdentity:fromIdentity displayName:displayName timestamp:[NSDate date].timeIntervalSince1970];
    [self notifyHostOfInCallRequest:[NSString stringWithFormat:@"%@ wants to share their screen",
                                     displayName.length ? displayName : @"Someone"]];
}

// MARK: - Requests moderation logic (screen-share requests)

- (void)approveScreenShareRequestForParticipant:(NSString *)identity {
    [self.screenShareQueue removeRequestWithIdentity:identity];
    [self.moderationController approveScreenShareWithIdentity:identity];
    [self resolveScreenShareRequest:identity approved:YES];
}

- (void)denyScreenShareRequestForParticipant:(NSString *)identity {
    [self.screenShareQueue removeRequestWithIdentity:identity];
    [self.moderationController denyScreenShareWithIdentity:identity];
    [self resolveScreenShareRequest:identity approved:NO];
}

/// Best-effort server call to remove a resolved request from Redis ZSET.
- (void)resolveScreenShareRequest:(NSString *)identity approved:(BOOL)approved {
    NSString *roomCode = self.roomController.roomCode;
    NSString *callerIdentity = self.roomController.localParticipantIdentity;
    NSString *serverURL = self.roomController.tokenServerURL;
    if (!roomCode.length || !callerIdentity.length || !serverURL.length) return;

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/room/resolve-screen-share-request", serverURL]];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSString *token = self.roomController.tokenService.currentAccessToken;
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }

    NSDictionary *body = @{
        @"roomCode": roomCode,
        @"callerIdentity": callerIdentity,
        @"targetIdentity": identity,
        @"resolution": approved ? @"approved" : @"denied",
    };
    NSError *jsonError = nil;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError) {
        NSLog(@"[ShareQueue] resolveScreenShareRequest JSON error: %@", jsonError.localizedDescription);
        return;
    }
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
#pragma unused(d, r)
        if (e) NSLog(@"[ShareQueue] resolveScreenShareRequest failed: %@", e.localizedDescription);
    }] resume];
}

// MARK: - Requests moderation logic (camera-unlock requests)

- (void)approveCameraUnlockRequestForParticipant:(NSString *)identity {
    // Remove from queue immediately so the UI stays responsive.
    [self.cameraUnlockQueue removeRequestWithIdentity:identity];
    // Persist to Redis first; only then send the DataChannel approval and clear the tile badge.
    // Always proceed even on Redis failure (best-effort) so the participant is not left locked.
    // We send `approveCameraUnlock` (NOT liftCameraLockOne), mirroring the mic flow's
    // `approveMicUnlock`: the participant grants themselves access (per-tile → free toggle,
    // global mute-all → one-time slot) rather than being force-restored. This is what makes
    // the approval work under a global camera-lock-all; liftCameraLockOne only cleared the
    // per-tile flag and left the global lock active, trapping the participant in a loop.
    __weak typeof(self) weakSelf = self;
    [self persistCameraLock:NO identity:identity completion:^(BOOL success) {
#pragma unused(success)
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.moderationController approveCameraUnlockWithIdentity:identity];
            [weakSelf.normalRemoteLayout setIsHostCameraLocked:NO forParticipant:identity];
        });
    }];
}

- (void)denyCameraUnlockRequestForParticipant:(NSString *)identity {
    // Notify the participant so they can clear their pending-request flag.
    [self.moderationController denyCameraUnlockWithIdentity:identity];
    [self.cameraUnlockQueue removeRequestWithIdentity:identity];
}

// MARK: - Requests moderation logic (mic-unlock requests)

- (void)approveMicUnlockRequestForParticipant:(NSString *)identity {
    // Send approval signal to participant.
    [self.moderationController approveMicUnlockWithIdentity:identity];
    // Only lift tile badge and hostMutedParticipants when mute-all is NOT active.
    // When isAllMuted=YES the approval is a one-time slot (participant wiring takes
    // the global-mute path): the per-tile restriction remains after the slot is
    // used and revoke fires. Removing the identity here would cause the F1 filter
    // to silently discard the participant's next request once mute-all is lifted,
    // because F1 discards when !isAllMuted && !inHostMutedParticipants.
    if (!self.moderationController.isAllMuted) {
        [self.normalRemoteLayout setHostMuted:NO forParticipant:identity];
        [self.hostMutedParticipants removeObject:identity];
    }
    // Remove from queue.
    [self.micUnlockQueue removeRequestWithIdentity:identity];
}

- (void)denyMicUnlockRequestForParticipant:(NSString *)identity {
    // Notify the participant so they can clear their pending-request flag.
    [self.moderationController denyMicUnlockWithIdentity:identity];
    [self.micUnlockQueue removeRequestWithIdentity:identity];
}

- (void)moderationControllerScreenShareRequestApproved:(InterModerationController *)controller {
#pragma unused(controller)
    self.normalShareRequestPending = NO;
    [self.normalControlPanel setShareStartPending:NO];
    [self.normalControlPanel setShareStatusText:@"Screen share approved — choose what to share..."];

    // Now actually start the share on behalf of the participant.
    if (![InterScreenCaptureVideoSource preflightScreenCaptureAccess]) {
        (void)[InterScreenCaptureVideoSource requestScreenCaptureAccessIfNeeded];
        [self.normalControlPanel setShareStatusText:@"Screen recording permission is required. Enable it in System Settings."];
        return;
    }

    [self presentNormalSharePicker];
}

- (void)moderationControllerScreenShareRequestDenied:(InterModerationController *)controller {
#pragma unused(controller)
    self.normalShareRequestPending = NO;
    [self.normalControlPanel setShareStartPending:NO];
    [self.normalControlPanel setShareStatusText:@"Screen share request denied by host."];
}

/// The host (or another authorised participant) asked us to stop our screen share.
/// Stop the share immediately and display a non-blocking notice on the control panel.
- (void)moderationControllerReceivedStopScreenShare:(InterModerationController *)controller
                               requestedByIdentity:(NSString *)senderIdentity {
#pragma unused(controller)
    BOOL locallySharing = (self.normalSurfaceShareController.isSharing ||
                           self.normalSurfaceShareController.isStartPending);
    if (!locallySharing) return;

    // Stop the share track, clean up, and update UI.
    self.normalShareRequestPending = NO;
    self.normalPendingShareRequestIdentity = nil;
    [self.roomController.publisher unpublishScreenShareWithCompletion:nil];
    [self.normalSurfaceShareController stopSharingFromSurfaceView:nil];
    self.normalSurfaceShareController.networkPublishSink = nil;
    [self.normalControlPanel setShareStartPending:NO];
    [self.normalControlPanel setSharingEnabled:NO];
    [self.normalRecordingCoordinator screenShareDidChangeWithIsActive:NO];

    // Display a notice — fetch the display name from the room for a friendlier message.
    NSString *displayName = [self.roomController displayNameForParticipantIdentity:senderIdentity];
    if (displayName.length == 0) displayName = @"Another participant";
    NSString *msg = [NSString stringWithFormat:@"%@ took over screen sharing.", displayName];
    [self.normalControlPanel setShareStatusText:msg];
}

/// The host stopped ALL screen shares. If we are sharing, stop and show a notice.
- (void)moderationControllerReceivedStopScreenShareAll:(InterModerationController *)controller
                                  requestedByIdentity:(NSString *)senderIdentity {
#pragma unused(controller, senderIdentity)
    BOOL locallySharing = (self.normalSurfaceShareController.isSharing ||
                           self.normalSurfaceShareController.isStartPending);
    if (!locallySharing) return;

    // Stop the share track, clean up, and update UI (same sequence as the
    // per-participant stop above).
    self.normalShareRequestPending = NO;
    self.normalPendingShareRequestIdentity = nil;
    [self.roomController.publisher unpublishScreenShareWithCompletion:nil];
    [self.normalSurfaceShareController stopSharingFromSurfaceView:nil];
    self.normalSurfaceShareController.networkPublishSink = nil;
    [self.normalControlPanel setShareStartPending:NO];
    [self.normalControlPanel setSharingEnabled:NO];
    [self.normalRecordingCoordinator screenShareDidChangeWithIsActive:NO];
    [self.normalControlPanel setShareStatusText:@"The host stopped all screen sharing."];
}

/// The host changed the share-conflict policy mid-meeting. Sync the local policy.
- (void)moderationController:(InterModerationController *)controller
 receivedShareConflictPolicyChange:(NSString *)policy {
#pragma unused(controller)
    // roomController tracks the policy for serialisation; moderationController holds
    // the runtime value used by signal validation and preemption logic.
    [self.roomController updateShareConflictPolicy:policy];
}

// MARK: - Camera Mute Delegate (Camera Mute feature)

- (void)moderationControllerReceivedCameraMuteOne:(InterModerationController *)controller {
#pragma unused(controller)
    // Host locked OUR camera off.
    [self.normalMediaWiring applyHostCameraMuteForParticipant];
}

- (void)moderationControllerReceivedCameraMuteAll:(InterModerationController *)controller {
#pragma unused(controller)
    // Host locked ALL cameras off — apply to our local camera.
    [self.normalMediaWiring applyHostCameraMuteForAll];
    // Sync the room-wide lock-all cause for ANY moderator (host or co-host) so the
    // cause-derived camera menu shows "Allow Camera" (mirror of the mic mute-all path).
    BOOL canModerate = [InterPermissionMatrix
                        role:controller.localRole
                        hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    if (canModerate) {
        self.normalRemoteLayout.globalCameraLockActive = YES;
    }
}

- (void)moderationControllerReceivedCameraLiftOne:(InterModerationController *)controller {
#pragma unused(controller)
    // Host lifted the camera lock for US.
    [self.normalMediaWiring applyHostCameraLiftForParticipant];
}

- (void)moderationControllerReceivedCameraLiftAll:(InterModerationController *)controller {
#pragma unused(controller)
    // Host lifted camera lock for everyone — apply to our local camera.
    [self.normalMediaWiring applyHostCameraLiftForAll];
    BOOL canModerate = [InterPermissionMatrix
                        role:controller.localRole
                        hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    if (canModerate) {
        self.normalRemoteLayout.globalCameraLockActive = NO;
    }
}

- (void)moderationController:(InterModerationController *)controller
  shouldApplyCameraMuteForParticipant:(NSString *)identity {
#pragma unused(controller)
    // We are the host and we just sent the mute signal — update the remote tile badge.
    [self.normalRemoteLayout setIsHostCameraLocked:YES forParticipant:identity];
}

- (void)moderationController:(InterModerationController *)controller
  shouldLiftCameraLockForParticipant:(NSString *)identity {
#pragma unused(controller)
    // We are the host and we just sent the lift signal — update the remote tile badge.
    [self.normalRemoteLayout setIsHostCameraLocked:NO forParticipant:identity];
}

// MARK: Camera Unlock Request Flow

- (void)moderationController:(InterModerationController *)controller
  receivedCameraUnlockRequest:(NSString *)fromIdentity
                  displayName:(NSString *)displayName {
#pragma unused(controller)
    BOOL canModerate = [InterPermissionMatrix role:self.moderationController.localRole
                                    hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    if (!canModerate) return;
    // A locked participant is requesting camera unlock — show in the panel.
    [self.cameraUnlockQueue addRequestWithIdentity:fromIdentity displayName:displayName];
    [self notifyHostOfInCallRequest:[NSString stringWithFormat:@"%@ asked to turn on their camera",
                                     displayName.length ? displayName : @"Someone"]];
}

- (void)moderationController:(InterModerationController *)controller
  receivedMicUnlockRequest:(NSString *)fromIdentity
               displayName:(NSString *)displayName {
#pragma unused(controller)
    BOOL canModerate = [InterPermissionMatrix role:self.moderationController.localRole
                                    hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    if (!canModerate) return;
    // F1 mitigation: discard if the sender is not actually mic-restricted.
    if (!self.moderationController.isAllMuted &&
        ![self.hostMutedParticipants containsObject:fromIdentity]) {
        NSLog(@"[MicUnlock] discarded requestMicUnlock from non-restricted participant %@", fromIdentity);
        return;
    }
    [self.micUnlockQueue addRequestWithIdentity:fromIdentity displayName:displayName];
    [self notifyHostOfInCallRequest:[NSString stringWithFormat:@"%@ asked to unmute",
                                     displayName.length ? displayName : @"Someone"]];
}

- (void)moderationControllerCameraUnlockApproved:(InterModerationController *)controller {
#pragma unused(controller)
    // Host approved our camera unlock request — allow one camera toggle.
    [self.normalMediaWiring applyHostCameraApprovalForParticipant];
    // Show a brief status message to let the participant know they can turn camera on.
    [self.normalControlPanel setMediaStatusText:@"Camera unlocked — you can turn it on now"];
}

- (void)moderationControllerCameraUnlockDenied:(InterModerationController *)controller {
#pragma unused(controller)
    // Host/co-host denied the request — clear the pending flag so the UI reverts to "Ask to Unlock".
    [self.normalMediaWiring resetCameraUnlockFlowState];
    [self.normalControlPanel setMediaStatusText:@"Camera unlock request was denied."];
}

- (void)moderationControllerMicUnlockApproved:(InterModerationController *)controller {
#pragma unused(controller)
    // Host approved our mic unlock request — allow one mic toggle.
    [self.normalMediaWiring applyMicUnlockApproved];
    [self.normalControlPanel setMediaStatusText:@"Mic unlocked — you can unmute now"];
}

- (void)moderationControllerMicUnlockDenied:(InterModerationController *)controller {
#pragma unused(controller)
    // Host/co-host denied the request — clear the pending flag so UI reverts to "Ask to Unmute".
    [self.normalMediaWiring resetMicUnlockFlowState];
    [self.normalControlPanel setMediaStatusText:@"Mic unlock request was denied."];
}

- (void)moderationController:(InterModerationController *)controller
  receivedScreenShareModeChange:(NSString *)mode {
#pragma unused(controller)
    // A co-host or participant received a mode change broadcast — sync local state and UI.
    [self.roomController updateSharingPermissions:mode];
    [self.normalControlPanel setScreenSharePermissionMode:mode];
    // If moving away from "request", clear the pending queue locally
    if ([mode isEqualToString:@"everyone"] || [mode isEqualToString:@"hostOnly"]) {
        [self.screenShareQueue reset];
    }
}

- (void)moderationController:(InterModerationController *)controller meetingLockStateChanged:(BOOL)isLocked {
#pragma unused(controller)
    NSLog(@"[Phase 9] Meeting %@", isLocked ? @"locked" : @"unlocked");
}

- (void)moderationController:(InterModerationController *)controller participantSuspendStateChanged:(NSString *)identity isSuspended:(BOOL)isSuspended {
#pragma unused(controller)
    if ([identity isEqualToString:self.roomController.localParticipantIdentity]) {
        // WE were suspended/unsuspended
        if (self.normalChatPanel) {
            [self.normalChatPanel setChatInputEnabled:!isSuspended];
        }
        if (isSuspended) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Suspended";
            alert.informativeText = @"You have been suspended by the host. Your audio, video, and chat have been disabled.";
            [alert addButtonWithTitle:@"OK"];
            [alert runModal];
        }
    }
}

- (void)moderationController:(InterModerationController *)controller forceSpotlightOnParticipants:(NSArray<NSString *> *)identities {
#pragma unused(controller)
    if (!self.normalRemoteLayout) return;
    // A participant has no remote camera view for themselves — their own feed is
    // the local self-view tile. Remove the local participant's identity from the
    // pinned list so they never see a blank tile for themselves on stage.
    NSString *localId = self.roomController.localParticipantIdentity;
    NSArray<NSString *> *remoteOnly = localId.length
        ? [identities filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != %@", localId]]
        : identities;
    [self.normalRemoteLayout setHostForcedSpotlightTileKeys:remoteOnly animated:YES];
}

- (void)moderationControllerDidClearForceSpotlight:(InterModerationController *)controller {
#pragma unused(controller)
    if (self.normalRemoteLayout) {
        [self.normalRemoteLayout setHostForcedSpotlightTileKeys:@[] animated:YES];
    }
}

- (void)moderationControllerLocalParticipantWasRemoved:(InterModerationController *)controller {
#pragma unused(controller)
    // DataChannel-signal path. The LiveKit forced-disconnect path
    // (mediaWiringControllerDidDetectRemovalByHost) usually fires first and is
    // more reliable; handleForcedExit de-duplicates so only one message shows.
    [self handleForcedExitWithTitle:@"Removed from Meeting"
                            message:@"You have been removed from this meeting by the host. You may not rejoin."];
}

#pragma mark - InterMediaWiringDelegate (forced exit)

- (void)mediaWiringControllerDidDetectRemovalByHost {
    [self handleForcedExitWithTitle:@"Removed from Meeting"
                            message:@"You have been removed from this meeting by the host. You may not rejoin."];
}

- (void)mediaWiringControllerDidDetectRoomEndedByHost {
    [self handleForcedExitWithTitle:@"Meeting Ended"
                            message:@"The host has ended the meeting for everyone."];
}

- (void)moderationController:(InterModerationController *)controller participantRoleChanged:(NSString *)identity newRole:(NSString *)newRole {
    NSLog(@"[Phase 9] Role changed: %@ → %@", identity, newRole);
    // If the local user's role changed, refresh the tile host-mode flag so the
    // three-dot moderation menus appear (or disappear) immediately.
    NSString *localId = self.roomController.localParticipantIdentity;
    if (localId.length > 0 && [identity isEqualToString:localId] && self.normalRemoteLayout) {
        BOOL canModerate = [InterPermissionMatrix
                            role:controller.localRole
                            hasPermission:(InterPermission)InterPermissionCanMuteOthers];
        self.normalRemoteLayout.isHostMode = canModerate;
        // Role assignment is host-only — update so the tile menu hides/shows Make Co-Host.
        self.normalRemoteLayout.localUserCanAssignCoHost =
            (controller.localRole == InterParticipantRoleHost);

        // When becoming a moderator mid-meeting, mark existing host tiles so the
        // tile menu shows only pin/unpin for the host participant.
        if (canModerate) {
            // Sync the room-wide moderation cause flags onto the layout so a co-host
            // promoted DURING an active Mute-All / camera Lock-All sees the correct
            // cause-derived menu ("Allow to Speak" / "Allow Camera") instead of
            // "Mute Mic" / "Stop Video". isAllMuted/isAllCameraMuted are the controller's
            // authoritative global state (kept accurate for all clients via the receive
            // path), so this is correct whether the restriction was set before or after
            // this user was promoted.
            self.normalRemoteLayout.globalMuteActive = self.moderationController.isAllMuted;
            self.normalRemoteLayout.globalCameraLockActive = self.moderationController.isAllCameraMuted;
            for (NSDictionary<NSString *, NSString *> *p in [self.roomController remoteParticipantList]) {
                NSString *pid = p[@"identity"];
                if (!pid.length) continue;
                InterParticipantRole pRole = [self.roomController roleForParticipantIdentity:pid];
                BOOL isHostRole = (pRole == InterParticipantRoleHost);
                [self.normalRemoteLayout setIsHostParticipant:isHostRole forParticipant:pid];
            }
        }

        // If promoted to co-host mid-meeting, show the screen-share permission control.
        // Hosts already have it from setupNormalControlPanel; now co-hosts need it too.
        BOOL nowCoHostOrHost = [newRole isEqualToString:@"co-host"] || [newRole isEqualToString:@"host"];
        if (nowCoHostOrHost && self.normalControlPanel) {
            NSString *activeMode = self.roomController.activeSharingPermissions ?: @"everyone";
            [self.normalControlPanel setScreenSharePermissionMode:activeMode];
            // Bind the live-update handler if not already set (host has it from setup;
            // co-hosts promoted mid-meeting need it installed here).
            if (!self.normalControlPanel.screenShareModeChangedHandler) {
                __weak typeof(self) weakSelf = self;
                self.normalControlPanel.screenShareModeChangedHandler = ^(NSString *mode) {
                    [weakSelf handleScreenShareModeChanged:mode];
                };
            }
        } else if (self.normalControlPanel) {
            // Demoted back to a non-moderator role — clear the handler and hide the control.
            self.normalControlPanel.screenShareModeChangedHandler = nil;
            [self.normalControlPanel setScreenSharePermissionMode:nil];
        }
        // Update recording button visibility when role changes mid-meeting.
        if (self.normalControlPanel) {
            BOOL canRecordNow = [InterPermissionMatrix
                                 role:controller.localRole
                                 hasPermission:(InterPermission)InterPermissionCanStartRecording];
            [self.normalControlPanel setRecordingButtonHidden:!canRecordNow];
        }
        // Manage moderation chrome (More-menu items + Requests) on promotion/demotion.
        [self.normalControlPanel setModerationVisible:nowCoHostOrHost];
        [self.normalControlPanel setRenameVisible:(!nowCoHostOrHost &&
            [self.moderationController canLocalParticipantSelfRename])];
        if (self.normalLobbyPanel) {
            [self.normalLobbyPanel setLobbyToggleEnabled:self.roomController.isHost];
        }
        // Re-evaluate chat enabled state whenever local role changes.
        // Promotions: a co-host must always have chat enabled regardless of the
        //   host's chat-disabled state (moderators are exempt from the lock).
        // Demotions: if chat is currently disabled by the host, a demoted co-host
        //   loses the moderator exemption and must have their input disabled again.
        if (self.normalChatPanel && self.moderationController) {
            BOOL isChatModerator = [InterPermissionMatrix
                                    role:controller.localRole
                                    hasPermission:(InterPermission)InterPermissionCanDisableChat];
            BOOL chatShouldBeEnabled = isChatModerator || !self.moderationController.isChatDisabled;
            [self.normalChatPanel setChatInputEnabled:chatShouldBeEnabled];
        }
        // Update poll panel host mode when local role changes.
        if (self.normalPollPanel) {
            BOOL canCreatePoll = [InterPermissionMatrix
                                  role:controller.localRole
                                  hasPermission:(InterPermission)InterPermissionCanMuteOthers];
            self.normalPollPanel.isHost = canCreatePoll;
            // Refresh the current view so the create form shows/hides immediately.
            [self.normalPollPanel resetToCreateForm];
        }
        // Sync poll/QA controller host status so promoted co-hosts can launch
        // polls and perform QA moderation actions immediately.
        if (self.pollController) {
            BOOL canHostPoll = [InterPermissionMatrix
                                role:controller.localRole
                                hasPermission:(InterPermission)InterPermissionCanMuteOthers];
            [self.pollController updateHostStatus:canHostPoll];
        }
        if (self.qaController) {
            BOOL canHostQA = [InterPermissionMatrix
                              role:controller.localRole
                              hasPermission:(InterPermission)InterPermissionCanMuteOthers];
            [self.qaController updateHostStatus:canHostQA];
        }
        [self _updateChatExportVisibility];
    }
    // Sync the co-host crown badge on the remote tile
    // Note: InterParticipantRole.coHost.stringValue is "co-host" (hyphenated)
    BOOL nowCoHost = [newRole isEqualToString:@"co-host"];
    if (self.normalRemoteLayout) {
        [self.normalRemoteLayout setIsCoHost:nowCoHost forParticipant:identity];
        // Track host-participant status so co-host tile menus show only pin/unpin
        // for the host's tile.
        BOOL nowHost = [newRole isEqualToString:@"host"];
        [self.normalRemoteLayout setIsHostParticipant:nowHost forParticipant:identity];
    }
}

- (void)moderationController:(InterModerationController *)controller
           participantRenamed:(NSString *)identity
             newDisplayName:(NSString *)newDisplayName {
#pragma unused(controller)
    // Record the session rename override in the single naming authority so chat, tiles,
    // and notifications all resolve to the same effective name (and so the recent
    // attested-name reconciliation no longer reverts renamed names in chat).
    [self.roomController setSessionDisplayName:newDisplayName forIdentity:identity];
    // Push a per-session rename OVERRIDE into the roster. The roster is the single source of
    // truth for video tiles: every presence/track change (e.g. ANY participant toggling
    // their camera) re-emits a snapshot, and on a fresh camera subscribe the attested
    // (original) name is re-stamped. The override layer wins over the attested name in the
    // emitted snapshot, so the rename survives camera toggles — without any server call.
    // The override is dropped automatically when the participant leaves (per-session).
    [self.roomController.subscriber.roster setDisplayNameOverride:newDisplayName for:identity];
    // Update the tile label for everyone's view.
    if (self.normalRemoteLayout) {
        [self.normalRemoteLayout registerDisplayName:newDisplayName forParticipant:identity];
    }
    // If the local user was renamed, show a banner so they know, and update
    // the display name used in future outgoing chat / control signals.
    NSString *localId = self.roomController.localParticipantIdentity;
    if ([identity isEqualToString:localId]) {
        if (self.normalChatPanel) {
            [self.normalChatPanel displaySystemMessage:
                [NSString stringWithFormat:@"Your display name was changed to \"%@\".", newDisplayName]];
        }
        [self.chatController updateLocalDisplayName:newDisplayName];
        [self.moderationController updateLocalDisplayName:newDisplayName];
        // Set the roster's LOCAL per-session rename override so the unified local self-tile
        // reflects the new name and survives camera toggles. Client-only, dropped on leave.
        [self.roomController.subscriber.roster setLocalDisplayNameOverride:newDisplayName];
    }
    // Refresh the DM recipient list so all participants see the updated name
    // in the "To:" picker immediately (DataChannel renames don't update LiveKit
    // metadata, so refreshChatParticipantList must apply the layout manager override).
    [self refreshChatParticipantList];
}

- (void)moderationControllerAllowCoHostLocalRecordingChanged:(InterModerationController *)controller
                                                       allowed:(BOOL)allowed {
#pragma unused(controller)
    self.coHostLocalRecordingAllowed = allowed;
}

- (void)moderationController:(InterModerationController *)controller lobbyParticipantJoined:(NSString *)identity displayName:(NSString *)displayName {
#pragma unused(controller)
    if (self.normalLobbyPanel) {
        [self.normalLobbyPanel addWaitingParticipant:identity displayName:displayName];
    }
    // Instant badge update — don't wait for the 4s poll. Single source of truth:
    // the controller's lobbyWaitingParticipants count.
    [self refreshLobbyWaitingBadge];
    // Transient toast for the host/co-host (the controller only fires this
    // delegate for newly-seen waiters, so no de-dupe needed here).
    [self presentLobbyToastForNewWaiter:displayName];
}

- (void)moderationController:(InterModerationController *)controller lobbyParticipantLeft:(NSString *)identity {
#pragma unused(controller)
    // A waiter withdrew (or was admitted/denied out-of-band) — drop their row so the host's
    // panel converges with the server. Safe if the row is already gone (no-op).
    if (self.normalLobbyPanel) {
        [self.normalLobbyPanel removeWaitingParticipant:identity];
    }
    [self refreshLobbyWaitingBadge];
}

/// Push the authoritative lobby-waiting count to the bar (drives the combined
/// More badge + "Waiting Room (n)…" row) and dismiss the toast once the lobby
/// empties. Single source: moderationController.lobbyWaitingParticipants.
- (void)refreshLobbyWaitingBadge {
    NSUInteger count = self.moderationController.lobbyWaitingParticipants.count;
    [self.normalControlPanel setLobbyWaitingCount:(NSInteger)count];
    if (count == 0) {
        [self.normalLobbyToast dismiss];
    }
}

/// Show the bottom-left arrival toast when a new waiter appears — but only for
/// moderators who can admit, and never while the Waiting Room panel is already
/// open in front of the host (they're looking at it). Coalesces into one banner.
- (void)presentLobbyToastForNewWaiter:(NSString *)displayName {
    if (!self.moderationController || !self.normalLobbyToast) return;
    BOOL canAdmit = [InterPermissionMatrix role:self.moderationController.localRole
                                  hasPermission:(InterPermission)InterPermissionCanAdmitFromLobby];
    if (!canAdmit) return;
    if (self.normalLobbyWindow && self.normalLobbyWindow.isVisible) return;

    NSUInteger count = self.moderationController.lobbyWaitingParticipants.count;
    NSString *message;
    if (count <= 1) {
        NSString *name = (displayName.length > 0) ? displayName : @"Someone";
        message = [NSString stringWithFormat:@"%@ is waiting to join", name];
    } else {
        message = [NSString stringWithFormat:@"%lu people are waiting to join", (unsigned long)count];
    }
    [self.normalLobbyToast showWithMessage:message];
}

/// Soft bottom-left toast notifying the host/co-host that a new in-call request
/// arrived (raise hand, screen share, mic/camera unlock). Gated on moderator
/// permission so non-moderators never see it. The "Open" action surfaces the
/// consolidated Requests panel.
- (void)notifyHostOfInCallRequest:(NSString *)message {
    if (!self.normalRequestToast || message.length == 0) return;
    BOOL canModerate = [InterPermissionMatrix role:self.moderationController.localRole
                                    hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    if (!canModerate) return;
    [self.normalRequestToast showWithMessage:message];
}

#pragma mark - Recording (Phase 10)

/// Shared local-recording starter: presents the minimal layout choice (Automatic /
/// Speaker view), seeds the participants already present so the composed recording
/// engages gallery/grid correctly from the first frame, then starts local recording.
- (void)beginNormalLocalRecordingWithTier:(NSString *)tier {
    InterRecordingCoordinator *coordinator = self.normalRecordingCoordinator;
    if (!coordinator || !self.normalMediaController || !self.normalSurfaceShareController) return;

    // Minimal layout choice (default Automatic). Automatic = gallery for 3+, side-by-side
    // for 2, full for 1; Speaker view keeps the active speaker prominent + local self-view.
    NSAlert *viewAlert = [[NSAlert alloc] init];
    viewAlert.messageText = @"Recording View";
    viewAlert.informativeText = @"Automatic shows everyone (gallery for 3+ participants). "
                                 @"Speaker view follows the active speaker.";
    [viewAlert addButtonWithTitle:@"Automatic"];     // NSAlertFirstButtonReturn (default)
    [viewAlert addButtonWithTitle:@"Speaker View"];  // NSAlertSecondButtonReturn
    viewAlert.alertStyle = NSAlertStyleInformational;
    NSModalResponse layoutResp = [viewAlert runModal];
    coordinator.preferredLayout = (layoutResp == NSAlertSecondButtonReturn)
        ? InterRecordingLayoutPreferenceSpeaker
        : InterRecordingLayoutPreferenceAuto;

    // Seed participants already present. Presence join callbacks only fire for
    // participants who join AFTER recording starts, so existing ones must be seeded
    // explicitly or grid/gallery would never engage for them (the freeze cause).
    NSArray<NSString *> *seed = [self.roomController.subscriber recordingSeedParticipantIdentities] ?: @[];

    [coordinator startLocalRecordingWithScreenShareSource:self.normalSurfaceShareController
                                               subscriber:self.roomController.subscriber
                                      localMediaController:self.normalMediaController
                                                 userTier:tier
                                     existingParticipants:seed];
}

- (void)handleRecordToggle {
    InterRecordingCoordinator *coordinator = self.normalRecordingCoordinator;
    if (!coordinator) return;
    InterRecordingState state = coordinator.state;
    if (state == InterRecordingStateIdle || state == InterRecordingStateFinalized) {
        if (!self.normalMediaController || !self.normalSurfaceShareController) return;
        NSString *tier = self.roomController.tokenService.effectiveTier ?: @"free";

        // [2B] Push current participant display names to the recording coordinator BEFORE
        // starting. The coordinator caches them and replays onto the renderer at creation,
        // so the first camera-off placeholders show names/avatars rather than raw identities.
        [self refreshChatParticipantList];

        // Co-hosts initiate cloud recording on behalf of the host — the recording is
        // attributed to the host's account and the server validates using the host's tier.
        // Skip the client-side cloud-recording gate for co-hosts so they always see the
        // recording mode dialog; the server returns a clear error if the host lacks pro.
        BOOL isLocalCoHost = (self.moderationController.localRole == InterParticipantRoleCoHost);

        // Free/ungated tiers for the host: local recording only (no cloud option)
        if (!isLocalCoHost && ![InterFeatureGate isFeature:InterFeatureCloudRecording availableForTier:tier]) {
            // Co-hosts require explicit host permission for local recording.
            if (self.moderationController.localRole == InterParticipantRoleCoHost
                && !self.coHostLocalRecordingAllowed) {
                NSAlert *blocked = [[NSAlert alloc] init];
                blocked.messageText = @"Local Recording Not Permitted";
                blocked.informativeText = @"The meeting host has not enabled local recording for co-hosts.";
                [blocked addButtonWithTitle:@"OK"];
                [blocked runModal];
                return;
            }
            [self beginNormalLocalRecordingWithTier:tier];
            return;
        }

        // Paid tiers (pro / pro+ / hiring): present mode selection
        NSAlert *modeAlert = [[NSAlert alloc] init];
        modeAlert.messageText = @"Recording Mode";
        modeAlert.informativeText = @"Choose where to save the recording.\n\nLocal: saved to your Mac.\nCloud: recorded server-side and available for download.";
        [modeAlert addButtonWithTitle:@"Record Locally"];
        [modeAlert addButtonWithTitle:@"Record to Cloud"];
        [modeAlert addButtonWithTitle:@"Cancel"];
        modeAlert.alertStyle = NSAlertStyleInformational;

        NSModalResponse response = [modeAlert runModal];

        if (response == NSAlertFirstButtonReturn) {
            // Local recording — check co-host permission
            if (self.moderationController.localRole == InterParticipantRoleCoHost
                && !self.coHostLocalRecordingAllowed) {
                NSAlert *blocked = [[NSAlert alloc] init];
                blocked.messageText = @"Local Recording Not Permitted";
                blocked.informativeText = @"The meeting host has not enabled local recording for co-hosts.";
                [blocked addButtonWithTitle:@"OK"];
                [blocked runModal];
                return;
            }
            [self beginNormalLocalRecordingWithTier:tier];
        } else if (response == NSAlertSecondButtonReturn) {
            // Cloud recording via Egress
            NSString *serverURL = self.roomController.tokenServerURL;
            NSString *roomCode  = self.roomController.roomCode;
            NSString *identity  = self.roomController.localParticipantIdentity;

            if (serverURL.length == 0 || roomCode.length == 0 || identity.length == 0) {
                NSLog(@"[Recording] Cloud recording missing required parameters — serverURL:%@ roomCode:%@ identity:%@",
                      serverURL, roomCode, identity);
                return;
            }

            __weak typeof(self) weakSelf = self;
            [coordinator startCloudRecordingWithServerURL:serverURL
                                                roomCode:roomCode
                                          callerIdentity:identity
                                estimatedDurationMinutes:60
                                                    mode:@"cloud_composed"
                                              completion:^(NSString *egressId, NSString *sessionId, NSError *error) {
                if (error) {
                    NSLog(@"[Recording] Cloud recording start failed: %@", error.localizedDescription);
                    NSAlert *errAlert = [[NSAlert alloc] init];
                    errAlert.messageText = @"Cloud Recording Failed";
                    errAlert.informativeText = error.localizedDescription ?: @"Could not start cloud recording.";
                    [errAlert addButtonWithTitle:@"OK"];
                    errAlert.alertStyle = NSAlertStyleWarning;
                    [errAlert runModal];
                } else {
                    NSLog(@"[Recording] Cloud recording started (egress=%@, session=%@)", egressId, sessionId);
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf) {
                        strongSelf.normalRecordingIndicatorView.indicatorActive = YES;
                    }
                }
            }];
        }
        // NSAlertThirdButtonReturn (Cancel) — do nothing
    } else if (state == InterRecordingStateRecording) {
        [coordinator pauseRecording];
    } else if (state == InterRecordingStatePaused) {
        [coordinator stopRecording];
    }
}

#pragma mark - InterRecordingCoordinatorDelegate (Phase 10)

- (void)recordingStateDidChange:(InterRecordingState)state {
    BOOL active = (state == InterRecordingStateRecording);
    BOOL paused = (state == InterRecordingStatePaused);
    [self.normalControlPanel setRecordingActive:(active || paused)];
    self.normalRecordingIndicatorView.indicatorActive = (active || paused);
    self.normalRecordingIndicatorView.indicatorPaused = paused;
    if (state == InterRecordingStateIdle || state == InterRecordingStateFinalized) {
        [self.normalRecordingIndicatorView setElapsedDuration:0];
    }
}

- (void)recordingDidCompleteWithOutputURL:(NSURL *)outputURL error:(NSError *)error {
    if (error) {
        NSAlert *alert = [NSAlert alertWithError:error];
        [alert runModal];
    } else if (outputURL) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[outputURL]];
    }
    [self.normalControlPanel setRecordingActive:NO];
    self.normalRecordingIndicatorView.indicatorActive = NO;
}

- (void)recordingDurationDidUpdate:(NSTimeInterval)duration {
    [self.normalRecordingIndicatorView setElapsedDuration:duration];
}

#pragma mark - InterRecordingSignalDelegate (Phase 10)

- (void)recordingDidStart {
    self.normalRecordingIndicatorView.indicatorActive = YES;
    self.normalRecordingIndicatorView.indicatorPaused = NO;
    // [Phase 10 R3] Show consent to non-host participants when remote recording starts
    if (!self.roomController.isHost) {
        [self showRecordingConsentOverlayForRemoteRecording];
        self.normalRecordingConsentHandled = YES;
    }
}

- (void)recordingDidPause {
    self.normalRecordingIndicatorView.indicatorPaused = YES;
}

- (void)recordingDidResume {
    self.normalRecordingIndicatorView.indicatorPaused = NO;
}

- (void)recordingDidStop {
    self.normalRecordingIndicatorView.indicatorActive = NO;
    [self.normalRecordingIndicatorView setElapsedDuration:0];
    // Allow consent to be shown again if a new recording starts this session.
    self.normalRecordingConsentHandled = NO;
}

// ---------------------------------------------------------------------------
#pragma mark - Recording List Panel (Phase 10 R2)
// ---------------------------------------------------------------------------

- (void)toggleNormalRecordingListPanel {
    if (!self.normalRecordingListWindow) {
        CGFloat panelWidth = 360;
        CGFloat panelHeight = 420;
        NSRect windowFrame = self.normalCallWindow.frame;
        CGFloat x = NSMaxX(windowFrame) - panelWidth - 12;
        CGFloat y = windowFrame.origin.y + 100;

        self.normalRecordingListPanel = [[InterRecordingListPanel alloc] initWithFrame:NSMakeRect(0, 0, panelWidth, panelHeight)];
        self.normalRecordingListPanel.delegate = self;
        self.normalRecordingListPanel.serverBaseURL = self.roomController.tokenService.serverURL;
        self.normalRecordingListPanel.accessToken = self.roomController.tokenService.currentAccessToken;

        self.normalRecordingListWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(x, y, panelWidth, panelHeight)
                                                                     styleMask:(NSWindowStyleMaskTitled |
                                                                                NSWindowStyleMaskClosable |
                                                                                NSWindowStyleMaskResizable)
                                                                       backing:NSBackingStoreBuffered
                                                                         defer:NO];
        self.normalRecordingListWindow.title = @"Recordings";
        self.normalRecordingListWindow.minSize = NSMakeSize(280, 260);
        self.normalRecordingListWindow.releasedWhenClosed = NO;
        self.normalRecordingListWindow.level = NSFloatingWindowLevel;
        [self.normalRecordingListWindow setSharingType:InterWindowSharingType()];
        [self.normalRecordingListWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
        self.normalRecordingListWindow.contentView = self.normalRecordingListPanel;

        [self.normalRecordingListPanel reloadRecordings];
        [self.normalRecordingListWindow makeKeyAndOrderFront:nil];
        return;
    }

    if (self.normalRecordingListWindow.isVisible) {
        [self.normalRecordingListWindow orderOut:nil];
    } else {
        self.normalRecordingListPanel.accessToken = self.roomController.tokenService.currentAccessToken;
        [self.normalRecordingListPanel reloadRecordings];
        [self.normalRecordingListWindow makeKeyAndOrderFront:nil];
    }
}

#pragma mark - InterRecordingListPanelDelegate (Phase 10 R2)

- (void)recordingListPanel:(InterRecordingListPanel *)panel didRequestOpenLocal:(NSURL *)fileURL {
    [[NSWorkspace sharedWorkspace] openURL:fileURL];
}

- (void)recordingListPanel:(InterRecordingListPanel *)panel didRequestDownload:(NSString *)recordingId {
    NSString *baseURL = self.roomController.tokenService.serverURL;
    if (!baseURL || !recordingId) return;

    NSString *encodedId = [recordingId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlStr = [NSString stringWithFormat:@"%@/recordings/%@/download", baseURL, encodedId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (void)recordingListPanel:(InterRecordingListPanel *)panel didRequestDelete:(NSString *)recordingId {
    NSString *baseURL = self.roomController.tokenService.serverURL;
    NSString *token = self.roomController.tokenService.currentAccessToken;
    if (!baseURL || !token || !recordingId) return;

    NSString *encodedId = [recordingId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlStr = [NSString stringWithFormat:@"%@/recordings/%@", baseURL, encodedId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"DELETE";
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                NSAlert *alert = [NSAlert alertWithError:error];
                [alert runModal];
                return;
            }
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Delete Failed";
                alert.informativeText = @"Could not delete recording. Please try again.";
                [alert runModal];
                return;
            }
            [weakSelf.normalRecordingListPanel reloadRecordings];
        });
    }] resume];
}

// ---------------------------------------------------------------------------
#pragma mark - Recording Consent Panel (Phase 10 R3)
// ---------------------------------------------------------------------------

/// Show the consent overlay for a remote-initiated recording.
- (void)showRecordingConsentOverlayForRemoteRecording {
    [self showRecordingConsentOverlayForRemoteRecordingWithMode:@"local_composed"];
}

/// Present the recording-consent overlay for a non-host participant, using the
/// server-reported recording mode so the description matches the actual recording.
- (void)showRecordingConsentOverlayForRemoteRecordingWithMode:(NSString *)mode {
    if (self.normalRecordingConsentPanel) return; // already showing

    NSView *contentView = self.normalCallWindow.contentView;
    if (!contentView) return;

    self.normalRecordingConsentPanel = [[InterRecordingConsentPanel alloc]
        initWithFrame:contentView.bounds];
    self.normalRecordingConsentPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.normalRecordingConsentPanel.delegate = self;
    [contentView addSubview:self.normalRecordingConsentPanel];
    [self.normalRecordingConsentPanel showConsentForMode:(mode.length > 0 ? mode : @"local_composed")];
}

- (void)dismissRecordingConsentOverlay {
    if (self.normalRecordingConsentPanel) {
        [self.normalRecordingConsentPanel dismiss];
        [self.normalRecordingConsentPanel removeFromSuperview];
        self.normalRecordingConsentPanel = nil;
    }
}

#pragma mark - InterRecordingConsentPanelDelegate (Phase 10 R3)

- (void)recordingConsentPanelDidAccept:(InterRecordingConsentPanel *)panel {
    [self dismissRecordingConsentOverlay];
    self.normalRecordingConsentHandled = YES;
}

- (void)recordingConsentPanelDidDecline:(InterRecordingConsentPanel *)panel {
    [self dismissRecordingConsentOverlay];
    // Participant declined — leave the call
    [self.roomController disconnect];
    [self teardownActiveWindows];
    [self launchSetupUI];
}

#pragma mark - Settings

- (void)openSettingsWindow {
    InterTokenService *ts = self.roomController.tokenService;
    if (!self.settingsWindow) {
        // Unified SwiftUI settings window (account + meetings + devices). Self-
        // contained: it talks to the server through the token service directly.
        self.settingsHostView =
            [[InterSettingsHostView alloc] initWithFrame:NSMakeRect(0, 0, 820, 560)
                                            tokenService:ts
                                         mediaController:self.normalMediaController];

        __weak typeof(self) weakSelf = self;
        self.settingsHostView.onSignOut = ^{
            [weakSelf.settingsWindow orderOut:nil];
            [weakSelf handleLogout];
        };
        self.settingsHostView.onAccountDeleted = ^{
            // Dismiss and navigate back to the login screen — same as sign-out.
            [weakSelf.settingsWindow orderOut:nil];
            [weakSelf handleLogout];
        };
        // Signed-out gate on the ACCOUNT tabs — route to the login window.
        self.settingsHostView.onSignIn = ^{ [weakSelf handleSignIn]; };
        self.settingsHostView.onSignUp = ^{ [weakSelf handleSignUp]; };

        self.settingsWindow =
            [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 820, 560)
                                        styleMask:(NSWindowStyleMaskTitled |
                                                   NSWindowStyleMaskClosable |
                                                   NSWindowStyleMaskResizable)
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
        [self.settingsWindow setTitle:@"Settings"]; // Mission Control/⌘-Tab label; not drawn
        [self.settingsWindow setMinSize:NSMakeSize(720, 480)];
        [self.settingsWindow setSharingType:InterWindowSharingType()];
        // Seamless chrome (canonical migrated-screen treatment).
        [InterWindowChrome applySeamlessChromeTo:self.settingsWindow];
        [self.settingsWindow setReleasedWhenClosed:NO];
        [self.settingsWindow setContentView:self.settingsHostView];
        [self.settingsWindow setDelegate:self];
        self.settingsHostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.settingsWindow center];
    }

    [self.settingsHostView setTier:ts.currentTier ?: @"free"];
    [self.settingsHostView reload];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)openTeamsPanel:(id)sender {
#pragma unused(sender)
    InterTokenService *ts = self.roomController.tokenService;
    if (!self.teamsWindow) {
        // Self-contained SwiftUI Teams screen (Option A): the bridge builds its
        // own data layer from the account token service. No data is pushed in
        // and no delegate callbacks come out — it talks to the server directly.
        self.teamsPanel = [[InterTeamsPanelBridge alloc] initWithFrame:NSMakeRect(0, 0, 760, 520)
                                                          tokenService:ts];

        self.teamsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 520)
                                                        styleMask:(NSWindowStyleMaskTitled |
                                                                   NSWindowStyleMaskClosable |
                                                                   NSWindowStyleMaskResizable)
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
        [self.teamsWindow setTitle:@"Teams"]; // Mission Control/⌘-Tab label; not drawn
        [self.teamsWindow setMinSize:NSMakeSize(680.0, 440.0)];
        [self.teamsWindow setSharingType:InterWindowSharingType()];
        // Seamless chrome: no title-bar band — content extends to the window top and
        // the traffic lights float over the sidebar (canonical migrated-screen chrome).
        [InterWindowChrome applySeamlessChromeTo:self.teamsWindow];
        [self.teamsWindow setReleasedWhenClosed:NO];
        [self.teamsWindow setContentView:self.teamsPanel];
        [self.teamsWindow setDelegate:self];
        self.teamsPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    [self.teamsWindow center];
    [self.teamsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    // Refresh the list each time the window is shown (fresh unread badges).
    [self.teamsPanel reload];
}

// ---------------------------------------------------------------------------
// MARK: - Account Settings Window
// ---------------------------------------------------------------------------

- (void)openAccountSettingsWindow {
    // Account settings live in the unified settings window now — deep-link to
    // the Profile tab. (Selector preserved: the home avatar menu targets it.)
    [self openSettingsWindow];
    [self.settingsHostView selectAnchor:InterSettingsTabAnchorProfile];
}

- (void)closeSettingsWindow {
    [self.settingsWindow orderOut:nil];
}

/// Keep the home screen's events/history live: refresh whenever the setup
/// window regains key (returning from a call, schedule window, etc.).
- (void)windowDidBecomeKey:(NSNotification *)notification {
    if (notification.object == self.setupWindow) {
        [self.connectionPanel reloadMeetings];
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender == self.setupWindow && self.currentCallMode == InterCallModeNone) {
        InterTeardownSetupWindow(&_setupWindow, &_setupRenderView, &_connectionPanel);
        [NSApp terminate:nil];
        return NO;
    }

    // Green room close button = cancel back to the setup screen.
    if (sender == self.greenRoomWindow) {
        [self cancelGreenRoom];
        return NO;
    }

    if (sender == self.normalCallWindow && self.currentCallMode != InterCallModeNone) {
        // Show a confirmation before destroying the call — the user may have
        // clicked the red button by mistake.
        [self confirmEndCallWithMessage:@"Closing this window will end the call. Are you sure?"
                     confirmButtonTitle:@"End Call"
                             completion:^{ [self exitCurrentMode]; }];
        return NO;
    }

    // Login window is a secondary sign-in sheet — closing it returns to the
    // setup screen (which is always visible underneath).
    if (sender == self.loginWindow) {
        [self dismissLoginWindow];
        return NO;
    }

    return YES;
}

- (void)teardownActiveWindows {
    // [Phase 10] Stop recording and clean up indicator before tearing down media sources
    if (self.normalRecordingCoordinator.canStop) {
        [self.normalRecordingCoordinator stopRecording];
    }
    if (self.normalControlPanel) {
        self.normalControlPanel.recordToggleHandler = nil;
        self.normalControlPanel.viewRecordingsHandler = nil;
    }
    if (self.normalRecordingIndicatorView) {
        [self.normalRecordingIndicatorView removeFromSuperview];
        self.normalRecordingIndicatorView = nil;
    }
    // [Phase 10 R2] Tear down recording list window
    if (self.normalRecordingListWindow) {
        [self.normalRecordingListWindow orderOut:nil];
        self.normalRecordingListWindow = nil;
    }
    self.normalRecordingListPanel = nil;
    // [Phase 10 R3] Dismiss consent overlay
    [self dismissRecordingConsentOverlay];
    self.chatController.recordingDelegate = nil;

    if (self.normalControlPanel) {
        self.normalControlPanel.cameraToggleHandler = nil;
        self.normalControlPanel.microphoneToggleHandler = nil;
        self.normalControlPanel.speakerToggleHandler = nil;
        self.normalControlPanel.shareToggleHandler = nil;
        self.normalControlPanel.screenShareModeChangedHandler = nil;
        self.normalControlPanel.audioInputSelectionChangedHandler = nil;
        self.normalControlPanel.chatToggleHandler = nil;
        self.normalControlPanel.pollToggleHandler = nil;
        self.normalControlPanel.qaToggleHandler = nil;
        self.normalControlPanel.raiseHandToggleHandler = nil;
        self.normalControlPanel.lobbyHandler = nil;
        self.normalControlPanel.renameHandler = nil;
        self.normalControlPanel.leaveHandler = nil;
        self.normalControlPanel.requestApproveHandler = nil;
        self.normalControlPanel.requestDenyHandler = nil;
        self.normalControlPanel.moderationMenuWillOpenHandler = nil;
        self.normalControlPanel.toggleMuteAllHandler = nil;
        self.normalControlPanel.toggleAllCamerasHandler = nil;
        self.normalControlPanel.stopAllSharesHandler = nil;
        self.normalControlPanel.toggleChatDisabledHandler = nil;
        self.normalControlPanel.toggleCoHostRecordingHandler = nil;
        self.normalControlPanel.toggleLockHandler = nil;
        self.normalControlPanel.passwordViewHandler = nil;
        self.normalControlPanel.passwordChangeHandler = nil;
        self.normalControlPanel.passwordRemoveHandler = nil;
        self.normalControlPanel.shareConflictChangedHandler = nil;
        self.normalControlPanel.participantsProvider = nil;
        self.normalControlPanel.participantMuteHandler = nil;
        self.normalControlPanel.participantUnmuteHandler = nil;
        [self.normalControlPanel setScreenSharePermissionMode:nil];
    }

    [self.normalSurfaceShareController stopSharingFromSurfaceView:nil];
    self.normalSurfaceShareController = nil;

    self.normalMediaController.audioInputOptionsChangedHandler = nil;
    [self.normalMediaController shutdown];
    self.normalMediaController = nil;
    [self.normalLobbyToast dismiss];
    self.normalLobbyToast.onOpen = nil;
    self.normalLobbyToast = nil;
    [self.normalRequestToast dismiss];
    self.normalRequestToast.onOpen = nil;
    self.normalRequestToast = nil;
    // Reset local speaker-mute so it never persists into the next call.
    [InterAudioEngineAccess setSpeakerMuted:NO];
    self.normalControlPanel = nil;

    // [Phase 8] Tear down chat and speaker queue UI
    [self.chatController detach];
    [self.speakerQueue reset];
    [self.screenShareQueue reset];
    [self.hostMutedParticipants removeAllObjects];
    self.chatController.chatDelegate = nil;
    self.chatController.controlDelegate = nil;
    self.chatController.isChatVisible = NO;
    self.normalChatSelectedRecipient = nil;
    if (self.normalChatPanel) {
        [self.normalChatPanel removeFromSuperview];
        self.normalChatPanel = nil;
    }

    // [Phase 8.5] Tear down poll window
    if (self.normalPollWindow) {
        [self.normalPollWindow orderOut:nil];
        self.normalPollWindow = nil;
    }
    self.normalPollPanel = nil;

    // [Phase 8.6] Tear down Q&A window
    if (self.normalQAWindow) {
        [self.normalQAWindow orderOut:nil];
        self.normalQAWindow = nil;
    }
    self.normalQAPanel = nil;

    // [Phase 9] Tear down lobby window
    if (self.normalLobbyWindow) {
        [self.normalLobbyWindow orderOut:nil];
        self.normalLobbyWindow = nil;
    }
    self.normalLobbyPanel = nil;

    // [Phase 9] Tear down lobby joining/waiting window (participant side)
    [self _dismissJoiningOverlay];

    // Pre-meeting panel (if dismissed mid-flow for some reason)
    [self dismissPreMeetingPanel];
    self.pendingMeetingSettings = nil;
    self.pendingConnectionPanel = nil;
    self.currentMeetingPassword = nil;

    // [Phase 11] Tear down schedule window
    if (self.normalScheduleWindow) {
        [self.normalScheduleWindow orderOut:nil];
        self.normalScheduleWindow = nil;
    }
    self.normalSchedulePanel = nil;

    // [3.2] Tear down remote video layout
    if (self.normalRemoteLayout) {
        [self.normalRemoteLayout teardown];
        [self.normalRemoteLayout removeFromSuperview];
        self.normalRemoteLayout = nil;
    }
    if (self.normalTrackRendererBridge) {
        if (self.roomController) {
            self.roomController.subscriber.trackRenderer = nil;
        }
        self.normalTrackRendererBridge = nil;
    }

    [self.secureController destroySecureWindow];
    self.secureController = nil;

    if (self.fullScreenExitPendingWindow) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSWindowDidExitFullScreenNotification
                                                      object:self.fullScreenExitPendingWindow];
        self.fullScreenExitPendingWindow = nil;
    }

    if (self.setupRenderView != nil) {
        [self.setupRenderView removeFromSuperview];
        self.setupRenderView = nil;
    }

    if (self.normalRenderView != nil) {
        [self.normalRenderView removeFromSuperview];
        self.normalRenderView = nil;
    }

    if (self.normalCallWindow != nil) {
        [self.normalCallWindow orderOut:nil];
    }
}

- (void)handleNormalWindowDidExitFullScreen:(NSNotification *)notification {
    if (notification.object != self.fullScreenExitPendingWindow) {
        return;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidExitFullScreenNotification
                                                  object:self.fullScreenExitPendingWindow];
    self.fullScreenExitPendingWindow = nil;
    [self finalizeCurrentModeExit];
}

- (void)finalizeCurrentModeExit {
    // Unlock the meeting tier lock so that any tier changes that arrived
    // during the meeting now take effect.
    [self.roomController.tokenService unlockTierFromMeeting];

    // Stop host-side lobby polling
    [self stopLobbyPolling];

    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
    [self stopScreenMonitoring];
    self.isShowingExternalDisplayAlert = NO;

    // Hide all call windows FIRST so the user sees instant visual feedback,
    // then perform potentially-slow teardown (room disconnect, AVCaptureSession
    // stop, etc.) without the user staring at a frozen window.
    if (self.normalCallWindow != nil) {
        [self.normalCallWindow orderOut:nil];
    }
    // Hide standalone panel windows immediately
    [self.normalPollWindow orderOut:nil];
    [self.normalQAWindow orderOut:nil];
    [self.normalLobbyWindow orderOut:nil];
    [self.secureController hideSecureWindow];

    // [2.5.7] [G8] Disconnect room on exit. Guarded: skip if nil
    if (self.roomController) {
        [self.roomController disconnect];
    }

    [self teardownActiveWindows];

    [self.sessionCoordinator finishExit];
    [self launchSetupUI];
}

#pragma mark - Screen Monitoring

- (void)startScreenMonitoring {
    if (!InterShouldEnforceInterviewExternalDisplayPolicy()) {
        return;
    }

    if (self.isScreenObserverRegistered) {
        return;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleScreenChange:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
    self.isScreenObserverRegistered = YES;
}

- (void)stopScreenMonitoring {
    if (!self.isScreenObserverRegistered) {
        return;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSApplicationDidChangeScreenParametersNotification
                                                  object:nil];
    self.isScreenObserverRegistered = NO;
}

- (void)handleScreenChange:(NSNotification *)notification {
#pragma unused(notification)
    if (!InterShouldEnforceInterviewExternalDisplayPolicy()) {
        return;
    }

    BOOL isIntervieweeMode = (self.currentCallMode == InterCallModeInterview &&
                              self.currentInterviewRole == InterInterviewRoleInterviewee);
    if (!isIntervieweeMode) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([NSScreen screens].count < 2 || self.isShowingExternalDisplayAlert) {
            return;
        }

        self.isShowingExternalDisplayAlert = YES;
        [self showExternalDisplayAlertMid];
    });
}

#pragma mark - Restrictions

- (void)applyKioskRestrictions {
    NSApplicationPresentationOptions options =
    NSApplicationPresentationDisableAppleMenu |
    NSApplicationPresentationHideDock |
    NSApplicationPresentationHideMenuBar |
    NSApplicationPresentationDisableProcessSwitching |
    NSApplicationPresentationDisableForceQuit |
    NSApplicationPresentationDisableSessionTermination;

    [NSApp setPresentationOptions:options];
}

#pragma mark - Alerts

- (void)showExternalDisplayAlert {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"External Display Detected";
    alert.informativeText = @"Please disconnect external monitors to join interview as interviewee.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)showExternalDisplayAlertMid {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"External Display Detected";
    alert.informativeText = @"Disconnect external monitors to continue interview mode.";
    [alert addButtonWithTitle:@"Continue"];
    [alert addButtonWithTitle:@"Exit"];

    NSWindow *window = NSApp.mainWindow ?: NSApp.keyWindow;
    if (!window) {
        NSModalResponse returnCode = [alert runModal];
        if (returnCode == NSAlertFirstButtonReturn && [NSScreen screens].count >= 2) {
            [self showExternalDisplayAlertMid];
            return;
        }
        if (returnCode != NSAlertFirstButtonReturn) {
            [self exitCurrentMode];
            return;
        }

        self.isShowingExternalDisplayAlert = NO;
        return;
    }

    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            if ([NSScreen screens].count >= 2) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showExternalDisplayAlertMid];
                });
                return;
            }

            self.isShowingExternalDisplayAlert = NO;
            return;
        }

        [self exitCurrentMode];
    }];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
#pragma unused(app)
    return NO;
}

- (BOOL)applicationShouldSaveApplicationState:(NSApplication *)sender {
#pragma unused(sender)
    return NO;
}

- (BOOL)applicationShouldRestoreApplicationState:(NSApplication *)sender {
#pragma unused(sender)
    return NO;
}

#pragma mark - Billing Actions

- (void)handleViewPlans {
    NSLog(@"[Billing] User requested billing plans page");
    if (!self.roomController.tokenService) {
        NSLog(@"[Billing] tokenService is nil — cannot open plans");
        [self.connectionPanel setBillingStatusText:@"Unable to open plans."];
        return;
    }

    BOOL isAuth = self.roomController.tokenService.isAuthenticated;

    // Unauthenticated: ask the server for the public plans page URL.
    // The server owns the canonical URL — the app never hardcodes it.
    if (!isAuth) {
        [self.connectionPanel setBillingActionEnabled:NO];
        [self.connectionPanel setBillingStatusText:@""];

        __weak typeof(self) weakSelf = self;
        [self.roomController.tokenService requestPublicPlansURLWithCompletion:^(NSString *url) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { return; }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (url.length) {
                    NSURL *plansURL = [NSURL URLWithString:url];
                    if (plansURL) {
                        [[NSWorkspace sharedWorkspace] openURL:plansURL];
                    } else {
                        [strongSelf.connectionPanel setBillingStatusText:@"Unable to open plans."];
                    }
                } else {
                    [strongSelf.connectionPanel setBillingStatusText:@"Unable to open plans. Try again."];
                }

                [strongSelf.connectionPanel setBillingActionEnabled:YES];
            });
        }];
        return;
    }

    // Authenticated: request a tokenized URL so the page shows the current plan.
    [self.connectionPanel setBillingActionEnabled:NO];
    [self.connectionPanel setBillingStatusText:@""];

    __weak typeof(self) weakSelf = self;
    [self.roomController.tokenService requestBillingPageURLWithCompletion:^(NSString *url) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (url.length) {
                NSURL *plansURL = [NSURL URLWithString:url];
                if (plansURL) {
                    [[NSWorkspace sharedWorkspace] openURL:plansURL];
                } else {
                    NSLog(@"[Billing] Plans URL is malformed: %@", url);
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Unable to Open Plans";
                    alert.informativeText = @"The plans page link appears to be invalid. Please try again.";
                    alert.alertStyle = NSAlertStyleWarning;
                    [alert addButtonWithTitle:@"OK"];
                    [alert runModal];
                }
            } else {
                NSLog(@"[Billing] Failed to get billing plans URL");
                [strongSelf.connectionPanel setBillingStatusText:@"Failed to open plans. Try again."];
            }

            [strongSelf.connectionPanel setBillingActionEnabled:YES];
        });
    }];
}

- (void)handleManageSubscription {
    NSLog(@"[Billing] User requested subscription management");
    if (!self.roomController.tokenService) {
        NSLog(@"[Billing] tokenService is nil — cannot open portal");
        [self.connectionPanel setBillingStatusText:@"Not signed in."];
        return;
    }
    [self.connectionPanel setBillingActionEnabled:NO];

    __weak typeof(self) weakSelf = self;
    [self.roomController.tokenService requestPortalURLWithCompletion:^(NSString *url) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (url.length) {
                NSURL *portalURL = [NSURL URLWithString:url];
                if (portalURL) {
                    [[NSWorkspace sharedWorkspace] openURL:portalURL];
                } else {
                    NSLog(@"[Billing] Portal URL is malformed: %@", url);
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Unable to Open Subscription Portal";
                    alert.informativeText = @"The portal link appears to be invalid. Please try again.";
                    alert.alertStyle = NSAlertStyleWarning;
                    [alert addButtonWithTitle:@"OK"];
                    [alert runModal];
                }
            } else {
                NSLog(@"[Billing] Failed to get portal URL");
                [strongSelf.connectionPanel setBillingStatusText:@"Failed to open subscription portal."];
            }

            [strongSelf.connectionPanel setBillingActionEnabled:YES];
        });
    }];
}

#pragma mark - Idle Timeout (G3)

static const NSTimeInterval kIdleTimeoutSeconds = 30 * 60; // 30 minutes

- (void)setupIdleTimeout {
    self.lastUserActivityAt = [NSDate date];
    self.isIdleLocked = NO;

    // Check every 60 seconds
    self.idleCheckTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                          target:self
                                                        selector:@selector(checkIdleTimeout:)
                                                        userInfo:nil
                                                         repeats:YES];

    // Monitor user input events globally
    __weak typeof(self) weakSelf = self;
    self.globalEventMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskMouseMoved |
                                                                               NSEventMaskKeyDown    |
                                                                               NSEventMaskLeftMouseDown |
                                                                               NSEventMaskScrollWheel)
                                                                     handler:^(NSEvent * __unused event) {
        weakSelf.lastUserActivityAt = [NSDate date];
    }];

    // Also monitor local events (when our app is frontmost)
    self.localEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskMouseMoved |
                                                                             NSEventMaskKeyDown    |
                                                                             NSEventMaskLeftMouseDown |
                                                                             NSEventMaskScrollWheel)
                                                                   handler:^NSEvent *(NSEvent *event) {
        weakSelf.lastUserActivityAt = [NSDate date];
        return event;
    }];
}

- (void)checkIdleTimeout:(NSTimer *)timer {
#pragma unused(timer)
    // Only applies to authenticated users
    if (!self.roomController.tokenService.currentAccessToken) return;
    if (self.isIdleLocked) return;

    NSTimeInterval idle = [[NSDate date] timeIntervalSinceDate:self.lastUserActivityAt];
    if (idle < kIdleTimeoutSeconds) return;

    self.isIdleLocked = YES;
    NSLog(@"[Auth] Idle timeout reached (%.0f seconds) — prompting reauthentication", idle);

    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Session Timed Out";
        alert.informativeText = @"You've been inactive for 30 minutes. Please enter your password to continue.";
        [alert addButtonWithTitle:@"Unlock"];
        [alert addButtonWithTitle:@"Log Out"];

        NSSecureTextField *passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
        passwordField.placeholderString = @"Password";
        alert.accessoryView = passwordField;
        [alert.window setInitialFirstResponder:passwordField];

        NSModalResponse response = [alert runModal];
        if (response == NSAlertSecondButtonReturn) {
            // Log out — revoke token on server and clear local state
            [self.roomController.tokenService logoutWithCompletion:nil];
            if (self.setupWindow) {
                [self refreshSetupChrome];
            } else {
                [self launchSetupUI];
            }
            self.isIdleLocked = NO;
            return;
        }

        // Re-authenticate by calling login with stored email + entered password
        NSString *password = passwordField.stringValue;
        NSString *email = self.roomController.tokenService.currentEmail;

        if (!password.length || !email.length) {
            NSAlert *errAlert = [[NSAlert alloc] init];
            errAlert.messageText = @"Cannot Unlock";
            errAlert.informativeText = password.length ? @"Session data unavailable. Please log out and sign in again."
                                                       : @"Please enter your password.";
            [errAlert addButtonWithTitle:@"OK"];
            [errAlert runModal];
            self.isIdleLocked = NO;
            return;
        }

        NSString *baseURL = self.roomController.tokenService.serverURL ?: @"http://localhost:3000";
        [self.roomController.tokenService loginWithEmail:email
                                                password:password
                                               serverURL:baseURL
                                              completion:^(InterAuthResponse *authResponse, NSError *loginError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (authResponse && !loginError) {
                    NSLog(@"[Auth] Idle reauthentication successful");
                    self.lastUserActivityAt = [NSDate date];
                    self.isIdleLocked = NO;
                } else {
                    NSAlert *errAlert = [[NSAlert alloc] init];
                    errAlert.messageText = @"Authentication Failed";
                    errAlert.informativeText = @"Incorrect password. Please try again or log out.";
                    [errAlert addButtonWithTitle:@"Try Again"];
                    [errAlert addButtonWithTitle:@"Log Out"];
                    NSModalResponse retry = [errAlert runModal];
                    if (retry == NSAlertSecondButtonReturn) {
                        [self.roomController.tokenService logoutWithCompletion:nil];
                        if (self.setupWindow) {
                            [self refreshSetupChrome];
                        } else {
                            [self launchSetupUI];
                        }
                    }
                    self.isIdleLocked = NO;
                }
            });
        }];
    });
}

#pragma mark - OAuth Social Sign-In (Phase F)

- (void)startOAuthSignInWithProvider:(NSString *)provider {
    // Validate provider to prevent URL path injection
    if (![provider isEqualToString:@"google"] && ![provider isEqualToString:@"microsoft"]) {
        NSLog(@"[OAuth] Unknown provider: %@", provider);
        return;
    }

    // Ask the server for the OAuth start URL — the app never hardcodes it.
    __weak typeof(self) weakSelf = self;
    [self.roomController.tokenService requestOAuthStartURLWithProvider:provider
                                                           completion:^(NSString *urlString) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!urlString.length) {
                NSLog(@"[OAuth] Server did not return a start URL for provider: %@", provider);
                [strongSelf.loginPanel showError:@"Unable to start sign-in. Please try again."];
                return;
            }
            NSURL *startURL = [NSURL URLWithString:urlString];
            if (!startURL) {
                NSLog(@"[OAuth] Invalid start URL: %@", urlString);
                [strongSelf.loginPanel showError:@"Unable to start sign-in. Please try again."];
                return;
            }

            ASWebAuthenticationSession *session =
                [[ASWebAuthenticationSession alloc] initWithURL:startURL
                                              callbackURLScheme:@"com-inter-app"
                                              completionHandler:^(NSURL *callbackURL, NSError *error) {
                strongSelf.oauthSession = nil; // Release session — allow deep link fallback
                if (error) {
                    if (error.code != ASWebAuthenticationSessionErrorCodeCanceledLogin) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [strongSelf.loginPanel showError:@"Sign-in failed. Please try again."];
                        });
                    }
                    return;
                }
                if (!callbackURL) return;

                // Parse handoff code from callback URL
                NSURLComponents *components = [NSURLComponents componentsWithURL:callbackURL
                                                         resolvingAgainstBaseURL:NO];
                NSString *code = nil;
                NSString *oauthError = nil;
                for (NSURLQueryItem *item in components.queryItems) {
                    if ([item.name isEqualToString:@"code"]) code = item.value;
                    if ([item.name isEqualToString:@"error"]) oauthError = item.value;
                }

                if (oauthError.length > 0) {
                    NSString *message = [oauthError isEqualToString:@"access_denied"]
                        ? @"Sign-in was cancelled."
                        : @"Sign-in failed. Please try again.";
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [strongSelf.loginPanel showError:message];
                    });
                    return;
                }

                if (code.length > 0) {
                    [strongSelf handleOAuthCallbackWithCode:code];
                }
            }];

            session.presentationContextProvider = strongSelf;
            session.prefersEphemeralWebBrowserSession = YES;
            [session start];
            strongSelf.oauthSession = session;
        });
    }];
}

- (void)handleOAuthCallbackWithCode:(NSString *)code {
    NSLog(@"[OAuth] Exchanging handoff code for tokens");

    [self.roomController.tokenService exchangeOAuthCode:code completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                NSLog(@"[OAuth] Authentication successful");
                [self dismissLoginWindow];
                [self refreshSetupChrome];
            } else {
                NSLog(@"[OAuth] Exchange failed: %@", error.localizedDescription);
                [self.loginPanel showError:@"Sign-in failed. Please try again."];
            }
        });
    }];
}

#pragma mark - ASWebAuthenticationPresentationContextProviding

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
#pragma unused(session)
    return self.loginWindow ?: NSApp.mainWindow ?: NSApp.windows.firstObject;
}

#pragma mark - Deep Link Handling (inter:// URL scheme)

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
#pragma unused(application)
    // Allowed deep-link paths per host (whitelist)
    NSDictionary<NSString *, NSArray<NSString *> *> *allowedPaths = @{
        @"billing": @[@"/success"],
        @"reset-password": @[@"/"],
        @"oauth-callback": @[@"/"],
    };

    // Hosts that require a query string (e.g. token parameter)
    NSSet<NSString *> *hostsAllowingQuery = [NSSet setWithObjects:@"reset-password", @"oauth-callback", nil];

    for (NSURL *url in urls) {
        // Reject any URL that does not carry the exact registered scheme
        if (![url.scheme isEqualToString:@"com-inter-app"]) {
            NSLog(@"[DeepLink] Rejected URL with unexpected scheme: %@", url.scheme);
            continue;
        }

        NSString *host = url.host;
        NSString *path = url.path;

        // Reject empty or nil host
        if (!host.length) {
            NSLog(@"[DeepLink] Rejected URL with missing host: %@", url.absoluteString);
            continue;
        }

        // Reject host not in allowlist
        NSArray<NSString *> *allowedForHost = allowedPaths[host];
        if (!allowedForHost) {
            NSLog(@"[DeepLink] Rejected URL with unknown host '%@'", host);
            continue;
        }

        // Normalize path: treat nil/empty as "/"
        if (!path.length) { path = @"/"; }

        // Reject path not in allowlist for this host
        if (![allowedForHost containsObject:path]) {
            NSLog(@"[DeepLink] Rejected URL with unknown path '%@' for host '%@'", path, host);
            continue;
        }

        // Reject URLs carrying a query string or fragment unless the host allows it
        if (url.fragment.length) {
            NSLog(@"[DeepLink] Rejected URL with fragment: %@", url.absoluteString);
            continue;
        }
        if (url.query.length && ![hostsAllowingQuery containsObject:host]) {
            NSLog(@"[DeepLink] Rejected URL with unexpected query for host '%@': %@", host, url.absoluteString);
            continue;
        }

        // Dispatch to the appropriate handler
        if ([host isEqualToString:@"billing"] && [path isEqualToString:@"/success"]) {
            [self handleBillingSuccessDeepLink];
            return;
        }

        if ([host isEqualToString:@"reset-password"]) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            NSString *token = nil;
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"token"]) {
                    token = item.value;
                    break;
                }
            }
            if (token.length > 0) {
                [self handlePasswordResetDeepLinkWithToken:token];
            } else {
                NSLog(@"[DeepLink] reset-password URL missing token parameter");
            }
            return;
        }

        if ([host isEqualToString:@"oauth-callback"]) {
            // ASWebAuthenticationSession intercepts the callback URL scheme before
            // it reaches application:openURLs:. If oauthSession is still alive,
            // the completionHandler already handled this — skip to avoid double exchange.
            if (self.oauthSession) {
                NSLog(@"[DeepLink] oauth-callback ignored — ASWebAuthenticationSession active");
                return;
            }
            NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            NSString *code = nil;
            NSString *error = nil;
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"code"]) code = item.value;
                if ([item.name isEqualToString:@"error"]) error = item.value;
            }
            if (error.length > 0) {
                NSString *message = [error isEqualToString:@"access_denied"]
                    ? @"Sign-in was cancelled."
                    : @"Sign-in failed. Please try again.";
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.loginPanel showError:message];
                });
            } else if (code.length > 0) {
                [self handleOAuthCallbackWithCode:code];
            } else {
                NSLog(@"[DeepLink] oauth-callback URL missing code and error");
            }
            return;
        }

        // Should not be reached given the whitelist above, but log defensively
        NSLog(@"[DeepLink] Unhandled whitelisted URL: %@", url.absoluteString);
    }
}

- (void)handleBillingSuccessDeepLink {
    NSLog(@"[Billing] Deep link received — com-inter-app://billing/success");

    // Bring app to front
    [NSApp activateIgnoringOtherApps:YES];
    if (self.setupWindow) {
        [self.setupWindow makeKeyAndOrderFront:nil];
    }

    // Guard against duplicate polls
    if (self.isBillingPollInProgress) {
        NSLog(@"[Billing] Poll already in progress — ignoring duplicate deep link");
        return;
    }
    self.isBillingPollInProgress = YES;

    [self.connectionPanel setBillingStatusText:@"Verifying your upgrade…"];
    [self.connectionPanel setBillingActionEnabled:NO];

    NSString *previousTier = self.roomController.tokenService.currentTier ?: @"free";
    NSUInteger pollGen = self.billingPollGeneration;

    __weak typeof(self) weakSelf = self;
    [self.roomController.tokenService refreshAndWaitForTierChangeWithPreviousTier:previousTier
                                                                     maxAttempts:15
                                                                        interval:2.0
                                                                      completion:^(NSString *newTier) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (pollGen != strongSelf.billingPollGeneration) {
                NSLog(@"[Billing] Stale poll completion (gen %lu vs %lu) — ignoring",
                      (unsigned long)pollGen, (unsigned long)strongSelf.billingPollGeneration);
                return;
            }
            strongSelf.isBillingPollInProgress = NO;

            if (newTier.length) {
                NSLog(@"[Billing] Tier upgraded: %@ → %@", previousTier, newTier);

                // Re-render chrome so the avatar menu offers "Manage Subscription"
                [strongSelf refreshSetupChrome];
                [strongSelf.connectionPanel setBillingStatusText:
                    [NSString stringWithFormat:@"Upgraded to %@!", [newTier capitalizedString]]];
                [strongSelf.connectionPanel setBillingActionEnabled:YES];

                // Clear the success message after a few seconds
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if ([strongSelf.connectionPanel.billingStatusText containsString:@"Upgraded"]) {
                        [strongSelf.connectionPanel setBillingStatusText:@""];
                    }
                });
            } else {
                NSLog(@"[Billing] Tier poll timed out — tier unchanged from %@", previousTier);
                [strongSelf.connectionPanel setBillingStatusText:@"Upgrade pending — it may take a moment."];
                [strongSelf.connectionPanel setBillingActionEnabled:YES];
            }
        });
    }];
}

#pragma mark - Password Reset Deep Link

- (void)handlePasswordResetDeepLinkWithToken:(NSString *)token {
    NSLog(@"[Auth] Password reset deep link received");

    // Bring app to front
    [NSApp activateIgnoringOtherApps:YES];

    // Resolve the redemption server BEFORE prompting for a password — never ask the user
    // to type a new password we already know we can't send anywhere.
    // Redeem against the SAME server that ISSUED the link, from EXPLICIT sources only:
    // the issuing URL persisted when the reset was requested, then the live auth server,
    // then the configured default. We deliberately do NOT fall back to a hardcoded
    // localhost — POSTing a reset token + new password to an implicit local server would
    // leak credentials to an unintended backend for signed-out / custom-server users.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *baseURL = [defaults stringForKey:@"InterPasswordResetIssuingServerURL"];
    // Expire the stored issuer: server reset tokens live 1 hour, so an older stored URL can
    // never redeem a valid token — it is pure staleness liability (it may point at a server
    // the user no longer uses, e.g. an old custom/dev backend). Unknown age (no stamp,
    // persisted by an older build) is treated as stale. Discard and resolve from the live
    // sources below instead.
    NSDate *issuerSetAt = [defaults objectForKey:@"InterPasswordResetIssuingServerSetAt"];
    BOOL issuerStale = ![issuerSetAt isKindOfClass:[NSDate class]]
        || [[NSDate date] timeIntervalSinceDate:issuerSetAt] > 3600.0;
    if (baseURL.length && issuerStale) {
        NSLog(@"[Auth] Stored password-reset issuer is stale — discarding it.");
        [defaults removeObjectForKey:@"InterPasswordResetIssuingServerURL"];
        [defaults removeObjectForKey:@"InterPasswordResetIssuingServerSetAt"];
        baseURL = nil;
    }
    if (!baseURL.length) {
        baseURL = self.roomController.tokenService.serverURL;
    }
    if (!baseURL.length) {
        baseURL = [defaults stringForKey:@"InterDefaultTokenServerURL"];
    }
    // Fail closed: if no explicit issuing server can be resolved, abort rather than
    // defaulting to localhost. The token + new password are never sent to an implicit server.
    if (!baseURL.length) {
        NSLog(@"[Auth] Password reset aborted — could not resolve the issuing server URL; "
               "refusing to POST credentials to an implicit default.");
        // User-facing framing: the only reliable recovery on an unconfigured Mac is the
        // web form on the server's reset page (re-opening the email link always lands
        // there, and viewing the page does not consume the token). Do NOT suggest the
        // in-app "Forgot password" here — on a machine with no configured server that
        // request can't reach a backend either, which would be a second dead end.
        NSAlert *errAlert = [[NSAlert alloc] init];
        errAlert.messageText = @"Finish Your Password Reset in the Browser";
        errAlert.informativeText = @"The app on this Mac isn't connected to your account yet, "
                                    "so it can't finish the reset here. Open the reset link "
                                    "from your email in your browser and set your new password "
                                    "using the form on that page.";
        errAlert.alertStyle = NSAlertStyleInformational;
        [errAlert addButtonWithTitle:@"OK"];
        [errAlert runModal];
        return;
    }

    // Show a password reset alert with a secure text field
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Reset Your Password";
    alert.informativeText = @"Enter a new password (8–72 bytes UTF-8). Emoji and accented characters may count as multiple bytes.";
    [alert addButtonWithTitle:@"Reset Password"];
    [alert addButtonWithTitle:@"Cancel"];

    NSSecureTextField *passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    passwordField.placeholderString = @"New password";
    alert.accessoryView = passwordField;
    [alert.window setInitialFirstResponder:passwordField];

    NSModalResponse response = [alert runModal];
    if (response != NSAlertFirstButtonReturn) return;

    NSString *newPassword = passwordField.stringValue;
    NSUInteger passwordBytes = [newPassword lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (passwordBytes < 8 || passwordBytes > 72) {
        NSAlert *errAlert = [[NSAlert alloc] init];
        errAlert.messageText = @"Invalid Password";
        errAlert.informativeText = @"Password must be between 8 and 72 bytes (UTF-8).";
        [errAlert addButtonWithTitle:@"OK"];
        [errAlert runModal];
        return;
    }

    // POST to /auth/reset-password (on the server resolved above) with the token and
    // new password.
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/auth/reset-password", baseURL]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{@"token": token, @"newPassword": newPassword};
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            NSAlert *resultAlert = [[NSAlert alloc] init];
            [resultAlert addButtonWithTitle:@"OK"];

            if (error || httpResponse.statusCode != 200) {
                NSString *serverMsg = @"Something went wrong. Please request a new reset link.";
                if (data) {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (json[@"error"]) serverMsg = json[@"error"];
                }
                resultAlert.messageText = @"Password Reset Failed";
                resultAlert.informativeText = serverMsg;
                resultAlert.alertStyle = NSAlertStyleWarning;
            } else {
                resultAlert.messageText = @"Password Updated";
                resultAlert.informativeText = @"Your password has been reset. Please log in with your new password.";
                // One-shot: the token is now redeemed (single-use server-side), so the stored
                // issuing-server hint has served its purpose — clear it so it cannot steer
                // any future, unrelated redemption.
                NSUserDefaults *cleanupDefaults = [NSUserDefaults standardUserDefaults];
                [cleanupDefaults removeObjectForKey:@"InterPasswordResetIssuingServerURL"];
                [cleanupDefaults removeObjectForKey:@"InterPasswordResetIssuingServerSetAt"];
            }
            [resultAlert runModal];
        });
    }] resume];
}

@end
