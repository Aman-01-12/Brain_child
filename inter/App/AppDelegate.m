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
#import "InterConnectionSetupPanel.h"
#import "InterLoginPanel.h"
#import "InterRemoteVideoLayoutManager.h"
#import "InterTrackRendererBridge.h"
#import "InterParticipantOverlayView.h"
#import "InterNetworkStatusView.h"
#import "InterChatPanel.h"
#import "InterSpeakerQueuePanel.h"
#import "InterPollPanel.h"
#import "InterQAPanel.h"
#import "InterLobbyPanel.h"
#import "InterRecordingIndicatorView.h"
#import "InterRecordingListPanel.h"
#import "InterRecordingConsentPanel.h"
#import "InterSchedulePanel.h"
#import "InterTeamsPanel.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AuthenticationServices/AuthenticationServices.h>

// [2.5.1] Swift module import for networking layer
#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

@interface AppDelegate () <NSWindowDelegate, InterConnectionSetupPanelDelegate, InterLoginPanelDelegate, InterAuthSessionDelegate, InterParticipantOverlayDelegate, InterChatPanelDelegate, InterSpeakerQueuePanelDelegate, InterPollPanelDelegate, InterQAPanelDelegate, InterMediaWiringDelegate, InterModerationDelegate, InterLobbyPanelDelegate, InterRecordingCoordinatorDelegate, InterRecordingSignalDelegate, InterRecordingListPanelDelegate, InterRecordingConsentPanelDelegate, InterSchedulePanelDelegate, InterTeamsPanelDelegate, ASWebAuthenticationPresentationContextProviding>
@property (nonatomic, strong) NSMutableArray<CapWindow *> *capWindows;
@property (nonatomic, strong) SecureWindowController *secureController;
@property (nonatomic, strong) NSWindow *setupWindow;
@property (nonatomic, strong) MetalSurfaceView *setupRenderView;
@property (nonatomic, strong) NSWindow *settingsWindow;
@property (nonatomic, strong) NSWindow *normalCallWindow;
@property (nonatomic, strong) MetalSurfaceView *normalRenderView;
@property (nonatomic, strong) InterLocalMediaController *normalMediaController;
@property (nonatomic, strong) InterSurfaceShareController *normalSurfaceShareController;
@property (nonatomic, strong) InterLocalCallControlPanel *normalControlPanel;
@property (nonatomic, strong) InterCallSessionCoordinator *sessionCoordinator;
@property (nonatomic, strong, nullable) InterConnectionSetupPanel *connectionPanel;
@property (nonatomic, strong, nullable) InterRemoteVideoLayoutManager *normalRemoteLayout;
@property (nonatomic, strong, nullable) InterTrackRendererBridge *normalTrackRendererBridge;
@property (nonatomic, strong, nullable) InterNetworkStatusView *normalNetworkStatusView;
@property (nonatomic, strong, nullable) InterMediaWiringController *normalMediaWiring;

// [Phase 8] In-meeting communication
@property (nonatomic, strong, nullable) InterChatController *chatController;
@property (nonatomic, strong, nullable) InterChatPanel *normalChatPanel;
@property (nonatomic, strong, nullable) InterSpeakerQueue *speakerQueue;
@property (nonatomic, strong, nullable) InterSpeakerQueuePanel *normalSpeakerQueuePanel;
@property (nonatomic, strong, nullable) NSButton *normalChatToggleButton;
@property (nonatomic, strong, nullable) NSButton *normalHandRaiseButton;
@property (nonatomic, strong, nullable) NSButton *normalQueueToggleButton;

// [Phase 8.5] Live polls
@property (nonatomic, strong, nullable) InterPollController *pollController;
@property (nonatomic, strong, nullable) InterPollPanel *normalPollPanel;
@property (nonatomic, strong, nullable) NSWindow *normalPollWindow;
@property (nonatomic, strong, nullable) NSButton *normalPollToggleButton;

// [Phase 8.6] Q&A
@property (nonatomic, strong, nullable) InterQAController *qaController;
@property (nonatomic, strong, nullable) InterQAPanel *normalQAPanel;
@property (nonatomic, strong, nullable) NSWindow *normalQAWindow;
@property (nonatomic, strong, nullable) NSButton *normalQAToggleButton;

// [Phase 9] Meeting management
@property (nonatomic, strong, nullable) InterModerationController *moderationController;
@property (nonatomic, strong, nullable) InterLobbyPanel *normalLobbyPanel;
@property (nonatomic, strong, nullable) NSWindow *normalLobbyWindow;
@property (nonatomic, strong, nullable) NSButton *normalLobbyToggleButton;
@property (nonatomic, strong, nullable) NSButton *normalModerationButton;
@property (nonatomic, copy, nullable) NSString *normalChatSelectedRecipient;
@property (nonatomic, assign) BOOL normalShareSystemAudioEnabled;
@property (nonatomic, assign) BOOL isScreenObserverRegistered;
@property (nonatomic, assign) BOOL isShowingExternalDisplayAlert;
@property (nonatomic, weak) NSWindow *fullScreenExitPendingWindow;

// [Phase 10] Recording
@property (nonatomic, strong, nullable) InterRecordingCoordinator *normalRecordingCoordinator;
@property (nonatomic, strong, nullable) InterRecordingIndicatorView *normalRecordingIndicatorView;
@property (nonatomic, strong, nullable) InterRecordingListPanel *normalRecordingListPanel;
@property (nonatomic, strong, nullable) NSWindow *normalRecordingListWindow;
@property (nonatomic, strong, nullable) InterRecordingConsentPanel *normalRecordingConsentPanel;

// [Phase 11] Scheduling
@property (nonatomic, strong, nullable) InterSchedulePanel *normalSchedulePanel;
@property (nonatomic, strong, nullable) NSWindow *normalScheduleWindow;

// [Phase 11.1] Calendar service
@property (nonatomic, strong, nullable) InterCalendarService *calendarService;

// [Phase 11.4] Teams
@property (nonatomic, strong, nullable) InterTeamsPanel *teamsPanel;
@property (nonatomic, strong, nullable) NSWindow *teamsWindow;

// Settings window — calendar connect/disconnect buttons (rebuilt each open)
@property (nonatomic, strong, nullable) NSButton *settingsGoogleButton;
@property (nonatomic, strong, nullable) NSButton *settingsOutlookButton;
@property (nonatomic, strong, nullable) NSTextField *settingsGoogleStatusLabel;
@property (nonatomic, strong, nullable) NSTextField *settingsOutlookStatusLabel;

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
@property (nonatomic, strong, nullable) NSButton *upgradeButton;
@property (nonatomic, strong, nullable) NSButton *manageSubscriptionButton;
@property (nonatomic, strong, nullable) NSTextField *billingStatusLabel;
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
                                     MetalSurfaceView *__strong *renderViewRef,
                                     InterConnectionSetupPanel *__strong *connectionPanelRef) {
    MetalSurfaceView *renderView = *renderViewRef;
    if (renderView != nil) {
        [renderView shutdownRenderingSynchronously];
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
        [self exitCurrentMode];
    });
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

    // Lock the tier for the duration of this meeting so that mid-meeting
    // token refreshes (which may carry a tier change) do not affect the
    // active session.
    [self.roomController.tokenService lockTierForMeeting];

    [self teardownActiveWindows];
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

    if (isIntervieweeMode) {
        [self applyKioskRestrictions];
        [self startScreenMonitoring];
        self.secureController = [[SecureWindowController alloc] init];
        // [2.6.1] Pass room controller reference to secure window
        self.secureController.roomController = self.roomController;
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
    [self.setupWindow setTitle:@"Secure Call Setup"];
    [self.setupWindow setSharingType:NSWindowSharingNone];
    [self.setupWindow setDelegate:self];
    [self.setupWindow setBackgroundColor:[NSColor blackColor]];
    [self.setupWindow setMinSize:NSMakeSize(660.0, 600.0)];
    [self.setupWindow setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

    NSView *view = [[NSView alloc] initWithFrame:self.setupWindow.contentView.bounds];
    [view setWantsLayer:YES];
    view.layer.backgroundColor = [NSColor blackColor].CGColor;
    [self.setupWindow setContentView:view];

    self.setupRenderView = [[MetalSurfaceView alloc] initWithFrame:view.bounds];
    self.setupRenderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.setupRenderView];

    [self launchNativeSetupControlsInContainerView:view];

    [self.setupWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)launchNativeSetupControlsInContainerView:(NSView *)containerView {
    // Clear billing UI from any previous setup window lifecycle
    [self.upgradeButton removeFromSuperview];
    self.upgradeButton = nil;
    [self.manageSubscriptionButton removeFromSuperview];
    self.manageSubscriptionButton = nil;
    [self.billingStatusLabel removeFromSuperview];
    self.billingStatusLabel = nil;
    self.isBillingPollInProgress = NO;
    self.billingPollGeneration++;

    NSView *overlayView = [[NSView alloc] initWithFrame:containerView.bounds];
    overlayView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [overlayView setWantsLayer:YES];
    overlayView.layer.backgroundColor = NSColor.clearColor.CGColor;
    [containerView addSubview:overlayView];

    // [3.1.1] Connection setup panel — server URLs, display name, room code, action buttons.
    // The panel is created once and survives auth state changes. Only the chrome
    // (Sign In/Out, Settings, Billing) around it is rebuilt.
    CGFloat panelW = 420.0;
    CGFloat panelH = 480.0;
    CGFloat panelX = (containerView.bounds.size.width - panelW) / 2.0;
    CGFloat panelY = (containerView.bounds.size.height - panelH) / 2.0;
    self.connectionPanel = [[InterConnectionSetupPanel alloc] initWithFrame:NSMakeRect(panelX, panelY, panelW, panelH)];
    self.connectionPanel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    self.connectionPanel.delegate = self;
    [overlayView addSubview:self.connectionPanel];

    [self buildSetupChromeInOverlay:overlayView];
}

/// Build (or rebuild) the auth-dependent controls that surround the connection panel.
///
/// Layout varies by auth state:
/// - Unauthenticated: "Sign In / Sign Up" (right), Settings (left — gated),
///   Billing (center — gated), billingStatusLabel.
/// - Authenticated: "Sign Out" (left), Settings (right), Billing (functional),
///   billingStatusLabel.
/// - Offline with persisted session: "Sign Out" (left), Settings (right),
///   Billing (cached tier), billingStatusLabel shows "Offline — reconnecting…".
///   The user sees their identity but server-dependent actions are unavailable
///   until the background retry timer restores the session.
///
/// This method removes any existing chrome view before building a new one,
/// preserving the connection panel and its field values.
- (void)buildSetupChromeInOverlay:(NSView *)overlayView {
    // Remove previous chrome controls — everything except the connection panel.
    for (NSView *sub in [overlayView.subviews copy]) {
        if (sub != self.connectionPanel) {
            [sub removeFromSuperview];
        }
    }
    self.upgradeButton = nil;
    self.manageSubscriptionButton = nil;
    self.billingStatusLabel = nil;

    CGFloat panelW = 420.0;
    CGFloat panelH = 480.0;
    CGFloat panelX = (overlayView.bounds.size.width - panelW) / 2.0;
    CGFloat panelY = (overlayView.bounds.size.height - panelH) / 2.0;

    BOOL isAuth = self.roomController.tokenService.isAuthenticated;
    BOOL isOfflineWithSession = !isAuth && self.roomController.tokenService.hasPersistedSession;

    // Row 1: Left button + Right button (positioned above the connection panel)
    if (isAuth || isOfflineWithSession) {
        NSButton *signOutButton = [[NSButton alloc] initWithFrame:NSMakeRect(panelX, panelY + panelH + 8, 100, 26)];
        signOutButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
        [signOutButton setTitle:@"Sign Out"];
        [signOutButton setTarget:self];
        [signOutButton setAction:@selector(handleLogout)];
        [overlayView addSubview:signOutButton];

        NSButton *settingsButton = [[NSButton alloc] initWithFrame:NSMakeRect(panelX + panelW - 112, panelY + panelH + 8, 112, 26)];
        settingsButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
        [settingsButton setTitle:@"Settings"];
        [settingsButton setTarget:self];
        [settingsButton setAction:@selector(openSettingsWindow)];
        [overlayView addSubview:settingsButton];
    } else {
        NSButton *settingsButton = [[NSButton alloc] initWithFrame:NSMakeRect(panelX, panelY + panelH + 8, 112, 26)];
        settingsButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
        [settingsButton setTitle:@"Settings"];
        [settingsButton setTarget:self];
        [settingsButton setAction:@selector(openSettingsWindow)];
        [overlayView addSubview:settingsButton];

        NSButton *signInButton = [[NSButton alloc] initWithFrame:NSMakeRect(panelX + panelW - 140, panelY + panelH + 8, 140, 26)];
        signInButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
        [signInButton setTitle:@"Sign In / Sign Up"];
        [signInButton setTarget:self];
        [signInButton setAction:@selector(handleSignIn)];
        [overlayView addSubview:signInButton];
    }

    // Row 2: Billing buttons (centered, above row 1)
    CGFloat billingY = panelY + panelH + 42;

    if (isAuth || isOfflineWithSession) {
        NSString *currentTier = self.roomController.tokenService.currentTier ?: @"free";
        BOOL isPaid = ([currentTier isEqualToString:@"pro"] || [currentTier isEqualToString:@"pro+"]);
        NSLog(@"[Billing UI] Setting up buttons — currentTier=%@ isPaid=%@", currentTier, isPaid ? @"YES" : @"NO");

        if (!isPaid) {
            self.upgradeButton = [[NSButton alloc] initWithFrame:NSMakeRect(panelX + (panelW - 100) / 2.0, billingY, 100, 26)];
            self.upgradeButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
            [self.upgradeButton setTitle:@"View Plans"];
            [self.upgradeButton setTarget:self];
            [self.upgradeButton setAction:@selector(handleViewPlans)];
            [overlayView addSubview:self.upgradeButton];
        } else {
            self.manageSubscriptionButton = [[NSButton alloc] initWithFrame:NSMakeRect(panelX + (panelW - 160) / 2.0, billingY, 160, 26)];
            self.manageSubscriptionButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
            [self.manageSubscriptionButton setTitle:@"Manage Subscription"];
            [self.manageSubscriptionButton setTarget:self];
            [self.manageSubscriptionButton setAction:@selector(handleManageSubscription)];
            [overlayView addSubview:self.manageSubscriptionButton];
        }
    } else {
        self.upgradeButton = [[NSButton alloc] initWithFrame:NSMakeRect(panelX + (panelW - 100) / 2.0, billingY, 100, 26)];
        self.upgradeButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
        [self.upgradeButton setTitle:@"View Plans"];
        [self.upgradeButton setTarget:self];
        [self.upgradeButton setAction:@selector(handleViewPlans)];
        [overlayView addSubview:self.upgradeButton];
    }

    self.billingStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(panelX, panelY - 28, panelW, 20)];
    self.billingStatusLabel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    self.billingStatusLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.billingStatusLabel.alignment = NSTextAlignmentCenter;
    self.billingStatusLabel.editable = NO;
    self.billingStatusLabel.selectable = NO;
    self.billingStatusLabel.bezeled = NO;
    self.billingStatusLabel.drawsBackground = NO;
    [overlayView addSubview:self.billingStatusLabel];

    // Show offline indicator when signed in but server is unreachable
    if (isOfflineWithSession) {
        NSString *displayName = self.roomController.tokenService.currentDisplayName ?: @"";
        if (displayName.length > 0) {
            self.billingStatusLabel.stringValue = [NSString stringWithFormat:@"%@ — Offline, reconnecting…", displayName];
        } else {
            self.billingStatusLabel.stringValue = @"Offline — reconnecting…";
        }
        self.billingStatusLabel.textColor = [NSColor systemOrangeColor];
    } else {
        self.billingStatusLabel.stringValue = @"";
        self.billingStatusLabel.textColor = [NSColor secondaryLabelColor];
    }

    // [Phase 11] Schedule Meetings button — shown for authenticated users and
    // offline-with-session (T5: role-based rendering, not connectivity-based).
    // When offline, clicking opens the panel; the server call fails gracefully via T3.
    if (isAuth || isOfflineWithSession) {
        CGFloat schedY = panelY - 34;
        NSButton *scheduleButton = [[NSButton alloc] initWithFrame:NSMakeRect(panelX + (panelW - 160) / 2.0, schedY, 160, 26)];
        scheduleButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin;
        [scheduleButton setTitle:@"Schedule Meeting"];
        [scheduleButton setTarget:self];
        [scheduleButton setAction:@selector(handleShowSchedulePanel)];
        [overlayView addSubview:scheduleButton];
    }
}

/// Rebuild the auth-dependent chrome (Sign In/Out, Settings, Billing) in-place
/// without tearing down the setup window or the connection panel.
- (void)refreshSetupChrome {
    if (!self.connectionPanel || !self.connectionPanel.superview) {
        return;
    }
    NSView *overlayView = self.connectionPanel.superview;
    [self buildSetupChromeInOverlay:overlayView];
}

#pragma mark - Auth Login Window [Phase B.4d]

/// Show the login window so the user can sign in or create an account.
/// Called from the "Sign In / Sign Up" button on the unauthenticated setup screen.
- (void)handleSignIn {
    [self showLoginWindow];
}

/// Auth-gated action: user tapped Settings while not signed in.
- (void)handleSettingsRequiresAuth {
    [self.connectionPanel setStatusText:@"Sign in to access settings."];
}

#pragma mark - Schedule Panel [Phase 11]

/// Show or bring to front the scheduling floating window.
- (void)handleShowSchedulePanel {
    if (self.normalScheduleWindow) {
        [self.normalScheduleWindow makeKeyAndOrderFront:nil];
        [self reloadScheduleData];
        return;
    }

    CGFloat panelWidth  = 360;
    CGFloat panelHeight = 640;
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
    self.normalScheduleWindow.title = @"Schedule Meeting";
    self.normalScheduleWindow.minSize = NSMakeSize(320, 480);
    self.normalScheduleWindow.releasedWhenClosed = NO;
    self.normalScheduleWindow.level = NSFloatingWindowLevel;
    [self.normalScheduleWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
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
    [ts scheduleMeetingWithTitle:title
                    description:description
                    scheduledAt:scheduledAt
                durationMinutes:duration
                       roomType:roomType
                   hostTimezone:timezone
                       password:password
                   lobbyEnabled:lobbyEnabled
                     completion:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
        if (error) {
            [panel setStatusText:@"Could not schedule meeting. Please try again."];
            panel.scheduleButton.enabled = YES;
            return;
        }
        [panel resetForm];
        panel.scheduleButton.enabled = YES;
        [self reloadScheduleData];

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

        // [Phase 11.1] Remove from Apple Calendar
        [self.calendarService removeEventForMeetingId:meetingId];

        // [Phase 11.2.4/11.2.5] No explicit calendar delete API — sync servers
        // handle deletion via the server-side cancellation flag.
    }];
}

- (void)schedulePanel:(InterSchedulePanel *)panel didRequestJoin:(NSString *)roomCode meetingId:(NSString *)meetingId {
    // Close the schedule window and switch to the connection panel.
    [self.normalScheduleWindow orderOut:nil];
    [self.connectionPanel setRoomCodeText:roomCode];
    [self.connectionPanel setStatusText:@"Joining scheduled meeting…"];

    InterRoomController *rc = self.roomController;
    if (!rc) {
        [self.connectionPanel setStatusText:@"Network unavailable — cannot join."];
        return;
    }

    NSString *serverURL   = self.connectionPanel.serverURL;
    NSString *tokenURL    = self.connectionPanel.tokenServerURL;
    NSString *displayName = self.connectionPanel.displayName;

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

    __weak typeof(self) weakSelf = self;
    [rc connectWithConfiguration:config completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            InterConnectionSetupPanel *p = strongSelf.connectionPanel;
            if (error) {
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
                [strongSelf showIntervieweeConfirmationWithCompletion:^(BOOL accepted) {
                    if (accepted) {
                        [strongSelf enterMode:InterCallModeInterview role:InterInterviewRoleInterviewee];
                    } else {
                        [rc disconnect];
                        [p setIndicatorState:InterConnectionIndicatorStateIdle];
                        [p setStatusText:@"Disconnected — declined interview session."];
                    }
                }];
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

// ============================================================================
#pragma mark - InterTeamsPanelDelegate
// ============================================================================

- (void)teamsPanelDidRequestRefresh:(InterTeamsPanel *)panel {
    [self reloadTeamsData];
    // Also refresh members if a team is already selected
    NSString *teamId = [panel selectedTeamId];
    if (!teamId) return;
    InterTokenService *ts = self.roomController.tokenService;
    if (!ts) return;
    __weak typeof(self) weakSelf = self;
    [ts fetchTeamDetailsWithTeamId:teamId completion:^(NSDictionary<NSString *,id> *team, NSArray<NSDictionary<NSString *,id> *> *members, NSString *callerRole, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (error) {
            [strongSelf.teamsPanel setStatusText:@"Could not load team details. Please try again."];
            return;
        }
        [strongSelf.teamsPanel setCurrentTeamMembers:members ?: @[] callerRole:callerRole ?: @""];
    }];
}

- (void)teamsPanel:(InterTeamsPanel *)panel
  didRequestCreateTeamName:(NSString *)name
               description:(NSString *)description {
    InterTokenService *ts = self.roomController.tokenService;
    if (!ts) return;
    __weak typeof(self) weakSelf = self;
    [ts createTeamWithName:name teamDescription:description completion:^(NSDictionary<NSString *,id> *team, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.teamsPanel resetCreateButton];
        if (error) {
            [strongSelf.teamsPanel setStatusText:@"Could not create team. Please try again."];
        } else {
            [strongSelf.teamsPanel setStatusText:@"Team created!"];
            [strongSelf reloadTeamsData];
        }
    }];
}

- (void)teamsPanel:(InterTeamsPanel *)panel
didRequestInviteEmails:(NSArray<NSString *> *)emails
            toTeamId:(NSString *)teamId {
    InterTokenService *ts = self.roomController.tokenService;
    if (!ts) return;
    __weak typeof(self) weakSelf = self;
    [ts inviteToTeamWithTeamId:teamId emails:emails completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.teamsPanel resetInviteButton];
        if (error || !success) {
            [strongSelf.teamsPanel setStatusText:@"Could not send invitations. Please try again."];
        } else {
            [strongSelf.teamsPanel setStatusText:@"Invitations sent!"];
        }
    }];
}

- (void)teamsPanel:(InterTeamsPanel *)panel
didRequestAcceptInvitationForTeamId:(NSString *)teamId {
    InterTokenService *ts = self.roomController.tokenService;
    if (!ts) return;
    __weak typeof(self) weakSelf = self;
    [ts acceptTeamInvitationWithTeamId:teamId completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.teamsPanel resetAcceptButton];
        if (error || !success) {
            [strongSelf.teamsPanel setStatusText:@"Could not accept invitation. Please try again."];
        } else {
            [strongSelf.teamsPanel setStatusText:@"Joined team!"];
            [strongSelf reloadTeamsData];
        }
    }];
}

- (void)teamsPanel:(InterTeamsPanel *)panel
didRequestRemoveMemberId:(NSString *)memberId
         fromTeamId:(NSString *)teamId {
    InterTokenService *ts = self.roomController.tokenService;
    if (!ts) return;
    __weak typeof(self) weakSelf = self;
    [ts removeTeamMemberWithTeamId:teamId memberId:memberId completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (error || !success) {
            [strongSelf.teamsPanel setStatusText:@"Could not remove member. Please try again."];
        } else {
            [strongSelf.teamsPanel setStatusText:@"Member removed."];
            [strongSelf teamsPanelDidRequestRefresh:panel];
        }
    }];
}

- (void)teamsPanel:(InterTeamsPanel *)panel
didRequestDeleteTeamId:(NSString *)teamId {
    InterTokenService *ts = self.roomController.tokenService;
    if (!ts) return;
    __weak typeof(self) weakSelf = self;
    [ts deleteTeamWithTeamId:teamId completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.teamsPanel resetDeleteButton];
        if (error || !success) {
            [strongSelf.teamsPanel setStatusText:@"Could not delete team. Please try again."];
        } else {
            [strongSelf.teamsPanel setStatusText:@"Team deleted."];
            [strongSelf reloadTeamsData];
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
    [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 500)
                                styleMask:(NSWindowStyleMaskTitled |
                                           NSWindowStyleMaskClosable)
                                  backing:NSBackingStoreBuffered
                                    defer:NO];
    [self.loginWindow center];
    [self.loginWindow setTitle:@"Inter — Sign In"];
    [self.loginWindow setBackgroundColor:[NSColor colorWithWhite:0.1 alpha:1.0]];
    [self.loginWindow setDelegate:self];
    [self.loginWindow setMinSize:NSMakeSize(420.0, 500.0)];

    NSView *contentView = self.loginWindow.contentView;
    contentView.wantsLayer = YES;
    contentView.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:1.0].CGColor;

    CGFloat panelW = 380.0;
    CGFloat panelH = 460.0;
    CGFloat panelX = (contentView.bounds.size.width - panelW) / 2.0;
    CGFloat panelY = (contentView.bounds.size.height - panelH) / 2.0;

    self.loginPanel = [[InterLoginPanel alloc] initWithFrame:NSMakeRect(panelX, panelY, panelW, panelH)];
    self.loginPanel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
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
    [self connectAndEnterMode:InterCallModeNormal role:InterInterviewRoleNone panel:panel];
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
    [self connectAndEnterMode:InterCallModeInterview role:InterInterviewRoleInterviewer panel:panel];
}

- (void)setupPanelDidRequestJoin:(InterConnectionSetupPanel *)panel {
    NSString *code = panel.roomCode;
    if (code.length == 0) {
        [panel setStatusText:@"Enter a room code to join."];
        return;
    }

    [self joinRoomWithCode:code panel:panel];
}

/// [3.1.2] Host flow: create room → get code → display it → connect → enter mode.
- (void)connectAndEnterMode:(InterCallMode)mode
                       role:(InterInterviewRole)role
                      panel:(InterConnectionSetupPanel *)panel {
    NSString *serverURL    = panel.serverURL;
    NSString *tokenURL     = panel.tokenServerURL;
    NSString *displayName  = panel.displayName;

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

/// [3.1.3] Join flow: validate code → connect → enter as guest (normal call).
- (void)joinRoomWithCode:(NSString *)code panel:(InterConnectionSetupPanel *)panel {
    NSString *serverURL    = panel.serverURL;
    NSString *tokenURL     = panel.tokenServerURL;
    NSString *displayName  = panel.displayName;

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
            [panel setStatusText:@"Joined"];
            [panel setActionsEnabled:YES];

            // Determine mode from the server-reported room type
            NSString *roomType = rc.roomType;
            BOOL isInterviewRoom = [roomType isEqualToString:@"interview"];

            if (isInterviewRoom) {
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
            } else {
                // Normal call
                [strongSelf enterMode:InterCallModeNormal role:InterInterviewRoleNone];
            }
        });
    }];
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
    [self.normalCallWindow setSharingType:NSWindowSharingNone];
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

    self.normalRenderView = [[MetalSurfaceView alloc] initWithFrame:view.bounds];
    self.normalRenderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.normalRenderView];

    // [3.2.1] Remote video layout (camera + screen share views + participant overlay)
    self.normalRemoteLayout = [[InterRemoteVideoLayoutManager alloc] initWithFrame:view.bounds];
    self.normalRemoteLayout.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.normalRemoteLayout];

    [self attachNormalCallControlsInView:view];

    // [B1] Wire shared media wiring controller — properties that exist now
    self.normalMediaWiring.controlPanel = self.normalControlPanel;
    self.normalMediaWiring.remoteLayout = self.normalRemoteLayout;
    self.normalMediaWiring.networkStatusView = self.normalNetworkStatusView;
    self.normalMediaWiring.renderView = self.normalRenderView;
    __weak typeof(self) weakMediaSummarySelf = self;
    self.normalMediaWiring.mediaStateSummaryBlock = ^NSString *{
        return [weakMediaSummarySelf normalMediaStateSummary];
    };

    [self wireNormalRemoteRendering];
    [self startNormalLocalMediaFlow];

    // [B1] Wire media + surface share AFTER startNormalLocalMediaFlow creates them
    self.normalMediaWiring.mediaController = self.normalMediaController;
    self.normalMediaWiring.surfaceShareController = self.normalSurfaceShareController;

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

    // [Phase 8] Speaker queue panel (positioned above the bottom control bar)
    CGFloat queueX = view.bounds.size.width - 300.0 - 260.0 - 12.0;
    self.normalSpeakerQueuePanel = [[InterSpeakerQueuePanel alloc] initWithFrame:NSMakeRect(queueX, 90.0, 260.0, 300.0)];
    self.normalSpeakerQueuePanel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.normalSpeakerQueuePanel.delegate = self;
    [view addSubview:self.normalSpeakerQueuePanel];

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
        [self.normalPollWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];

        self.normalPollPanel = [[InterPollPanel alloc] initWithFrame:NSMakeRect(0, 0, pollW, pollH)];
        self.normalPollPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.normalPollPanel.delegate = self;
        self.normalPollPanel.isHost = self.roomController.isHost;
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
        [self.normalQAWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];

        self.normalQAPanel = [[InterQAPanel alloc] initWithFrame:NSMakeRect(0, 0, qaW, qaH)];
        self.normalQAPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.normalQAPanel.delegate = self;
        self.normalQAPanel.isHost = self.roomController.isHost;
        self.normalQAWindow.contentView = self.normalQAPanel;
    }

    // [Phase 8.6] Wire Q&A controller delegate
    self.qaController.delegate = (id<InterQAControllerDelegate>)self;

    [self.normalCallWindow makeKeyAndOrderFront:nil];
}

- (void)attachNormalCallControlsInView:(NSView *)view {
    NSTextField *label = [NSTextField labelWithString:@"Metal surface shell for secure video call UI composition."];
    label.frame = NSMakeRect(70, 560, 480, 24);
    label.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    label.font = [NSFont systemFontOfSize:15];
    label.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    [view addSubview:label];

    NSButton *exitButton = [[NSButton alloc] initWithFrame:NSMakeRect(40, 40, 160, 42)];
    exitButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [exitButton setTitle:@"End Call"];
    [exitButton setTarget:self];
    [exitButton setAction:@selector(requestExitCurrentMode)];
    [view addSubview:exitButton];

    NSRect panelFrame = NSMakeRect(view.bounds.size.width - 300.0,
                                   22.0,
                                   278.0,
                                   470.0);
    self.normalControlPanel = [[InterLocalCallControlPanel alloc] initWithFrame:panelFrame];
    self.normalControlPanel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self.normalControlPanel setPanelTitleText:@"Normal Call Controls"];
    [self.normalControlPanel setShareModeSelectorHidden:NO];
    [self.normalControlPanel setShareMode:InterShareModeThisApp];
    [self.normalControlPanel setShareSystemAudioEnabled:NO];
    [self.normalControlPanel setShareSystemAudioToggleHidden:YES];
    [self.normalControlPanel setShareModeOptionEnabled:YES forMode:InterShareModeWindow];
    [self.normalControlPanel setShareModeOptionEnabled:YES forMode:InterShareModeEntireScreen];
    [view addSubview:self.normalControlPanel];

    __weak typeof(self) weakSelf = self;
    self.normalControlPanel.cameraToggleHandler = ^{
        // [2.5.6] [G2] Two-phase camera toggle via shared wiring controller
        [weakSelf.normalMediaWiring twoPhaseToggleCamera];
    };
    self.normalControlPanel.microphoneToggleHandler = ^{
        // If host-muted and NOT currently allowed to speak, raise hand
        if (weakSelf.normalMediaWiring.isHostMuted && !weakSelf.normalMediaWiring.isAllowedToSpeak) {
            [weakSelf toggleNormalHandRaise];
            // Update mic button based on hand state
            NSString *localId = weakSelf.roomController.localParticipantIdentity;
            if (localId.length > 0 && [weakSelf.speakerQueue isHandRaisedFor:localId]) {
                [weakSelf.normalControlPanel setMicrophoneButtonTitle:@"⏳ Waiting..."];
            } else {
                [weakSelf.normalControlPanel setMicrophoneButtonTitle:@"✋ Raise Hand to Speak"];
            }
            return;
        }

        // Capture pre-toggle state: if mic is currently ON and host-muted,
        // the participant is about to turn it OFF — revoke after toggle.
        BOOL willRevokeAllow = weakSelf.normalMediaWiring.isHostMuted
                            && weakSelf.normalMediaWiring.isAllowedToSpeak
                            && !weakSelf.normalMediaWiring.isMicNetworkMuted;

        // [2.5.6] [G2] Two-phase microphone toggle via shared wiring controller
        [weakSelf.normalMediaWiring twoPhaseToggleMicrophone];

        // Revoke one-time allow after turning mic off (async mute hasn't
        // completed yet so we use the pre-toggle snapshot above).
        if (willRevokeAllow) {
            [weakSelf.normalMediaWiring revokeAllowToSpeak];
        }
    };
    self.normalControlPanel.shareToggleHandler = ^{
        [weakSelf toggleNormalSurfaceShare];
    };
    self.normalControlPanel.shareModeChangedHandler = ^(InterShareMode shareMode) {
        [weakSelf handleNormalShareModeChanged:shareMode];
    };
    self.normalControlPanel.audioInputSelectionChangedHandler = ^(NSString * _Nullable deviceID) {
        [weakSelf handleNormalAudioInputSelection:deviceID];
    };
    self.normalControlPanel.shareSystemAudioChangedHandler = ^(BOOL enabled) {
        [weakSelf handleNormalShareSystemAudioChanged:enabled];
    };

    // [Phase 10] Record toggle — visible to host/co-host only
    [self.normalControlPanel setRecordingButtonHidden:!self.roomController.isHost];
    self.normalControlPanel.recordToggleHandler = ^{
        [weakSelf handleRecordToggle];
    };

    // [Phase 10 R2] View Recordings — visible to authenticated users
    BOOL canViewRecordings = self.roomController.tokenService.isAuthenticated;
    [self.normalControlPanel setViewRecordingsButtonHidden:!canViewRecordings];
    self.normalControlPanel.viewRecordingsHandler = ^{
        [weakSelf toggleNormalRecordingListPanel];
    };

    // [3.4.4] Network quality signal bars in the control panel
    self.normalNetworkStatusView = [[InterNetworkStatusView alloc] initWithFrame:NSMakeRect(0, 0, 40, 16)];
    [self.normalControlPanel.networkStatusContainerView addSubview:self.normalNetworkStatusView];

    // [3.4.5] [G9] Triple-click diagnostic: copy snapshot to clipboard via wiring controller
    NSClickGestureRecognizer *tripleClick = [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                                                      action:@selector(forwardDiagnosticTripleClick:)];
    tripleClick.numberOfClicksRequired = 3;
    [self.normalControlPanel.networkStatusContainerView addGestureRecognizer:tripleClick];

    // [Phase 8] Chat, hand-raise, and queue toggle buttons — bottom bar next to End Call
    self.normalChatToggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(220, 40, 80, 42)];
    self.normalChatToggleButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.normalChatToggleButton setTitle:@"💬 Chat"];
    [self.normalChatToggleButton setTarget:self];
    [self.normalChatToggleButton setAction:@selector(toggleNormalChatPanel)];
    [self.normalChatToggleButton setKeyEquivalent:@"c"];
    [self.normalChatToggleButton setKeyEquivalentModifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    [view addSubview:self.normalChatToggleButton];

    self.normalHandRaiseButton = [[NSButton alloc] initWithFrame:NSMakeRect(310, 40, 100, 42)];
    self.normalHandRaiseButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.normalHandRaiseButton setTitle:@"✋ Raise"];
    [self.normalHandRaiseButton setTarget:self];
    [self.normalHandRaiseButton setAction:@selector(toggleNormalHandRaise)];
    [view addSubview:self.normalHandRaiseButton];

    // Only show the speaker queue button to the host / co-host
    if (self.roomController.isHost) {
        self.normalQueueToggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(420, 40, 90, 42)];
        self.normalQueueToggleButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
        [self.normalQueueToggleButton setTitle:@"📋 Queue"];
        [self.normalQueueToggleButton setTarget:self];
        [self.normalQueueToggleButton setAction:@selector(toggleNormalSpeakerQueue)];
        [view addSubview:self.normalQueueToggleButton];
    }

    // [Phase 8.5] Poll toggle button
    CGFloat pollX = self.roomController.isHost ? 520.0 : 420.0;
    self.normalPollToggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(pollX, 40, 80, 42)];
    self.normalPollToggleButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.normalPollToggleButton setTitle:@"📊 Poll"];
    [self.normalPollToggleButton setTarget:self];
    [self.normalPollToggleButton setAction:@selector(toggleNormalPollPanel)];
    [view addSubview:self.normalPollToggleButton];

    // [Phase 8.6] Q&A toggle button
    CGFloat qaX = pollX + 90.0;
    self.normalQAToggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(qaX, 40, 80, 42)];
    self.normalQAToggleButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.normalQAToggleButton setTitle:@"❓ Q&A"];
    [self.normalQAToggleButton setTarget:self];
    [self.normalQAToggleButton setAction:@selector(toggleNormalQAPanel)];
    [view addSubview:self.normalQAToggleButton];

    // [Phase 9] Lobby & moderation buttons (host/co-host only)
    if (self.roomController.isHost) {
        CGFloat modX = qaX + 90.0;
        self.normalLobbyToggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(modX, 40, 90, 42)];
        self.normalLobbyToggleButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
        [self.normalLobbyToggleButton setTitle:@"🚪 Lobby"];
        [self.normalLobbyToggleButton setTarget:self];
        [self.normalLobbyToggleButton setAction:@selector(toggleNormalLobbyPanel)];
        [view addSubview:self.normalLobbyToggleButton];

        self.normalModerationButton = [[NSButton alloc] initWithFrame:NSMakeRect(modX + 100, 40, 120, 42)];
        self.normalModerationButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
        [self.normalModerationButton setTitle:@"⚙️ Moderate"];
        [self.normalModerationButton setTarget:self];
        [self.normalModerationButton setAction:@selector(showModerationMenu:)];
        [view addSubview:self.normalModerationButton];
    }
}

- (void)startNormalLocalMediaFlow {
    self.normalShareSystemAudioEnabled = NO;
    self.normalMediaController = [[InterLocalMediaController alloc] init];
    self.normalSurfaceShareController = [[InterSurfaceShareController alloc] init];
    [self.normalSurfaceShareController configureWithSessionKind:InterShareSessionKindNormal
                                                      shareMode:self.normalControlPanel.selectedShareMode];
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

    [self.normalMediaController attachPreviewToView:self.normalControlPanel.previewContainerView];
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

        // [2.5.4] Wire network publishing if room is connected
        [weakSelf.normalMediaWiring wireNetworkPublish];
    }];
}

- (void)handleNormalShareModeChanged:(InterShareMode)shareMode {
    if (self.normalSurfaceShareController.isSharing) {
        [self.normalControlPanel setShareMode:self.normalSurfaceShareController.configuration.shareMode];
        [self.normalControlPanel setShareStatusText:@"Stop sharing before changing source mode."];
        return;
    }

    BOOL supportsSystemAudio = shareMode != InterShareModeThisApp;
    [self.normalControlPanel setShareSystemAudioToggleHidden:!supportsSystemAudio];
    if (!supportsSystemAudio) {
        self.normalShareSystemAudioEnabled = NO;
        [self.normalControlPanel setShareSystemAudioEnabled:NO];
    }

    [self.normalSurfaceShareController configureWithSessionKind:InterShareSessionKindNormal
                                                      shareMode:shareMode];
    [self.normalSurfaceShareController setShareSystemAudioEnabled:self.normalShareSystemAudioEnabled];

    if (shareMode == InterShareModeThisApp) {
        [self.normalControlPanel setShareStatusText:@"Share This App is ready."];
        return;
    }

    if (shareMode == InterShareModeWindow) {
        NSString *status = self.normalShareSystemAudioEnabled ? @"Share Window + system audio is ready." : @"Share Window is ready.";
        [self.normalControlPanel setShareStatusText:status];
        return;
    }

    NSString *status = self.normalShareSystemAudioEnabled ? @"Share Entire Screen + system audio is ready." : @"Share Entire Screen is ready.";
    [self.normalControlPanel setShareStatusText:status];
}

- (void)handleNormalShareSystemAudioChanged:(BOOL)enabled {
    self.normalShareSystemAudioEnabled = enabled;
    [self.normalSurfaceShareController setShareSystemAudioEnabled:enabled];

    if (self.normalControlPanel.selectedShareMode == InterShareModeWindow) {
        NSString *status = enabled ? @"Share Window + system audio is ready." : @"Share Window is ready.";
        [self.normalControlPanel setShareStatusText:status];
    } else if (self.normalControlPanel.selectedShareMode == InterShareModeEntireScreen) {
        NSString *status = enabled ? @"Share Entire Screen + system audio is ready." : @"Share Entire Screen is ready.";
        [self.normalControlPanel setShareStatusText:status];
    }
}

- (NSString *)normalMediaStateSummary {
    BOOL cameraOn = self.normalMediaController.isCameraEnabled;
    // When connected the mic toggle only mutes the LiveKit track and
    // does NOT touch InterLocalMediaController, so isMicrophoneEnabled
    // stays YES. Use the wiring controller's network mute flag instead.
    BOOL microphoneOn = self.normalMediaController.isMicrophoneEnabled
                        && !self.normalMediaWiring.isMicNetworkMuted;
    return [NSString stringWithFormat:@"Camera %@, Mic %@.",
            cameraOn ? @"on" : @"off",
            microphoneOn ? @"on" : @"off"];
}

- (void)refreshNormalAudioInputOptions {
    if (!self.normalMediaController || !self.normalControlPanel) {
        return;
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *options = [self.normalMediaController availableAudioInputOptions];
    NSString *selectedDeviceID = [self.normalMediaController selectedAudioInputDeviceID];
    [self.normalControlPanel setAudioInputOptions:options selectedDeviceID:selectedDeviceID];
}

- (void)handleNormalAudioInputSelection:(NSString * _Nullable)deviceID {
    if (!self.normalMediaController) {
        return;
    }

    // When connected, modifying the AVCaptureSession's audio input calls
    // beginConfiguration / commitConfiguration which momentarily interrupts
    // ALL session outputs — including the camera video preview. LiveKit
    // captures the mic natively (not through the session) so changing the
    // session's audio input has no effect on what remote participants hear.
    // Store the preference and skip the disruptive reconfiguration.
    InterRoomController *rc = self.roomController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
    if (isConnected) {
        // Remember the selection so it's applied on next session setup /
        // reconnect, and refresh the UI to reflect the stored choice.
        [self.normalMediaController storePreferredAudioDeviceID:deviceID];
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
    if (!self.normalRenderView) {
        return;
    }

    // Sync button state — an async error may have reset sharing behind our back
    BOOL currentlySharing = self.normalSurfaceShareController.isSharing;
    BOOL startPending = self.normalSurfaceShareController.isStartPending;
    [self.normalControlPanel setShareStartPending:startPending];
    [self.normalControlPanel setSharingEnabled:currentlySharing];

    if (currentlySharing || startPending) {
        // Unpublish screen share track from LiveKit before stopping
        [self.roomController.publisher unpublishScreenShareWithCompletion:nil];
        [self.normalSurfaceShareController stopSharingFromSurfaceView:self.normalRenderView];
        // Clear network sink on stop
        self.normalSurfaceShareController.networkPublishSink = nil;
        [self.normalControlPanel setShareStartPending:self.normalSurfaceShareController.isStartPending];
        [self.normalControlPanel setSharingEnabled:self.normalSurfaceShareController.isSharing];

        // [Phase 10] Notify recording coordinator that screen share stopped.
        [self.normalRecordingCoordinator screenShareDidChangeWithIsActive:NO];
        return;
    }

    InterShareMode selectedMode = self.normalControlPanel.selectedShareMode;

    BOOL requiresScreenRecordingPermission = (selectedMode == InterShareModeWindow ||
                                              selectedMode == InterShareModeEntireScreen);
    if (requiresScreenRecordingPermission && ![InterScreenCaptureVideoSource preflightScreenCaptureAccess]) {
        (void)[InterScreenCaptureVideoSource requestScreenCaptureAccessIfNeeded];
        [self.normalControlPanel setShareStatusText:@"Screen recording permission is required. Enable it in System Settings, then click Start Surface Share again."];
        [self.normalControlPanel setShareStartPending:NO];
        [self.normalControlPanel setSharingEnabled:NO];
        return;
    }

    // For Window mode, show the picker first so the user can choose which window
    if (selectedMode == InterShareModeWindow) {
        NSWindow *parent = self.normalCallWindow;
        if (!parent) { return; }

        __weak typeof(self) weakSelf = self;
        [InterWindowPickerPanel showPickerRelativeToWindow:parent completion:^(NSString * _Nullable selectedWindowIdentifier) {
            if (!selectedWindowIdentifier) {
                // User cancelled — do nothing
                return;
            }

            [weakSelf startNormalWindowShareWithIdentifier:selectedWindowIdentifier];
        }];
        return;
    }

    [self startNormalShareWithMode:selectedMode windowIdentifier:nil];
}

/// Start window share after the user picked a specific window.
- (void)startNormalWindowShareWithIdentifier:(NSString *)windowIdentifier {
    [self startNormalShareWithMode:InterShareModeWindow windowIdentifier:windowIdentifier];
}

/// Common path for starting a normal surface share, optionally with a pre-selected
/// window identifier (for Window mode).
- (void)startNormalShareWithMode:(InterShareMode)shareMode
                windowIdentifier:(NSString * _Nullable)windowIdentifier {
    [self.normalSurfaceShareController configureWithSessionKind:InterShareSessionKindNormal
                                                      shareMode:shareMode];
    [self.normalSurfaceShareController setShareSystemAudioEnabled:self.normalShareSystemAudioEnabled];

    if (windowIdentifier.length > 0) {
        self.normalSurfaceShareController.configuration.selectedWindowIdentifier = windowIdentifier;
    }

    // [2.5.5] Wire network sink before starting share
    [self.normalMediaWiring wireNetworkSinkOnSurfaceShareController:self.normalSurfaceShareController];

    [self.normalSurfaceShareController startSharingFromSurfaceView:self.normalRenderView];
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
        [self.normalHandRaiseButton setTitle:@"✋ Raise"];
    } else {
        [self.chatController raiseHand];
        NSString *displayName = self.roomController.localParticipantName;
        [self.speakerQueue addHandWithIdentity:localIdentity displayName:displayName];
        [self.normalHandRaiseButton setTitle:@"🖐 Lower"];
    }
    [self.normalSpeakerQueuePanel setEntries:self.speakerQueue.entries];
}

- (void)toggleNormalSpeakerQueue {
    [self.normalSpeakerQueuePanel togglePanel];
}

// MARK: InterChatControllerDelegate

- (void)chatController:(InterChatController *)controller
      didReceiveMessage:(InterChatMessageInfo *)message {
    [self.normalChatPanel appendMessage:message];
    if (!self.normalChatPanel.isExpanded) {
        [self.normalChatPanel setUnreadBadge:controller.unreadCount];
    }
}

- (void)chatController:(InterChatController *)controller
   didUpdateUnreadCount:(NSInteger)count {
    if (!self.normalChatPanel.isExpanded) {
        [self.normalChatPanel setUnreadBadge:count];
    }
}

// MARK: InterControlSignalDelegate

- (void)chatController:(InterChatController *)controller
  participantDidRaiseHand:(NSString *)identity
            displayName:(NSString *)displayName {
    [self.speakerQueue addHandWithIdentity:identity displayName:displayName];
    [self.normalSpeakerQueuePanel setEntries:self.speakerQueue.entries];
    [self.normalRemoteLayout setHandRaised:YES forParticipant:identity];
}

- (void)chatController:(InterChatController *)controller
  participantDidLowerHand:(NSString *)identity {
    [self.speakerQueue removeHandFor:identity];
    [self.normalSpeakerQueuePanel setEntries:self.speakerQueue.entries];
    [self.normalRemoteLayout setHandRaised:NO forParticipant:identity];

    // If the dismissed identity is our own (host lowered our hand), reset the local button
    NSString *localIdentity = self.roomController.localParticipantIdentity;
    if ([identity isEqualToString:localIdentity]) {
        [self.normalHandRaiseButton setTitle:@"✋ Raise"];
        // If still host-muted AND not allowed to speak, reset mic button.
        // Skip if isAllowedToSpeak is YES — the host just allowed us and
        // the lowerHand signal is a companion cleanup, not a deny.
        if (self.normalMediaWiring.isHostMuted && !self.normalMediaWiring.isAllowedToSpeak) {
            [self.normalControlPanel setMicrophoneButtonTitle:@"✋ Raise Hand to Speak"];
        }
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

// MARK: InterSpeakerQueuePanelDelegate

- (void)speakerQueuePanel:(InterSpeakerQueuePanel *)panel didDismissParticipant:(NSString *)identity {
#pragma unused(panel)
    // Lower the hand via network so participant gets notified
    [self.chatController lowerHandForParticipant:identity];
    [self.speakerQueue removeHandFor:identity];
    [self.normalSpeakerQueuePanel setEntries:self.speakerQueue.entries];
    [self.normalRemoteLayout setHandRaised:NO forParticipant:identity];
}

- (void)speakerQueuePanel:(InterSpeakerQueuePanel *)panel didAllowParticipant:(NSString *)identity {
#pragma unused(panel)
    // Send allowToSpeak signal so the participant can unmute
    [self.moderationController allowToSpeakWithIdentity:identity];

    // Lower the hand via network + remove from queue
    [self.chatController lowerHandForParticipant:identity];
    [self.speakerQueue removeHandFor:identity];
    [self.normalSpeakerQueuePanel setEntries:self.speakerQueue.entries];
    [self.normalRemoteLayout setHandRaised:NO forParticipant:identity];
}

- (void)speakerQueuePanelDidDismissAll:(InterSpeakerQueuePanel *)panel {
#pragma unused(panel)
    // Dismiss each raised hand via the network so participants get notified
    NSArray<InterRaisedHandEntry *> *entries = [self.speakerQueue.entries copy];
    for (InterRaisedHandEntry *entry in entries) {
        [self.chatController lowerHandForParticipant:entry.participantIdentity];
        [self.normalRemoteLayout setHandRaised:NO forParticipant:entry.participantIdentity];
    }
    [self.speakerQueue reset];
    [self.normalSpeakerQueuePanel setEntries:self.speakerQueue.entries];
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
    }
}

// MARK: InterMediaWiringDelegate (Phase 8 — participant list sync)

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
    NSArray<NSDictionary<NSString *, NSString *> *> *participants = [self.roomController remoteParticipantList];
    [self.normalChatPanel setParticipantList:participants];
}

// MARK: - Phase 9 — Lobby Panel

- (void)toggleNormalLobbyPanel {
    if (!self.normalLobbyWindow) {
        // Create lobby panel next to the control bar
        CGFloat panelWidth = 280;
        CGFloat panelHeight = 320;
        NSRect windowFrame = self.normalCallWindow.frame;
        CGFloat x = NSMaxX(windowFrame) - panelWidth - 12;
        CGFloat y = windowFrame.origin.y + 100;
        self.normalLobbyPanel = [[InterLobbyPanel alloc] initWithFrame:NSMakeRect(0, 0, panelWidth, panelHeight)];
        self.normalLobbyPanel.delegate = self;

        self.normalLobbyWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(x, y, panelWidth, panelHeight)
                                                             styleMask:(NSWindowStyleMaskTitled |
                                                                        NSWindowStyleMaskClosable |
                                                                        NSWindowStyleMaskResizable)
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO];
        self.normalLobbyWindow.title = @"Waiting Room";
        self.normalLobbyWindow.minSize = NSMakeSize(220, 200);
        self.normalLobbyWindow.releasedWhenClosed = NO;
        self.normalLobbyWindow.level = NSFloatingWindowLevel;
        [self.normalLobbyWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
        self.normalLobbyWindow.contentView = self.normalLobbyPanel;

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

// MARK: - Phase 9 — Moderation Menu

- (void)showModerationMenu:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Moderation"];

    // Mute All / Unmute All
    if (self.moderationController.isAllMuted) {
        [menu addItemWithTitle:@"🔊 Unmute All" action:@selector(moderationUnmuteAll) keyEquivalent:@""];
    } else {
        [menu addItemWithTitle:@"🔇 Mute All" action:@selector(moderationMuteAll) keyEquivalent:@""];
    }

    // Disable/Enable Chat
    if (self.moderationController.isChatDisabled) {
        [menu addItemWithTitle:@"💬 Enable Chat" action:@selector(moderationEnableChat) keyEquivalent:@""];
    } else {
        [menu addItemWithTitle:@"🚫 Disable Chat" action:@selector(moderationDisableChat) keyEquivalent:@""];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    // Lock/Unlock Meeting
    if (self.moderationController.isMeetingLocked) {
        [menu addItemWithTitle:@"🔓 Unlock Meeting" action:@selector(moderationUnlockMeeting) keyEquivalent:@""];
    } else {
        [menu addItemWithTitle:@"🔒 Lock Meeting" action:@selector(moderationLockMeeting) keyEquivalent:@""];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    // Password
    [menu addItemWithTitle:@"🔑 Set Password…" action:@selector(moderationSetPassword) keyEquivalent:@""];
    [menu addItemWithTitle:@"🔑 Remove Password" action:@selector(moderationRemovePassword) keyEquivalent:@""];

    [NSMenu popUpContextMenu:menu withEvent:[NSApp currentEvent] forView:sender];
}

- (void)moderationMuteAll {
    [self.moderationController muteAllWithCompletion:^(BOOL success, NSInteger count, NSError *error) {
        if (success) {
            NSLog(@"[Phase 9] Muted %ld participants", (long)count);
            // Show "Allow" buttons in the speaker queue for raised hands
            self.normalSpeakerQueuePanel.showAllowActions = YES;
        } else {
            NSLog(@"[Phase 9] Mute all failed: %@", error.localizedDescription);
        }
    }];
}

- (void)moderationUnmuteAll {
    [self.moderationController unmuteAllWithCompletion:^(BOOL success, NSInteger count, NSError *error) {
        if (success) {
            NSLog(@"[Phase 9] Broadcast unmute-all request to participants");
            // Hide "Allow" buttons — everyone can unmute freely now
            self.normalSpeakerQueuePanel.showAllowActions = NO;
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
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Set Meeting Password";
    alert.informativeText = @"Enter a password for this meeting:";
    [alert addButtonWithTitle:@"Set"];
    [alert addButtonWithTitle:@"Cancel"];

    NSSecureTextField *passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    passwordField.placeholderString = @"Password";
    alert.accessoryView = passwordField;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *password = passwordField.stringValue;
        if (password.length > 0) {
            [self.moderationController setPassword:password completion:^(BOOL success, NSError *error) {
                if (!success) {
                    NSLog(@"[Phase 9] Set password failed: %@", error.localizedDescription);
                }
            }];
        }
    }
}

- (void)moderationRemovePassword {
    [self.moderationController removePasswordWithCompletion:^(BOOL success, NSError *error) {
        if (!success) {
            NSLog(@"[Phase 9] Remove password failed: %@", error.localizedDescription);
        }
    }];
}

// MARK: InterModerationDelegate

- (void)moderationController:(InterModerationController *)controller chatDisabledStateChanged:(BOOL)isDisabled {
#pragma unused(controller)
    if (self.normalChatPanel) {
        [self.normalChatPanel setChatInputEnabled:!isDisabled];
        if (isDisabled) {
            [self.normalChatPanel displaySystemMessage:@"Chat has been disabled by the host."];
        } else {
            [self.normalChatPanel displaySystemMessage:@"Chat has been re-enabled."];
        }
    }
}

- (void)moderationController:(InterModerationController *)controller receivedUnmuteRequest:(NSString *)fromIdentity displayName:(NSString *)displayName {
#pragma unused(controller)
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

- (void)moderationControllerReceivedUnmuteAllRequest:(InterModerationController *)controller {
#pragma unused(controller)
    NSLog(@"[Phase 9] Host unmuted all — restoring mic toggle ability");
    [self.normalMediaWiring applyUnmuteAll];
}

- (void)moderationControllerReceivedMuteAllRequest:(InterModerationController *)controller {
#pragma unused(controller)
    NSLog(@"[Phase 9] Host muted all — updating local mic state");
    [self.normalMediaWiring applyRemoteMicMute];
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
        [self.normalSpeakerQueuePanel setEntries:self.speakerQueue.entries];
    }
    [self.normalHandRaiseButton setTitle:@"✋ Raise"];
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

- (void)moderationController:(InterModerationController *)controller forceSpotlightOnParticipant:(NSString *)identity {
#pragma unused(controller)
    if (self.normalRemoteLayout) {
        [self.normalRemoteLayout setManualSpotlightTileKey:identity animated:YES];
    }
}

- (void)moderationControllerDidClearForceSpotlight:(InterModerationController *)controller {
#pragma unused(controller)
    if (self.normalRemoteLayout) {
        [self.normalRemoteLayout setManualSpotlightTileKey:nil animated:YES];
    }
}

- (void)moderationControllerLocalParticipantWasRemoved:(InterModerationController *)controller {
#pragma unused(controller)
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Removed";
    alert.informativeText = @"You have been removed from the meeting by the host.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [self requestExitCurrentMode];
}

- (void)moderationController:(InterModerationController *)controller participantRoleChanged:(NSString *)identity newRole:(NSString *)newRole {
#pragma unused(controller)
    NSLog(@"[Phase 9] Role changed: %@ → %@", identity, newRole);
    // Could update overlay badges, tile labels, etc. here in the future
}

- (void)moderationController:(InterModerationController *)controller lobbyParticipantJoined:(NSString *)identity displayName:(NSString *)displayName {
#pragma unused(controller)
    if (self.normalLobbyPanel) {
        [self.normalLobbyPanel addWaitingParticipant:identity displayName:displayName];
    }
}

#pragma mark - Recording (Phase 10)

- (void)handleRecordToggle {
    InterRecordingCoordinator *coordinator = self.normalRecordingCoordinator;
    if (!coordinator) return;
    InterRecordingState state = coordinator.state;
    if (state == InterRecordingStateIdle || state == InterRecordingStateFinalized) {
        if (!self.normalMediaController || !self.normalSurfaceShareController) return;
        NSString *tier = self.roomController.tokenService.effectiveTier ?: @"free";
        [coordinator startLocalRecordingWithScreenShareSource:self.normalSurfaceShareController
                                                   subscriber:self.roomController.subscriber
                                          localMediaController:self.normalMediaController
                                                     userTier:tier];
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
        [self.normalRecordingListWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
        self.normalRecordingListWindow.contentView = self.normalRecordingListPanel;

        [self.normalRecordingListPanel reloadRecordings];
        [self.normalRecordingListWindow makeKeyAndOrderFront:nil];
        return;
    }

    if (self.normalRecordingListWindow.isVisible) {
        [self.normalRecordingListWindow orderOut:nil];
    } else {
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
    }] resume];
}

// ---------------------------------------------------------------------------
#pragma mark - Recording Consent Panel (Phase 10 R3)
// ---------------------------------------------------------------------------

/// Show the consent overlay for a remote-initiated recording.
- (void)showRecordingConsentOverlayForRemoteRecording {
    if (self.normalRecordingConsentPanel) return; // already showing

    NSView *contentView = self.normalCallWindow.contentView;
    if (!contentView) return;

    self.normalRecordingConsentPanel = [[InterRecordingConsentPanel alloc]
        initWithFrame:contentView.bounds];
    self.normalRecordingConsentPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.normalRecordingConsentPanel.delegate = self;
    [contentView addSubview:self.normalRecordingConsentPanel];
    [self.normalRecordingConsentPanel showConsentForMode:@"local_composed"];
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
}

- (void)recordingConsentPanelDidDecline:(InterRecordingConsentPanel *)panel {
    [self dismissRecordingConsentOverlay];
    // Participant declined — leave the call
    [self.roomController disconnect];
    [self teardownActiveWindows];
    [self launchSetupUI];
}

#pragma mark - Diagnostics [3.4.5]

/// [B1] Trampoline: gesture recognizer target must be self; forward to wiring controller.
- (void)forwardDiagnosticTripleClick:(NSClickGestureRecognizer *)recognizer {
#pragma unused(recognizer)
    [self.normalMediaWiring handleDiagnosticTripleClick];
}

#pragma mark - Settings

- (void)openSettingsWindow {
    // Rebuild every time so calendar status is always fresh.
    if (self.settingsWindow) {
        [self.settingsWindow orderOut:nil];
        self.settingsWindow = nil;
        self.settingsGoogleButton = nil;
        self.settingsOutlookButton = nil;
        self.settingsGoogleStatusLabel = nil;
        self.settingsOutlookStatusLabel = nil;
    }

    self.settingsWindow =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 310)
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    [self.settingsWindow setTitle:@"Settings"];
    [self.settingsWindow setSharingType:NSWindowSharingNone];
    [self.settingsWindow setReleasedWhenClosed:NO];

    NSView *cv = self.settingsWindow.contentView;
    CGFloat w = 420.0;

    // ---- Section: Calendar Sync -------------------------------------------
    NSTextField *calHeader = [NSTextField labelWithString:@"Calendar Sync"];
    calHeader.frame = NSMakeRect(20, 250, 200, 20);
    calHeader.font  = [NSFont boldSystemFontOfSize:13];
    [cv addSubview:calHeader];

    // Google row
    NSTextField *googleLabel = [NSTextField labelWithString:@"Google Calendar"];
    googleLabel.frame = NSMakeRect(20, 218, 160, 18);
    googleLabel.font = [NSFont systemFontOfSize:12];
    [cv addSubview:googleLabel];

    self.settingsGoogleStatusLabel = [NSTextField labelWithString:@"Checking…"];
    self.settingsGoogleStatusLabel.frame = NSMakeRect(20, 200, 200, 14);
    self.settingsGoogleStatusLabel.font = [NSFont systemFontOfSize:11];
    self.settingsGoogleStatusLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:self.settingsGoogleStatusLabel];

    self.settingsGoogleButton = [[NSButton alloc] initWithFrame:NSMakeRect(w - 120, 212, 100, 28)];
    [self.settingsGoogleButton setTitle:@"Connect"];
    [self.settingsGoogleButton setBezelStyle:NSBezelStyleRounded];
    [self.settingsGoogleButton setTarget:self];
    [self.settingsGoogleButton setAction:@selector(handleGoogleCalendarButtonTapped:)];
    [cv addSubview:self.settingsGoogleButton];

    // Separator
    NSBox *calSep = [[NSBox alloc] initWithFrame:NSMakeRect(20, 194, w - 40, 1)];
    calSep.boxType = NSBoxSeparator;
    [cv addSubview:calSep];

    // Outlook row
    NSTextField *outlookLabel = [NSTextField labelWithString:@"Outlook Calendar"];
    outlookLabel.frame = NSMakeRect(20, 170, 160, 18);
    outlookLabel.font = [NSFont systemFontOfSize:12];
    [cv addSubview:outlookLabel];

    self.settingsOutlookStatusLabel = [NSTextField labelWithString:@"Checking…"];
    self.settingsOutlookStatusLabel.frame = NSMakeRect(20, 152, 200, 14);
    self.settingsOutlookStatusLabel.font = [NSFont systemFontOfSize:11];
    self.settingsOutlookStatusLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:self.settingsOutlookStatusLabel];

    self.settingsOutlookButton = [[NSButton alloc] initWithFrame:NSMakeRect(w - 120, 164, 100, 28)];
    [self.settingsOutlookButton setTitle:@"Connect"];
    [self.settingsOutlookButton setBezelStyle:NSBezelStyleRounded];
    [self.settingsOutlookButton setTarget:self];
    [self.settingsOutlookButton setAction:@selector(handleOutlookCalendarButtonTapped:)];
    [cv addSubview:self.settingsOutlookButton];

    // ---- Section separator ------------------------------------------------
    NSBox *teamsSep = [[NSBox alloc] initWithFrame:NSMakeRect(20, 142, w - 40, 1)];
    teamsSep.boxType = NSBoxSeparator;
    [cv addSubview:teamsSep];

    // ---- Section: Teams ---------------------------------------------------
    NSTextField *teamsHeader = [NSTextField labelWithString:@"Teams"];
    teamsHeader.frame = NSMakeRect(20, 114, 200, 20);
    teamsHeader.font  = [NSFont boldSystemFontOfSize:13];
    [cv addSubview:teamsHeader];

    NSButton *teamsButton = [[NSButton alloc] initWithFrame:NSMakeRect(w - 150, 108, 130, 28)];
    [teamsButton setTitle:@"Manage Teams…"];
    [teamsButton setBezelStyle:NSBezelStyleRounded];
    [teamsButton setTarget:self];
    [teamsButton setAction:@selector(openTeamsPanel:)];
    [cv addSubview:teamsButton];

    // ---- Close button -----------------------------------------------------
    NSBox *bottomSep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 56, w, 1)];
    bottomSep.boxType = NSBoxSeparator;
    [cv addSubview:bottomSep];

    NSButton *closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(w - 112, 16, 92, 34)];
    [closeButton setTitle:@"Close"];
    [closeButton setBezelStyle:NSBezelStyleRounded];
    [closeButton setTarget:self];
    [closeButton setAction:@selector(closeSettingsWindow)];
    [cv addSubview:closeButton];

    [self.settingsWindow center];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Fetch live calendar connection status
    [self refreshSettingsCalendarStatus];
}

- (void)refreshSettingsCalendarStatus {
    InterTokenService *ts = self.roomController.tokenService;
    if (!ts) return;
    __weak typeof(self) weakSelf = self;
    [ts fetchCalendarStatusWithCompletion:^(NSDictionary<NSString *, id> *status, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !status) return;
        NSDictionary *google  = status[@"google"]  ?: @{};
        NSDictionary *outlook = status[@"outlook"] ?: @{};
        BOOL gConnected = [google[@"connected"] boolValue];
        BOOL oConnected = [outlook[@"connected"] boolValue];
        BOOL gReauth    = [google[@"reauthRequired"]  boolValue];
        BOOL oReauth    = [outlook[@"reauthRequired"] boolValue];

        NSString *gStatus = gConnected ? (gReauth ? @"Connected (re-auth required)" : @"Connected") : @"Not connected";
        NSString *oStatus = oConnected ? (oReauth ? @"Connected (re-auth required)" : @"Connected") : @"Not connected";

        strongSelf.settingsGoogleStatusLabel.stringValue  = gStatus;
        strongSelf.settingsOutlookStatusLabel.stringValue = oStatus;
        [strongSelf.settingsGoogleButton  setTitle:gConnected ? @"Disconnect" : @"Connect"];
        [strongSelf.settingsOutlookButton setTitle:oConnected ? @"Disconnect" : @"Connect"];
    }];
}

- (void)handleGoogleCalendarButtonTapped:(id)sender {
#pragma unused(sender)
    [self handleCalendarButtonTappedForProvider:@"google" button:self.settingsGoogleButton];
}

- (void)handleOutlookCalendarButtonTapped:(id)sender {
#pragma unused(sender)
    [self handleCalendarButtonTappedForProvider:@"outlook" button:self.settingsOutlookButton];
}

- (void)handleCalendarButtonTappedForProvider:(NSString *)provider button:(NSButton *)button {
    InterTokenService *ts = self.roomController.tokenService;
    if (!ts) return;

    BOOL isDisconnect = [button.title isEqualToString:@"Disconnect"];
    button.enabled = NO;

    __weak typeof(self) weakSelf = self;

    if (isDisconnect) {
        [ts disconnectCalendarWithProvider:provider completion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            button.enabled = YES;
            if (success) {
                [strongSelf refreshSettingsCalendarStatus];
            } else {
                NSLog(@"[Calendar] Disconnect failed for %@: %@", provider, error.localizedDescription);
            }
        }];
    } else {
        [ts requestCalendarConnectURLWithProvider:provider completion:^(NSString *authUrl, NSError *error) {
            button.enabled = YES;
            if (authUrl.length > 0) {
                NSURL *url = [NSURL URLWithString:authUrl];
                if (url) [[NSWorkspace sharedWorkspace] openURL:url];
            } else {
                NSLog(@"[Calendar] Failed to get connect URL for %@: %@", provider, error.localizedDescription);
            }
        }];
    }
}

- (void)openTeamsPanel:(id)sender {
#pragma unused(sender)
    if (!self.teamsWindow) {
        self.teamsPanel = [[InterTeamsPanel alloc] initWithFrame:NSMakeRect(0, 0, 640, 460)];
        self.teamsPanel.delegate = self;

        self.teamsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 460)
                                                        styleMask:(NSWindowStyleMaskTitled |
                                                                   NSWindowStyleMaskClosable |
                                                                   NSWindowStyleMaskResizable)
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
        [self.teamsWindow setTitle:@"Teams"];
        [self.teamsWindow setSharingType:NSWindowSharingNone];
        [self.teamsWindow setReleasedWhenClosed:NO];
        [self.teamsWindow setContentView:self.teamsPanel];
        [self.teamsWindow setDelegate:self];
        self.teamsPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    [self.teamsWindow center];
    [self.teamsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    // Initial load
    [self reloadTeamsData];
}

- (void)reloadTeamsData {
    InterTokenService *ts = self.roomController.tokenService;
    if (!ts || !self.teamsPanel) return;
    [self.teamsPanel setLoading:YES];
    __weak typeof(self) weakSelf = self;
    [ts fetchTeamsWithCompletion:^(NSArray<NSDictionary<NSString *, id> *> *teams, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.teamsPanel setLoading:NO];
        if (error) {
            [strongSelf.teamsPanel setStatusText:@"Could not load teams. Please try again."];
            return;
        }
        [strongSelf.teamsPanel setTeams:teams ?: @[]];
        [strongSelf.teamsPanel setStatusText:@""];
    }];
}

- (void)closeSettingsWindow {
    [self.settingsWindow orderOut:nil];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender == self.setupWindow && self.currentCallMode == InterCallModeNone) {
        InterTeardownSetupWindow(&_setupWindow, &_setupRenderView, &_connectionPanel);
        [NSApp terminate:nil];
        return NO;
    }

    if (sender == self.normalCallWindow && self.currentCallMode != InterCallModeNone) {
        [self requestExitCurrentMode];
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
        self.normalControlPanel.shareToggleHandler = nil;
        self.normalControlPanel.shareModeChangedHandler = nil;
        self.normalControlPanel.audioInputSelectionChangedHandler = nil;
        self.normalControlPanel.shareSystemAudioChangedHandler = nil;
    }

    [self.normalSurfaceShareController stopSharingFromSurfaceView:self.normalRenderView];
    self.normalSurfaceShareController = nil;

    self.normalMediaController.audioInputOptionsChangedHandler = nil;
    [self.normalMediaController shutdown];
    self.normalMediaController = nil;
    self.normalControlPanel = nil;

    // [Phase 8] Tear down chat and speaker queue UI
    [self.chatController detach];
    [self.speakerQueue reset];
    self.chatController.chatDelegate = nil;
    self.chatController.controlDelegate = nil;
    self.chatController.isChatVisible = NO;
    self.normalChatSelectedRecipient = nil;
    if (self.normalChatPanel) {
        [self.normalChatPanel removeFromSuperview];
        self.normalChatPanel = nil;
    }
    if (self.normalSpeakerQueuePanel) {
        [self.normalSpeakerQueuePanel removeFromSuperview];
        self.normalSpeakerQueuePanel = nil;
    }
    self.normalChatToggleButton = nil;
    self.normalHandRaiseButton = nil;
    self.normalQueueToggleButton = nil;

    // [Phase 8.5] Tear down poll window
    if (self.normalPollWindow) {
        [self.normalPollWindow orderOut:nil];
        self.normalPollWindow = nil;
    }
    self.normalPollPanel = nil;
    self.normalPollToggleButton = nil;

    // [Phase 8.6] Tear down Q&A window
    if (self.normalQAWindow) {
        [self.normalQAWindow orderOut:nil];
        self.normalQAWindow = nil;
    }
    self.normalQAPanel = nil;
    self.normalQAToggleButton = nil;

    // [Phase 9] Tear down lobby window
    if (self.normalLobbyWindow) {
        [self.normalLobbyWindow orderOut:nil];
        self.normalLobbyWindow = nil;
    }
    self.normalLobbyPanel = nil;
    self.normalLobbyToggleButton = nil;

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
        [self.setupRenderView shutdownRenderingSynchronously];
        [self.setupRenderView removeFromSuperview];
        self.setupRenderView = nil;
    }

    if (self.normalRenderView != nil) {
        [self.normalRenderView shutdownRenderingSynchronously];
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
        self.billingStatusLabel.stringValue = @"Unable to open plans.";
        return;
    }

    BOOL isAuth = self.roomController.tokenService.isAuthenticated;

    // Unauthenticated: ask the server for the public plans page URL.
    // The server owns the canonical URL — the app never hardcodes it.
    if (!isAuth) {
        if (self.upgradeButton) {
            [self.upgradeButton setEnabled:NO];
            [self.upgradeButton setTitle:@"Loading…"];
        }
        self.billingStatusLabel.stringValue = @"";

        __weak typeof(self) weakSelf = self;
        [self.roomController.tokenService requestPublicPlansURLWithCompletion:^(NSString *url) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { return; }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (url.length) {
                    NSURL *plansURL = [NSURL URLWithString:url];
                    if (plansURL) {
                        [[NSWorkspace sharedWorkspace] openURL:plansURL];
                        strongSelf.billingStatusLabel.stringValue = @"Plans page opened in your browser.";
                    } else {
                        strongSelf.billingStatusLabel.stringValue = @"Unable to open plans.";
                    }
                } else {
                    strongSelf.billingStatusLabel.stringValue = @"Unable to open plans. Try again.";
                }

                if (strongSelf.upgradeButton) {
                    [strongSelf.upgradeButton setEnabled:YES];
                    [strongSelf.upgradeButton setTitle:@"View Plans"];
                }
            });
        }];
        return;
    }

    // Authenticated: request a tokenized URL so the page shows the current plan.
    if (self.upgradeButton) {
        [self.upgradeButton setEnabled:NO];
        [self.upgradeButton setTitle:@"Loading…"];
    }
    self.billingStatusLabel.stringValue = @"";

    __weak typeof(self) weakSelf = self;
    [self.roomController.tokenService requestBillingPageURLWithCompletion:^(NSString *url) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (url.length) {
                NSURL *plansURL = [NSURL URLWithString:url];
                if (plansURL) {
                    [[NSWorkspace sharedWorkspace] openURL:plansURL];
                    strongSelf.billingStatusLabel.stringValue = @"Plans page opened in your browser.";
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
                strongSelf.billingStatusLabel.stringValue = @"Failed to open plans. Try again.";
            }

            if (strongSelf.upgradeButton) {
                [strongSelf.upgradeButton setEnabled:YES];
                [strongSelf.upgradeButton setTitle:@"View Plans"];
            }
        });
    }];
}

- (void)handleManageSubscription {
    NSLog(@"[Billing] User requested subscription management");
    if (!self.roomController.tokenService) {
        NSLog(@"[Billing] tokenService is nil — cannot open portal");
        self.billingStatusLabel.stringValue = @"Not signed in.";
        return;
    }
    if (self.manageSubscriptionButton) {
        [self.manageSubscriptionButton setEnabled:NO];
        [self.manageSubscriptionButton setTitle:@"Loading…"];
    }

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
                strongSelf.billingStatusLabel.stringValue = @"Failed to open subscription portal.";
            }

            if (strongSelf.manageSubscriptionButton) {
                [strongSelf.manageSubscriptionButton setEnabled:YES];
                [strongSelf.manageSubscriptionButton setTitle:@"Manage Subscription"];
            }
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

        // Re-authenticate by calling login with stored email + entered password
        NSString *password = passwordField.stringValue;
        NSString *email = self.roomController.tokenService.currentEmail;

        if (!password.length || !email.length) {
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

    self.billingStatusLabel.stringValue = @"Verifying your upgrade…";
    if (self.upgradeButton) {
        [self.upgradeButton setEnabled:NO];
        [self.upgradeButton setTitle:@"Verifying…"];
    }
    if (self.manageSubscriptionButton) {
        [self.manageSubscriptionButton setEnabled:NO];
    }

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

                // Rebuild chrome to show "Manage Subscription" instead of "View Plans"
                [strongSelf refreshSetupChrome];
                strongSelf.billingStatusLabel.stringValue =
                    [NSString stringWithFormat:@"Upgraded to %@!", [newTier capitalizedString]];

                // Clear the success message after a few seconds
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if ([strongSelf.billingStatusLabel.stringValue containsString:@"Upgraded"]) {
                        strongSelf.billingStatusLabel.stringValue = @"";
                    }
                });
            } else {
                NSLog(@"[Billing] Tier poll timed out — tier unchanged from %@", previousTier);
                strongSelf.billingStatusLabel.stringValue = @"Upgrade pending — it may take a moment.";
                if (strongSelf.upgradeButton) {
                    [strongSelf.upgradeButton setEnabled:YES];
                    [strongSelf.upgradeButton setTitle:@"View Plans"];
                }
                if (strongSelf.manageSubscriptionButton) {
                    [strongSelf.manageSubscriptionButton setEnabled:YES];
                }
            }
        });
    }];
}

#pragma mark - Password Reset Deep Link

- (void)handlePasswordResetDeepLinkWithToken:(NSString *)token {
    NSLog(@"[Auth] Password reset deep link received");

    // Bring app to front
    [NSApp activateIgnoringOtherApps:YES];

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

    // POST to /auth/reset-password with the token and new password
    NSString *baseURL = self.roomController.tokenService.serverURL ?: @"http://localhost:3000";
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
            }
            [resultAlert runModal];
        });
    }] resume];
}

@end
