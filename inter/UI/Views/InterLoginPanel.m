#import "InterLoginPanel.h"

@interface InterLoginPanel () <NSTextFieldDelegate>
@property (nonatomic, strong) NSTextField *emailField;
@property (nonatomic, strong) NSSecureTextField *passwordField;
@property (nonatomic, strong) NSTextField *displayNameField;
@property (nonatomic, strong) NSTextField *displayNameLabel;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *errorLabel;
@property (nonatomic, strong) NSButton *actionButton;
@property (nonatomic, strong) NSButton *toggleModeButton;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, assign) BOOL isRegisterMode;
@end

@implementation InterLoginPanel

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.isRegisterMode = NO;
    [self buildUI];
    return self;
}

#pragma mark - Public API

- (void)showError:(NSString *)message {
    self.errorLabel.stringValue = message ?: @"";
    self.errorLabel.hidden = NO;
}

- (void)clearError {
    self.errorLabel.stringValue = @"";
    self.errorLabel.hidden = YES;
}

- (void)setActionsEnabled:(BOOL)enabled {
    self.actionButton.enabled = enabled;
    self.toggleModeButton.enabled = enabled;
}

- (void)setLoading:(BOOL)loading {
    if (loading) {
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
    } else {
        [self.spinner stopAnimation:nil];
        self.spinner.hidden = YES;
    }
}

#pragma mark - Actions

- (void)handleAction:(id)sender {
#pragma unused(sender)
    [self clearError];

    NSString *email = [self.emailField.stringValue stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *password = self.passwordField.stringValue;

    if (email.length == 0) {
        [self showError:@"Email is required."];
        return;
    }
    if (password.length < 8) {
        [self showError:@"Password must be at least 8 characters."];
        return;
    }

    if (self.isRegisterMode) {
        NSString *displayName = [self.displayNameField.stringValue stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (displayName.length == 0) {
            [self showError:@"Display name is required."];
            return;
        }
        [self.delegate loginPanel:self didRequestRegisterWithEmail:email
                         password:password displayName:displayName];
    } else {
        [self.delegate loginPanel:self didRequestLoginWithEmail:email password:password];
    }
}

- (void)handleToggleMode:(id)sender {
#pragma unused(sender)
    self.isRegisterMode = !self.isRegisterMode;
    [self clearError];
    [self updateModeUI];
}

- (void)updateModeUI {
    BOOL reg = self.isRegisterMode;
    self.displayNameField.hidden = !reg;
    self.displayNameLabel.hidden = !reg;
    self.titleLabel.stringValue = reg ? @"Create an Account" : @"Sign In to Inter";
    [self.actionButton setTitle:reg ? @"Create Account" : @"Log In"];
    NSMutableAttributedString *linkTitle = [[NSMutableAttributedString alloc]
        initWithString:(reg ? @"Back to Login" : @"Create Account")
        attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: [NSColor systemBlueColor],
        }];
    self.toggleModeButton.attributedTitle = linkTitle;
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidEndEditing:(NSNotification *)obj {
#pragma unused(obj)
    // No persistence for login fields — security-sensitive
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

    // ── Title ──
    CGFloat y = self.bounds.size.height - 40;
    self.titleLabel = [NSTextField labelWithString:@"Sign In to Inter"];
    NSTextField *titleLabel = self.titleLabel;
    titleLabel.frame = NSMakeRect(xPad, y, fieldW, 22);
    titleLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    titleLabel.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    titleLabel.textColor = [NSColor colorWithWhite:0.95 alpha:1.0];
    titleLabel.alignment = NSTextAlignmentCenter;
    [self addSubview:titleLabel];
    y -= 30;

    // ── Email ──
    NSTextField *emailLabel = [self createLabelWithText:@"Email" atY:y width:fieldW];
    [self addSubview:emailLabel];
    y -= 24;
    self.emailField = [self createTextFieldAtY:y width:fieldW placeholder:@"you@example.com"];
    [self addSubview:self.emailField];
    y -= 26;

    // ── Password ──
    NSTextField *passwordLabel = [self createLabelWithText:@"Password" atY:y width:fieldW];
    [self addSubview:passwordLabel];
    y -= 24;
    self.passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(xPad, y, fieldW, 22)];
    self.passwordField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.passwordField.font = [NSFont systemFontOfSize:12];
    self.passwordField.placeholderString = @"Minimum 8 characters";
    self.passwordField.bordered = YES;
    self.passwordField.bezeled = YES;
    self.passwordField.bezelStyle = NSTextFieldRoundedBezel;
    self.passwordField.drawsBackground = YES;
    self.passwordField.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.9];
    self.passwordField.textColor = [NSColor colorWithWhite:0.95 alpha:1.0];
    self.passwordField.delegate = self;
    [self addSubview:self.passwordField];
    y -= 26;

    // ── Display Name (register mode only) ──
    self.displayNameLabel = [self createLabelWithText:@"Display Name" atY:y width:fieldW];
    self.displayNameLabel.hidden = YES;
    [self addSubview:self.displayNameLabel];
    y -= 24;
    self.displayNameField = [self createTextFieldAtY:y width:fieldW placeholder:@"Your name"];
    self.displayNameField.hidden = YES;
    [self addSubview:self.displayNameField];
    y -= 30;

    // ── Error label ──
    self.errorLabel = [NSTextField labelWithString:@""];
    self.errorLabel.frame = NSMakeRect(xPad, y, fieldW, 32);
    self.errorLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.errorLabel.font = [NSFont systemFontOfSize:11];
    self.errorLabel.textColor = [NSColor systemRedColor];
    self.errorLabel.maximumNumberOfLines = 2;
    self.errorLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.errorLabel.hidden = YES;
    [self addSubview:self.errorLabel];
    y -= 34;

    // ── Action button ──
    self.actionButton = [[NSButton alloc] initWithFrame:NSMakeRect(xPad, y, fieldW, 32)];
    [self.actionButton setTitle:@"Log In"];
    [self.actionButton setTarget:self];
    [self.actionButton setAction:@selector(handleAction:)];
    self.actionButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self addSubview:self.actionButton];
    y -= 30;

    // ── Toggle mode link ──
    self.toggleModeButton = [NSButton buttonWithTitle:@"Create Account"
                                               target:self
                                               action:@selector(handleToggleMode:)];
    self.toggleModeButton.frame = NSMakeRect(xPad, y, fieldW, 20);
    self.toggleModeButton.bordered = NO;
    self.toggleModeButton.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    NSMutableAttributedString *linkAttr = [[NSMutableAttributedString alloc]
        initWithString:@"Create Account"
        attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: [NSColor systemBlueColor],
        }];
    self.toggleModeButton.attributedTitle = linkAttr;
    [self addSubview:self.toggleModeButton];
    y -= 24;

    // ── Spinner ──
    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(W / 2.0 - 10, y, 20, 20)];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    self.spinner.hidden = YES;
    self.spinner.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin;
    [self addSubview:self.spinner];
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
