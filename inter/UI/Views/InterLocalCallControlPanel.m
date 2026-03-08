#import "InterLocalCallControlPanel.h"

@interface InterLocalCallControlPanel ()
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *mediaStatusLabel;
@property (nonatomic, strong) NSTextField *shareStatusLabel;
@property (nonatomic, strong) NSTextField *shareModeLabel;
@property (nonatomic, strong) NSButton *cameraButton;
@property (nonatomic, strong) NSButton *microphoneButton;
@property (nonatomic, strong) NSButton *shareButton;
@property (nonatomic, strong) NSPopUpButton *shareModePopUpButton;
@property (nonatomic, strong, readwrite) NSView *previewContainerView;
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

    self.cameraButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 88, self.bounds.size.width - 32, 30)];
    self.cameraButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.cameraButton setTitle:@"Turn Camera On"];
    [self.cameraButton setTarget:self];
    [self.cameraButton setAction:@selector(handleCameraToggle:)];
    [self addSubview:self.cameraButton];

    self.microphoneButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 56, self.bounds.size.width - 32, 30)];
    self.microphoneButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.microphoneButton setTitle:@"Turn Mic On"];
    [self.microphoneButton setTarget:self];
    [self.microphoneButton setAction:@selector(handleMicrophoneToggle:)];
    [self addSubview:self.microphoneButton];

    self.shareButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 20, self.bounds.size.width - 32, 30)];
    self.shareButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.shareButton setTitle:@"Start Surface Share"];
    [self.shareButton setTarget:self];
    [self.shareButton setAction:@selector(handleShareToggle:)];
    [self addSubview:self.shareButton];

    [self setShareMode:InterShareModeThisApp];
}

- (void)setPanelTitleText:(NSString *)title {
    self.titleLabel.stringValue = title ?: @"Local Media Controls";
}

- (void)setCameraEnabled:(BOOL)enabled {
    self.cameraButton.title = enabled ? @"Turn Camera Off" : @"Turn Camera On";
}

- (void)setMicrophoneEnabled:(BOOL)enabled {
    self.microphoneButton.title = enabled ? @"Turn Mic Off" : @"Turn Mic On";
}

- (void)setSharingEnabled:(BOOL)enabled {
    self.shareButton.title = enabled ? @"Stop Surface Share" : @"Start Surface Share";
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

- (NSMenuItem *)shareModeMenuItemForMode:(InterShareMode)shareMode {
    for (NSMenuItem *item in self.shareModePopUpButton.itemArray) {
        if (item.tag == (NSInteger)shareMode) {
            return item;
        }
    }
    return nil;
}

@end
