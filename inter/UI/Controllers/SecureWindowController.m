#import "SecureWindowController.h"
#import "InterLocalCallControlPanel.h"
#import "InterLocalMediaController.h"
#import "InterSurfaceShareController.h"
#import "MetalSurfaceView.h"
#import "SecureWindow.h"


@interface SecureWindowController ()
@property (nonatomic, strong) MetalSurfaceView *renderView;
@property (nonatomic, strong) InterLocalCallControlPanel *controlPanel;
@property (nonatomic, strong) InterLocalMediaController *localMediaController;
@property (nonatomic, strong) InterSurfaceShareController *surfaceShareController;
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
    [self.secureWindow setBackgroundColor:[NSColor grayColor]];
    [self.secureWindow setSharingType:NSWindowSharingNone];
    [self.secureWindow setMovable:NO];
    [self.secureWindow setReleasedWhenClosed:NO];
    [self.secureWindow setHidesOnDeactivate:NO];

    NSRect contentFrame = NSMakeRect(0, 0, screen.frame.size.width, screen.frame.size.height);
    NSView *view = [[NSView alloc] initWithFrame:contentFrame];
    [view setWantsLayer:YES];
    [self.secureWindow setContentView:view];

    self.renderView = [[MetalSurfaceView alloc] initWithFrame:view.bounds];
    self.renderView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.renderView];

    NSTextField *headline = [NSTextField labelWithString:@"Interview secure surface (Metal)"];
    headline.frame = NSMakeRect(40, view.bounds.size.height - 52, 460, 24);
    headline.font = [NSFont boldSystemFontOfSize:15];
    headline.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    headline.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [view addSubview:headline];

    [self attachControlPanelInView:view];
    [self startLocalMediaFlow];

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

- (void)destroySecureWindow {
    if (self.controlPanel) {
        self.controlPanel.cameraToggleHandler = nil;
        self.controlPanel.microphoneToggleHandler = nil;
        self.controlPanel.shareToggleHandler = nil;
        self.controlPanel.shareModeChangedHandler = nil;
    }

    [self.surfaceShareController stopSharingFromSurfaceView:self.renderView];
    self.surfaceShareController = nil;

    [self.localMediaController shutdown];
    self.localMediaController = nil;

    self.controlPanel = nil;

    [self.renderView removeFromSuperview];
    self.renderView = nil;

    [self.secureWindow orderOut:nil];
    self.secureWindow = nil;
    self.exitSessionHandler = nil;
}

#pragma mark - Controls

- (void)attachControlPanelInView:(NSView *)view {
    NSRect panelFrame = NSMakeRect(view.bounds.size.width - 312.0,
                                   26.0,
                                   278.0,
                                   410.0);
    self.controlPanel = [[InterLocalCallControlPanel alloc] initWithFrame:panelFrame];
    self.controlPanel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self.controlPanel setPanelTitleText:@"Interview Controls"];
    [self.controlPanel setShareModeSelectorHidden:YES];
    [self.controlPanel setShareMode:InterShareModeThisApp];
    [self.controlPanel setShareStatusText:@"Secure surface share is off."];
    [view addSubview:self.controlPanel];

    __weak typeof(self) weakSelf = self;
    self.controlPanel.cameraToggleHandler = ^{
        [weakSelf toggleCamera];
    };
    self.controlPanel.microphoneToggleHandler = ^{
        [weakSelf toggleMicrophone];
    };
    self.controlPanel.shareToggleHandler = ^{
        [weakSelf toggleSurfaceShare];
    };
}

- (void)startLocalMediaFlow {
    self.localMediaController = [[InterLocalMediaController alloc] init];
    self.surfaceShareController = [[InterSurfaceShareController alloc] init];
    [self.surfaceShareController configureWithSessionKind:InterShareSessionKindInterview
                                                shareMode:InterShareModeThisApp
                                         recordingEnabled:YES];

    __weak typeof(self) weakSelf = self;
    self.surfaceShareController.statusHandler = ^(NSString *statusText) {
        [weakSelf.controlPanel setShareStatusText:statusText];
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
    }];
}

- (NSString *)secureMediaStateSummary {
    BOOL cameraOn = self.localMediaController.isCameraEnabled;
    BOOL microphoneOn = self.localMediaController.isMicrophoneEnabled;
    return [NSString stringWithFormat:@"Camera %@, Mic %@.",
            cameraOn ? @"on" : @"off",
            microphoneOn ? @"on" : @"off"];
}

- (void)toggleCamera {
    BOOL shouldEnable = !self.localMediaController.isCameraEnabled;
    __weak typeof(self) weakSelf = self;
    [self.localMediaController setCameraEnabled:shouldEnable completion:^(BOOL success) {
        if (!success) {
            [weakSelf.controlPanel setMediaStatusText:@"Unable to change camera state."];
            return;
        }

        [weakSelf.controlPanel setCameraEnabled:weakSelf.localMediaController.isCameraEnabled];
        [weakSelf.controlPanel setMediaStatusText:[weakSelf secureMediaStateSummary]];
    }];
}

- (void)toggleMicrophone {
    BOOL shouldEnable = !self.localMediaController.isMicrophoneEnabled;
    __weak typeof(self) weakSelf = self;
    [self.localMediaController setMicrophoneEnabled:shouldEnable completion:^(BOOL success) {
        if (!success) {
            [weakSelf.controlPanel setMediaStatusText:@"Unable to change microphone state."];
            return;
        }

        [weakSelf.controlPanel setMicrophoneEnabled:weakSelf.localMediaController.isMicrophoneEnabled];
        [weakSelf.controlPanel setMediaStatusText:[weakSelf secureMediaStateSummary]];
    }];
}

- (void)toggleSurfaceShare {
    if (!self.renderView) {
        return;
    }

    if (self.surfaceShareController.isSharing) {
        [self.surfaceShareController stopSharingFromSurfaceView:self.renderView];
        [self.controlPanel setSharingEnabled:self.surfaceShareController.isSharing];
        return;
    }

    [self.surfaceShareController startSharingFromSurfaceView:self.renderView];
    [self.controlPanel setSharingEnabled:self.surfaceShareController.isSharing];
}

@end
