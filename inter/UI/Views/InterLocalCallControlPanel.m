#import "InterLocalCallControlPanel.h"

@interface InterLocalCallControlPanel ()
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *connectionStatusLabel;
@property (nonatomic, strong) NSTextField *roomCodeLabel;
@property (nonatomic, strong) NSTextField *mediaStatusLabel;
@property (nonatomic, strong) NSTextField *shareStatusLabel;
@property (nonatomic, strong) NSTextField *shareModeLabel;
@property (nonatomic, strong) NSTextField *interviewToolLabel;
@property (nonatomic, strong) NSTextField *audioInputLabel;
@property (nonatomic, strong) NSButton *cameraButton;
@property (nonatomic, strong) NSButton *microphoneButton;
@property (nonatomic, strong) NSButton *shareButton;
@property (nonatomic, strong) NSPopUpButton *shareModePopUpButton;
@property (nonatomic, strong) NSSegmentedControl *interviewToolSegmentedControl;
@property (nonatomic, strong) NSPopUpButton *audioInputPopUpButton;
@property (nonatomic, strong) NSButton *shareSystemAudioButton;
@property (nonatomic, strong, readwrite) NSView *previewContainerView;
@property (nonatomic, strong, readwrite) NSView *networkStatusContainerView;
@property (nonatomic, assign) BOOL suppressAudioInputCallback;
@property (nonatomic, assign) BOOL shareButtonActive;
@property (nonatomic, assign) BOOL shareButtonStartPending;
@end

@implementation InterLocalCallControlPanel

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    [self configurePanelUI];
    return self;
}

- (BOOL)isFlipped {
    return NO;
}

- (void)configurePanelUI {
    self.wantsLayer = YES;
    self.layer.cornerRadius = 14.0;
    self.layer.backgroundColor = [[NSColor colorWithWhite:0.05 alpha:0.65] CGColor];
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.12] CGColor];

    self.titleLabel = [NSTextField labelWithString:@"Local Media Controls"];
    self.titleLabel.frame = NSMakeRect(16, self.bounds.size.height - 38, self.bounds.size.width - 32, 22);
    self.titleLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.titleLabel.font = [NSFont boldSystemFontOfSize:14];
    self.titleLabel.textColor = [NSColor colorWithWhite:0.94 alpha:1.0];
    [self addSubview:self.titleLabel];

    // [3.4.1] Connection status label
    self.connectionStatusLabel = [NSTextField labelWithString:@""];
    self.connectionStatusLabel.frame = NSMakeRect(16, self.bounds.size.height - 56, self.bounds.size.width - 72, 14);
    self.connectionStatusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.connectionStatusLabel.font = [NSFont systemFontOfSize:10];
    self.connectionStatusLabel.textColor = [NSColor colorWithWhite:0.70 alpha:1.0];
    [self addSubview:self.connectionStatusLabel];

    // [3.4.4] Network status container (for signal bars view)
    self.networkStatusContainerView = [[NSView alloc] initWithFrame:NSMakeRect(self.bounds.size.width - 56, self.bounds.size.height - 56, 40, 16)];
    self.networkStatusContainerView.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self addSubview:self.networkStatusContainerView];

    // [3.4.2] Room code label (hidden by default)
    self.roomCodeLabel = [NSTextField labelWithString:@""];
    self.roomCodeLabel.frame = NSMakeRect(16, self.bounds.size.height - 72, self.bounds.size.width - 32, 14);
    self.roomCodeLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.roomCodeLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    self.roomCodeLabel.textColor = [NSColor systemGreenColor];
    self.roomCodeLabel.hidden = YES;
    [self addSubview:self.roomCodeLabel];

    self.previewContainerView = [[NSView alloc] initWithFrame:NSMakeRect(16,
                                                                          self.bounds.size.height - 200,
                                                                          self.bounds.size.width - 32,
                                                                          140)];
    self.previewContainerView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.previewContainerView.wantsLayer = YES;
    self.previewContainerView.layer.cornerRadius = 10.0;
    self.previewContainerView.layer.masksToBounds = YES;
    self.previewContainerView.layer.backgroundColor = [[NSColor colorWithWhite:0.12 alpha:0.85] CGColor];
    self.previewContainerView.layer.borderWidth = 1.0;
    self.previewContainerView.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.16] CGColor];
    [self addSubview:self.previewContainerView];

    self.mediaStatusLabel = [NSTextField labelWithString:@"Camera/mic not started."];
    self.mediaStatusLabel.frame = NSMakeRect(16, self.bounds.size.height - 226, self.bounds.size.width - 32, 18);
    self.mediaStatusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.mediaStatusLabel.font = [NSFont systemFontOfSize:11];
    self.mediaStatusLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    [self addSubview:self.mediaStatusLabel];

    self.shareStatusLabel = [NSTextField labelWithString:@"Secure surface share is off."];
    self.shareStatusLabel.frame = NSMakeRect(16, self.bounds.size.height - 246, self.bounds.size.width - 32, 18);
    self.shareStatusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.shareStatusLabel.font = [NSFont systemFontOfSize:11];
    self.shareStatusLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    [self addSubview:self.shareStatusLabel];

    self.audioInputLabel = [NSTextField labelWithString:@"Microphone Source"];
    self.audioInputLabel.frame = NSMakeRect(16, 196, self.bounds.size.width - 32, 16);
    self.audioInputLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    self.audioInputLabel.font = [NSFont systemFontOfSize:11];
    self.audioInputLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    [self addSubview:self.audioInputLabel];

    self.audioInputPopUpButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(16, 166, self.bounds.size.width - 32, 26)
                                                             pullsDown:NO];
    self.audioInputPopUpButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.audioInputPopUpButton setTarget:self];
    [self.audioInputPopUpButton setAction:@selector(handleAudioInputChange:)];
    [self addSubview:self.audioInputPopUpButton];

    self.shareModeLabel = [NSTextField labelWithString:@"Share Source"];
    self.shareModeLabel.frame = NSMakeRect(16, 146, 120, 18);
    self.shareModeLabel.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    self.shareModeLabel.font = [NSFont systemFontOfSize:11];
    self.shareModeLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    [self addSubview:self.shareModeLabel];

    self.shareModePopUpButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(16, 118, self.bounds.size.width - 32, 26)
                                                            pullsDown:NO];
    self.shareModePopUpButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.shareModePopUpButton addItemWithTitle:@"Share This App"];
    [self.shareModePopUpButton addItemWithTitle:@"Share Window"];
    [self.shareModePopUpButton addItemWithTitle:@"Share Entire Screen"];
    [self.shareModePopUpButton setTarget:self];
    [self.shareModePopUpButton setAction:@selector(handleShareModeChange:)];

    [self.shareModePopUpButton.itemArray[0] setTag:InterShareModeThisApp];
    [self.shareModePopUpButton.itemArray[1] setTag:InterShareModeWindow];
    [self.shareModePopUpButton.itemArray[2] setTag:InterShareModeEntireScreen];

    [self addSubview:self.shareModePopUpButton];

    self.interviewToolLabel = [NSTextField labelWithString:@"Interview Tool"];
    self.interviewToolLabel.frame = NSMakeRect(16, 146, 140, 18);
    self.interviewToolLabel.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    self.interviewToolLabel.font = [NSFont systemFontOfSize:11];
    self.interviewToolLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    [self addSubview:self.interviewToolLabel];

    self.interviewToolSegmentedControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(16, 118, self.bounds.size.width - 32, 26)];
    self.interviewToolSegmentedControl.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    self.interviewToolSegmentedControl.segmentCount = 3;
    [self.interviewToolSegmentedControl setLabel:@"Off" forSegment:0];
    [self.interviewToolSegmentedControl setLabel:@"Code" forSegment:1];
    [self.interviewToolSegmentedControl setLabel:@"Board" forSegment:2];
    self.interviewToolSegmentedControl.trackingMode = NSSegmentSwitchTrackingSelectOne;
    [self.interviewToolSegmentedControl setTarget:self];
    [self.interviewToolSegmentedControl setAction:@selector(handleInterviewToolSelection:)];
    [self addSubview:self.interviewToolSegmentedControl];

    self.shareSystemAudioButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 4, self.bounds.size.width - 32, 18)];
    self.shareSystemAudioButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    self.shareSystemAudioButton.buttonType = NSButtonTypeSwitch;
    self.shareSystemAudioButton.title = @"Share System Audio";
    self.shareSystemAudioButton.state = NSControlStateValueOff;
    [self.shareSystemAudioButton setTarget:self];
    [self.shareSystemAudioButton setAction:@selector(handleShareSystemAudioToggle:)];
    [self addSubview:self.shareSystemAudioButton];

    self.cameraButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 86, self.bounds.size.width - 32, 30)];
    self.cameraButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.cameraButton setTitle:@"Turn Camera On"];
    [self.cameraButton setTarget:self];
    [self.cameraButton setAction:@selector(handleCameraToggle:)];
    [self addSubview:self.cameraButton];

    self.microphoneButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 54, self.bounds.size.width - 32, 30)];
    self.microphoneButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.microphoneButton setTitle:@"Turn Mic On"];
    [self.microphoneButton setTarget:self];
    [self.microphoneButton setAction:@selector(handleMicrophoneToggle:)];
    [self addSubview:self.microphoneButton];

    self.shareButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 22, self.bounds.size.width - 32, 30)];
    self.shareButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.shareButton setTitle:@"Start Surface Share"];
    [self.shareButton setTarget:self];
    [self.shareButton setAction:@selector(handleShareToggle:)];
    [self addSubview:self.shareButton];

    [self setShareMode:InterShareModeThisApp];
    [self setSelectedInterviewToolKind:InterInterviewToolKindNone];
    [self setInterviewToolSelectorHidden:YES];
    [self updateShareButtonPresentation];
}

- (void)setPanelTitleText:(NSString *)title {
    self.titleLabel.stringValue = title ?: @"Local Media Controls";
}

// [3.4.1] Connection status text
- (void)setConnectionStatusText:(NSString *)text {
    self.connectionStatusLabel.stringValue = text ?: @"";
}

// [3.4.2] Room code display
- (void)setRoomCodeText:(NSString *)code {
    if (code.length > 0) {
        self.roomCodeLabel.stringValue = [NSString stringWithFormat:@"Room: %@", code];
        self.roomCodeLabel.hidden = NO;
    } else {
        self.roomCodeLabel.stringValue = @"";
        self.roomCodeLabel.hidden = YES;
    }
}

- (void)setCameraEnabled:(BOOL)enabled {
    self.cameraButton.title = enabled ? @"Turn Camera Off" : @"Turn Camera On";
}

- (void)setMicrophoneEnabled:(BOOL)enabled {
    self.microphoneButton.title = enabled ? @"Turn Mic Off" : @"Turn Mic On";
}

- (void)setSharingEnabled:(BOOL)enabled {
    if (self.shareButtonActive == enabled) {
        return;
    }

    self.shareButtonActive = enabled;
    [self updateShareButtonPresentation];
}

- (void)setShareStartPending:(BOOL)pending {
    if (self.shareButtonStartPending == pending) {
        return;
    }

    // Keep the public API separate from the private storage to avoid
    // accidentally recursing back into this setter.
    self.shareButtonStartPending = pending;
    [self updateShareButtonPresentation];
}

- (void)setMediaStatusText:(NSString *)text {
    self.mediaStatusLabel.stringValue = text ?: @"";
}

- (void)setShareStatusText:(NSString *)text {
    self.shareStatusLabel.stringValue = text ?: @"";
}

- (void)setShareMode:(InterShareMode)shareMode {
    NSMenuItem *item = [self shareModeMenuItemForMode:shareMode];
    if (item) {
        [self.shareModePopUpButton selectItem:item];
    }
}

- (InterShareMode)selectedShareMode {
    NSMenuItem *selectedItem = self.shareModePopUpButton.selectedItem;
    if (!selectedItem) {
        return InterShareModeThisApp;
    }

    return (InterShareMode)selectedItem.tag;
}

- (void)setShareModeOptionEnabled:(BOOL)enabled forMode:(InterShareMode)shareMode {
    NSMenuItem *item = [self shareModeMenuItemForMode:shareMode];
    if (!item) {
        return;
    }

    item.enabled = enabled;
}

- (void)setShareModeSelectorHidden:(BOOL)hidden {
    self.shareModeLabel.hidden = hidden;
    self.shareModePopUpButton.hidden = hidden;
}

- (void)setShareSystemAudioEnabled:(BOOL)enabled {
    self.shareSystemAudioButton.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)setShareSystemAudioToggleHidden:(BOOL)hidden {
    self.shareSystemAudioButton.hidden = hidden;
}

- (void)setInterviewToolSelectorHidden:(BOOL)hidden {
    self.interviewToolLabel.hidden = hidden;
    self.interviewToolSegmentedControl.hidden = hidden;
}

- (void)setSelectedInterviewToolKind:(InterInterviewToolKind)toolKind {
    NSInteger segment = 0;
    switch (toolKind) {
        case InterInterviewToolKindCodeEditor:
            segment = 1;
            break;
        case InterInterviewToolKindWhiteboard:
            segment = 2;
            break;
        case InterInterviewToolKindNone:
        default:
            segment = 0;
            break;
    }

    self.interviewToolSegmentedControl.selectedSegment = segment;
}

- (InterInterviewToolKind)selectedInterviewToolKind {
    switch (self.interviewToolSegmentedControl.selectedSegment) {
        case 1:
            return InterInterviewToolKindCodeEditor;
        case 2:
            return InterInterviewToolKindWhiteboard;
        case 0:
        default:
            return InterInterviewToolKindNone;
    }
}

- (void)setAudioInputOptions:(NSArray<NSDictionary<NSString *,NSString *> *> *)options
            selectedDeviceID:(NSString *)selectedDeviceID {
    self.suppressAudioInputCallback = YES;

    [self.audioInputPopUpButton removeAllItems];
    if (options.count == 0) {
        [self.audioInputPopUpButton addItemWithTitle:@"No microphone detected"];
        NSMenuItem *item = self.audioInputPopUpButton.itemArray.firstObject;
        item.enabled = NO;
        self.audioInputPopUpButton.enabled = NO;
        self.suppressAudioInputCallback = NO;
        return;
    }

    self.audioInputPopUpButton.enabled = YES;
    NSInteger selectedIndex = NSNotFound;
    NSInteger index = 0;
    for (NSDictionary<NSString *, NSString *> *entry in options) {
        NSString *name = entry[@"name"];
        NSString *deviceID = entry[@"id"];
        if (name.length == 0 || deviceID.length == 0) {
            continue;
        }

        [self.audioInputPopUpButton addItemWithTitle:name];
        NSMenuItem *item = self.audioInputPopUpButton.lastItem;
        item.representedObject = deviceID;
        if (selectedDeviceID.length > 0 && [selectedDeviceID isEqualToString:deviceID]) {
            selectedIndex = index;
        }
        index += 1;
    }

    if (self.audioInputPopUpButton.numberOfItems == 0) {
        [self.audioInputPopUpButton addItemWithTitle:@"No microphone detected"];
        NSMenuItem *item = self.audioInputPopUpButton.itemArray.firstObject;
        item.enabled = NO;
        self.audioInputPopUpButton.enabled = NO;
    } else if (selectedIndex != NSNotFound) {
        [self.audioInputPopUpButton selectItemAtIndex:selectedIndex];
    } else {
        [self.audioInputPopUpButton selectItemAtIndex:0];
    }

    self.suppressAudioInputCallback = NO;
}

- (void)handleCameraToggle:(id)sender {
#pragma unused(sender)
    dispatch_block_t handler = self.cameraToggleHandler;
    if (handler) {
        handler();
    }
}

- (void)handleMicrophoneToggle:(id)sender {
#pragma unused(sender)
    dispatch_block_t handler = self.microphoneToggleHandler;
    if (handler) {
        handler();
    }
}

- (void)handleShareToggle:(id)sender {
#pragma unused(sender)
    dispatch_block_t handler = self.shareToggleHandler;
    if (handler) {
        handler();
    }
}

- (void)handleShareModeChange:(id)sender {
#pragma unused(sender)
    void (^handler)(InterShareMode) = self.shareModeChangedHandler;
    if (!handler) {
        return;
    }

    handler([self selectedShareMode]);
}

- (void)handleAudioInputChange:(id)sender {
#pragma unused(sender)
    if (self.suppressAudioInputCallback) {
        return;
    }

    void (^handler)(NSString * _Nullable) = self.audioInputSelectionChangedHandler;
    if (!handler) {
        return;
    }

    NSMenuItem *selectedItem = self.audioInputPopUpButton.selectedItem;
    NSString *deviceID = [selectedItem.representedObject isKindOfClass:[NSString class]]
    ? (NSString *)selectedItem.representedObject
    : nil;
    handler(deviceID);
}

- (void)handleShareSystemAudioToggle:(id)sender {
#pragma unused(sender)
    void (^handler)(BOOL) = self.shareSystemAudioChangedHandler;
    if (!handler) {
        return;
    }

    BOOL enabled = self.shareSystemAudioButton.state == NSControlStateValueOn;
    handler(enabled);
}

- (void)handleInterviewToolSelection:(id)sender {
#pragma unused(sender)
    void (^handler)(InterInterviewToolKind) = self.interviewToolChangedHandler;
    if (!handler) {
        return;
    }

    handler([self selectedInterviewToolKind]);
}

- (NSMenuItem *)shareModeMenuItemForMode:(InterShareMode)shareMode {
    for (NSMenuItem *item in self.shareModePopUpButton.itemArray) {
        if (item.tag == (NSInteger)shareMode) {
            return item;
        }
    }
    return nil;
}

- (void)updateShareButtonPresentation {
    self.shareButton.title = self.shareButtonActive ? @"Stop Surface Share" : @"Start Surface Share";

    // Keep the button label stable across short start-up transitions. The
    // controller still exposes pending state, but the button only uses it to
    // suppress extra clicks until the share either becomes active or fails.
    self.shareButton.enabled = !self.shareButtonStartPending;
}

@end
