// ============================================================================
// InterAccountPanel.m
// inter
//
// Account management panel — Profile, Security, Sessions, Danger Zone.
//
// Layout: NSScrollView (fills parent minus close-button row) containing a
// fixed-width (460 pt) content view tall enough for all four sections.
// All coordinates are in AppKit's bottom-left origin system.
// ============================================================================

#import "InterAccountPanel.h"

// ---------------------------------------------------------------------------
// MARK: - Layout constants
// ---------------------------------------------------------------------------

static const CGFloat kAPWidth         = 460.0;
static const CGFloat kAPContentHeight = 780.0;  // scrollable content height
static const CGFloat kAPWindowHeight  = 600.0;  // visible window height
static const CGFloat kAPCloseBarH     = 44.0;   // close-button bar at bottom
static const CGFloat kAPScrollH       = kAPWindowHeight - kAPCloseBarH;
static const CGFloat kAPMargin        = 20.0;
static const CGFloat kAPInnerW        = kAPWidth - kAPMargin * 2.0; // 420

// ---------------------------------------------------------------------------
// MARK: - Private interface
// ---------------------------------------------------------------------------

@interface InterAccountPanel ()

// Profile
@property (nonatomic, strong) NSTextField *emailValueLabel;
@property (nonatomic, strong) NSTextField *tierValueLabel;

// Change Password
@property (nonatomic, strong) NSSecureTextField *currentPwField;
@property (nonatomic, strong) NSSecureTextField *updatedPwField;
@property (nonatomic, strong) NSSecureTextField *confirmPwField;
@property (nonatomic, strong) NSButton          *changePwButton;
@property (nonatomic, strong) NSProgressIndicator *changePwSpinner;
@property (nonatomic, strong) NSTextField       *changePwStatusLabel;

// Change Email
@property (nonatomic, strong) NSSecureTextField *emailConfirmPwField;
@property (nonatomic, strong) NSTextField       *updatedEmailField;
@property (nonatomic, strong) NSButton          *changeEmailButton;
@property (nonatomic, strong) NSProgressIndicator *changeEmailSpinner;
@property (nonatomic, strong) NSTextField       *changeEmailStatusLabel;

// Sessions
@property (nonatomic, strong) NSScrollView      *sessionsTableScrollView;
@property (nonatomic, strong) NSTableView       *sessionsTableView;
@property (nonatomic, strong) NSButton          *refreshSessionsButton;
@property (nonatomic, strong) NSProgressIndicator *sessionsSpinner;
@property (nonatomic, strong) NSTextField       *sessionsEmptyLabel;
@property (nonatomic, copy)   NSArray<NSDictionary *> *sessionItems;

// Danger Zone
@property (nonatomic, strong) NSButton          *deleteAccountButton;

// Error banner (inside scroll content, auto-scrolls to top on show)
@property (nonatomic, strong) NSTextField       *bannerLabel;
@property (nonatomic, strong) NSView            *scrollContentView;
@property (nonatomic, strong) NSScrollView      *outerScrollView;

@end

// ---------------------------------------------------------------------------
// MARK: - Implementation
// ---------------------------------------------------------------------------

@implementation InterAccountPanel

// ---------------------------------------------------------------------------
// MARK: - Init
// ---------------------------------------------------------------------------

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    _sessionItems = @[];
    [self _buildUI];
    return self;
}

// ---------------------------------------------------------------------------
// MARK: - UI Construction
// ---------------------------------------------------------------------------

- (void)_buildUI {
    CGFloat W = kAPWidth;

    // ---- Outer scroll view (fills panel minus close-bar) -----------------
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, kAPCloseBarH, W, kAPScrollH)];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sv.hasVerticalScroller   = YES;
    sv.hasHorizontalScroller = NO;
    sv.drawsBackground = NO;
    [self addSubview:sv];
    self.outerScrollView = sv;

    // ---- Scroll content view ---------------------------------------------
    NSView *cv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, kAPContentHeight)];
    sv.documentView = cv;
    self.scrollContentView = cv;

    // ---- Close / separator bar -------------------------------------------
    NSBox *closeSep = [[NSBox alloc] initWithFrame:NSMakeRect(0, kAPCloseBarH - 1, W, 1)];
    closeSep.boxType = NSBoxSeparator;
    [self addSubview:closeSep];

    NSButton *closeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(W - 108, 6, 92, 32)];
    [closeBtn setTitle:@"Close"];
    [closeBtn setBezelStyle:NSBezelStyleRounded];
    [closeBtn setTarget:self];
    [closeBtn setAction:@selector(_closeWindow:)];
    [self addSubview:closeBtn];

    // ===== SCROLL CONTENT VIEW LAYOUT =====================================
    // All y coordinates are from the BOTTOM of cv (AppKit convention).
    // Content height = kAPContentHeight (780). Visual flow goes top → bottom
    // i.e. high y values appear at the top of the scroll.

    // --- Error banner (visual top: 4..22) ----------------------------------
    // y = 780 - 4 - 16 = 760
    self.bannerLabel = [NSTextField labelWithString:@""];
    self.bannerLabel.frame = NSMakeRect(kAPMargin, 760, kAPInnerW, 16);
    self.bannerLabel.textColor = [NSColor systemRedColor];
    self.bannerLabel.font = [NSFont systemFontOfSize:12];
    self.bannerLabel.hidden = YES;
    [cv addSubview:self.bannerLabel];

    // =========================================================
    // SECTION: Profile (visual top 24..92)
    // =========================================================

    NSTextField *profileHeader = [NSTextField labelWithString:@"Profile"];
    profileHeader.frame = NSMakeRect(kAPMargin, 738, 200, 18);
    profileHeader.font  = [NSFont boldSystemFontOfSize:13];
    [cv addSubview:profileHeader];

    self.emailValueLabel = [NSTextField labelWithString:@"—"];
    self.emailValueLabel.frame = NSMakeRect(kAPMargin, 716, kAPInnerW, 16);
    self.emailValueLabel.font  = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.emailValueLabel.textColor = [NSColor secondaryLabelColor];
    self.emailValueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [cv addSubview:self.emailValueLabel];

    self.tierValueLabel = [NSTextField labelWithString:@"—"];
    self.tierValueLabel.frame = NSMakeRect(kAPMargin, 696, 200, 16);
    self.tierValueLabel.font = [NSFont systemFontOfSize:11];
    self.tierValueLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:self.tierValueLabel];

    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(kAPMargin, 686, kAPInnerW, 1)];
    sep1.boxType = NSBoxSeparator;
    [cv addSubview:sep1];

    // =========================================================
    // SECTION: Security (visual top 98..438)
    // =========================================================

    NSTextField *secHeader = [NSTextField labelWithString:@"Security"];
    secHeader.frame = NSMakeRect(kAPMargin, 662, 200, 18);
    secHeader.font  = [NSFont boldSystemFontOfSize:13];
    [cv addSubview:secHeader];

    // ---- Change Password subsection ------------------------------------

    NSTextField *changePwLabel = [NSTextField labelWithString:@"Change Password"];
    changePwLabel.frame = NSMakeRect(kAPMargin, 638, 300, 14);
    changePwLabel.font  = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    changePwLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:changePwLabel];

    self.currentPwField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(kAPMargin, 608, kAPInnerW, 26)];
    self.currentPwField.placeholderString = @"Current password";
    self.currentPwField.bezelStyle = NSTextFieldRoundedBezel;
    [cv addSubview:self.currentPwField];

    self.updatedPwField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(kAPMargin, 578, kAPInnerW, 26)];
    self.updatedPwField.placeholderString = @"New password (8–72 characters)";
    self.updatedPwField.bezelStyle = NSTextFieldRoundedBezel;
    [cv addSubview:self.updatedPwField];

    self.confirmPwField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(kAPMargin, 548, kAPInnerW, 26)];
    self.confirmPwField.placeholderString = @"Confirm new password";
    self.confirmPwField.bezelStyle = NSTextFieldRoundedBezel;
    [cv addSubview:self.confirmPwField];


    self.changePwButton = [[NSButton alloc] initWithFrame:NSMakeRect(W - kAPMargin - 140, 512, 140, 28)];
    [self.changePwButton setTitle:@"Change Password"];
    [self.changePwButton setBezelStyle:NSBezelStyleRounded];
    [self.changePwButton setTarget:self];
    [self.changePwButton setAction:@selector(_changePasswordTapped:)];
    [cv addSubview:self.changePwButton];

    self.changePwSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(kAPMargin, 514, 22, 22)];
    self.changePwSpinner.style = NSProgressIndicatorStyleSpinning;
    self.changePwSpinner.controlSize = NSControlSizeSmall;
    self.changePwSpinner.hidden = YES;
    [cv addSubview:self.changePwSpinner];

    self.changePwStatusLabel = [NSTextField labelWithString:@""];
    self.changePwStatusLabel.frame = NSMakeRect(kAPMargin + 26, 516, 270, 14);
    self.changePwStatusLabel.font = [NSFont systemFontOfSize:11];
    self.changePwStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.changePwStatusLabel.hidden = YES;
    [cv addSubview:self.changePwStatusLabel];

    // ---- Separator between subsections --------------------------------

    NSBox *sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(kAPMargin, 500, kAPInnerW, 1)];
    sep2.boxType = NSBoxSeparator;
    [cv addSubview:sep2];

    // ---- Change Email subsection ----------------------------------------

    NSTextField *changeEmailLabel = [NSTextField labelWithString:@"Change Email"];
    changeEmailLabel.frame = NSMakeRect(kAPMargin, 480, 300, 14);
    changeEmailLabel.font  = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    changeEmailLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:changeEmailLabel];

    self.emailConfirmPwField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(kAPMargin, 450, kAPInnerW, 26)];
    self.emailConfirmPwField.placeholderString = @"Confirm your password";
    self.emailConfirmPwField.bezelStyle = NSTextFieldRoundedBezel;
    [cv addSubview:self.emailConfirmPwField];

    self.updatedEmailField = [[NSTextField alloc] initWithFrame:NSMakeRect(kAPMargin, 420, kAPInnerW, 26)];
    self.updatedEmailField.placeholderString = @"New email address";
    self.updatedEmailField.bezelStyle = NSTextFieldRoundedBezel;
    [cv addSubview:self.updatedEmailField];

    self.changeEmailButton = [[NSButton alloc] initWithFrame:NSMakeRect(W - kAPMargin - 140, 384, 140, 28)];
    [self.changeEmailButton setTitle:@"Send Verification"];
    [self.changeEmailButton setBezelStyle:NSBezelStyleRounded];
    [self.changeEmailButton setTarget:self];
    [self.changeEmailButton setAction:@selector(_changeEmailTapped:)];
    [cv addSubview:self.changeEmailButton];

    self.changeEmailSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(kAPMargin, 386, 22, 22)];
    self.changeEmailSpinner.style = NSProgressIndicatorStyleSpinning;
    self.changeEmailSpinner.controlSize = NSControlSizeSmall;
    self.changeEmailSpinner.hidden = YES;
    [cv addSubview:self.changeEmailSpinner];

    self.changeEmailStatusLabel = [NSTextField labelWithString:@""];
    self.changeEmailStatusLabel.frame = NSMakeRect(kAPMargin + 26, 388, 250, 14);
    self.changeEmailStatusLabel.font = [NSFont systemFontOfSize:11];
    self.changeEmailStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.changeEmailStatusLabel.hidden = YES;
    [cv addSubview:self.changeEmailStatusLabel];

    NSBox *sep3 = [[NSBox alloc] initWithFrame:NSMakeRect(kAPMargin, 372, kAPInnerW, 1)];
    sep3.boxType = NSBoxSeparator;
    [cv addSubview:sep3];

    // =========================================================
    // SECTION: Active Sessions (visual top ~386..580)
    // =========================================================

    NSTextField *sessionsHeader = [NSTextField labelWithString:@"Active Sessions"];
    sessionsHeader.frame = NSMakeRect(kAPMargin, 348, 200, 18);
    sessionsHeader.font  = [NSFont boldSystemFontOfSize:13];
    [cv addSubview:sessionsHeader];

    self.refreshSessionsButton = [[NSButton alloc] initWithFrame:NSMakeRect(W - kAPMargin - 80, 348, 80, 22)];
    [self.refreshSessionsButton setTitle:@"Refresh"];
    [self.refreshSessionsButton setBezelStyle:NSBezelStyleRounded];
    [self.refreshSessionsButton setFont:[NSFont systemFontOfSize:11]];
    [self.refreshSessionsButton setTarget:self];
    [self.refreshSessionsButton setAction:@selector(_refreshSessionsTapped:)];
    [cv addSubview:self.refreshSessionsButton];

    self.sessionsSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(kAPMargin, 350, 18, 18)];
    self.sessionsSpinner.style = NSProgressIndicatorStyleSpinning;
    self.sessionsSpinner.controlSize = NSControlSizeSmall;
    self.sessionsSpinner.hidden = YES;
    [cv addSubview:self.sessionsSpinner];

    // Sessions table inside its own scroll view
    NSScrollView *tsv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 188, W, 154)];
    tsv.hasVerticalScroller = YES;
    tsv.hasHorizontalScroller = NO;
    tsv.drawsBackground = YES;
    [cv addSubview:tsv];
    self.sessionsTableScrollView = tsv;

    NSTableView *tv = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, W, 154)];
    tv.dataSource = self;
    tv.delegate   = self;
    tv.rowHeight   = 28.0;
    tv.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    tv.intercellSpacing = NSMakeSize(0, 1);

    NSTableColumn *colDevice = [[NSTableColumn alloc] initWithIdentifier:@"device"];
    colDevice.title = @"Device";
    colDevice.width = 120;
    [tv addTableColumn:colDevice];

    NSTableColumn *colCreated = [[NSTableColumn alloc] initWithIdentifier:@"created"];
    colCreated.title = @"Started";
    colCreated.width = 110;
    [tv addTableColumn:colCreated];

    NSTableColumn *colUsed = [[NSTableColumn alloc] initWithIdentifier:@"lastUsed"];
    colUsed.title = @"Last Used";
    colUsed.width = 110;
    [tv addTableColumn:colUsed];

    NSTableColumn *colAction = [[NSTableColumn alloc] initWithIdentifier:@"action"];
    colAction.title = @"";
    colAction.width = 120;
    [tv addTableColumn:colAction];

    tsv.documentView = tv;
    self.sessionsTableView = tv;

    // Empty-state label (overlaps table area, shown when sessions == 0)
    self.sessionsEmptyLabel = [NSTextField labelWithString:@"No active sessions found."];
    self.sessionsEmptyLabel.frame = NSMakeRect(kAPMargin, 238, kAPInnerW, 16);
    self.sessionsEmptyLabel.alignment = NSTextAlignmentCenter;
    self.sessionsEmptyLabel.textColor = [NSColor tertiaryLabelColor];
    self.sessionsEmptyLabel.font = [NSFont systemFontOfSize:11];
    self.sessionsEmptyLabel.hidden = YES;
    [cv addSubview:self.sessionsEmptyLabel];

    NSBox *sep4 = [[NSBox alloc] initWithFrame:NSMakeRect(0, 183, W, 1)];
    sep4.boxType = NSBoxSeparator;
    [cv addSubview:sep4];

    // =========================================================
    // SECTION: Danger Zone (visual top ~593..680)
    // =========================================================

    NSTextField *dangerHeader = [NSTextField labelWithString:@"⚠ Danger Zone"];
    dangerHeader.frame = NSMakeRect(kAPMargin, 158, 260, 18);
    dangerHeader.font  = [NSFont boldSystemFontOfSize:13];
    dangerHeader.textColor = [NSColor systemRedColor];
    [cv addSubview:dangerHeader];

    NSTextField *dangerDesc = [NSTextField labelWithString:
        @"Permanently deletes your account and cancels any active subscription. Cannot be undone."];
    dangerDesc.frame = NSMakeRect(kAPMargin, 132, kAPInnerW, 26);
    dangerDesc.font = [NSFont systemFontOfSize:11];
    dangerDesc.textColor = [NSColor secondaryLabelColor];
    dangerDesc.maximumNumberOfLines = 2;
    dangerDesc.lineBreakMode = NSLineBreakByWordWrapping;
    [cv addSubview:dangerDesc];

    self.deleteAccountButton = [[NSButton alloc] initWithFrame:NSMakeRect(W - kAPMargin - 140, 92, 140, 28)];
    [self.deleteAccountButton setTitle:@"Delete Account…"];
    [self.deleteAccountButton setBezelStyle:NSBezelStyleRounded];
    [self.deleteAccountButton setTarget:self];
    [self.deleteAccountButton setAction:@selector(_deleteAccountTapped:)];
    if (@available(macOS 11.0, *)) {
        self.deleteAccountButton.contentTintColor = [NSColor systemRedColor];
    }
    [cv addSubview:self.deleteAccountButton];
}

// ---------------------------------------------------------------------------
// MARK: - Public API
// ---------------------------------------------------------------------------

- (void)setEmail:(nullable NSString *)email tier:(nullable NSString *)tier {
    self.emailValueLabel.stringValue = email ?: @"—";
    NSString *tierStr = tier.length > 0 ? tier : @"free";
    self.tierValueLabel.stringValue = [NSString stringWithFormat:@"Plan: %@", tierStr.capitalizedString];
}

- (void)setSessions:(nullable NSArray<NSDictionary *> *)sessions {
    self.sessionItems = sessions ?: @[];
    [self.sessionsTableView reloadData];
    self.sessionsTableScrollView.hidden = (self.sessionItems.count == 0);
    self.sessionsEmptyLabel.hidden      = (self.sessionItems.count > 0);
}

- (void)setSessionsLoading:(BOOL)loading {
    if (loading) {
        self.sessionsSpinner.hidden = NO;
        [self.sessionsSpinner startAnimation:nil];
        self.refreshSessionsButton.enabled = NO;
    } else {
        [self.sessionsSpinner stopAnimation:nil];
        self.sessionsSpinner.hidden = YES;
        self.refreshSessionsButton.enabled = YES;
    }
}

- (void)showBannerError:(NSString *)message {
    self.bannerLabel.stringValue = message ?: @"";
    self.bannerLabel.hidden = NO;
    // Scroll to top so the banner is visible
    NSPoint topPoint = NSMakePoint(0, kAPContentHeight - kAPScrollH);
    if (topPoint.y < 0) topPoint.y = 0;
    [self.outerScrollView.contentView scrollToPoint:topPoint];
    [self.outerScrollView reflectScrolledClipView:self.outerScrollView.contentView];
}

- (void)clearBanner {
    self.bannerLabel.stringValue = @"";
    self.bannerLabel.hidden = YES;
}

// ---------------------------------------------------------------------------
// MARK: - Actions
// ---------------------------------------------------------------------------

- (void)_closeWindow:(id)sender {
#pragma unused(sender)
    [self.window orderOut:nil];
}

- (void)_changePasswordTapped:(id)sender {
#pragma unused(sender)
    [self clearBanner];

    NSString *current  = self.currentPwField.stringValue;
    NSString *updatedPw = self.updatedPwField.stringValue;
    NSString *confirm    = self.confirmPwField.stringValue;

    if (current.length == 0 || updatedPw.length == 0 || confirm.length == 0) {
        [self _showPwStatus:@"Please fill in all password fields." isError:YES];
        return;
    }
    if (updatedPw.length < 8 || updatedPw.length > 72) {
        [self _showPwStatus:@"New password must be between 8 and 72 characters." isError:YES];
        return;
    }
    if (![updatedPw isEqualToString:confirm]) {
        [self _showPwStatus:@"Passwords do not match." isError:YES];
        return;
    }

    [self _setPwActionsEnabled:NO loading:YES];

    __weak typeof(self) weakSelf = self;
    [self.delegate accountPanel:self
       didRequestChangePassword:current
                    newPassword:updatedPw
                     completion:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf _setPwActionsEnabled:YES loading:NO];
        if (error) {
            [strongSelf _showPwStatus:error.localizedDescription isError:YES];
        } else {
            strongSelf.currentPwField.stringValue   = @"";
            strongSelf.updatedPwField.stringValue    = @"";
            strongSelf.confirmPwField.stringValue    = @"";
            [strongSelf _showPwStatus:@"Password changed. Other sessions revoked." isError:NO];
        }
    }];
}

- (void)_changeEmailTapped:(id)sender {
#pragma unused(sender)
    [self clearBanner];

    NSString *pw       = self.emailConfirmPwField.stringValue;
    NSString *newEmail = [self.updatedEmailField.stringValue
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (pw.length == 0 || newEmail.length == 0) {
        [self _showEmailStatus:@"Please fill in both fields." isError:YES];
        return;
    }
    // Minimal email format check
    if ([newEmail rangeOfString:@"@"].location == NSNotFound) {
        [self _showEmailStatus:@"Enter a valid email address." isError:YES];
        return;
    }

    [self _setEmailActionsEnabled:NO loading:YES];

    __weak typeof(self) weakSelf = self;
    NSString *capturedEmail = newEmail;
    [self.delegate accountPanel:self
          didRequestChangeEmail:pw
                       newEmail:capturedEmail
                     completion:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf _setEmailActionsEnabled:YES loading:NO];
        if (error) {
            [strongSelf _showEmailStatus:error.localizedDescription isError:YES];
        } else {
            strongSelf.emailConfirmPwField.stringValue  = @"";
            strongSelf.updatedEmailField.stringValue     = @"";
            NSString *msg = [NSString stringWithFormat:
                @"Verification email sent to %@. Click the link to confirm.", capturedEmail];
            [strongSelf _showEmailStatus:msg isError:NO];
        }
    }];
}

- (void)_refreshSessionsTapped:(id)sender {
#pragma unused(sender)
    [self clearBanner];
    [self setSessionsLoading:YES];

    __weak typeof(self) weakSelf = self;
    [self.delegate accountPanelDidRequestLoadSessions:self
                                           completion:^(NSArray<NSDictionary *> *sessions, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setSessionsLoading:NO];
        if (error) {
            [strongSelf showBannerError:error.localizedDescription];
        } else {
            [strongSelf setSessions:sessions];
        }
    }];
}

- (void)_revokeSessionAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.sessionItems.count) return;

    NSDictionary *session = self.sessionItems[row];
    NSString *sessionId   = session[@"id"];
    if (sessionId.length == 0) return;

    // Disable all revoke buttons while the request is in-flight
    [self setSessionsLoading:YES];

    __weak typeof(self) weakSelf = self;
    [self.delegate accountPanel:self
        didRequestRevokeSession:sessionId
                     completion:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            [strongSelf setSessionsLoading:NO];
            [strongSelf showBannerError:error.localizedDescription];
        } else {
            // Reload the sessions list after successful revocation
            [strongSelf _refreshSessionsTapped:nil];
        }
    }];
}

- (void)_deleteAccountTapped:(id)sender {
#pragma unused(sender)
    [self clearBanner];

    // Show a confirmation alert with a password field
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Delete Account";
    alert.informativeText =
        @"This will permanently delete your account and cancel any active subscription.\n\n"
        @"Enter your password to confirm. This cannot be undone.";
    [alert addButtonWithTitle:@"Delete My Account"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.buttons[0].hasDestructiveAction = YES;

    NSSecureTextField *pwField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    pwField.placeholderString = @"Password";
    pwField.bezelStyle = NSTextFieldRoundedBezel;
    alert.accessoryView = pwField;

    NSWindow *parentWindow = self.window;
    if (parentWindow) {
        __weak typeof(self) weakSelf = self;
        [alert beginSheetModalForWindow:parentWindow completionHandler:^(NSModalResponse response) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (response != NSAlertFirstButtonReturn) return;

            NSString *password = pwField.stringValue;
            if (password.length == 0) {
                [strongSelf showBannerError:@"Password is required to delete your account."];
                return;
            }

            [strongSelf.deleteAccountButton setEnabled:NO];

            [strongSelf.delegate accountPanel:strongSelf
                didRequestDeleteAccount:password
                             completion:^(NSError *error) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf.deleteAccountButton setEnabled:YES];
                if (error) {
                    [strongSelf showBannerError:error.localizedDescription];
                } else {
                    if ([strongSelf.delegate respondsToSelector:@selector(accountPanelDidDeleteAccount:)]) {
                        [strongSelf.delegate accountPanelDidDeleteAccount:strongSelf];
                    } else {
                        // Fallback: delegate didn't handle teardown — dismiss the window
                        // ourselves so the UI is never left in an inconsistent state.
                        [strongSelf.window orderOut:nil];
                    }
                }
            }];
        }];
    } else {
        // Fallback: run modally if no parent window (should not happen in normal use)
        NSModalResponse response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) return;

        NSString *password = pwField.stringValue;
        if (password.length == 0) {
            [self showBannerError:@"Password is required to delete your account."];
            return;
        }

        [self.deleteAccountButton setEnabled:NO];
        __weak typeof(self) weakSelf = self;
        [self.delegate accountPanel:self
            didRequestDeleteAccount:password
                         completion:^(NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.deleteAccountButton setEnabled:YES];
            if (error) {
                [strongSelf showBannerError:error.localizedDescription];
            } else {
                if ([strongSelf.delegate respondsToSelector:@selector(accountPanelDidDeleteAccount:)]) {
                    [strongSelf.delegate accountPanelDidDeleteAccount:strongSelf];
                } else {
                    // Fallback: delegate didn't handle teardown — dismiss the window
                    // ourselves so the UI is never left in an inconsistent state.
                    [strongSelf.window orderOut:nil];
                }
            }
        }];
    }
}

// ---------------------------------------------------------------------------
// MARK: - Private Helpers
// ---------------------------------------------------------------------------

- (void)_setPwActionsEnabled:(BOOL)enabled loading:(BOOL)loading {
    self.changePwButton.enabled    = enabled;
    self.currentPwField.enabled    = enabled;
    self.updatedPwField.enabled    = enabled;
    self.confirmPwField.enabled    = enabled;
    self.changePwSpinner.hidden    = !loading;
    if (loading) {
        [self.changePwSpinner startAnimation:nil];
    } else {
        [self.changePwSpinner stopAnimation:nil];
    }
}

- (void)_setEmailActionsEnabled:(BOOL)enabled loading:(BOOL)loading {
    self.changeEmailButton.enabled       = enabled;
    self.emailConfirmPwField.enabled     = enabled;
    self.updatedEmailField.enabled       = enabled;
    self.changeEmailSpinner.hidden      = !loading;
    if (loading) {
        [self.changeEmailSpinner startAnimation:nil];
    } else {
        [self.changeEmailSpinner stopAnimation:nil];
    }
}

- (void)_showPwStatus:(NSString *)message isError:(BOOL)isError {
    self.changePwStatusLabel.stringValue = message;
    self.changePwStatusLabel.textColor   = isError ? [NSColor systemRedColor]
                                                    : [NSColor systemGreenColor];
    self.changePwStatusLabel.hidden      = NO;
}

- (void)_showEmailStatus:(NSString *)message isError:(BOOL)isError {
    self.changeEmailStatusLabel.stringValue = message;
    self.changeEmailStatusLabel.textColor   = isError ? [NSColor systemRedColor]
                                                       : [NSColor systemGreenColor];
    self.changeEmailStatusLabel.hidden      = NO;
}

// ---------------------------------------------------------------------------
// MARK: - Private: NSNull-safe accessors
// ---------------------------------------------------------------------------

/// Returns nil when value is NSNull or not an NSString; otherwise the string itself.
static inline NSString *_safeString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// Returns NO when value is NSNull; otherwise calls -boolValue.
static inline BOOL _safeBool(id value) {
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

// ---------------------------------------------------------------------------
// MARK: - NSTableViewDataSource
// ---------------------------------------------------------------------------

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
#pragma unused(tableView)
    return (NSInteger)self.sessionItems.count;
}

// ---------------------------------------------------------------------------
// MARK: - NSTableViewDelegate
// ---------------------------------------------------------------------------

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.sessionItems.count) return nil;

    NSDictionary *session = self.sessionItems[row];
    NSString *colId       = tableColumn.identifier;
    NSString *cellId      = [NSString stringWithFormat:@"cell_%@", colId];

    BOOL isCurrent = _safeBool(session[@"isCurrent"]);

    if ([colId isEqualToString:@"action"]) {
        // Action column: "This Device" label or "Revoke" button
        if (isCurrent) {
            NSTextField *label = [tableView makeViewWithIdentifier:@"cell_current" owner:nil];
            if (!label) {
                label = [NSTextField labelWithString:@"This Device"];
                label.identifier = @"cell_current";
            }
            label.stringValue = @"This Device";
            label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
            label.textColor = [NSColor systemGreenColor];
            label.alignment = NSTextAlignmentCenter;
            return label;
        } else {
            NSButton *revokeBtn = [tableView makeViewWithIdentifier:@"cell_revoke" owner:nil];
            if (!revokeBtn) {
                revokeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 22)];
                [revokeBtn setBezelStyle:NSBezelStyleRounded];
                [revokeBtn setFont:[NSFont systemFontOfSize:11]];
                revokeBtn.identifier = @"cell_revoke";
                [revokeBtn setTarget:self];
                [revokeBtn setAction:@selector(_revokeButtonClicked:)];
            }
            [revokeBtn setTitle:@"Revoke"];
            revokeBtn.tag = row;
            return revokeBtn;
        }
    }

    NSTextField *cell = [tableView makeViewWithIdentifier:cellId owner:nil];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = cellId;
        cell.font = [NSFont systemFontOfSize:11];
        cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }

    if ([colId isEqualToString:@"device"]) {
        NSString *clientId = _safeString(session[@"clientId"]) ?: @"";
        if (clientId.length > 8) {
            clientId = [NSString stringWithFormat:@"\u2026%@", [clientId substringFromIndex:clientId.length - 8]];
        } else if (clientId.length == 0) {
            clientId = @"Unknown";
        }
        cell.stringValue = clientId;
    } else if ([colId isEqualToString:@"created"]) {
        cell.stringValue = [self _formattedDate:_safeString(session[@"createdAt"])] ?: @"\u2014";
    } else if ([colId isEqualToString:@"lastUsed"]) {
        cell.stringValue = [self _formattedDate:_safeString(session[@"lastUsedAt"])] ?: @"Never";
    }

    return cell;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
#pragma unused(tableView, row)
    return 28.0;
}

// ---------------------------------------------------------------------------
// MARK: - Private: Revoke Button Action
// ---------------------------------------------------------------------------

- (void)_revokeButtonClicked:(NSButton *)sender {
    [self _revokeSessionAtRow:sender.tag];
}

// ---------------------------------------------------------------------------
// MARK: - Private: Date Formatting
// ---------------------------------------------------------------------------

- (nullable NSString *)_formattedDate:(nullable id)value {
    if (!value || value == [NSNull null]) return nil;
    NSString *str = [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
    if (str.length == 0) return nil;

    static NSISO8601DateFormatter *isoFmtWithFractionalSeconds = nil;
    static NSISO8601DateFormatter *isoFmtWithoutFractionalSeconds = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isoFmtWithFractionalSeconds = [[NSISO8601DateFormatter alloc] init];
        isoFmtWithFractionalSeconds.formatOptions = NSISO8601DateFormatWithInternetDateTime
                                                  | NSISO8601DateFormatWithFractionalSeconds;
        isoFmtWithoutFractionalSeconds = [[NSISO8601DateFormatter alloc] init];
        isoFmtWithoutFractionalSeconds.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });

    NSDate *date = [isoFmtWithFractionalSeconds dateFromString:str];
    if (!date) {
        date = [isoFmtWithoutFractionalSeconds dateFromString:str];
    }
    if (!date) return nil;

    static NSDateFormatter *displayFmt = nil;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        displayFmt = [[NSDateFormatter alloc] init];
        displayFmt.dateStyle = NSDateFormatterShortStyle;
        displayFmt.timeStyle = NSDateFormatterShortStyle;
        displayFmt.doesRelativeDateFormatting = YES;
    });

    return [displayFmt stringFromDate:date];
}

@end
