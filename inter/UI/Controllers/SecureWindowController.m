#import "SecureWindowController.h"
#import "InterLocalCallControlPanel.h"
#import "InterLocalMediaController.h"
#import "InterMediaWiringController.h"
#import "InterSurfaceShareController.h"
#import "MetalSurfaceView.h"
#import "SecureWindow.h"
#import "InterRemoteVideoLayoutManager.h"
#import "InterTrackRendererBridge.h"
#import "InterParticipantOverlayView.h"
#import "InterNetworkStatusView.h"
#import "InterSecureToolHostView.h"
#import "InterSecureInterviewStageView.h"
#import "InterViewSnapshotVideoSource.h"

// [2.6] Swift module import for networking layer
#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

static const CGFloat InterSecureSidebarWidth = 278.0;
static const CGFloat InterSecureSidebarTrailingMargin = 34.0;
static const CGFloat InterSecureSidebarBottomMargin = 26.0;
static const CGFloat InterSecurePanelHeight = 470.0;
static const CGFloat InterSecureRemotePreviewHeight = 190.0;
static const CGFloat InterSecureTopMargin = 40.0;
static const CGFloat InterSecureLeftMargin = 40.0;
static const CGFloat InterSecureBottomWorkspaceMargin = 100.0;

@interface SecureWindowController () <InterParticipantOverlayDelegate>
@property (nonatomic, strong) MetalSurfaceView *renderView;
@property (nonatomic, strong) InterSecureInterviewStageView *stageView;
@property (nonatomic, strong) InterSecureToolHostView *toolHostView;
@property (nonatomic, strong) InterLocalCallControlPanel *controlPanel;
@property (nonatomic, strong) InterLocalMediaController *localMediaController;
@property (nonatomic, strong) InterSurfaceShareController *surfaceShareController;
@property (nonatomic, strong, nullable) InterRemoteVideoLayoutManager *remoteLayout;
@property (nonatomic, strong, nullable) InterTrackRendererBridge *trackRendererBridge;
@property (nonatomic, strong, nullable) InterNetworkStatusView *networkStatusView;
@property (nonatomic, strong, nullable) InterMediaWiringController *mediaWiring;
@end

@implementation SecureWindowController

- (void)createSecureWindow {

    NSScreen *screen = [NSScreen mainScreen];
    if (!screen) {
        return;
    }

    self.secureWindow =
    [[SecureWindow alloc] initWithContentRect:screen.frame
                                styleMask:NSWindowStyleMaskBorderless
                                  backing:NSBackingStoreBuffered
                                    defer:NO];

    [self.secureWindow setLevel:NSScreenSaverWindowLevel];
    [self.secureWindow setOpaque:YES];
    [self.secureWindow setBackgroundColor:[NSColor blackColor]];
    [self.secureWindow setSharingType:NSWindowSharingNone];
    [self.secureWindow setMovable:NO];
    [self.secureWindow setReleasedWhenClosed:NO];
    [self.secureWindow setHidesOnDeactivate:NO];

    NSRect contentFrame = NSMakeRect(0, 0, screen.frame.size.width, screen.frame.size.height);
    NSView *view = [[NSView alloc] initWithFrame:contentFrame];
    [view setWantsLayer:YES];
    view.layer.backgroundColor = [NSColor blackColor].CGColor;
    [self.secureWindow setContentView:view];

    self.renderView = [[MetalSurfaceView alloc] initWithFrame:view.bounds];
    self.renderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.renderView];

    self.stageView = [[InterSecureInterviewStageView alloc] initWithFrame:view.bounds];
    self.stageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.stageView];

    // The secure stage owns both the authoritative tool capture host and the
    // local-only remote media presentation. Keep controller-level references so
    // existing networking and overlay wiring can remain explicit.
    self.toolHostView = self.stageView.toolCaptureHostView;
    self.remoteLayout = self.stageView.remoteLayoutManager;

    NSTextField *headline = [NSTextField labelWithString:@"Interview secure surface (Metal)"];
    headline.frame = NSMakeRect(InterSecureLeftMargin,
                                view.bounds.size.height - 52.0,
                                NSMaxX([self secureToolHostFrameInView:view]) - InterSecureLeftMargin,
                                24.0);
    headline.font = [NSFont boldSystemFontOfSize:15];
    headline.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    headline.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [view addSubview:headline];

    [self attachControlPanelInView:view];
    [self startLocalMediaFlow];
    [self updateSecureWorkspacePresentationAnimated:NO];
    [self.stageView layoutSubtreeIfNeeded];

    NSButton *exitButton =
    [[NSButton alloc] initWithFrame:NSMakeRect(40, 40, 140, 45)];
    exitButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;

    [exitButton setTitle:@"Exit Session"];
    [exitButton setTarget:self];
    [exitButton setAction:@selector(exitSession)];

    [view addSubview:exitButton];
    [self.secureWindow makeKeyAndOrderFront:nil];
}

- (void)exitSession {
    dispatch_block_t exitHandler = self.exitSessionHandler;
    if (exitHandler) {
        exitHandler();
    }
}

- (void)hideSecureWindow {
    if (self.secureWindow) {
        // Ordering the borderless secure window out before the Metal view is
        // quiesced leaves a window where the CAMetalLayer can lose its drawable
        // while the display-link thread is still issuing work. Stop rendering
        // first so exit never races layer teardown.
        [self.renderView shutdownRenderingSynchronously];
        [self.secureWindow orderOut:nil];
    }
}

- (void)destroySecureWindow {
    if (self.controlPanel) {
        self.controlPanel.cameraToggleHandler = nil;
        self.controlPanel.microphoneToggleHandler = nil;
        self.controlPanel.shareToggleHandler = nil;
        self.controlPanel.shareModeChangedHandler = nil;
        self.controlPanel.audioInputSelectionChangedHandler = nil;
        self.controlPanel.shareSystemAudioChangedHandler = nil;
        self.controlPanel.interviewToolChangedHandler = nil;
    }

    [self.renderView shutdownRenderingSynchronously];
    [self.surfaceShareController stopSharingFromSurfaceView:self.renderView];
    // [2.6.5] Clear network sink but do NOT disconnect room
    self.surfaceShareController.networkPublishSink = nil;
    self.surfaceShareController = nil;

    self.localMediaController.audioInputOptionsChangedHandler = nil;
    [self.localMediaController shutdown];
    self.localMediaController = nil;

    // [2.6] Tear down KVO before releasing
    [self.mediaWiring teardownRoomControllerKVO];
    self.mediaWiring = nil;

    // [3.3] Tear down remote video layout
    if (self.remoteLayout) {
        [self.remoteLayout teardown];
        [self.remoteLayout removeFromSuperview];
        self.remoteLayout = nil;
    }
    if (self.trackRendererBridge) {
        if (self.roomController) {
            self.roomController.subscriber.trackRenderer = nil;
        }
        self.trackRendererBridge = nil;
    }

    self.controlPanel = nil;

    [self.stageView removeFromSuperview];
    self.stageView = nil;
    self.toolHostView = nil;
    self.remoteLayout = nil;

    [self.renderView removeFromSuperview];
    self.renderView = nil;

    [self.secureWindow orderOut:nil];
    self.secureWindow = nil;
    self.exitSessionHandler = nil;
}

#pragma mark - Controls

- (void)attachControlPanelInView:(NSView *)view {
    NSRect panelFrame = [self secureControlPanelFrameInView:view];
    self.controlPanel = [[InterLocalCallControlPanel alloc] initWithFrame:panelFrame];
    self.controlPanel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self.controlPanel setPanelTitleText:@"Interview Controls"];
    [self.controlPanel setShareModeSelectorHidden:YES];
    [self.controlPanel setInterviewToolSelectorHidden:NO];
    [self.controlPanel setSelectedInterviewToolKind:InterInterviewToolKindNone];
    [self.controlPanel setShareMode:InterShareModeThisApp];
    [self.controlPanel setShareSystemAudioEnabled:NO];
    [self.controlPanel setShareSystemAudioToggleHidden:YES];
    [self.controlPanel setShareStartPending:NO];
    [self.controlPanel setShareStatusText:@"Secure tool share is off."];
    [view addSubview:self.controlPanel];

    __weak typeof(self) weakSelf = self;
    self.controlPanel.cameraToggleHandler = ^{
        // [2.6.3] [G2] Two-phase camera toggle via shared wiring controller
        [weakSelf.mediaWiring twoPhaseToggleCamera];
    };
    self.controlPanel.microphoneToggleHandler = ^{
        // [2.6.3] [G2] Two-phase mic toggle via shared wiring controller
        [weakSelf.mediaWiring twoPhaseToggleMicrophone];
    };
    self.controlPanel.shareToggleHandler = ^{
        [weakSelf toggleSurfaceShare];
    };
    self.controlPanel.audioInputSelectionChangedHandler = ^(NSString * _Nullable deviceID) {
        [weakSelf handleSecureAudioInputSelection:deviceID];
    };
    self.controlPanel.interviewToolChangedHandler = ^(InterInterviewToolKind toolKind) {
        [weakSelf handleInterviewToolSelection:toolKind];
    };

    // [3.4.4] Network quality signal bars
    self.networkStatusView = [[InterNetworkStatusView alloc] initWithFrame:NSMakeRect(0, 0, 40, 16)];
    [self.controlPanel.networkStatusContainerView addSubview:self.networkStatusView];

    // [3.4.5] Triple-click diagnostic via wiring controller
    NSClickGestureRecognizer *tripleClick = [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                                                      action:@selector(forwardDiagnosticTripleClick:)];
    tripleClick.numberOfClicksRequired = 3;
    [self.controlPanel.networkStatusContainerView addGestureRecognizer:tripleClick];
}

- (void)startLocalMediaFlow {
    self.localMediaController = [[InterLocalMediaController alloc] init];
    self.surfaceShareController = [[InterSurfaceShareController alloc] init];
    [self.surfaceShareController configureWithSessionKind:InterShareSessionKindInterview
                                                shareMode:InterShareModeThisApp];
    [self.surfaceShareController setShareSystemAudioEnabled:NO];
    __weak typeof(self) weakSelf = self;
    self.localMediaController.audioInputOptionsChangedHandler = ^{
        [weakSelf refreshSecureAudioInputOptions];
    };
    if (self.stageView.toolCaptureHostView) {
        self.surfaceShareController.customVideoSource =
        [[InterViewSnapshotVideoSource alloc] initWithCapturedView:self.stageView.toolCaptureHostView];
    }
    [self refreshSecureAudioInputOptions];

    self.surfaceShareController.statusHandler = ^(NSString *statusText) {
        [weakSelf.controlPanel setShareStatusText:statusText];
        BOOL startPending = weakSelf.surfaceShareController.isStartPending;
        BOOL sharing = weakSelf.surfaceShareController.isSharing;
        [weakSelf.controlPanel setShareStartPending:startPending];
        [weakSelf.controlPanel setSharingEnabled:sharing];
        weakSelf.stageView.secureShareActive = sharing;
        [weakSelf updateSecureWorkspacePresentationAnimated:YES];
        [weakSelf.stageView focusActiveToolIfVisible];
        // Publish screen share track to LiveKit when sharing starts
        if (sharing && weakSelf.roomController.connectionState == InterRoomConnectionStateConnected) {
            [weakSelf.roomController.publisher publishScreenShareWithCompletion:^(NSError *error) {
                if (error) {
                    NSLog(@"[G8] Screen share publish error: %@", error.localizedDescription);
                }
            }];
        }
    };
    self.surfaceShareController.audioSampleObserverRegistrationBlock =
    ^(InterSurfaceShareAudioSampleHandler _Nullable sampleHandler) {
        weakSelf.localMediaController.audioSampleBufferHandler = sampleHandler;
    };

    [self.controlPanel setMediaStatusText:@"Requesting camera/mic permission..."];
    [self.localMediaController attachPreviewToView:self.controlPanel.previewContainerView];

    [self.localMediaController prepareWithCompletion:^(BOOL success, NSString * _Nullable failureReason) {
        if (!success) {
            NSString *message = failureReason ?: @"Camera/mic initialization failed.";
            [weakSelf.controlPanel setMediaStatusText:message];
            [weakSelf.controlPanel setCameraEnabled:NO];
            [weakSelf.controlPanel setMicrophoneEnabled:NO];
            return;
        }

        [weakSelf.localMediaController start];
        [weakSelf.controlPanel setCameraEnabled:weakSelf.localMediaController.isCameraEnabled];
        [weakSelf.controlPanel setMicrophoneEnabled:weakSelf.localMediaController.isMicrophoneEnabled];

        NSString *message = [weakSelf secureMediaStateSummary];
        if (failureReason.length > 0) {
            message = failureReason;
        }
        [weakSelf.controlPanel setMediaStatusText:message];

        // [2.6.2] Wire network publishing if room is connected
        [weakSelf.mediaWiring wireNetworkPublish];
    }];

    // [B1] Create and wire shared media wiring controller
    self.mediaWiring = [[InterMediaWiringController alloc] init];
    self.mediaWiring.roomController = self.roomController;
    self.mediaWiring.mediaController = self.localMediaController;
    self.mediaWiring.controlPanel = self.controlPanel;
    self.mediaWiring.remoteLayout = self.remoteLayout;
    self.mediaWiring.networkStatusView = self.networkStatusView;
    self.mediaWiring.surfaceShareController = self.surfaceShareController;
    self.mediaWiring.renderView = self.renderView;
    self.mediaWiring.mediaStateSummaryBlock = ^NSString *{
        return [weakSelf secureMediaStateSummary];
    };
    [self.mediaWiring setupRoomControllerKVO];

    // [3.3.1] Wire remote rendering
    [self wireSecureRemoteRendering];
}

- (NSString *)secureMediaStateSummary {
    BOOL cameraOn = self.localMediaController.isCameraEnabled;
    BOOL microphoneOn = self.localMediaController.isMicrophoneEnabled;
    return [NSString stringWithFormat:@"Camera %@, Mic %@.",
            cameraOn ? @"on" : @"off",
            microphoneOn ? @"on" : @"off"];
}

- (NSRect)secureControlPanelFrameInView:(NSView *)view {
    CGFloat originX = view.bounds.size.width - InterSecureSidebarTrailingMargin - InterSecureSidebarWidth;
    return NSMakeRect(originX,
                      InterSecureSidebarBottomMargin,
                      InterSecureSidebarWidth,
                      InterSecurePanelHeight);
}

- (NSRect)secureRemoteLayoutFrameInView:(NSView *)view {
    CGFloat originX = view.bounds.size.width - InterSecureSidebarTrailingMargin - InterSecureSidebarWidth;
    CGFloat originY = view.bounds.size.height - InterSecureTopMargin - InterSecureRemotePreviewHeight;
    return NSMakeRect(originX,
                      originY,
                      InterSecureSidebarWidth,
                      InterSecureRemotePreviewHeight);
}

- (NSRect)secureToolHostFrameInView:(NSView *)view {
    CGFloat sidebarOriginX = NSMinX([self secureControlPanelFrameInView:view]);
    CGFloat width = MAX(320.0, sidebarOriginX - (InterSecureLeftMargin + 24.0));
    CGFloat height = MAX(320.0, view.bounds.size.height - (InterSecureBottomWorkspaceMargin + InterSecureTopMargin + 30.0));
    return NSMakeRect(InterSecureLeftMargin,
                      InterSecureBottomWorkspaceMargin,
                      width,
                      height);
}

- (NSString *)secureToolDescriptionForKind:(InterInterviewToolKind)toolKind {
    switch (toolKind) {
        case InterInterviewToolKindCodeEditor:
            return @"Code editor";
        case InterInterviewToolKindWhiteboard:
            return @"Whiteboard";
        case InterInterviewToolKindNone:
        default:
            return @"No secure tool";
    }
}

- (void)refreshSecureAudioInputOptions {
    if (!self.localMediaController || !self.controlPanel) {
        return;
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *options = [self.localMediaController availableAudioInputOptions];
    NSString *selectedDeviceID = [self.localMediaController selectedAudioInputDeviceID];
    [self.controlPanel setAudioInputOptions:options selectedDeviceID:selectedDeviceID];
}

- (void)handleInterviewToolSelection:(InterInterviewToolKind)toolKind {
    if (!self.stageView || !self.controlPanel) {
        return;
    }

    [self.stageView setActiveToolKind:toolKind];
    [self.controlPanel setSelectedInterviewToolKind:toolKind];

    if (self.surfaceShareController.isSharing && toolKind == InterInterviewToolKindNone) {
        // Interview sharing should never keep streaming a placeholder once the
        // user explicitly turns tools off. Stop the share so the main stage can
        // return to remote video immediately.
        [self.roomController.publisher unpublishScreenShareWithCompletion:nil];
        [self.surfaceShareController stopSharingFromSurfaceView:self.renderView];
        self.surfaceShareController.networkPublishSink = nil;
        [self.controlPanel setShareStartPending:self.surfaceShareController.isStartPending];
        [self.controlPanel setSharingEnabled:self.surfaceShareController.isSharing];
        [self updateSecureWorkspacePresentationAnimated:YES];
        return;
    }

    if (self.surfaceShareController.isSharing) {
        NSString *toolDescription = [self secureToolDescriptionForKind:toolKind];
        [self.controlPanel setShareStatusText:[NSString stringWithFormat:@"Secure tool share is active. %@ visible to the other participant.", toolDescription]];
    } else {
        if (toolKind == InterInterviewToolKindNone) {
            [self.controlPanel setShareStatusText:@"Secure tool share is off. Choose a tool before you begin sharing."];
        } else {
            NSString *toolDescription = [self secureToolDescriptionForKind:toolKind];
            [self.controlPanel setShareStatusText:[NSString stringWithFormat:@"Secure tool share is off. %@ selected. Press Share to start publishing it.", toolDescription]];
        }
    }

    [self updateSecureWorkspacePresentationAnimated:YES];
    [self.stageView focusActiveToolIfVisible];
}

- (void)applyRemoteLayoutFrameAnimated:(BOOL)animated {
#pragma unused(animated)
    // Secure interview stage layout is now owned entirely by InterSecureInterviewStageView.
}

- (BOOL)shouldDisplaySecureToolSurface {
    if (!self.stageView || !self.surfaceShareController) {
        return NO;
    }

    return self.surfaceShareController.isSharing &&
           self.stageView.activeToolKind != InterInterviewToolKindNone;
}

- (NSRect)targetRemoteLayoutFrameInView:(NSView *)view {
    if (![self shouldDisplaySecureToolSurface]) {
        // Mirror the normal-call behavior: when there is no active secure tool
        // share, remote media owns the main workspace region instead of leaving
        // an empty reserved surface on screen.
        return [self secureToolHostFrameInView:view];
    }

    return [self secureRemoteLayoutFrameInView:view];
}

- (void)updateSecureWorkspacePresentationAnimated:(BOOL)animated {
#pragma unused(animated)
    if (!self.stageView) {
        return;
    }

    self.stageView.secureShareActive = [self shouldDisplaySecureToolSurface];
    [self.stageView setNeedsLayout:YES];
}

- (void)handleSecureAudioInputSelection:(NSString * _Nullable)deviceID {
    if (!self.localMediaController) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self.localMediaController selectAudioInputDeviceWithID:deviceID completion:^(BOOL success) {
        [weakSelf refreshSecureAudioInputOptions];
        if (!success) {
            [weakSelf.controlPanel setMediaStatusText:@"Unable to switch microphone source."];
            return;
        }

        [weakSelf.controlPanel setMediaStatusText:[weakSelf secureMediaStateSummary]];
    }];
}

// [B1] toggleCamera + toggleMicrophone removed — now in InterMediaWiringController.

- (void)toggleSurfaceShare {
    if (!self.renderView || !self.stageView) {
        return;
    }

    BOOL sharing = self.surfaceShareController.isSharing;
    BOOL startPending = self.surfaceShareController.isStartPending;
    [self.controlPanel setShareStartPending:startPending];
    [self.controlPanel setSharingEnabled:sharing];

    if (sharing || startPending) {
        // Unpublish screen share track from LiveKit before stopping
        [self.roomController.publisher unpublishScreenShareWithCompletion:nil];
        [self.surfaceShareController stopSharingFromSurfaceView:self.renderView];
        self.surfaceShareController.networkPublishSink = nil;
        [self.controlPanel setShareStartPending:self.surfaceShareController.isStartPending];
        [self.controlPanel setSharingEnabled:self.surfaceShareController.isSharing];
        [self updateSecureWorkspacePresentationAnimated:YES];
        return;
    }

    if (self.stageView.activeToolKind == InterInterviewToolKindNone) {
        [self.controlPanel setShareStatusText:@"Select Code or Whiteboard before starting secure tool share."];
        [self updateSecureWorkspacePresentationAnimated:YES];
        return;
    }

    // [2.6.4] Wire network sink before starting (interview: always ThisApp)
    [self.mediaWiring wireNetworkSinkOnSurfaceShareController:self.surfaceShareController];

    [self.surfaceShareController startSharingFromSurfaceView:self.renderView];
    [self.controlPanel setShareStartPending:self.surfaceShareController.isStartPending];
    [self.controlPanel setSharingEnabled:self.surfaceShareController.isSharing];
    // Don't optimistically read isSharing here — it may be YES momentarily
    // before an async permission error resets it. The statusHandler will
    // sync the button state when the capture actually succeeds or fails.
}

#pragma mark - Network Wiring [2.6]

// [B1] twoPhaseToggleCamera, twoPhaseToggleMicrophone, wireSecureNetworkPublish,
// wireNetworkSinkOnSurfaceShareController:, handleDiagnosticTripleClick:,
// setupRoomControllerKVO, teardownRoomControllerKVO, observeValueForKeyPath:,
// handleConnectionStateChanged:, handlePresenceStateChanged:
// are now in InterMediaWiringController (self.mediaWiring).

/// [3.3.1] Wire remote video rendering in secure mode.
- (void)wireSecureRemoteRendering {
    InterRoomController *rc = self.roomController;
    if (!rc || !self.remoteLayout) {
        return;
    }

    self.trackRendererBridge = [[InterTrackRendererBridge alloc] initWithLayoutManager:self.remoteLayout
                                                                      previewObserver:self.stageView];
    rc.subscriber.trackRenderer = (id<InterRemoteTrackRenderer>)self.trackRendererBridge;

    // [3.3.3] [G6] Show waiting overlay when alone + connected
    if (rc.connectionState == InterRoomConnectionStateConnected &&
        rc.participantPresenceState == InterParticipantPresenceStateAlone) {
        [self.remoteLayout.participantOverlay setOverlayState:InterParticipantOverlayStateWaiting];
    }

    self.remoteLayout.participantOverlay.delegate = self;
}

#pragma mark - InterParticipantOverlayDelegate [3.3.3]

- (void)overlayDidRequestWait:(InterParticipantOverlayView *)overlay {
    [overlay setOverlayState:InterParticipantOverlayStateWaiting];
}

- (void)overlayDidRequestEndCall:(InterParticipantOverlayView *)overlay {
    [overlay setOverlayState:InterParticipantOverlayStateHidden];
    [self exitSession];
}

#pragma mark - Diagnostics [3.4.5]

// TODO: [Phase 8.1.5] Add chat panel / hand-raise UI to secure interviewee mode.
// The chatController is already attached via AppDelegate.enterMode: so data flows.
// Secure mode needs a minimal chat UI (or at least a notification badge).

/// [B1] Trampoline: gesture recognizer target must be self; forward to wiring controller.
- (void)forwardDiagnosticTripleClick:(NSClickGestureRecognizer *)recognizer {
#pragma unused(recognizer)
    [self.mediaWiring handleDiagnosticTripleClick];
}

@end
