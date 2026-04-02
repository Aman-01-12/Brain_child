// ============================================================================
// InterRecordingConsentPanel.m
// inter
//
// Phase 10D.5 — New joiner consent dialog.
// Shown as a modal-style overlay when a participant joins a room
// where recording is already in progress.
//
// ISOLATION INVARIANT [G8]:
// This view has NO side effects on media, recording, or networking.
// All actions are reported via the delegate protocol.
// ============================================================================

#import "InterRecordingConsentPanel.h"

@interface InterRecordingConsentPanel ()
@property (nonatomic, strong) NSView        *backdropView;
@property (nonatomic, strong) NSView        *dialogBox;
@property (nonatomic, strong) NSImageView   *iconView;
@property (nonatomic, strong) NSTextField   *titleLabel;
@property (nonatomic, strong) NSTextField   *bodyLabel;
@property (nonatomic, strong) NSTextField   *modeLabel;
@property (nonatomic, strong) NSButton      *acceptButton;
@property (nonatomic, strong) NSButton      *declineButton;
@end

@implementation InterRecordingConsentPanel

// ---------------------------------------------------------------------------
// MARK: - Init
// ---------------------------------------------------------------------------

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self _setupUI];
    }
    return self;
}

// ---------------------------------------------------------------------------
// MARK: - UI Setup
// ---------------------------------------------------------------------------

- (void)_setupUI {
    self.wantsLayer = YES;
    self.hidden = YES;

    // Semi-transparent backdrop covering the entire parent
    _backdropView = [[NSView alloc] initWithFrame:NSZeroRect];
    _backdropView.wantsLayer = YES;
    _backdropView.layer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.6] CGColor];
    _backdropView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_backdropView];

    // Dialog box (centered, fixed width)
    _dialogBox = [[NSView alloc] initWithFrame:NSZeroRect];
    _dialogBox.wantsLayer = YES;
    _dialogBox.layer.backgroundColor = [[NSColor colorWithWhite:0.15 alpha:1.0] CGColor];
    _dialogBox.layer.cornerRadius = 14.0;
    _dialogBox.layer.borderColor = [[NSColor colorWithWhite:0.3 alpha:1.0] CGColor];
    _dialogBox.layer.borderWidth = 1.0;
    _dialogBox.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_dialogBox];

    // Recording icon (red circle)
    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    NSImage *recImage = [NSImage imageWithSystemSymbolName:@"record.circle.fill" accessibilityDescription:@"Recording"];
    if (recImage) {
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:32 weight:NSFontWeightMedium];
        _iconView.image = [recImage imageWithSymbolConfiguration:config];
        _iconView.contentTintColor = [NSColor systemRedColor];
    }
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [_dialogBox addSubview:_iconView];

    // Title
    _titleLabel = [NSTextField labelWithString:@"This Meeting Is Being Recorded"];
    _titleLabel.font = [NSFont boldSystemFontOfSize:17];
    _titleLabel.textColor = [NSColor whiteColor];
    _titleLabel.alignment = NSTextAlignmentCenter;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_dialogBox addSubview:_titleLabel];

    // Body text
    _bodyLabel = [NSTextField wrappingLabelWithString:
        @"The host has started recording this meeting. By continuing to participate, "
        @"you consent to being recorded. Your audio and video may be captured.\n\n"
        @"If you do not consent, you may leave the meeting."];
    _bodyLabel.font = [NSFont systemFontOfSize:13];
    _bodyLabel.textColor = [NSColor secondaryLabelColor];
    _bodyLabel.alignment = NSTextAlignmentCenter;
    _bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_dialogBox addSubview:_bodyLabel];

    // Mode label (shows recording type)
    _modeLabel = [NSTextField labelWithString:@""];
    _modeLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _modeLabel.textColor = [NSColor tertiaryLabelColor];
    _modeLabel.alignment = NSTextAlignmentCenter;
    _modeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_dialogBox addSubview:_modeLabel];

    // Accept button (primary)
    _acceptButton = [NSButton buttonWithTitle:@"Continue & Accept" target:self action:@selector(_accept:)];
    _acceptButton.bezelStyle = NSBezelStyleRounded;
    _acceptButton.controlSize = NSControlSizeRegular;
    _acceptButton.keyEquivalent = @"\r"; // Enter key
    _acceptButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_dialogBox addSubview:_acceptButton];

    // Decline button
    _declineButton = [NSButton buttonWithTitle:@"Leave Meeting" target:self action:@selector(_decline:)];
    _declineButton.bezelStyle = NSBezelStyleRounded;
    _declineButton.controlSize = NSControlSizeRegular;
    _declineButton.contentTintColor = [NSColor systemRedColor];
    _declineButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_dialogBox addSubview:_declineButton];

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        // Backdrop fills entire panel
        [_backdropView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_backdropView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_backdropView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_backdropView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        // Dialog box centered, fixed width
        [_dialogBox.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_dialogBox.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_dialogBox.widthAnchor constraintEqualToConstant:380],

        // Icon
        [_iconView.topAnchor constraintEqualToAnchor:_dialogBox.topAnchor constant:24],
        [_iconView.centerXAnchor constraintEqualToAnchor:_dialogBox.centerXAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:40],
        [_iconView.heightAnchor constraintEqualToConstant:40],

        // Title
        [_titleLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:12],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_dialogBox.leadingAnchor constant:20],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_dialogBox.trailingAnchor constant:-20],

        // Body
        [_bodyLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:12],
        [_bodyLabel.leadingAnchor constraintEqualToAnchor:_dialogBox.leadingAnchor constant:24],
        [_bodyLabel.trailingAnchor constraintEqualToAnchor:_dialogBox.trailingAnchor constant:-24],

        // Mode label
        [_modeLabel.topAnchor constraintEqualToAnchor:_bodyLabel.bottomAnchor constant:8],
        [_modeLabel.leadingAnchor constraintEqualToAnchor:_dialogBox.leadingAnchor constant:24],
        [_modeLabel.trailingAnchor constraintEqualToAnchor:_dialogBox.trailingAnchor constant:-24],

        // Buttons — side by side
        [_declineButton.topAnchor constraintEqualToAnchor:_modeLabel.bottomAnchor constant:20],
        [_declineButton.leadingAnchor constraintEqualToAnchor:_dialogBox.leadingAnchor constant:24],
        [_declineButton.bottomAnchor constraintEqualToAnchor:_dialogBox.bottomAnchor constant:-20],

        [_acceptButton.topAnchor constraintEqualToAnchor:_modeLabel.bottomAnchor constant:20],
        [_acceptButton.trailingAnchor constraintEqualToAnchor:_dialogBox.trailingAnchor constant:-24],
        [_acceptButton.bottomAnchor constraintEqualToAnchor:_dialogBox.bottomAnchor constant:-20],
    ]];
}

// ---------------------------------------------------------------------------
// MARK: - Public API
// ---------------------------------------------------------------------------

- (void)showConsentForMode:(NSString *)mode {
    NSString *modeText = @"";
    if ([mode isEqualToString:@"local_composed"]) {
        modeText = @"Recording type: Local (composed video saved on host's device)";
    } else if ([mode isEqualToString:@"cloud_composed"]) {
        modeText = @"Recording type: Cloud (video saved to cloud storage)";
    } else if ([mode isEqualToString:@"multi_track"]) {
        modeText = @"Recording type: Multi-track (individual participant tracks saved to cloud)";
    }
    self.modeLabel.stringValue = modeText;

    self.hidden = NO;
    self.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        self.animator.alphaValue = 1.0;
    }];
}

- (void)dismiss {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        self.animator.alphaValue = 0.0;
    } completionHandler:^{
        self.hidden = YES;
    }];
}

// ---------------------------------------------------------------------------
// MARK: - Actions
// ---------------------------------------------------------------------------

- (void)_accept:(id)sender {
    if ([self.delegate respondsToSelector:@selector(recordingConsentPanelDidAccept:)]) {
        [self.delegate recordingConsentPanelDidAccept:self];
    }
    [self dismiss];
}

- (void)_decline:(id)sender {
    if ([self.delegate respondsToSelector:@selector(recordingConsentPanelDidDecline:)]) {
        [self.delegate recordingConsentPanelDidDecline:self];
    }
    [self dismiss];
}

// ---------------------------------------------------------------------------
// MARK: - Hit Testing
// ---------------------------------------------------------------------------

- (NSView *)hitTest:(NSPoint)point {
    if (self.isHidden) return nil;
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if (!NSPointInRect(local, self.bounds)) return nil;
    // Block all clicks through — this is a modal overlay
    NSView *hit = [super hitTest:point];
    return hit ?: self;
}

@end
