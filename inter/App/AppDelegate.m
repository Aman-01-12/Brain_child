#import "AppDelegate.h"
#import "CapWindow.h"
#import "InterLocalMediaController.h"
#import "InterLocalCallControlPanel.h"
#import "InterSurfaceShareController.h"
#import "MetalSurfaceView.h"
#import "SecureWindowController.h"

@interface AppDelegate () <NSWindowDelegate>
@property (nonatomic, strong) NSMutableArray<CapWindow *> *capWindows;
@property (nonatomic, strong) SecureWindowController *secureController;
@property (nonatomic, strong) NSWindow *setupWindow;
@property (nonatomic, strong) MetalSurfaceView *setupRenderView;
@property (nonatomic, strong) NSWindow *normalCallWindow;
@property (nonatomic, strong) MetalSurfaceView *normalRenderView;
@property (nonatomic, strong) InterLocalMediaController *normalMediaController;
@property (nonatomic, strong) InterSurfaceShareController *normalSurfaceShareController;
@property (nonatomic, strong) InterLocalCallControlPanel *normalControlPanel;
@property (nonatomic, assign, readwrite) InterCallMode currentCallMode;
@property (nonatomic, assign, readwrite) InterInterviewRole currentInterviewRole;
@property (nonatomic, assign) BOOL isScreenObserverRegistered;
@property (nonatomic, assign) BOOL isShowingExternalDisplayAlert;
@property (nonatomic, assign) BOOL isExitingCurrentMode;
@property (nonatomic, weak) NSWindow *fullScreenExitPendingWindow;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.currentCallMode = InterCallModeNone;
    self.currentInterviewRole = InterInterviewRoleNone;
    [self launchSetupUI];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
#pragma unused(notification)
    [self stopScreenMonitoring];

    if (self.fullScreenExitPendingWindow) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSWindowDidExitFullScreenNotification
                                                      object:self.fullScreenExitPendingWindow];
        self.fullScreenExitPendingWindow = nil;
    }
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
    if (self.currentCallMode == InterCallModeNone || self.isExitingCurrentMode) {
        return;
    }

    self.isExitingCurrentMode = YES;

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
            if (!strongSelf || !strongSelf.isExitingCurrentMode) {
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
    if (isIntervieweeMode && [NSScreen screens].count > 1) {
        [self showExternalDisplayAlert];
        return;
    }

    [self teardownActiveWindows];
    [self.setupWindow orderOut:nil];
    [self.setupRenderView removeFromSuperview];
    self.setupRenderView = nil;
    self.setupWindow = nil;

    self.currentCallMode = mode;
    self.currentInterviewRole = role;

    if (isIntervieweeMode) {
        [self applyKioskRestrictions];
        [self startScreenMonitoring];
        self.secureController = [[SecureWindowController alloc] init];
        [self.secureController createSecureWindow];
        return;
    }

    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
    [self stopScreenMonitoring];
    [self launchNormalCallWindow];
}

#pragma mark - UI

- (void)launchSetupUI {
    if (self.setupWindow != nil) {
        [self.setupWindow orderOut:nil];
        [self.setupRenderView removeFromSuperview];
        self.setupRenderView = nil;
        self.setupWindow = nil;
    }

    self.setupWindow =
    [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 620, 430)
                                styleMask:(NSWindowStyleMaskTitled |
                                           NSWindowStyleMaskClosable)
                                  backing:NSBackingStoreBuffered
                                    defer:NO];

    [self.setupWindow center];
    [self.setupWindow setTitle:@"Secure Call Setup"];
    [self.setupWindow setSharingType:NSWindowSharingNone];
    [self.setupWindow setDelegate:self];

    NSView *view = [[NSView alloc] initWithFrame:self.setupWindow.contentView.bounds];
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

    NSView *panelView = [[NSView alloc] initWithFrame:NSMakeRect(120, 106, 380, 250)];
    panelView.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [panelView setWantsLayer:YES];
    panelView.layer.backgroundColor = [[NSColor colorWithWhite:0.08 alpha:0.60] CGColor];
    panelView.layer.cornerRadius = 16.0;
    panelView.layer.borderWidth = 1.0;
    panelView.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.12] CGColor];
    [overlayView addSubview:panelView];

    NSTextField *headline = [NSTextField labelWithString:@"Choose how you want to continue"];
    headline.frame = NSMakeRect(20, 200, 340, 30);
    headline.alignment = NSTextAlignmentCenter;
    headline.font = [NSFont boldSystemFontOfSize:16];
    headline.textColor = [NSColor colorWithWhite:0.95 alpha:1.0];
    [panelView addSubview:headline];

    NSButton *normalCallButton = [[NSButton alloc] initWithFrame:NSMakeRect(80, 132, 220, 44)];
    [normalCallButton setTitle:@"Start Normal Call"];
    [normalCallButton setTarget:self];
    [normalCallButton setAction:@selector(startNormalCallMode)];
    [panelView addSubview:normalCallButton];

    NSButton *createInterviewButton = [[NSButton alloc] initWithFrame:NSMakeRect(80, 76, 220, 44)];
    [createInterviewButton setTitle:@"Create Interview"];
    [createInterviewButton setTarget:self];
    [createInterviewButton setAction:@selector(createInterviewAsInterviewer)];
    [panelView addSubview:createInterviewButton];

    NSButton *joinInterviewButton = [[NSButton alloc] initWithFrame:NSMakeRect(80, 20, 220, 44)];
    [joinInterviewButton setTitle:@"Join Interview"];
    [joinInterviewButton setTarget:self];
    [joinInterviewButton setAction:@selector(joinInterviewAsInterviewee)];
    [panelView addSubview:joinInterviewButton];
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

    self.normalRenderView = [[MetalSurfaceView alloc] initWithFrame:view.bounds];
    self.normalRenderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.normalRenderView];

    [self attachNormalCallControlsInView:view];
    [self startNormalLocalMediaFlow];

    [self.normalControlPanel setCameraEnabled:self.normalMediaController.isCameraEnabled];
    [self.normalControlPanel setMicrophoneEnabled:self.normalMediaController.isMicrophoneEnabled];
    [self.normalControlPanel setSharingEnabled:self.normalSurfaceShareController.isSharing];

    [self.normalControlPanel setShareStatusText:@"Secure surface share is off."];

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
                                   410.0);
    self.normalControlPanel = [[InterLocalCallControlPanel alloc] initWithFrame:panelFrame];
    self.normalControlPanel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self.normalControlPanel setPanelTitleText:@"Normal Call Controls"];
    [view addSubview:self.normalControlPanel];

    __weak typeof(self) weakSelf = self;
    self.normalControlPanel.cameraToggleHandler = ^{
        [weakSelf toggleNormalCamera];
    };
    self.normalControlPanel.microphoneToggleHandler = ^{
        [weakSelf toggleNormalMicrophone];
    };
    self.normalControlPanel.shareToggleHandler = ^{
        [weakSelf toggleNormalSurfaceShare];
    };
}

- (void)startNormalLocalMediaFlow {
    self.normalMediaController = [[InterLocalMediaController alloc] init];
    self.normalSurfaceShareController = [[InterSurfaceShareController alloc] init];

    __weak typeof(self) weakSelf = self;
    self.normalSurfaceShareController.statusHandler = ^(NSString *statusText) {
        [weakSelf.normalControlPanel setShareStatusText:statusText];
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
    }];
}

- (NSString *)normalMediaStateSummary {
    BOOL cameraOn = self.normalMediaController.isCameraEnabled;
    BOOL microphoneOn = self.normalMediaController.isMicrophoneEnabled;
    return [NSString stringWithFormat:@"Camera %@, Mic %@.",
            cameraOn ? @"on" : @"off",
            microphoneOn ? @"on" : @"off"];
}

- (void)toggleNormalCamera {
    BOOL shouldEnable = !self.normalMediaController.isCameraEnabled;
    __weak typeof(self) weakSelf = self;
    [self.normalMediaController setCameraEnabled:shouldEnable completion:^(BOOL success) {
        if (!success) {
            [weakSelf.normalControlPanel setMediaStatusText:@"Unable to change camera state."];
            return;
        }

        [weakSelf.normalControlPanel setCameraEnabled:weakSelf.normalMediaController.isCameraEnabled];
        [weakSelf.normalControlPanel setMediaStatusText:[weakSelf normalMediaStateSummary]];
    }];
}

- (void)toggleNormalMicrophone {
    BOOL shouldEnable = !self.normalMediaController.isMicrophoneEnabled;
    __weak typeof(self) weakSelf = self;
    [self.normalMediaController setMicrophoneEnabled:shouldEnable completion:^(BOOL success) {
        if (!success) {
            [weakSelf.normalControlPanel setMediaStatusText:@"Unable to change microphone state."];
            return;
        }

        [weakSelf.normalControlPanel setMicrophoneEnabled:weakSelf.normalMediaController.isMicrophoneEnabled];
        [weakSelf.normalControlPanel setMediaStatusText:[weakSelf normalMediaStateSummary]];
    }];
}

- (void)toggleNormalSurfaceShare {
    if (!self.normalRenderView) {
        return;
    }

    if (self.normalSurfaceShareController.isSharing) {
        [self.normalSurfaceShareController stopSharingFromSurfaceView:self.normalRenderView];
        [self.normalControlPanel setSharingEnabled:NO];
        return;
    }

    [self.normalSurfaceShareController startSharingFromSurfaceView:self.normalRenderView];
    [self.normalControlPanel setSharingEnabled:YES];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender == self.setupWindow && self.currentCallMode == InterCallModeNone) {
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
    }

    [self.normalSurfaceShareController stopSharingFromSurfaceView:self.normalRenderView];
    self.normalSurfaceShareController = nil;

    [self.normalMediaController shutdown];
    self.normalMediaController = nil;
    self.normalControlPanel = nil;

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
    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
    [self stopScreenMonitoring];
    self.isShowingExternalDisplayAlert = NO;

    [self teardownActiveWindows];

    self.currentCallMode = InterCallModeNone;
    self.currentInterviewRole = InterInterviewRoleNone;
    [self launchSetupUI];

    self.isExitingCurrentMode = NO;
}

#pragma mark - Screen Monitoring

- (void)startScreenMonitoring {
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
