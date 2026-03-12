#import "InterConnectionSetupPanel.h"

static NSString *const InterDefaultServerURLKey     = @"InterDefaultServerURL";
static NSString *const InterDefaultTokenURLKey       = @"InterDefaultTokenServerURL";
static NSString *const InterDefaultDisplayNameKey    = @"InterDefaultDisplayName";

@interface InterConnectionSetupPanel () <NSTextFieldDelegate>
@property (nonatomic, strong) NSTextField *serverURLField;
@property (nonatomic, strong) NSTextField *tokenServerURLField;
@property (nonatomic, strong) NSTextField *displayNameField;
@property (nonatomic, strong) NSTextField *roomCodeField;
@property (nonatomic, strong) NSView *indicatorDot;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *hostedRoomCodeLabel;
@property (nonatomic, strong) NSButton *hostCallButton;
@property (nonatomic, strong) NSButton *hostInterviewButton;
@property (nonatomic, strong) NSButton *joinButton;
@end

@implementation InterConnectionSetupPanel

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }
    [self buildUI];
    [self restoreDefaults];
    return self;
}

#pragma mark - Accessors

- (NSString *)serverURL {
    return self.serverURLField.stringValue ?: @"";
}

- (NSString *)tokenServerURL {
    return self.tokenServerURLField.stringValue ?: @"";
}

- (NSString *)displayName {
    return self.displayNameField.stringValue ?: @"";
}

- (NSString *)roomCode {
    return self.roomCodeField.stringValue ?: @"";
}

#pragma mark - Public API

- (void)setIndicatorState:(InterConnectionIndicatorState)state {
    NSColor *color = nil;
    switch (state) {
        case InterConnectionIndicatorStateIdle:
            color = [NSColor colorWithWhite:0.5 alpha:1.0];
            break;
        case InterConnectionIndicatorStateConnecting:
            color = [NSColor systemYellowColor];
            break;
        case InterConnectionIndicatorStateConnected:
            color = [NSColor systemGreenColor];
            break;
        case InterConnectionIndicatorStateError:
            color = [NSColor systemRedColor];
            break;
    }
    self.indicatorDot.layer.backgroundColor = color.CGColor;
}

- (void)setStatusText:(NSString *)text {
    self.statusLabel.stringValue = text ?: @"";
}

- (void)showHostedRoomCode:(NSString *)code {
    if (code.length > 0) {
        self.hostedRoomCodeLabel.stringValue = [NSString stringWithFormat:@"Room Code: %@", code];
        self.hostedRoomCodeLabel.hidden = NO;
    } else {
        self.hostedRoomCodeLabel.stringValue = @"";
        self.hostedRoomCodeLabel.hidden = YES;
    }
}

- (void)setActionsEnabled:(BOOL)enabled {
    self.hostCallButton.enabled = enabled;
    self.hostInterviewButton.enabled = enabled;
    self.joinButton.enabled = enabled;
}

- (void)setRoomCodeText:(NSString *)code {
    self.roomCodeField.stringValue = code ?: @"";
}

#pragma mark - Persistence

- (void)restoreDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedServerURL = [defaults stringForKey:InterDefaultServerURLKey];
    NSString *savedTokenURL  = [defaults stringForKey:InterDefaultTokenURLKey];
    NSString *savedName      = [defaults stringForKey:InterDefaultDisplayNameKey];

    self.serverURLField.stringValue      = savedServerURL.length > 0 ? savedServerURL : @"ws://localhost:7880";
    self.tokenServerURLField.stringValue = savedTokenURL.length  > 0 ? savedTokenURL  : @"http://localhost:3000";
    self.displayNameField.stringValue    = savedName.length      > 0 ? savedName      : @"";
}

- (void)persistValues {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:self.serverURLField.stringValue      forKey:InterDefaultServerURLKey];
    [defaults setObject:self.tokenServerURLField.stringValue forKey:InterDefaultTokenURLKey];
    [defaults setObject:self.displayNameField.stringValue    forKey:InterDefaultDisplayNameKey];
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    [self persistValues];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    // Auto-uppercase room code as the user types, enforce 6-char max
    if (obj.object == self.roomCodeField) {
        NSString *current = self.roomCodeField.stringValue;
        NSString *uppercased = [[current uppercaseString] substringToIndex:MIN(current.length, 6)];
        // Remove confusable characters per G7 (0, O, 1, I, L)
        NSCharacterSet *confusable = [NSCharacterSet characterSetWithCharactersInString:@"0O1IL"];
        NSString *cleaned = [[uppercased componentsSeparatedByCharactersInSet:confusable] componentsJoinedByString:@""];
        if (![cleaned isEqualToString:current]) {
            self.roomCodeField.stringValue = cleaned;
        }
    }
}

#pragma mark - Actions

- (void)handleHostCall:(id)sender {
#pragma unused(sender)
    [self persistValues];
    id<InterConnectionSetupPanelDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(setupPanelDidRequestHostCall:)]) {
        [d setupPanelDidRequestHostCall:self];
    }
}

- (void)handleHostInterview:(id)sender {
#pragma unused(sender)
    [self persistValues];
    id<InterConnectionSetupPanelDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(setupPanelDidRequestHostInterview:)]) {
        [d setupPanelDidRequestHostInterview:self];
    }
}

- (void)handleJoin:(id)sender {
#pragma unused(sender)
    [self persistValues];
    id<InterConnectionSetupPanelDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(setupPanelDidRequestJoin:)]) {
        [d setupPanelDidRequestJoin:self];
    }
}

#pragma mark - UI Construction

- (void)buildUI {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [[NSColor colorWithWhite:0.08 alpha:0.75] CGColor];
    self.layer.cornerRadius = 16.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.12] CGColor];

    CGFloat W = self.bounds.size.width;
    CGFloat fieldW = W - 40.0;
    CGFloat xPad = 20.0;

    // ── Connection Indicator (dot + label) ──
    self.indicatorDot = [[NSView alloc] initWithFrame:NSMakeRect(xPad, self.bounds.size.height - 30, 10, 10)];
    self.indicatorDot.wantsLayer = YES;
    self.indicatorDot.layer.cornerRadius = 5.0;
    self.indicatorDot.layer.backgroundColor = [[NSColor colorWithWhite:0.5 alpha:1.0] CGColor];
    self.indicatorDot.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:self.indicatorDot];

    self.statusLabel = [NSTextField labelWithString:@"Not connected"];
    self.statusLabel.frame = NSMakeRect(xPad + 16, self.bounds.size.height - 33, fieldW - 16, 16);
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor colorWithWhite:0.75 alpha:1.0];
    [self addSubview:self.statusLabel];

    // ── Hosted room code (hidden by default) ──
    self.hostedRoomCodeLabel = [NSTextField labelWithString:@""];
    self.hostedRoomCodeLabel.frame = NSMakeRect(xPad, self.bounds.size.height - 56, fieldW, 20);
    self.hostedRoomCodeLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.hostedRoomCodeLabel.font = [NSFont monospacedSystemFontOfSize:16 weight:NSFontWeightBold];
    self.hostedRoomCodeLabel.textColor = [NSColor systemGreenColor];
    self.hostedRoomCodeLabel.alignment = NSTextAlignmentCenter;
    self.hostedRoomCodeLabel.hidden = YES;
    [self addSubview:self.hostedRoomCodeLabel];

    // ── Labels + Fields (bottom-up layout: Y increases upward) ──
    CGFloat y = self.bounds.size.height - 86;

    NSTextField *serverLabel = [self createLabelWithText:@"Server URL" atY:y width:fieldW];
    [self addSubview:serverLabel];
    y -= 24;
    self.serverURLField = [self createTextFieldAtY:y width:fieldW placeholder:@"ws://localhost:7880"];
    [self addSubview:self.serverURLField];
    y -= 26;

    NSTextField *tokenLabel = [self createLabelWithText:@"Token Server URL" atY:y width:fieldW];
    [self addSubview:tokenLabel];
    y -= 24;
    self.tokenServerURLField = [self createTextFieldAtY:y width:fieldW placeholder:@"http://localhost:3000"];
    [self addSubview:self.tokenServerURLField];
    y -= 26;

    NSTextField *nameLabel = [self createLabelWithText:@"Display Name" atY:y width:fieldW];
    [self addSubview:nameLabel];
    y -= 24;
    self.displayNameField = [self createTextFieldAtY:y width:fieldW placeholder:@"Your name"];
    [self addSubview:self.displayNameField];
    y -= 26;

    NSTextField *codeLabel = [self createLabelWithText:@"Room Code (to join)" atY:y width:fieldW];
    [self addSubview:codeLabel];
    y -= 24;
    self.roomCodeField = [self createTextFieldAtY:y width:fieldW placeholder:@"e.g. X7K29M"];
    self.roomCodeField.formatter = nil; // rely on delegate for formatting
    [self addSubview:self.roomCodeField];
    y -= 34;

    // ── Action Buttons ──
    CGFloat buttonW = (fieldW - 10.0) / 2.0;

    self.hostCallButton = [[NSButton alloc] initWithFrame:NSMakeRect(xPad, y, buttonW, 32)];
    [self.hostCallButton setTitle:@"Host Call"];
    [self.hostCallButton setTarget:self];
    [self.hostCallButton setAction:@selector(handleHostCall:)];
    self.hostCallButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self addSubview:self.hostCallButton];

    self.hostInterviewButton = [[NSButton alloc] initWithFrame:NSMakeRect(xPad + buttonW + 10.0, y, buttonW, 32)];
    [self.hostInterviewButton setTitle:@"Host Interview"];
    [self.hostInterviewButton setTarget:self];
    [self.hostInterviewButton setAction:@selector(handleHostInterview:)];
    self.hostInterviewButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self addSubview:self.hostInterviewButton];
    y -= 38;

    self.joinButton = [[NSButton alloc] initWithFrame:NSMakeRect(xPad, y, fieldW, 32)];
    [self.joinButton setTitle:@"Join with Room Code"];
    [self.joinButton setTarget:self];
    [self.joinButton setAction:@selector(handleJoin:)];
    self.joinButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self addSubview:self.joinButton];
}

#pragma mark - Helpers

- (NSTextField *)createLabelWithText:(NSString *)text atY:(CGFloat)y width:(CGFloat)w {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = NSMakeRect(20.0, y, w, 16);
    label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    label.textColor = [NSColor colorWithWhite:0.75 alpha:1.0];
    return label;
}

- (NSTextField *)createTextFieldAtY:(CGFloat)y width:(CGFloat)w placeholder:(NSString *)placeholder {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(20.0, y, w, 22)];
    field.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    field.font = [NSFont systemFontOfSize:12];
    field.placeholderString = placeholder;
    field.bordered = YES;
    field.bezeled = YES;
    field.bezelStyle = NSTextFieldRoundedBezel;
    field.drawsBackground = YES;
    field.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.9];
    field.textColor = [NSColor colorWithWhite:0.95 alpha:1.0];
    field.delegate = self;
    return field;
}

@end
