// ============================================================================
// InterLobbyWaitingView.m
// inter
//
// Participant-side waiting room view — shown when lobby is enabled.
// Displays a spinner, position, status message, and cancel button.
//
// ISOLATION INVARIANT [G8]:
// This view has NO side effects on networking or media.
// All actions are reported via the delegate protocol.
// ============================================================================

#import "InterLobbyWaitingView.h"

@interface InterLobbyWaitingView ()
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *positionLabel;
@property (nonatomic, strong) NSButton    *cancelButton;
@property (nonatomic, strong) NSImageView *iconView;
@end

@implementation InterLobbyWaitingView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self _setupUI];
    }
    return self;
}

- (void)_setupUI {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [[NSColor colorWithWhite:0.10 alpha:1.0] CGColor];

    // Icon — lock/waiting indicator
    NSImage *lockImage = [NSImage imageWithSystemSymbolName:@"person.badge.clock"
                                  accessibilityDescription:@"Waiting"];
    _iconView = [NSImageView imageViewWithImage:lockImage ?: [NSImage imageNamed:NSImageNameCaution]];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentTintColor = [NSColor systemBlueColor];
    _iconView.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:48 weight:NSFontWeightLight];
    [self addSubview:_iconView];

    // Title
    _titleLabel = [NSTextField labelWithString:@"Waiting Room"];
    _titleLabel.font = [NSFont boldSystemFontOfSize:22];
    _titleLabel.textColor = [NSColor whiteColor];
    _titleLabel.alignment = NSTextAlignmentCenter;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_titleLabel];

    // Status message
    _statusLabel = [NSTextField labelWithString:@"Please wait, the host will let you in shortly."];
    _statusLabel.font = [NSFont systemFontOfSize:14];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.alignment = NSTextAlignmentCenter;
    _statusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _statusLabel.maximumNumberOfLines = 3;
    _statusLabel.preferredMaxLayoutWidth = 300;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_statusLabel];

    // Position label
    _positionLabel = [NSTextField labelWithString:@""];
    _positionLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    _positionLabel.textColor = [NSColor tertiaryLabelColor];
    _positionLabel.alignment = NSTextAlignmentCenter;
    _positionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _positionLabel.hidden = YES;
    [self addSubview:_positionLabel];

    // Spinner
    _spinner = [[NSProgressIndicator alloc] init];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeRegular;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [_spinner startAnimation:nil];
    [self addSubview:_spinner];

    // Cancel button
    _cancelButton = [NSButton buttonWithTitle:@"Leave" target:self action:@selector(_cancelClicked:)];
    _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    _cancelButton.bezelStyle = NSBezelStyleRounded;
    _cancelButton.controlSize = NSControlSizeRegular;
    _cancelButton.contentTintColor = [NSColor systemRedColor];
    [self addSubview:_cancelButton];

    // Layout — centered vertically
    [NSLayoutConstraint activateConstraints:@[
        [_iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_iconView.bottomAnchor constraintEqualToAnchor:_titleLabel.topAnchor constant:-16],
        [_iconView.widthAnchor constraintEqualToConstant:56],
        [_iconView.heightAnchor constraintEqualToConstant:56],

        [_titleLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-40],

        [_statusLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_statusLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:10],
        [_statusLabel.widthAnchor constraintLessThanOrEqualToConstant:320],

        [_positionLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_positionLabel.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:8],

        [_spinner.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_spinner.topAnchor constraintEqualToAnchor:_positionLabel.bottomAnchor constant:16],

        [_cancelButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_cancelButton.topAnchor constraintEqualToAnchor:_spinner.bottomAnchor constant:24],
        [_cancelButton.widthAnchor constraintGreaterThanOrEqualToConstant:100],
    ]];
}

// ---------------------------------------------------------------------------
// MARK: - Public API
// ---------------------------------------------------------------------------

- (void)setPosition:(NSInteger)position {
    if (position > 0) {
        self.positionLabel.hidden = NO;
        self.positionLabel.stringValue = [NSString stringWithFormat:@"Your position in queue: %ld", (long)position];
    } else {
        self.positionLabel.hidden = YES;
    }
}

- (void)setStatusMessage:(NSString *)message {
    self.statusLabel.stringValue = message ?: @"";
}

- (void)showDenied {
    [self.spinner stopAnimation:nil];
    self.spinner.hidden = YES;
    self.titleLabel.stringValue = @"Access Denied";
    self.titleLabel.textColor = [NSColor systemRedColor];
    self.statusLabel.stringValue = @"The host has denied your request to join this meeting.";
    self.positionLabel.hidden = YES;
    self.iconView.contentTintColor = [NSColor systemRedColor];
    [self.cancelButton setTitle:@"OK"];
}

- (void)showAdmitted {
    [self.spinner stopAnimation:nil];
    self.spinner.hidden = YES;
    self.titleLabel.stringValue = @"You're In!";
    self.titleLabel.textColor = [NSColor systemGreenColor];
    self.statusLabel.stringValue = @"The host has admitted you. Connecting…";
    self.positionLabel.hidden = YES;
    self.iconView.contentTintColor = [NSColor systemGreenColor];
    self.cancelButton.hidden = YES;
}

// ---------------------------------------------------------------------------
// MARK: - Actions
// ---------------------------------------------------------------------------

- (void)_cancelClicked:(id)sender {
    if ([self.delegate respondsToSelector:@selector(lobbyWaitingViewDidCancel:)]) {
        [self.delegate lobbyWaitingViewDidCancel:self];
    }
}

@end
