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
#import "InterRemoteVideoLayoutManager.h"
#import "InterTrackRendererBridge.h"
#import "InterParticipantOverlayView.h"
#import "InterNetworkStatusView.h"

// [2.5.1] Swift module import for networking layer
#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

@interface AppDelegate () <NSWindowDelegate, InterConnectionSetupPanelDelegate, InterParticipantOverlayDelegate>
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
@property (nonatomic, assign) BOOL normalShareSystemAudioEnabled;
@property (nonatomic, assign) BOOL isScreenObserverRegistered;
@property (nonatomic, assign) BOOL isShowingExternalDisplayAlert;
@property (nonatomic, weak) NSWindow *fullScreenExitPendingWindow;

// [2.5.2] Room controller — persists across mode transitions [G4]
@property (nonatomic, strong, nullable) InterRoomController *roomController;

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
    [self.normalMediaWiring setupRoomControllerKVO];

    [self launchSetupUI];
    [self preflightMediaPermissions];
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

    [self teardownActiveWindows];
    [self.settingsWindow orderOut:nil];
    InterTeardownSetupWindow(&_setupWindow, &_setupRenderView, &_connectionPanel);

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
    [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 560)
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
    [self.setupWindow setMinSize:NSMakeSize(660.0, 560.0)];
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
    NSView *overlayView = [[NSView alloc] initWithFrame:containerView.bounds];
    overlayView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [overlayView setWantsLayer:YES];
    overlayView.layer.backgroundColor = NSColor.clearColor.CGColor;
    [containerView addSubview:overlayView];

    // [3.1.1] Connection setup panel — server URLs, display name, room code, action buttons
    CGFloat panelW = 420.0;
    CGFloat panelH = 480.0;
    CGFloat panelX = (containerView.bounds.size.width - panelW) / 2.0;
    CGFloat panelY = (containerView.bounds.size.height - panelH) / 2.0;
    self.connectionPanel = [[InterConnectionSetupPanel alloc] initWithFrame:NSMakeRect(panelX, panelY, panelW, panelH)];
    self.connectionPanel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    self.connectionPanel.delegate = self;
    [overlayView addSubview:self.connectionPanel];

    NSButton *settingsButton = [[NSButton alloc] initWithFrame:NSMakeRect(panelX + panelW - 112, panelY + panelH + 8, 112, 26)];
    settingsButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [settingsButton setTitle:@"Settings"];
    [settingsButton setTarget:self];
    [settingsButton setAction:@selector(openSettingsWindow)];
    [overlayView addSubview:settingsButton];
}

#pragma mark - InterConnectionSetupPanelDelegate [3.1]

- (void)setupPanelDidRequestHostCall:(InterConnectionSetupPanel *)panel {
    [self connectAndEnterMode:InterCallModeNormal role:InterInterviewRoleNone panel:panel];
}

- (void)setupPanelDidRequestHostInterview:(InterConnectionSetupPanel *)panel {
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
                                                roomType:(mode == InterCallModeInterview) ? @"interview" : @"call"];

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
                                                roomType:@""];

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
    // InterNetworkErrorCode values from InterNetworkTypes.swift
    if (code == 2) return @"Invalid room code. Check and try again.";
    if (code == 3) return @"Room has expired. Ask the host for a new code.";
    if (code == 4) return @"Token fetch failed. Check token server URL.";
    if (code == 5) return @"Connection failed. Check server URL and network.";

    return error.localizedDescription ?: @"Connection failed.";
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
        // [2.5.6] [G2] Two-phase microphone toggle via shared wiring controller
        [weakSelf.normalMediaWiring twoPhaseToggleMicrophone];
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

    // [3.4.4] Network quality signal bars in the control panel
    self.normalNetworkStatusView = [[InterNetworkStatusView alloc] initWithFrame:NSMakeRect(0, 0, 40, 16)];
    [self.normalControlPanel.networkStatusContainerView addSubview:self.normalNetworkStatusView];

    // [3.4.5] [G9] Triple-click diagnostic: copy snapshot to clipboard via wiring controller
    NSClickGestureRecognizer *tripleClick = [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                                                      action:@selector(forwardDiagnosticTripleClick:)];
    tripleClick.numberOfClicksRequired = 3;
    [self.normalControlPanel.networkStatusContainerView addGestureRecognizer:tripleClick];
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
    BOOL microphoneOn = self.normalMediaController.isMicrophoneEnabled;
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

#pragma mark - Diagnostics [3.4.5]

/// [B1] Trampoline: gesture recognizer target must be self; forward to wiring controller.
- (void)forwardDiagnosticTripleClick:(NSClickGestureRecognizer *)recognizer {
#pragma unused(recognizer)
    [self.normalMediaWiring handleDiagnosticTripleClick];
}

#pragma mark - Settings

- (void)openSettingsWindow {
    if (!self.settingsWindow) {
        self.settingsWindow =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 140)
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
        [self.settingsWindow setTitle:@"Settings"];
        [self.settingsWindow setSharingType:NSWindowSharingNone];

        NSView *contentView = [[NSView alloc] initWithFrame:self.settingsWindow.contentView.bounds];
        contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.settingsWindow setContentView:contentView];

        NSTextField *placeholderLabel = [NSTextField labelWithString:@"No configurable settings yet."];
        placeholderLabel.frame = NSMakeRect(24, 72, 352, 24);
        placeholderLabel.font = [NSFont systemFontOfSize:13];
        placeholderLabel.textColor = [NSColor secondaryLabelColor];
        [contentView addSubview:placeholderLabel];

        NSButton *closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(284, 24, 92, 34)];
        [closeButton setTitle:@"Close"];
        [closeButton setTarget:self];
        [closeButton setAction:@selector(closeSettingsWindow)];
        [contentView addSubview:closeButton];
    }

    [self.settingsWindow center];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
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

    return YES;
}

- (void)teardownActiveWindows {
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
    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
    [self stopScreenMonitoring];
    self.isShowingExternalDisplayAlert = NO;

    // Hide all call windows FIRST so the user sees instant visual feedback,
    // then perform potentially-slow teardown (room disconnect, AVCaptureSession
    // stop, etc.) without the user staring at a frozen window.
    if (self.normalCallWindow != nil) {
        [self.normalCallWindow orderOut:nil];
    }
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

@end
