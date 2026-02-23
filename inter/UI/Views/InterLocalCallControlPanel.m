#import "InterLocalCallControlPanel.h"

@interface InterLocalCallControlPanel ()
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *mediaStatusLabel;
@property (nonatomic, strong) NSTextField *shareStatusLabel;
@property (nonatomic, strong) NSButton *cameraButton;
@property (nonatomic, strong) NSButton *microphoneButton;
@property (nonatomic, strong) NSButton *shareButton;
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

    self.cameraButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 132, self.bounds.size.width - 32, 38)];
    self.cameraButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.cameraButton setTitle:@"Turn Camera On"];
    [self.cameraButton setTarget:self];
    [self.cameraButton setAction:@selector(handleCameraToggle:)];
    [self addSubview:self.cameraButton];

    self.microphoneButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 86, self.bounds.size.width - 32, 38)];
    self.microphoneButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.microphoneButton setTitle:@"Turn Mic On"];
    [self.microphoneButton setTarget:self];
    [self.microphoneButton setAction:@selector(handleMicrophoneToggle:)];
    [self addSubview:self.microphoneButton];

    self.shareButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 40, self.bounds.size.width - 32, 38)];
    self.shareButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.shareButton setTitle:@"Start Surface Share"];
    [self.shareButton setTarget:self];
    [self.shareButton setAction:@selector(handleShareToggle:)];
    [self addSubview:self.shareButton];
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

@end
