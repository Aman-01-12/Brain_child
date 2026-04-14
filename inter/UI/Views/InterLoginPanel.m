#import "InterLoginPanel.h"

@interface InterLoginPanel () <NSTextFieldDelegate>
@property (nonatomic, strong) NSTextField *emailField;
@property (nonatomic, strong) NSSecureTextField *passwordField;
@property (nonatomic, strong) NSTextField *passwordPlainField;   // G6 – visible twin
@property (nonatomic, strong) NSButton *showPasswordButton;     // G6 – eye toggle
@property (nonatomic, assign) BOOL isPasswordVisible;
@property (nonatomic, strong) NSView *strengthBarContainer;     // G5 – meter
@property (nonatomic, strong) NSTextField *strengthLabel;       // G5 – text
@property (nonatomic, strong) NSButton *googleButton;
@property (nonatomic, strong) NSButton *microsoftButton;
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

- (void)handleOAuthGoogle:(id)sender {
#pragma unused(sender)
    if ([self.delegate respondsToSelector:@selector(loginPanel:didRequestOAuthWithProvider:)]) {
        [self.delegate loginPanel:self didRequestOAuthWithProvider:@"google"];
    }
}

- (void)handleOAuthMicrosoft:(id)sender {
#pragma unused(sender)
    if ([self.delegate respondsToSelector:@selector(loginPanel:didRequestOAuthWithProvider:)]) {
        [self.delegate loginPanel:self didRequestOAuthWithProvider:@"microsoft"];
    }
}

- (void)updateModeUI {
    BOOL reg = self.isRegisterMode;
    self.displayNameField.hidden = !reg;
    self.displayNameLabel.hidden = !reg;
    self.strengthBarContainer.hidden = !reg;
    self.strengthLabel.hidden = !reg;
    if (reg) [self updatePasswordStrength];
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

#pragma mark - Password Visibility Toggle (G6)

- (void)togglePasswordVisibility:(id)sender {
#pragma unused(sender)
    self.isPasswordVisible = !self.isPasswordVisible;

    // Preserve the attributed title's existing attributes (font, color, etc.)
    // and only swap the display string so the blue styled appearance is retained.
    NSAttributedString *currentTitle = self.showPasswordButton.attributedTitle;
    NSDictionary *attrs = (currentTitle && currentTitle.length > 0)
        ? [currentTitle attributesAtIndex:0 effectiveRange:nil]
        : @{
            NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor systemBlueColor],
        };

    if (self.isPasswordVisible) {
        self.passwordPlainField.stringValue = self.passwordField.stringValue;
        self.passwordField.hidden = YES;
        self.passwordPlainField.hidden = NO;
        [self.window makeFirstResponder:self.passwordPlainField];
        self.showPasswordButton.attributedTitle =
            [[NSAttributedString alloc] initWithString:@"Hide" attributes:attrs];
    } else {
        self.passwordField.stringValue = self.passwordPlainField.stringValue;
        self.passwordPlainField.hidden = YES;
        self.passwordField.hidden = NO;
        [self.window makeFirstResponder:self.passwordField];
        self.showPasswordButton.attributedTitle =
            [[NSAttributedString alloc] initWithString:@"Show" attributes:attrs];
    }
}

#pragma mark - Password Strength Meter (G5)

/// Simple entropy-based scoring: 0 = empty, 1 = weak, 2 = fair, 3 = strong, 4 = very strong.
- (NSInteger)scoreForPassword:(NSString *)password {
    if (password.length == 0) return 0;
    if (password.length < 8) return 1;

    BOOL hasLower = NO, hasUpper = NO, hasDigit = NO, hasSymbol = NO;
    for (NSUInteger i = 0; i < password.length; i++) {
        unichar c = [password characterAtIndex:i];
        if (c >= 'a' && c <= 'z') hasLower = YES;
        else if (c >= 'A' && c <= 'Z') hasUpper = YES;
        else if (c >= '0' && c <= '9') hasDigit = YES;
        else hasSymbol = YES;
    }
    NSInteger variety = (hasLower ? 1 : 0) + (hasUpper ? 1 : 0) + (hasDigit ? 1 : 0) + (hasSymbol ? 1 : 0);

    if (password.length >= 12 && variety >= 3) return 4;
    if (password.length >= 10 && variety >= 3) return 3;
    if (variety >= 2) return 2;
    return 1;
}

- (void)updatePasswordStrength {
    NSString *password = self.isPasswordVisible ? self.passwordPlainField.stringValue : self.passwordField.stringValue;
    NSInteger score = [self scoreForPassword:password];

    static NSArray<NSColor *> *colors = nil;
    static NSArray<NSString *> *labels = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colors = @[
            [NSColor clearColor],                                 // 0 – empty
            [NSColor systemRedColor],                             // 1 – weak
            [NSColor systemOrangeColor],                          // 2 – fair
            [NSColor colorWithRed:0.4 green:0.8 blue:0.2 alpha:1], // 3 – strong
            [NSColor systemGreenColor],                           // 4 – very strong
        ];
        labels = @[@"", @"Weak", @"Fair", @"Strong", @"Very Strong"];
    });

    NSColor *activeColor = colors[(NSUInteger)score];
    NSArray<NSView *> *bars = self.strengthBarContainer.subviews;
    for (NSUInteger i = 0; i < bars.count; i++) {
        bars[i].layer.backgroundColor = (i < (NSUInteger)score)
            ? activeColor.CGColor
            : [NSColor colorWithWhite:0.25 alpha:1.0].CGColor;
    }
    self.strengthLabel.stringValue = labels[(NSUInteger)score];
    self.strengthLabel.textColor = activeColor;
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidEndEditing:(NSNotification *)obj {
#pragma unused(obj)
    // No persistence for login fields — security-sensitive
}

- (void)controlTextDidChange:(NSNotification *)obj {
    NSTextField *field = obj.object;
    // Keep the visible/hidden password fields in sync
    if (field == self.passwordField) {
        self.passwordPlainField.stringValue = self.passwordField.stringValue;
    } else if (field == self.passwordPlainField) {
        self.passwordField.stringValue = self.passwordPlainField.stringValue;
    }
    if (field == self.passwordField || field == self.passwordPlainField) {
        [self updatePasswordStrength];
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
    y -= 34;

    // ── OAuth buttons ──
    self.googleButton = [[NSButton alloc] initWithFrame:NSMakeRect(xPad, y, fieldW, 30)];
    [self.googleButton setTitle:@"Continue with Google"];
    [self.googleButton setTarget:self];
    [self.googleButton setAction:@selector(handleOAuthGoogle:)];
    self.googleButton.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.googleButton.bezelStyle = NSBezelStyleRounded;
    [self addSubview:self.googleButton];
    y -= 34;

    self.microsoftButton = [[NSButton alloc] initWithFrame:NSMakeRect(xPad, y, fieldW, 30)];
    [self.microsoftButton setTitle:@"Continue with Microsoft"];
    [self.microsoftButton setTarget:self];
    [self.microsoftButton setAction:@selector(handleOAuthMicrosoft:)];
    self.microsoftButton.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.microsoftButton.bezelStyle = NSBezelStyleRounded;
    [self addSubview:self.microsoftButton];
    y -= 28;

    // ── Divider ──
    NSTextField *dividerLabel = [NSTextField labelWithString:@"— or sign in with email —"];
    dividerLabel.frame = NSMakeRect(xPad, y, fieldW, 16);
    dividerLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    dividerLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    dividerLabel.textColor = [NSColor colorWithWhite:0.5 alpha:1.0];
    dividerLabel.alignment = NSTextAlignmentCenter;
    [self addSubview:dividerLabel];
    y -= 22;

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

    // ── Password plain-text twin (G6, hidden by default) ──
    self.passwordPlainField = [[NSTextField alloc] initWithFrame:self.passwordField.frame];
    self.passwordPlainField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.passwordPlainField.font = [NSFont systemFontOfSize:12];
    self.passwordPlainField.placeholderString = @"Minimum 8 characters";
    self.passwordPlainField.bordered = YES;
    self.passwordPlainField.bezeled = YES;
    self.passwordPlainField.bezelStyle = NSTextFieldRoundedBezel;
    self.passwordPlainField.drawsBackground = YES;
    self.passwordPlainField.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.9];
    self.passwordPlainField.textColor = [NSColor colorWithWhite:0.95 alpha:1.0];
    self.passwordPlainField.delegate = self;
    self.passwordPlainField.hidden = YES;
    [self addSubview:self.passwordPlainField];

    // ── Show/Hide toggle (G6) ──
    self.showPasswordButton = [NSButton buttonWithTitle:@"Show"
                                                target:self
                                                action:@selector(togglePasswordVisibility:)];
    self.showPasswordButton.frame = NSMakeRect(xPad + fieldW - 50, y, 50, 22);
    self.showPasswordButton.bordered = NO;
    self.showPasswordButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    NSMutableAttributedString *showAttr = [[NSMutableAttributedString alloc]
        initWithString:@"Show"
        attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor systemBlueColor],
        }];
    self.showPasswordButton.attributedTitle = showAttr;
    [self addSubview:self.showPasswordButton];
    y -= 4;

    // ── Password strength meter (G5, visible in register mode) ──
    CGFloat barH = 4.0;
    CGFloat barGap = 3.0;
    CGFloat barW = (fieldW - barGap * 3.0) / 4.0;
    self.strengthBarContainer = [[NSView alloc] initWithFrame:NSMakeRect(xPad, y, fieldW, barH)];
    self.strengthBarContainer.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    NSMutableArray<NSView *> *strengthBars = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4; i++) {
        NSView *bar = [[NSView alloc] initWithFrame:NSZeroRect];
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        bar.wantsLayer = YES;
        bar.layer.backgroundColor = [NSColor colorWithWhite:0.25 alpha:1.0].CGColor;
        bar.layer.cornerRadius = 2.0;
        [self.strengthBarContainer addSubview:bar];
        [strengthBars addObject:bar];

        // Fixed height, centred vertically in the container
        [bar.heightAnchor constraintEqualToConstant:barH].active = YES;
        [bar.centerYAnchor constraintEqualToAnchor:self.strengthBarContainer.centerYAnchor].active = YES;

        // Each bar occupies 1/4 of the container width minus its share of the three gaps
        [bar.widthAnchor constraintEqualToAnchor:self.strengthBarContainer.widthAnchor
                                      multiplier:(1.0 / 4.0)
                                        constant:-(barGap * 3.0 / 4.0)].active = YES;

        // Pin leading edge: first bar to container, subsequent bars to previous bar's trailing edge
        if (i == 0) {
            [bar.leadingAnchor constraintEqualToAnchor:self.strengthBarContainer.leadingAnchor].active = YES;
        } else {
            [bar.leadingAnchor constraintEqualToAnchor:strengthBars[i - 1].trailingAnchor
                                              constant:barGap].active = YES;
        }
    }
    self.strengthBarContainer.hidden = YES;
    [self addSubview:self.strengthBarContainer];
    y -= 16;

    self.strengthLabel = [NSTextField labelWithString:@""];
    self.strengthLabel.frame = NSMakeRect(xPad, y, fieldW, 14);
    self.strengthLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.strengthLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    self.strengthLabel.textColor = [NSColor colorWithWhite:0.6 alpha:1.0];
    self.strengthLabel.hidden = YES;
    [self addSubview:self.strengthLabel];
    y -= 8;

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
