#import "SecureWindowController.h"
#import "InterWindowSecurity.h"
#import "InterLocalCallControlPanel.h"
#import "InterLocalMediaController.h"
#import "InterMediaWiringController.h"
#import "InterSurfaceShareController.h"
#import "SecureWindow.h"
#import "InterRemoteVideoLayoutManager.h"
#import "InterTrackRendererBridge.h"
#import "InterParticipantOverlayView.h"
#import "InterNetworkStatusView.h"
#import "InterSecureToolHostView.h"
#import "InterSecureInterviewStageView.h"
#import "InterViewSnapshotVideoSource.h"
#import "InterChatPanel.h"
#import "InterRecordingIndicatorView.h"
#import "InterFeatureGate.h"
#import "AppDelegate.h"
#import <objc/runtime.h>

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

@interface SecureWindowController () <InterParticipantOverlayDelegate, InterChatPanelDelegate, InterChatControllerDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSView *renderView;
@property (nonatomic, strong) InterSecureInterviewStageView *stageView;
@property (nonatomic, strong) InterSecureToolHostView *toolHostView;
@property (nonatomic, strong) InterSecureChromeBridge *controlPanel;
@property (nonatomic, strong, nullable) NSView *selfPreviewStrip;
@property (nonatomic, strong) InterLocalMediaController *localMediaController;
@property (nonatomic, strong) InterSurfaceShareController *surfaceShareController;
@property (nonatomic, strong, nullable) InterRemoteVideoLayoutManager *remoteLayout;
@property (nonatomic, strong, nullable) InterTrackRendererBridge *trackRendererBridge;
@property (nonatomic, strong, nullable) InterNetworkStatusView *networkStatusView;
@property (nonatomic, strong, nullable) InterMediaWiringController *mediaWiring;

// Chat overlay (floating panel window sitting above the secure window)
@property (nonatomic, strong, nullable) NSPanel *chatOverlayWindow;
@property (nonatomic, strong, nullable) InterChatPanel *secureChatPanel;
// [F2] Persistent recording badge so the interviewee always sees when the session is
// being recorded. `pendingRecordingActive` holds the desired state if set before the
// window exists (e.g. a late-joiner status poll resolving during window construction).
@property (nonatomic, strong, nullable) InterRecordingIndicatorView *recordingIndicatorView;
@property (nonatomic, assign) BOOL pendingRecordingActive;
// PRESENCE MONITORING (provisional, server flag default OFF). `pendingPresenceState`
// holds the desired chip state when -setPresenceMonitoringState: lands before the
// chrome exists — the same shape as pendingRecordingActive above. The details panel
// floats one level above the secure window, like the chat overlay.
@property (nonatomic, assign) NSInteger pendingPresenceState;
@property (nonatomic, strong, nullable) NSPanel *presenceDetailsWindow;
@property (nonatomic, strong, nullable) InterPresenceConsentHostView *presenceDetailsHost;
// The Phase 1 detector. Built on the media controller's sessionQueue and torn
// down from -destroySecureWindow on main, so the property is atomic.
@property (atomic, strong, nullable) InterPresenceCoordinator *presenceCoordinator;
@end

@implementation SecureWindowController

// When chatController is set after the chat overlay is already created, wire the delegate immediately.
- (void)setChatController:(InterChatController *)chatController {
    _chatController = chatController;
    if (chatController && self.secureChatPanel) {
        chatController.chatDelegate = self;
    }
}

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
    [self.secureWindow setSharingType:InterWindowSharingType()];
    [self.secureWindow setMovable:NO];
    [self.secureWindow setReleasedWhenClosed:NO];
    [self.secureWindow setHidesOnDeactivate:NO];

    NSRect contentFrame = NSMakeRect(0, 0, screen.frame.size.width, screen.frame.size.height);
    NSView *view = [[NSView alloc] initWithFrame:contentFrame];
    [view setWantsLayer:YES];
    view.layer.backgroundColor = [NSColor blackColor].CGColor;
    [self.secureWindow setContentView:view];

    self.renderView = [[NSView alloc] initWithFrame:view.bounds];
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

    // [Collaborative Code Editor] Wire the editor's DataChannel transport to the
    // room here — the same way chat/poll/Q&A controllers are attached — now that
    // the room is connected and the local attested identity is available. The
    // tool host forwards to its session-owned InterSecureToolsBridge, which
    // builds the shared document + controller, registers it on the room's
    // dispatcher, and configures the editor surface. Teardown is handled when the
    // host view deallocs (-[InterSecureToolsBridge invalidateHandlers]).
    // [candidate-tool-share-tile Phase 1] REVERSIBLE DISABLE — do NOT wire CRDT
    // collaboration for the candidate tool surface. The new one-way model keeps
    // the candidate code editor / whiteboard LOCAL (in-memory `text` mode): the
    // surface is published only as a screen-share track on an explicit Share tap.
    // Guarding this single call site is sufficient — it is the ONLY entry point
    // that reaches `InterSecureToolsBridge.configureCollaboration` (and hence
    // `CodeEditorViewModel.configure(document:controller:)` and the remote-cursor
    // overlay population); the bridge's deterministic KVO re-invoke only arms
    // *inside* `configureCollaborationWithRoomController:`, so not calling it here
    // means `configure` is never invoked and `remoteCursors` stays empty (no
    // overlay markers render). Phase 2 deletes this block and the CRDT path.
    // if (self.roomController) {
    //     [self.toolHostView configureCollaborationWithRoomController:self.roomController];
    // }

    [self attachControlPanelInView:view];
    [self startLocalMediaFlow];
    [self updateSecureWorkspacePresentationAnimated:NO];
    [self.stageView layoutSubtreeIfNeeded];

    // [F2] Persistent REC badge, top-centre, above the stage. Stays centred + pinned to
    // the top on resize. Reflects any state requested before the window existed.
    CGFloat badgeW = 132.0, badgeH = 28.0;
    self.recordingIndicatorView = [[InterRecordingIndicatorView alloc] initWithFrame:
        NSMakeRect((view.bounds.size.width - badgeW) / 2.0, view.bounds.size.height - badgeH - 10.0, badgeW, badgeH)];
    self.recordingIndicatorView.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    self.recordingIndicatorView.indicatorActive = self.pendingRecordingActive;
    [view addSubview:self.recordingIndicatorView positioned:NSWindowAbove relativeTo:nil];

    [self setupChatOverlayWindow];
    [self.secureWindow makeKeyAndOrderFront:nil];
}

// [F2] Drive the persistent recording badge. Tolerates being called before the window
// exists (stores the desired state, applied on creation).
- (void)setRecordingIndicatorActive:(BOOL)active {
    self.pendingRecordingActive = active;
    self.recordingIndicatorView.indicatorActive = active;
}

// PRESENCE MONITORING (provisional, server flag default OFF). Drive the persistent
// candidate chip. Tolerates being called before the chrome exists (stores the state,
// applied in -attachControlPanelInView:) — the setRecordingIndicatorActive: pattern.
// Delete this method and the one block in -attachControlPanelInView: to remove.
- (void)setPresenceMonitoringState:(NSInteger)state {
    self.pendingPresenceState = state;
    [self.controlPanel setPresenceMonitoringState:state];
    // An open details panel must never show a stale state.
    [self.presenceDetailsHost setMonitoringState:state];
}

- (void)setupChatOverlayWindow {
    // The secure window is fullscreen borderless at NSScreenSaverWindowLevel.
    // The chat panel lives in an NSPanel one level above so it floats on top.
    NSScreen *targetScreen = self.secureWindow.screen ?: [NSScreen mainScreen];
    NSRect screenFrame = targetScreen.frame;
    CGFloat panelW = 320.0;
    CGFloat panelH = screenFrame.size.height * 0.7;
    CGFloat panelX = NSMaxX(screenFrame) - panelW - 20.0;
    CGFloat panelY = NSMidY(screenFrame) - panelH / 2.0;

    self.chatOverlayWindow = [[NSPanel alloc] initWithContentRect:NSMakeRect(panelX, panelY, panelW, panelH)
                                                        styleMask:(NSWindowStyleMaskTitled |
                                                                   NSWindowStyleMaskResizable |
                                                                   NSWindowStyleMaskClosable)
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
    [self.chatOverlayWindow setLevel:NSScreenSaverWindowLevel + 1];
    [self.chatOverlayWindow setReleasedWhenClosed:NO];
    [self.chatOverlayWindow setTitle:@"Chat"];
    [self.chatOverlayWindow setOpaque:YES];
    [self.chatOverlayWindow setHidesOnDeactivate:NO];
    // Shield the chat panel from third-party capture/stream tools, exactly as the
    // secure window itself is shielded (createSecureWindow). The panel floats above
    // the secure surface during a live interview; without this it would be the one
    // unshielded surface a capture tool could read while everything else is black.
    [self.chatOverlayWindow setSharingType:InterWindowSharingType()];
    // Own the window's close lifecycle: the red title-bar close button is routed
    // through -windowShouldClose: so it HIDES (orderOut) and syncs toolbar state
    // rather than truly closing — the panel is a persistent hide/show overlay
    // (releasedWhenClosed == NO), so its content must survive every close path.
    self.chatOverlayWindow.delegate = self;

    // InterChatPanel fills the window's content view (always expanded in overlay mode)
    NSView *contentView = self.chatOverlayWindow.contentView;
    self.secureChatPanel = [[InterChatPanel alloc] initWithFrame:contentView.bounds];
    self.secureChatPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.secureChatPanel.delegate = self;
    [contentView addSubview:self.secureChatPanel];

    // Force the panel open immediately (it slides in; force-expand so it's always visible)
    [self.secureChatPanel expandPanel];

    // Wire to the chat controller if already set
    if (self.chatController) {
        self.chatController.chatDelegate = self;
    }
}

#pragma mark - Presence monitoring details (provisional)

// PRESENCE MONITORING (provisional, server flag default OFF).
// Presents the SAME PresenceConsentView the candidate saw before joining, in
// read-only details mode, in an NSPanel one level above the secure window — the
// setupChatOverlayWindow shape, including InterWindowSharingType() so the panel
// is shielded from third-party capture exactly like every other surface above
// the secure window. Reusing the one view is what keeps the pre-join promise and
// the mid-session explanation from drifting apart.
// Delete this method, the handler in -attachControlPanelInView: and
// -closePresenceDetailsPanel to remove the indicator's detail surface.
- (void)presentPresenceDetailsPanel {
    if (self.presenceDetailsWindow) {
        [self.presenceDetailsWindow makeKeyAndOrderFront:nil];
        return;
    }

    NSScreen *targetScreen = self.secureWindow.screen ?: [NSScreen mainScreen];
    NSRect screenFrame = targetScreen.frame;
    CGFloat panelW = 620.0;
    CGFloat panelH = MIN(640.0, screenFrame.size.height * 0.8);
    CGFloat panelX = NSMidX(screenFrame) - panelW / 2.0;
    CGFloat panelY = NSMidY(screenFrame) - panelH / 2.0;

    InterRoomController *rc = self.roomController;
    InterPresenceConsentHostView *host =
        [[InterPresenceConsentHostView alloc] initWithDetailsWithFrame:NSMakeRect(0, 0, panelW, panelH)
                                                      monitoringState:self.pendingPresenceState
                                                        retentionDays:rc ? rc.activePresenceRetentionDays : 90
                                                        rightsContact:rc.activePresenceRightsContact ?: @""
                                                externalDisplayPolicy:NO];
    // externalDisplayPolicy is NO on purpose: the secure-mode restriction list is
    // a PRE-JOIN notice and the details pane does not render it. The candidate is
    // already inside the secure window by the time this panel can open.
    __weak typeof(self) weakSelf = self;
    host.onCloseDetails = ^{
        [weakSelf closePresenceDetailsPanel];
    };

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(panelX, panelY, panelW, panelH)
                                                styleMask:(NSWindowStyleMaskTitled |
                                                           NSWindowStyleMaskClosable)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    [panel setLevel:NSScreenSaverWindowLevel + 1];
    [panel setReleasedWhenClosed:NO];
    [panel setTitle:@"What is and isn't measured"];
    [panel setOpaque:YES];
    [panel setHidesOnDeactivate:NO];
    [panel setSharingType:InterWindowSharingType()];
    [panel setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    panel.contentView = host;

    self.presenceDetailsHost = host;
    self.presenceDetailsWindow = panel;
    [panel makeKeyAndOrderFront:nil];
}

- (void)closePresenceDetailsPanel {
    [self.presenceDetailsHost invalidateHandlers];
    [self.presenceDetailsWindow orderOut:nil];
    self.presenceDetailsWindow = nil;
    self.presenceDetailsHost = nil;
}

- (void)toggleChatOverlay {
    if (!self.chatOverlayWindow) return;

    if (self.chatOverlayWindow.isVisible) {
        [self hideChatOverlaySyncingState];
    } else {
        [self.chatOverlayWindow makeKeyAndOrderFront:nil];
        self.chatController.isChatVisible = YES;  // setting YES resets unreadCount inside Swift
        [self.secureChatPanel setUnreadBadge:0];
        [self.controlPanel setChatVisible:YES];
        [self.controlPanel setChatUnread:0];
    }
}

/// Single hide path for the chat overlay, shared by the toolbar toggle, the
/// in-panel header "X" (chatPanelDidRequestClose:), and the window's red close
/// button (windowShouldClose:). Hides the window (never collapses the panel, so
/// its content stays expanded for the next open) and syncs the toolbar/visibility
/// state so the chat button never shows a stale "active" highlight.
- (void)hideChatOverlaySyncingState {
    if (!self.chatOverlayWindow) return;
    if (self.chatOverlayWindow.isVisible) {
        [self.chatOverlayWindow orderOut:nil];
    }
    self.chatController.isChatVisible = NO;
    [self.controlPanel setChatVisible:NO];
}

#pragma mark - InterChatPanelDelegate (close)

// In secure/interview mode the chat lives in a floating overlay window whose
// visibility is the toggle. The header "X" must HIDE that window — not collapse
// the InterChatPanel off-screen (which would leave an empty window on reopen,
// since the panel is force-expanded only once at setup and toggleChatOverlay
// only flips window visibility).
- (void)chatPanelDidRequestClose:(InterChatPanel *)panel {
#pragma unused(panel)
    [self hideChatOverlaySyncingState];
}

#pragma mark - NSWindowDelegate (chat overlay)

// Route the red title-bar close button through the same hide path and veto the
// real close, keeping the overlay (and its expanded panel content) alive for the
// next open. Only governs the chat overlay window; any other window closes normally.
- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender == self.chatOverlayWindow) {
        [self hideChatOverlaySyncingState];
        return NO;
    }
    return YES;
}

- (void)exitSession {
    dispatch_block_t exitHandler = self.exitSessionHandler;
    if (!exitHandler) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Are you sure you want to end this session?";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"End Session"];
    [alert addButtonWithTitle:@"Cancel"];

    NSWindow *targetWindow = self.secureWindow ?: [NSApp keyWindow];
    if (targetWindow) {
        [alert beginSheetModalForWindow:targetWindow completionHandler:^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn) {
                exitHandler();
            }
        }];
    } else {
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            exitHandler();
        }
    }
}

- (void)hideSecureWindow {
    if (self.secureWindow) {
        [self.secureWindow orderOut:nil];
    }
}

- (void)destroySecureWindow {
    // [review HIGH] The chrome bridge is a @MainActor Swift object and the
    // window/views are AppKit — teardown MUST run on the main thread. Re-route
    // defensively rather than assert: a background-thread release of the bridge
    // would tear down SwiftUI state off-main.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self destroySecureWindow]; });
        return;
    }

    // [paranoid #8] Drop every chrome handler block so none (and the controller
    // state they capture) outlives the session.
    [self.controlPanel invalidateHandlers];
    // [review MEDIUM] Explicitly detach the hosted chrome views (don't rely on
    // window dealloc cascading while the bridge may still be referenced).
    [self.controlPanel.topBarView removeFromSuperview];
    [self.controlPanel.bottomBarView removeFromSuperview];

    [self.surfaceShareController stopSharingFromSurfaceView:nil];
    // [2.6.5] Clear network sink but do NOT disconnect room
    self.surfaceShareController.networkPublishSink = nil;
    self.surfaceShareController = nil;

    // PRESENCE MONITORING (provisional). Stop the detector BEFORE the media
    // controller shuts the session down: it must remove its own output while the
    // session still exists, and its final flush closes any event still open.
    // Nil when the feature is off or consent was declined, so this is a no-op.
    [self.presenceCoordinator stop];
    self.presenceCoordinator = nil;

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
    if (self.selfPreviewStrip) {
        [self.selfPreviewStrip removeFromSuperview];
        self.selfPreviewStrip = nil;
    }

    [self.stageView removeFromSuperview];
    self.stageView = nil;
    self.toolHostView = nil;
    self.remoteLayout = nil;

    [self.renderView removeFromSuperview];
    self.renderView = nil;

    // PRESENCE MONITORING (provisional). Close the details panel and drop its
    // blocks so none outlives the session (paranoid #8).
    [self closePresenceDetailsPanel];
    self.pendingPresenceState = 0;

    // Tear down chat overlay
    if (self.chatOverlayWindow) {
        self.chatController.chatDelegate = nil;
        self.chatOverlayWindow.delegate = nil;
        [self.chatOverlayWindow orderOut:nil];
        self.chatOverlayWindow = nil;
        self.secureChatPanel = nil;
    }

    [self.secureWindow orderOut:nil];
    self.secureWindow = nil;
    self.exitSessionHandler = nil;
}

#pragma mark - Controls

- (void)attachControlPanelInView:(NSView *)view {
    // [Task: interviewee chrome] SwiftUI top status bar + bottom control bar
    // hosted INSIDE the capture-protected kiosk window (no new windows —
    // paranoid #2). The stage view, tool capture host, and chat overlay stay
    // AppKit; their geometry is untouched (#1): the bottom bar (88pt) fits
    // inside the stage's 100pt bottom workspace margin, the top bar (48pt)
    // inside its 70pt top reserve.
    InterSecureChromeBridge *chrome = [[InterSecureChromeBridge alloc] init];
    self.controlPanel = chrome;

    NSView *topBar = chrome.topBarView;
    topBar.frame = NSMakeRect(0, view.bounds.size.height - 48.0, view.bounds.size.width, 48.0);
    topBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [view addSubview:topBar];

    NSView *bottomBar = chrome.bottomBarView;
    bottomBar.frame = NSMakeRect(0, 0, view.bounds.size.width, 88.0);
    bottomBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [view addSubview:bottomBar];

    // Self-preview PiP in the sidebar column, above the bottom bar (the old
    // panel's preview container is gone). Camera preview attaches as a
    // sublayer; the network indicator overlays it as a subview.
    NSRect pipFrame = NSMakeRect(view.bounds.size.width - InterSecureSidebarTrailingMargin - InterSecureSidebarWidth,
                                 100.0,
                                 InterSecureSidebarWidth,
                                 157.0);
    NSView *pip = [[NSView alloc] initWithFrame:pipFrame];
    pip.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    pip.wantsLayer = YES;
    pip.layer.backgroundColor = [[NSColor colorWithWhite:0.08 alpha:1.0] CGColor];
    pip.layer.cornerRadius = 10.0;
    pip.layer.masksToBounds = YES;
    pip.layer.borderWidth = 1.0;
    pip.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.08] CGColor];
    [view addSubview:pip];
    self.selfPreviewStrip = pip;

    // Initial chrome state.
    [chrome setSelectedInterviewToolKind:InterInterviewToolKindNone];
    [chrome setShareStartPending:NO];
    [chrome setShareStatusText:@"Nothing is shared. Select Code or Board, then press Share."];
    if (self.roomController.roomCode.length > 0) {
        [chrome setRoomCodeText:self.roomController.roomCode];
    }

    __weak typeof(self) weakSelf = self;
    chrome.cameraToggleHandler = ^{
        // [2.6.3] [G2] Two-phase camera toggle via shared wiring controller
        [weakSelf.mediaWiring twoPhaseToggleCamera];
    };
    chrome.microphoneToggleHandler = ^{
        // [2.6.3] [G2] Two-phase mic toggle via shared wiring controller
        [weakSelf.mediaWiring twoPhaseToggleMicrophone];
    };
    chrome.shareToggleHandler = ^{
        // [paranoid #7] The ONLY publish trigger — tool selection never lands here.
        [weakSelf toggleSurfaceShare];
    };
    chrome.audioInputSelectionChangedHandler = ^(NSString * _Nullable deviceID) {
        [weakSelf handleSecureAudioInputSelection:deviceID];
    };
    chrome.interviewToolChangedHandler = ^(NSInteger toolKind) {
        [weakSelf handleInterviewToolSelection:(InterInterviewToolKind)toolKind];
    };
    chrome.chatToggleHandler = ^{
        [weakSelf toggleChatOverlay];
    };
    chrome.leaveHandler = ^{
        // [paranoid #5] The candidate's only escape from kiosk mode — routes
        // through the confirmation alert in exitSession (never exits silently).
        [weakSelf exitSession];
    };
    // PRESENCE MONITORING (provisional, server flag default OFF). The persistent
    // chip reopens the SAME disclosure copy the consent screen showed, so the
    // promise made before joining and the explanation given mid-session cannot
    // drift. The chip itself only renders when a state has been pushed, which
    // nothing does while the flag is off. Delete this handler, the pendingPresenceState
    // application below and -presentPresenceDetailsPanel to remove the indicator.
    chrome.presenceDetailsHandler = ^{
        [weakSelf presentPresenceDetailsPanel];
    };
    [chrome setPresenceMonitoringState:self.pendingPresenceState];

    // [3.4.4] Network quality signal bars — overlays the self-preview.
    self.networkStatusView = [[InterNetworkStatusView alloc] initWithFrame:NSMakeRect(6.0, pipFrame.size.height - 22.0, 40.0, 16.0)];
    self.networkStatusView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [pip addSubview:self.networkStatusView];
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
    [self.localMediaController attachPreviewToView:self.selfPreviewStrip];

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

        // PRESENCE MONITORING (provisional, server flag default OFF). One guard;
        // delete this block to remove the detector. `activePresenceMonitoringGranted`
        // is written only by the candidate's own consent decision on the join path,
        // so with the flag off (or on a decline) nothing below ever runs and no
        // frame is ever sampled. See .agents/tasks/presence-monitoring/REMOVAL.md.
        if (weakSelf.roomController.activePresenceMonitoringGranted) {
            InterLocalMediaController *media = weakSelf.localMediaController;
            AVCaptureSession *session = media.captureSession;
            dispatch_queue_t presenceQueue = media.sessionQueue;
            if (session && presenceQueue) {
                dispatch_async(presenceQueue, ^{
                    [weakSelf startPresenceMonitoringWithSession:session
                                                           queue:presenceQueue
                                                           media:media];
                });
            }
        }

        NSString *message = [weakSelf secureMediaStateSummary];
        if (failureReason.length > 0) {
            message = failureReason;
        }
        [weakSelf.controlPanel setMediaStatusText:message];

        // [Green room] Apply the candidate's pre-join mic/cam-off choices.
        // Same [R5] ordering rule as the normal flow: wireNetworkPublish must
        // wait for these async disables to land, or it reads stale enabled
        // state and publishes a ghost WebRTC mic track that keeps capturing
        // after the AVCaptureSession input is removed.
        dispatch_group_t joinGroup = dispatch_group_create();
        if (weakSelf.startWithMicrophoneOff) {
            dispatch_group_enter(joinGroup);
            [weakSelf.localMediaController setMicrophoneEnabled:NO completion:^(BOOL __unused s) {
                [weakSelf.controlPanel setMicrophoneEnabled:NO];
                dispatch_group_leave(joinGroup);
            }];
        }
        if (weakSelf.startWithCameraOff) {
            dispatch_group_enter(joinGroup);
            [weakSelf.localMediaController setCameraEnabled:NO completion:^(BOOL __unused s) {
                [weakSelf.controlPanel setCameraEnabled:NO];
                dispatch_group_leave(joinGroup);
            }];
        }
        dispatch_group_notify(joinGroup, dispatch_get_main_queue(), ^{
            // [2.6.2] Wire network publishing if room is connected
            [weakSelf.mediaWiring wireNetworkPublish];
            // Seed the self-tile mic/cam badges from the now-accurate device state
            // (parity with the normal-call path — the capture flags are only true
            // after start + join-time mute settles).
            [weakSelf.mediaWiring refreshLocalMediaStateInRoster];

            // [Mic preference] Apply the candidate's selected mic to LiveKit's native
            // capture (parity with the normal path); otherwise LiveKit uses the system
            // default at join. No-op when the preferred device already IS the default.
            NSString *prefMicID = [weakSelf.localMediaController selectedAudioInputDeviceID];
            if (prefMicID.length > 0) {
                NSString *prefMicName = [AVCaptureDevice deviceWithUniqueID:prefMicID].localizedName;
                [weakSelf.roomController setNetworkAudioInputWithDeviceID:prefMicID name:prefMicName completion:nil];
            }
            [weakSelf refreshSecureAudioInputOptions];
        });
    }];

    // [B1] Create and wire shared media wiring controller
    self.mediaWiring = [[InterMediaWiringController alloc] init];
    self.mediaWiring.roomController = self.roomController;
    self.mediaWiring.mediaController = self.localMediaController;
    self.mediaWiring.controlPanel = self.controlPanel;
    self.mediaWiring.remoteLayout = self.remoteLayout;
    self.mediaWiring.networkStatusView = self.networkStatusView;
    self.mediaWiring.surfaceShareController = self.surfaceShareController;
    self.mediaWiring.mediaStateSummaryBlock = ^NSString *{
        return [weakSelf secureMediaStateSummary];
    };
    [self.mediaWiring setupRoomControllerKVO];

    // [3.3.1] Wire remote rendering
    [self wireSecureRemoteRendering];
}

// PRESENCE MONITORING (provisional, server flag default OFF).
// Build the coordinator and hand it the session it must NOT reconfigure. Runs on
// the media controller's sessionQueue, reached from the one guard in
// -startLocalMediaFlow. The coordinator adds and removes only its own
// AVCaptureVideoDataOutput, never calls startRunning/stopRunning, never touches
// an input or a LiveKit track, and does NOT co-opt
// InterLocalMediaController.recordingFrameObserver (owned by
// InterRecordingCoordinator — taking it would break local recording's camera PiP).
// Delete this method with the block that calls it.
- (void)startPresenceMonitoringWithSession:(AVCaptureSession *)session
                                     queue:(dispatch_queue_t)queue
                                     media:(InterLocalMediaController *)media {
    InterRoomController *rc = self.roomController;
    if (!rc || !session || !queue || !media) { return; }
    if (self.presenceCoordinator) { return; }

    InterPresenceCoordinator *coordinator =
        [[InterPresenceCoordinator alloc] initWithThresholdsJSON:rc.activePresenceThresholds ?: @""];

    // The coordinator is the SINGLE writer of the chip state from here on
    // (0 absent · 1 on · 2 off · 3 paused — camera off).
    __weak typeof(self) weakSelf = self;
    coordinator.monitoringStateHandler = ^(NSInteger state) {
        [weakSelf setPresenceMonitoringState:state];
    };
    // Read-only view of the camera switch. `isCameraEnabled` is atomic, and the
    // strong capture keeps the controller alive for the block's lifetime; the
    // coordinator never mutes, unmutes or reconfigures anything.
    coordinator.cameraEnabledProvider = ^BOOL{
        return media.isCameraEnabled;
    };

    self.presenceCoordinator = coordinator;

    [coordinator startWithCaptureSession:session
                           sessionQueue:queue
                           tokenService:rc.tokenService
                              serverURL:rc.tokenServerURL ?: @""
                               roomCode:rc.roomCode ?: @""
                               identity:rc.localParticipantIdentity ?: @""
                   multipleFacesEnabled:rc.activePresenceMultipleFacesEnabled
                        detectorVersion:rc.activePresenceDetectorVersion ?: @""];
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
    NSString *selectedDeviceID = [self.localMediaController selectedAudioInputDeviceID];
    [self.controlPanel setAudioInputOptions:options selectedDeviceID:selectedDeviceID];
}

// Maps an interview tool kind to its centralized InterFeatureGate feature entry.
// Tier literals live ONLY in InterFeatureGate / token-server tiers.js — never here.
- (InterFeature)featureForToolKind:(InterInterviewToolKind)toolKind {
    switch (toolKind) {
        case InterInterviewToolKindWhiteboard:
            return InterFeatureCollaborativeWhiteboard;
        case InterInterviewToolKindCodeEditor:
        default:
            return InterFeatureCollaborativeCodeEditor;
    }
}

// Entitlement check for a collaborative interview tool (R7.2, R9.1, R9.2).
//
// Tool availability is keyed on the ROOM CREATOR's tier, delivered as the
// server-signed, unforgeable `tools` flag in the LOCAL participant's JWT
// metadata (derived from the room's snapshotted hostTier — see token-server
// `toolsEntitlement(hostTier)`). Whoever created the room defines tool
// availability for EVERYONE in it: a candidate — even anonymous or on a lower
// plan — is entitled exactly when the room's host tier grants it. This is the
// design that also lets the tools later appear in NORMAL meetings, where the
// `tools` flag distinguishes a pro-created from a hiring-created room.
//
// We therefore gate SOLELY on the server-signed flag (read only from our OWN
// participant, never a peer — R9.5) and DO NOT additionally check the local
// participant's own tier. The local tier is NOT the entitlement basis; checking
// it wrongly blocked legitimate candidates (e.g. an anonymous candidate, whose
// tier resolves to "free", in a hiring host's room). The JWT flag is the
// security boundary — it is server-signed and cannot be forged by a patched
// client (which could bypass any client-side tier check anyway). Per-tier
// availability is enforced where the LOCAL tier genuinely IS the basis — a host
// CREATING/hosting an interview — via InterFeatureGate at that call site.
- (BOOL)isCollaborativeToolEntitled:(InterInterviewToolKind)toolKind {
    if (toolKind == InterInterviewToolKindNone) {
        return YES;  // clearing the tool is never gated
    }

    return self.roomController.localParticipantHasToolsEntitlement;
}

- (void)handleInterviewToolSelection:(InterInterviewToolKind)toolKind {
    if (!self.stageView || !self.controlPanel) {
        return;
    }

    // Tier + server-entitlement gate for the collaborative interview tools
    // (R7.1, R7.5, R9.2, R9.5). Selecting a real tool is enabled only when BOTH
    // the LOCAL participant's server-signed `tools` JWT-metadata flag is true AND
    // the centralized InterFeatureGate tier check passes. We never trust a
    // peer-reported entitlement. Selecting "None" just clears and is never gated.
    if (toolKind != InterInterviewToolKindNone &&
        ![self isCollaborativeToolEntitled:toolKind]) {
        InterFeature feature = [self featureForToolKind:toolKind];
        NSString *minTier = [InterFeatureGate minimumTierForFeature:feature];
        NSString *displayName = [InterFeatureGate displayNameForFeature:feature];
        // Keep the currently active surface intact (never blank it) and reflect
        // the unchanged selection back into the chrome, plus a clear in-app
        // indication of the required tier (R7.1).
        [self.controlPanel setSelectedInterviewToolKind:self.stageView.activeToolKind];
        [self.controlPanel setShareStatusText:
            [NSString stringWithFormat:@"%@ requires the %@ plan.", displayName, minTier]];
        return;
    }

    [self.stageView setActiveToolKind:toolKind];
    [self.controlPanel setSelectedInterviewToolKind:toolKind];

    if (self.surfaceShareController.isSharing && toolKind == InterInterviewToolKindNone) {
        // Keep the share pipeline alive — the user is just switching away from
        // the tool view, not ending the share session. The share button remains
        // the authoritative toggle for starting/stopping the share.
        [self.controlPanel setShareStatusText:@"Sharing is paused — select a tool to resume."];
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

    // While connected, re-point LiveKit's native capture instead of reconfiguring the
    // shared AVCaptureSession (which would momentarily interrupt video). Parity with the
    // normal-call path. Pre-connect, reconfigure the capture session as before.
    InterRoomController *rc = self.roomController;
    if (rc && rc.connectionState == InterRoomConnectionStateConnected) {
        [self.localMediaController storePreferredAudioDeviceID:deviceID];
        NSString *deviceName = nil;
        if (deviceID.length > 0) {
            deviceName = [AVCaptureDevice deviceWithUniqueID:deviceID].localizedName;
        }
        // [NW1] The switch now runs off-main on the room controller's serial ADM queue;
        // the completion is delivered back on the main thread, so updating the panel and
        // refreshing the menu here is main-thread safe.
        __weak typeof(self) weakSelf = self;
        [rc setNetworkAudioInputWithDeviceID:deviceID name:deviceName completion:^(BOOL switched) {
            if (!switched) {
                [weakSelf.controlPanel setMediaStatusText:@"Couldn't switch microphone for the call."];
            }
            [weakSelf refreshSecureAudioInputOptions];
        }];
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
        [self.surfaceShareController stopSharingFromSurfaceView:nil];
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

    [self.surfaceShareController startSharingFromSurfaceView:nil];
    [self.controlPanel setShareStartPending:self.surfaceShareController.isStartPending];
    [self.controlPanel setSharingEnabled:self.surfaceShareController.isSharing];
    // Don't optimistically read isSharing here — it may be YES momentarily
    // before an async permission error resets it. The statusHandler will
    // sync the button state when the capture actually succeeds or fails.
}

#pragma mark - Network Wiring [2.6]

// [B1] twoPhaseToggleCamera, twoPhaseToggleMicrophone, wireSecureNetworkPublish,
// wireNetworkSinkOnSurfaceShareController:,
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
    // [B5] Parity with AppDelegate.wireNormalRemoteRendering: subscriber.attach() ran pre-connect
    // with an empty remoteParticipants set, and LiveKit fires no participantDidConnect for
    // participants already in the room, so the trackRenderer didSet only resyncs an empty roster.
    // Reseed now so a host already present (camera on OR off) is seeded into the roster and its
    // tile appears immediately on candidate join. reseedPresence is @objc and idempotent.
    [rc.subscriber reseedPresence];

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

// [Phase 8.1.5] Chat panel implemented: floating NSPanel overlay above secure window.
// Wire chatController by setting .chatController before createSecureWindow.

#pragma mark - InterChatControllerDelegate

- (void)chatController:(InterChatController *)controller
      didReceiveMessage:(InterChatMessageInfo *)message {
    [self.secureChatPanel appendMessage:message];
    if (!self.chatOverlayWindow.isVisible) {
        NSInteger unread = controller.unreadCount;
        [self.secureChatPanel setUnreadBadge:unread];
        // Badge on the top-bar chat button signals unread messages.
        [self.controlPanel setChatUnread:unread];
    }
}

- (void)chatController:(InterChatController *)controller
   didUpdateUnreadCount:(NSInteger)count {
    if (!self.chatOverlayWindow.isVisible) {
        [self.secureChatPanel setUnreadBadge:count];
        [self.controlPanel setChatUnread:count];
    }
}

#pragma mark - InterChatPanelDelegate (secure mode)

- (void)chatPanel:(InterChatPanel *)panel didSubmitMessage:(NSString *)text {
#pragma unused(panel)
    [self.chatController sendPublicMessage:text];
}

- (void)chatPanelDidRequestExport:(InterChatPanel *)panel {
#pragma unused(panel)
    // Export not available inside the secure kiosk — silently ignore.
}

- (void)chatPanel:(InterChatPanel *)panel didSelectRecipient:(NSString *)recipientIdentity {
#pragma unused(panel, recipientIdentity)
    // DM selection not supported in secure mode (single-channel chat only).
}

- (void)chatPanelDidRequestFileAttach:(InterChatPanel *)panel {
#pragma unused(panel)
    // File uploads from secure (interviewee kiosk) mode are not permitted —
    // the kiosk has restricted file-system access and no token server credentials.
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText   = @"File Sharing Unavailable";
    alert.informativeText = @"File sharing is not available in secure interview mode.";
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.chatOverlayWindow ?: [NSApp keyWindow]
                  completionHandler:nil];
}

- (void)chatPanel:(InterChatPanel *)panel didRequestDownloadFileMessage:(InterChatMessageInfo *)message {
#pragma unused(panel)
    // Files shared by the interviewer (who is in normal mode and has credentials) can
    // be downloaded by the interviewee. The interviewee has no leaveToken — so they
    // cannot authenticate against the server's download endpoint. Show a notice.
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText   = @"File Download Unavailable";
    NSString *fname = message.fileName.length > 0 ? message.fileName : @"file";
    alert.informativeText = [NSString stringWithFormat:
        @"\"%@\" was shared by the interviewer but cannot be downloaded during a secure session.",
        fname];
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.chatOverlayWindow ?: [NSApp keyWindow]
                  completionHandler:nil];
}

@end
