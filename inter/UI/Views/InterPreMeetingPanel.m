#import "InterPreMeetingPanel.h"

// ---------------------------------------------------------------------------
// MARK: - String constants
// ---------------------------------------------------------------------------

NSString *const InterChatPermissionsEveryone  = @"everyone";
NSString *const InterChatPermissionsHostOnly  = @"hostOnly";
NSString *const InterChatPermissionsDisabled  = @"disabled";

NSString *const InterSharingPermissionsHostOnly = @"hostOnly";
NSString *const InterSharingPermissionsEveryone = @"everyone";
NSString *const InterSharingPermissionsRequest  = @"request";

NSString *const InterSharingConflictOneAtATime    = @"oneattime";
NSString *const InterSharingConflictHostCanPreempt = @"hostCanPreempt";
NSString *const InterSharingConflictAnyCanPreempt  = @"anyCanPreempt";

// ---------------------------------------------------------------------------
// MARK: - UserDefaults keys
// ---------------------------------------------------------------------------

static NSString *const kUDMuteOnJoin          = @"InterPreMeeting_MuteOnJoin";
static NSString *const kUDCameraOffOnJoin      = @"InterPreMeeting_CameraOffOnJoin";
static NSString *const kUDLobbyEnabled         = @"InterPreMeeting_LobbyEnabled";
static NSString *const kUDJoinBeforeHost       = @"InterPreMeeting_JoinBeforeHost";
static NSString *const kUDAllowUnmuting        = @"InterPreMeeting_AllowUnmuting";
static NSString *const kUDChatPermissions      = @"InterPreMeeting_ChatPermissions";
static NSString *const kUDSharingPermissions   = @"InterPreMeeting_SharingPermissions";
static NSString *const kUDShareConflictPolicy  = @"InterPreMeeting_ShareConflictPolicy";
static NSString *const kUDAutoRecord           = @"InterPreMeeting_AutoRecord";
static NSString *const kUDAutoTranscript       = @"InterPreMeeting_AutoTranscript";
static NSString *const kUDAllowCoHostLocalRecording = @"InterPreMeeting_AllowCoHostLocalRecording";
/// Set once the host saves their meeting defaults; gates compact-vs-full panel.
static NSString *const kUDHasConfiguredDefaults = @"InterPreMeeting_HasConfiguredDefaults";

// ---------------------------------------------------------------------------
// MARK: - InterPreMeetingSettings
// ---------------------------------------------------------------------------

@implementation InterPreMeetingSettings

+ (instancetype)settingsWithDefaults {
    InterPreMeetingSettings *s = [[InterPreMeetingSettings alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    s.meetingDisplayName   = @"";
    s.meetingPassword      = @"";
    s.muteOnJoin           = [ud boolForKey:kUDMuteOnJoin];
    s.cameraOffOnJoin      = [ud boolForKey:kUDCameraOffOnJoin];
    s.lobbyEnabled         = [ud boolForKey:kUDLobbyEnabled];
    s.joinBeforeHost       = [ud boolForKey:kUDJoinBeforeHost];
    // allowUnmuting defaults to YES if never saved before
    s.allowUnmuting        = ([ud objectForKey:kUDAllowUnmuting] == nil)
                             ? YES : [ud boolForKey:kUDAllowUnmuting];
    s.chatPermissions      = [ud stringForKey:kUDChatPermissions] ?: InterChatPermissionsEveryone;
    s.sharingPermissions   = [ud stringForKey:kUDSharingPermissions] ?: InterSharingPermissionsHostOnly;
    s.shareConflictPolicy  = [ud stringForKey:kUDShareConflictPolicy] ?: InterSharingConflictOneAtATime;
    s.autoRecord           = [ud boolForKey:kUDAutoRecord];
    s.autoTranscript       = [ud boolForKey:kUDAutoTranscript];
    s.allowCoHostLocalRecording = [ud boolForKey:kUDAllowCoHostLocalRecording];
    return s;
}

- (void)saveToUserDefaults {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:self.muteOnJoin         forKey:kUDMuteOnJoin];
    [ud setBool:self.cameraOffOnJoin    forKey:kUDCameraOffOnJoin];
    [ud setBool:self.lobbyEnabled       forKey:kUDLobbyEnabled];
    [ud setBool:self.joinBeforeHost     forKey:kUDJoinBeforeHost];
    [ud setBool:self.allowUnmuting      forKey:kUDAllowUnmuting];
    [ud setObject:self.chatPermissions      forKey:kUDChatPermissions];
    [ud setObject:self.sharingPermissions   forKey:kUDSharingPermissions];
    [ud setObject:self.shareConflictPolicy  forKey:kUDShareConflictPolicy];
    [ud setBool:self.autoRecord         forKey:kUDAutoRecord];
    [ud setBool:self.autoTranscript     forKey:kUDAutoTranscript];
    [ud setBool:self.allowCoHostLocalRecording forKey:kUDAllowCoHostLocalRecording];
    // Mark that defaults have been configured so future host-calls use the compact panel.
    [ud setBool:YES forKey:kUDHasConfiguredDefaults];
    [ud synchronize];
}

+ (BOOL)hasConfiguredDefaults {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kUDHasConfiguredDefaults];
}

- (id)copyWithZone:(NSZone *)zone {
    InterPreMeetingSettings *c = [[InterPreMeetingSettings allocWithZone:zone] init];
    c.meetingDisplayName   = [self.meetingDisplayName copy];
    c.meetingPassword      = [self.meetingPassword copy];
    c.muteOnJoin           = self.muteOnJoin;
    c.cameraOffOnJoin      = self.cameraOffOnJoin;
    c.lobbyEnabled         = self.lobbyEnabled;
    c.joinBeforeHost       = self.joinBeforeHost;
    c.allowUnmuting        = self.allowUnmuting;
    c.chatPermissions      = [self.chatPermissions copy];
    c.sharingPermissions   = [self.sharingPermissions copy];
    c.shareConflictPolicy  = [self.shareConflictPolicy copy];
    c.autoRecord           = self.autoRecord;
    c.autoTranscript       = self.autoTranscript;
    c.allowCoHostLocalRecording = self.allowCoHostLocalRecording;
    return c;
}

@end

// ---------------------------------------------------------------------------
// MARK: - Layout helpers
// ---------------------------------------------------------------------------

/// Height of the scrollable content.
static const CGFloat kContentH = 756.0;
static const CGFloat kPanelW   = 440.0;

/// Horizontal margins and column positions.
static const CGFloat kMarginL    = 20.0;  // left margin for labels
static const CGFloat kControlX   = 280.0; // x-offset of right-side control
static const CGFloat kControlW   = 140.0; // width of popup/button controls

// ---------------------------------------------------------------------------
// MARK: - InterPreMeetingPanel
// ---------------------------------------------------------------------------

@interface InterPreMeetingPanel () {
    // Scroll + content layout
    NSScrollView *_scrollView;
    NSView       *_contentView;

    // Title area
    NSTextField  *_titleLabel;

    // General
    NSTextField  *_meetingNameField;

    // Participant controls
    NSButton     *_muteMicToggle;
    NSButton     *_cameraOffToggle;
    NSButton     *_allowUnmutingToggle;

    // Security
    NSButton     *_lobbyToggle;
    NSButton     *_passwordToggle;
    NSTextField  *_passwordField;
    NSButton     *_joinBeforeHostToggle;

    // Chat & Sharing
    NSPopUpButton *_chatPermissionsPopup;
    NSPopUpButton *_sharingPermissionsPopup;
    NSPopUpButton *_shareConflictPopup;

    // Pro features
    NSButton     *_autoRecordToggle;
    NSButton     *_autoTranscriptToggle;
    NSButton     *_allowCoHostLocalRecordingToggle;
    NSTextField  *_proNoteLabel;

    // Bottom buttons
    NSButton     *_cancelButton;
    NSButton     *_startButton;

    // Compact mode (additive overlay; full controls still built + hidden)
    BOOL              _compactMode;
    BOOL              _advancedExpanded;
    NSView           *_compactContainer;
    NSTextField      *_compactNameField;
    NSButton         *_compactPasswordToggle;
    NSSecureTextField *_compactPasswordField;
    NSButton         *_advancedButton;

    // Defaults-editor mode (Save instead of Start; no meeting launch)
    BOOL              _defaultsEditorMode;

    BOOL _isPro;
}
@end

@implementation InterPreMeetingPanel

// ---------------------------------------------------------------------------
// MARK: - Init
// ---------------------------------------------------------------------------

- (instancetype)initWithFrame:(NSRect)frame {
    return [self initWithFrame:frame compactMode:NO];
}

- (instancetype)initWithFrame:(NSRect)frame compactMode:(BOOL)compactMode {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _compactMode = compactMode;
    [self _buildUI];
    [self _loadDefaults];
    if (compactMode) {
        // Build the compact overlay AFTER defaults are loaded so the summary chips
        // reflect the actual saved settings. The full controls remain built (hidden),
        // so -_collectSettings keeps reading the single canonical set of controls.
        [self _buildCompactOverlay];
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frame defaultsEditor:(BOOL)defaultsEditor {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    // Set the flag BEFORE -_buildUI so the per-meeting rows are omitted entirely
    // (avoids leaving empty gaps that hiding-after-build would produce).
    _defaultsEditorMode = defaultsEditor;
    [self _buildUI];
    [self _loadDefaults];
    if (defaultsEditor) {
        [self configureAsDefaultsEditor];
    }
    return self;
}

+ (CGFloat)fullPanelHeight { return 620.0; }
+ (CGFloat)compactPanelHeight { return 380.0; }

- (void)configureAsDefaultsEditor {
    _defaultsEditorMode = YES;
    _startButton.title = @"Save";
    _cancelButton.title = @"Close";
    _titleLabel.stringValue = @"Default Meeting Settings";
}

// ---------------------------------------------------------------------------
// MARK: - Public API
// ---------------------------------------------------------------------------

- (void)setDisplayName:(NSString *)displayName {
    if (displayName.length > 0) {
        NSString *t = [NSString stringWithFormat:@"%@'s Meeting", displayName];
        _meetingNameField.stringValue = t;
        // Mirror into the compact field too (no-op when not in compact mode).
        _compactNameField.stringValue = t;
    }
}

- (void)setUserTier:(NSString *)tier {
    _isPro = ([tier isEqualToString:@"pro"] ||
              [tier isEqualToString:@"pro+"] ||
              [tier isEqualToString:@"hiring"]);
    [self _refreshProGating];
}

// ---------------------------------------------------------------------------
// MARK: - UI Construction
// ---------------------------------------------------------------------------

- (void)_buildUI {
    [self setWantsLayer:YES];
    self.layer.backgroundColor = [NSColor colorWithWhite:0.14 alpha:1.0].CGColor;

    // ---- Bottom action buttons (outside scroll, at panel bottom) ----
    CGFloat btnY = 12.0;
    _cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(kMarginL, btnY, 100.0, 32.0)];
    _cancelButton.title = @"Cancel";
    _cancelButton.bezelStyle = NSBezelStyleRounded;
    _cancelButton.target = self;
    _cancelButton.action = @selector(_cancelTapped:);
    [self addSubview:_cancelButton];

    _startButton = [[NSButton alloc] initWithFrame:
        NSMakeRect(kPanelW - kMarginL - 140.0, btnY, 140.0, 32.0)];
    _startButton.title = @"Start Meeting";
    _startButton.bezelStyle = NSBezelStyleRounded;
    _startButton.keyEquivalent = @"\r";
    [_startButton setContentTintColor:[NSColor systemBlueColor]];
    _startButton.target = self;
    _startButton.action = @selector(_startTapped:);
    [self addSubview:_startButton];

    // ---- Scroll view (fills everything above buttons) ----
    CGFloat scrollY   = 56.0;
    CGFloat scrollH   = self.bounds.size.height - scrollY;
    _scrollView = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, scrollY, kPanelW, scrollH)];
    _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.autohidesScrollers  = YES;
    _scrollView.drawsBackground     = NO;
    _scrollView.borderType          = NSNoBorder;

    _contentView = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, kPanelW, kContentH)];
    _scrollView.documentView = _contentView;
    [self addSubview:_scrollView];

    // Thin separator above buttons
    NSBox *btnSep = [[NSBox alloc]
        initWithFrame:NSMakeRect(0, 52.0, kPanelW, 1.0)];
    btnSep.boxType = NSBoxSeparator;
    [self addSubview:btnSep];

    // ---- Populate content view (from bottom up) ----
    CGFloat y = 12.0; // current y in contentView, bottom-up

    // ---- PRO FEATURES section ----
    y = [self _addSeparatorAt:y inView:_contentView];
    _autoTranscriptToggle = [self _addToggleRowWithLabel:@"Auto-Transcript" y:y inView:_contentView];
    y += 32.0;
    _autoRecordToggle = [self _addToggleRowWithLabel:@"Auto-Record to Cloud" y:y inView:_contentView];
    y += 32.0;
    _allowCoHostLocalRecordingToggle = [self _addToggleRowWithLabel:@"Allow Co-Host Local Recording" y:y inView:_contentView];
    y += 32.0;

    // Pro badge / note
    _proNoteLabel = [self _makeLabel:@"✦ Requires Pro or Pro+ subscription"
                               fontSize:10.0
                               isBold:NO];
    _proNoteLabel.frame = NSMakeRect(kMarginL, y, kPanelW - kMarginL * 2, 14.0);
    _proNoteLabel.textColor = [NSColor systemYellowColor];
    [_contentView addSubview:_proNoteLabel];
    y += 20.0;

    y = [self _addSectionHeader:@"RECORDING & TRANSCRIPTION" y:y inView:_contentView];

    // ---- CHAT & SHARING section ----
    y = [self _addSeparatorAt:y inView:_contentView];
    _shareConflictPopup = [self _addPopupRowWithLabel:@"Share Takeover"
                                              options:@[@"One at a Time", @"Host Can Take Over", @"Anyone Can Take Over"]
                                                    y:y
                                               inView:_contentView];
    y += 36.0;
    _sharingPermissionsPopup = [self _addPopupRowWithLabel:@"Screen Sharing"
                                                  options:@[@"Host Only", @"Everyone", @"Request to Share"]
                                                        y:y
                                                   inView:_contentView];
    y += 36.0;
    _chatPermissionsPopup = [self _addPopupRowWithLabel:@"Chat Permissions"
                                               options:@[@"Everyone", @"Host Only", @"Disabled"]
                                                     y:y
                                                inView:_contentView];
    y += 36.0;
    y = [self _addSectionHeader:@"CHAT & SHARING" y:y inView:_contentView];

    // ---- SECURITY section ----
    y = [self _addSeparatorAt:y inView:_contentView];
    _joinBeforeHostToggle = [self _addToggleRowWithLabel:@"Join Before Host" y:y inView:_contentView];
    y += 32.0;

    // Password row: toggle + inline text field.
    // Omitted in defaults-editor mode — a password is per-meeting, never a default.
    if (!_defaultsEditorMode) {
        y = [self _addPasswordRowAt:y inView:_contentView];
    }

    _lobbyToggle = [self _addToggleRowWithLabel:@"Enable Waiting Room" y:y inView:_contentView];
    y += 32.0;
    y = [self _addSectionHeader:@"SECURITY" y:y inView:_contentView];

    // ---- PARTICIPANT CONTROLS section ----
    y = [self _addSeparatorAt:y inView:_contentView];
    _allowUnmutingToggle = [self _addToggleRowWithLabel:@"Allow Unmuting" y:y inView:_contentView];
    y += 32.0;
    _cameraOffToggle = [self _addToggleRowWithLabel:@"Turn Off Camera After Joining" y:y inView:_contentView];
    y += 32.0;
    _muteMicToggle = [self _addToggleRowWithLabel:@"Mute Mic After Joining" y:y inView:_contentView];
    y += 32.0;
    y = [self _addSectionHeader:@"PARTICIPANT CONTROLS" y:y inView:_contentView];

    // ---- GENERAL section ----
    // Meeting Name is per-meeting (not a default), so omit it in defaults-editor mode.
    if (!_defaultsEditorMode) {
        y = [self _addSeparatorAt:y inView:_contentView];
        y = [self _addMeetingNameRowAt:y inView:_contentView];
        y = [self _addSectionHeader:@"GENERAL" y:y inView:_contentView];
    }

    // ---- Title ----
    y = [self _addSeparatorAt:y inView:_contentView];
    _titleLabel = [self _makeLabel:@"New Meeting"
                          fontSize:17.0
                            isBold:YES];
    _titleLabel.frame = NSMakeRect(kMarginL, y, kPanelW - kMarginL * 2, 28.0);
    [_contentView addSubview:_titleLabel];
    y += 34.0;
    y = [self _addSeparatorAt:y inView:_contentView];

    // Size the document view to the actual content height so there is no empty
    // gap at the top — important in defaults-editor mode where the Meeting Name
    // and Password rows are omitted and the content is shorter than kContentH.
    CGFloat usedHeight = MAX(y, _scrollView.bounds.size.height);
    NSRect cvFrame = _contentView.frame;
    cvFrame.size.height = usedHeight;
    _contentView.frame = cvFrame;

    // Scroll to top after building so the title area is visible first
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_scrollView.documentView
            scrollPoint:NSMakePoint(0, usedHeight - self->_scrollView.bounds.size.height)];
    });
}

// ---------------------------------------------------------------------------
// MARK: - Compact overlay (additive — full controls remain built + hidden)
// ---------------------------------------------------------------------------

/// Builds the compact UI: a meeting-name field, an opt-in password field, a
/// read-only summary of the saved default settings, and an "Advanced ▸"
/// disclosure. The full controls (already built by -_buildUI and populated by
/// -_loadDefaults) are hidden but retained, so -_collectSettings keeps reading
/// the single canonical set of controls — no divergent settings logic.
- (void)_buildCompactOverlay {
    // Hide the full settings scroll view; the compact container takes its place.
    _scrollView.hidden = YES;

    CGFloat W  = kPanelW;
    CGFloat Hc = self.bounds.size.height - 56.0; // area above the bottom buttons
    _compactContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 56.0, W, Hc)];
    _compactContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_compactContainer];

    CGFloat yy = Hc - 40.0;

    // Title
    NSTextField *title = [self _makeLabel:@"New Meeting" fontSize:17.0 isBold:YES];
    title.frame = NSMakeRect(kMarginL, yy, W - kMarginL * 2, 26.0);
    [_compactContainer addSubview:title];
    yy -= 26.0;

    // Helper text
    NSTextField *helper = [self _makeLabel:@"Using your saved default settings"
                                  fontSize:11.0 isBold:NO];
    helper.textColor = [NSColor secondaryLabelColor];
    helper.frame = NSMakeRect(kMarginL, yy, W - kMarginL * 2, 16.0);
    [_compactContainer addSubview:helper];
    yy -= 26.0;

    // Effective-settings chips (read from the same defaults the full controls hold)
    InterPreMeetingSettings *s = [InterPreMeetingSettings settingsWithDefaults];
    NSArray<NSString *> *chips = @[
        [NSString stringWithFormat:@"🚪 Waiting room: %@", s.lobbyEnabled ? @"On" : @"Off"],
        [NSString stringWithFormat:@"🎤 Mic: %@", s.muteOnJoin ? @"Muted" : @"On"],
        [NSString stringWithFormat:@"📷 Camera: %@", s.cameraOffOnJoin ? @"Off" : @"On"],
        [NSString stringWithFormat:@"📺 Sharing: %@", [self _shareSummaryFor:s.sharingPermissions]],
    ];
    CGFloat chipX = kMarginL;
    CGFloat chipRowY = yy - 20.0;
    for (NSString *text in chips) {
        NSView *chip = [self _makeChipWithText:text];
        CGFloat cw = chip.frame.size.width;
        if (chipX + cw > W - kMarginL) {        // wrap to next row
            chipX = kMarginL;
            chipRowY -= 26.0;
        }
        chip.frame = NSMakeRect(chipX, chipRowY, cw, chip.frame.size.height);
        [_compactContainer addSubview:chip];
        chipX += cw + 6.0;
    }
    yy = chipRowY - 18.0;

    // Meeting name
    NSTextField *nameLbl = [self _makeLabel:@"Meeting Name" fontSize:12.0 isBold:NO];
    nameLbl.frame = NSMakeRect(kMarginL, yy, W - kMarginL * 2, 16.0);
    [_compactContainer addSubview:nameLbl];
    yy -= 28.0;

    _compactNameField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(kMarginL, yy, W - kMarginL * 2, 26.0)];
    _compactNameField.placeholderString = @"Meeting name";
    _compactNameField.bezeled  = YES;
    _compactNameField.editable = YES;
    [_compactNameField setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    // Mirror whatever the canonical field already holds (e.g. from -setDisplayName:).
    _compactNameField.stringValue = _meetingNameField.stringValue ?: @"";
    [_compactContainer addSubview:_compactNameField];
    yy -= 38.0;

    // Opt-in password (NEVER persisted — per-meeting only)
    _compactPasswordToggle = [[NSButton alloc]
        initWithFrame:NSMakeRect(kMarginL, yy, W - kMarginL * 2, 22.0)];
    [_compactPasswordToggle setButtonType:NSButtonTypeSwitch];
    _compactPasswordToggle.title = @"  Require a password";
    _compactPasswordToggle.state = NSControlStateValueOff;
    _compactPasswordToggle.target = self;
    _compactPasswordToggle.action = @selector(_compactPasswordToggleChanged:);
    [_compactContainer addSubview:_compactPasswordToggle];
    yy -= 30.0;

    _compactPasswordField = [[NSSecureTextField alloc]
        initWithFrame:NSMakeRect(kMarginL, yy, W - kMarginL * 2, 24.0)];
    _compactPasswordField.placeholderString = @"Meeting password";
    _compactPasswordField.bezeled  = YES;
    _compactPasswordField.editable = YES;
    _compactPasswordField.hidden   = YES;   // shown only when the toggle is on
    [_compactPasswordField setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    [_compactContainer addSubview:_compactPasswordField];

    // Advanced disclosure (reveals the full settings for a one-off override)
    _advancedButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(kMarginL, 10.0, 180.0, 24.0)];
    _advancedButton.title = @"Advanced ▸";
    _advancedButton.bezelStyle = NSBezelStyleInline;
    _advancedButton.bordered = NO;
    _advancedButton.contentTintColor = [NSColor systemBlueColor];
    _advancedButton.alignment = NSTextAlignmentLeft;
    _advancedButton.target = self;
    _advancedButton.action = @selector(_advancedTapped:);
    [_compactContainer addSubview:_advancedButton];
}

/// Short human-readable summary for the sharing-permission constant.
- (NSString *)_shareSummaryFor:(NSString *)mode {
    if ([mode isEqualToString:InterSharingPermissionsEveryone]) return @"Everyone";
    if ([mode isEqualToString:InterSharingPermissionsRequest])  return @"Request";
    return @"Host only";
}

/// Builds a small rounded "chip" view wrapping a centered label.
- (NSView *)_makeChipWithText:(NSString *)text {
    NSTextField *lbl = [[NSTextField alloc] initWithFrame:NSZeroRect];
    lbl.stringValue = text;
    lbl.font = [NSFont systemFontOfSize:11.0];
    lbl.textColor  = [NSColor colorWithWhite:0.92 alpha:1.0];
    lbl.editable   = NO;
    lbl.selectable = NO;
    lbl.bezeled    = NO;
    lbl.drawsBackground = NO;
    lbl.alignment  = NSTextAlignmentCenter;
    [lbl sizeToFit];
    NSSize ts = lbl.frame.size;
    CGFloat padX = 9.0, h = 20.0;
    NSView *wrap = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, ts.width + padX * 2, h)];
    wrap.wantsLayer = YES;
    wrap.layer.backgroundColor = [NSColor colorWithWhite:0.24 alpha:1.0].CGColor;
    wrap.layer.cornerRadius = 9.0;
    lbl.frame = NSMakeRect(padX, (h - ts.height) / 2.0, ts.width, ts.height);
    [wrap addSubview:lbl];
    return wrap;
}

- (void)_compactPasswordToggleChanged:(NSButton *)sender {
    _compactPasswordField.hidden = (sender.state == NSControlStateValueOff);
    if (sender.state == NSControlStateValueOff) {
        _compactPasswordField.stringValue = @"";
    } else {
        [self.window makeFirstResponder:_compactPasswordField];
    }
}

/// "Advanced ▸" — reveal the full settings for this one meeting. Carries the
/// compact name/password into the canonical controls so the full panel shows them.
- (void)_advancedTapped:(NSButton *)sender {
#pragma unused(sender)
    _advancedExpanded = YES;
    [self _mirrorCompactIntoCanonical];
    _passwordField.hidden = (_passwordToggle.state == NSControlStateValueOff);

    _compactContainer.hidden = YES;
    _scrollView.hidden = NO;

    if ([self.delegate respondsToSelector:@selector(preMeetingPanel:didRequestExpandToHeight:)]) {
        [self.delegate preMeetingPanel:self didRequestExpandToHeight:[[self class] fullPanelHeight]];
    }
}

/// Copies the compact name/password into the canonical controls that
/// -_collectSettings reads. Returns NO if password is enabled but empty.
- (BOOL)_mirrorCompactIntoCanonical {
    _meetingNameField.stringValue = _compactNameField.stringValue ?: @"";
    BOOL pwOn = (_compactPasswordToggle.state == NSControlStateValueOn);
    _passwordToggle.state = pwOn ? NSControlStateValueOn : NSControlStateValueOff;
    _passwordField.stringValue = pwOn ? (_compactPasswordField.stringValue ?: @"") : @"";
    return !(pwOn && _compactPasswordField.stringValue.length == 0);
}

// ---------------------------------------------------------------------------
// MARK: - Layout helpers
// ---------------------------------------------------------------------------

/// Adds a horizontal separator and returns new y above it.
- (CGFloat)_addSeparatorAt:(CGFloat)y inView:(NSView *)view {
    NSBox *sep = [[NSBox alloc]
        initWithFrame:NSMakeRect(0, y + 6.0, kPanelW, 1.0)];
    sep.boxType = NSBoxSeparator;
    [view addSubview:sep];
    return y + 16.0;
}

/// Adds a section header label and returns new y above it.
- (CGFloat)_addSectionHeader:(NSString *)text
                           y:(CGFloat)y
                      inView:(NSView *)view {
    NSTextField *lbl = [self _makeLabel:text fontSize:10.0 isBold:NO];
    lbl.frame = NSMakeRect(kMarginL, y, kPanelW - kMarginL * 2, 14.0);
    lbl.textColor = [NSColor tertiaryLabelColor];
    [view addSubview:lbl];
    return y + 22.0;
}

/// Adds a label + toggle row. Returns the newly created NSButton.
- (NSButton *)_addToggleRowWithLabel:(NSString *)labelText
                                   y:(CGFloat)y
                              inView:(NSView *)view {
    NSTextField *lbl = [self _makeLabel:labelText fontSize:13.0 isBold:NO];
    lbl.frame = NSMakeRect(kMarginL, y + 3.0, kControlX - kMarginL - 8.0, 22.0);
    [view addSubview:lbl];

    NSButton *btn = [[NSButton alloc]
        initWithFrame:NSMakeRect(kControlX, y + 2.0, kControlW, 22.0)];
    [btn setButtonType:NSButtonTypeSwitch];
    btn.title = @"";
    btn.state = NSControlStateValueOff;
    [view addSubview:btn];
    return btn;
}

/// Adds a label + toggle row. Returns new y (unused; kept for compatibility).
- (CGFloat)_addRow:(NSButton **)outToggle
             label:(NSString *)labelText
           rowType:(NSString *)type
                 y:(CGFloat)y
            inView:(NSView *)view {
    NSButton *btn = [self _addToggleRowWithLabel:labelText y:y inView:view];
    if (outToggle) *outToggle = btn;
    return y + 32.0;
}

/// Adds the password toggle + inline text field row. Returns new y.
- (CGFloat)_addPasswordRowAt:(CGFloat)y inView:(NSView *)view {
    NSTextField *lbl = [self _makeLabel:@"Require Password"
                               fontSize:13.0
                                 isBold:NO];
    lbl.frame = NSMakeRect(kMarginL, y + 3.0, 140.0, 22.0);
    [view addSubview:lbl];

    _passwordToggle = [[NSButton alloc]
        initWithFrame:NSMakeRect(kControlX, y + 2.0, 24.0, 22.0)];
    [_passwordToggle setButtonType:NSButtonTypeSwitch];
    _passwordToggle.title = @"";
    _passwordToggle.state = NSControlStateValueOff;
    _passwordToggle.target = self;
    _passwordToggle.action = @selector(_passwordToggleChanged:);
    [view addSubview:_passwordToggle];

    _passwordField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(kControlX + 28.0, y, kPanelW - kControlX - 28.0 - kMarginL, 24.0)];
    _passwordField.placeholderString = @"Meeting password";
    _passwordField.bezeled  = YES;
    _passwordField.editable = YES;
    _passwordField.hidden   = YES;
    [_passwordField setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    [view addSubview:_passwordField];

    return y + 32.0;
}

/// Adds the meeting name label + text field row. Returns new y.
- (CGFloat)_addMeetingNameRowAt:(CGFloat)y inView:(NSView *)view {
    NSTextField *lbl = [self _makeLabel:@"Meeting Name"
                               fontSize:13.0
                                 isBold:NO];
    lbl.frame = NSMakeRect(kMarginL, y + 4.0, 100.0, 22.0);
    [view addSubview:lbl];

    _meetingNameField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(kMarginL + 110.0, y, kPanelW - kMarginL - 110.0 - kMarginL, 26.0)];
    _meetingNameField.placeholderString = @"Meeting name";
    _meetingNameField.bezeled  = YES;
    _meetingNameField.editable = YES;
    [_meetingNameField setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    [view addSubview:_meetingNameField];

    return y + 36.0;
}

/// Adds a label + NSPopUpButton row. Returns the newly created popup button.
- (NSPopUpButton *)_addPopupRowWithLabel:(NSString *)labelText
                                 options:(NSArray<NSString *> *)options
                                       y:(CGFloat)y
                                  inView:(NSView *)view {
    NSTextField *lbl = [self _makeLabel:labelText fontSize:13.0 isBold:NO];
    lbl.frame = NSMakeRect(kMarginL, y + 3.0, kControlX - kMarginL - 8.0, 22.0);
    [view addSubview:lbl];

    NSPopUpButton *popup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(kControlX, y, kControlW, 26.0)
            pullsDown:NO];
    popup.controlSize = NSControlSizeSmall;
    [popup removeAllItems];
    for (NSString *opt in options) {
        [popup addItemWithTitle:opt];
    }
    [popup setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    [view addSubview:popup];
    return popup;
}

/// Adds a label + NSPopUpButton row. Returns new y (unused; kept for compatibility).
- (CGFloat)_addPopupRow:(NSPopUpButton **)outPopup
                  label:(NSString *)labelText
                options:(NSArray<NSString *> *)options
                      y:(CGFloat)y
                 inView:(NSView *)view {
    NSPopUpButton *popup = [self _addPopupRowWithLabel:labelText options:options y:y inView:view];
    if (outPopup) *outPopup = popup;
    return y + 36.0;
}

/// Creates a read-only label with the given style.
- (NSTextField *)_makeLabel:(NSString *)text
                   fontSize:(CGFloat)size
                     isBold:(BOOL)bold {
    NSTextField *lbl = [[NSTextField alloc] initWithFrame:NSZeroRect];
    lbl.stringValue = text;
    lbl.font = bold
        ? [NSFont boldSystemFontOfSize:size]
        : [NSFont systemFontOfSize:size];
    lbl.textColor  = [NSColor labelColor];
    lbl.editable   = NO;
    lbl.selectable = NO;
    lbl.bezeled    = NO;
    lbl.drawsBackground = NO;
    return lbl;
}

// ---------------------------------------------------------------------------
// MARK: - Pro gating
// ---------------------------------------------------------------------------

- (void)_refreshProGating {
    _autoRecordToggle.enabled   = _isPro;
    _autoTranscriptToggle.enabled = _isPro;
    _allowCoHostLocalRecordingToggle.enabled = _isPro;
    _proNoteLabel.hidden = _isPro;

    // Reset pro toggles when user is not pro so they can't be activated
    if (!_isPro) {
        _autoRecordToggle.state    = NSControlStateValueOff;
        _autoTranscriptToggle.state = NSControlStateValueOff;
        _allowCoHostLocalRecordingToggle.state = NSControlStateValueOff;
    }
}

// ---------------------------------------------------------------------------
// MARK: - Load defaults
// ---------------------------------------------------------------------------

- (void)_loadDefaults {
    InterPreMeetingSettings *s = [InterPreMeetingSettings settingsWithDefaults];
    _muteMicToggle.state          = s.muteOnJoin        ? NSControlStateValueOn : NSControlStateValueOff;
    _cameraOffToggle.state        = s.cameraOffOnJoin   ? NSControlStateValueOn : NSControlStateValueOff;
    _lobbyToggle.state            = s.lobbyEnabled      ? NSControlStateValueOn : NSControlStateValueOff;
    _joinBeforeHostToggle.state   = s.joinBeforeHost    ? NSControlStateValueOn : NSControlStateValueOff;
    _allowUnmutingToggle.state    = s.allowUnmuting     ? NSControlStateValueOn : NSControlStateValueOff;
    _autoRecordToggle.state       = s.autoRecord        ? NSControlStateValueOn : NSControlStateValueOff;
    _autoTranscriptToggle.state   = s.autoTranscript    ? NSControlStateValueOn : NSControlStateValueOff;
    _allowCoHostLocalRecordingToggle.state = s.allowCoHostLocalRecording ? NSControlStateValueOn : NSControlStateValueOff;

    // Chat permissions popup
    NSDictionary<NSString *, NSString *> *chatTitles = @{
        InterChatPermissionsEveryone: @"Everyone",
        InterChatPermissionsHostOnly: @"Host Only",
        InterChatPermissionsDisabled: @"Disabled"
    };
    NSString *chatTitle = chatTitles[s.chatPermissions] ?: @"Everyone";
    [_chatPermissionsPopup selectItemWithTitle:chatTitle];

    // Sharing permissions popup
    NSDictionary<NSString *, NSString *> *shareTitles = @{
        InterSharingPermissionsHostOnly: @"Host Only",
        InterSharingPermissionsEveryone: @"Everyone",
        InterSharingPermissionsRequest:  @"Request to Share"
    };
    NSString *shareTitle = shareTitles[s.sharingPermissions] ?: @"Host Only";
    [_sharingPermissionsPopup selectItemWithTitle:shareTitle];

    // Share-conflict policy popup
    NSDictionary<NSString *, NSString *> *conflictTitles = @{
        InterSharingConflictOneAtATime:    @"One at a Time",
        InterSharingConflictHostCanPreempt: @"Host Can Take Over",
        InterSharingConflictAnyCanPreempt:  @"Anyone Can Take Over"
    };
    NSString *conflictTitle = conflictTitles[s.shareConflictPolicy] ?: @"One at a Time";
    [_shareConflictPopup selectItemWithTitle:conflictTitle];

    // Disable pro toggles initially (until setUserTier: is called)
    _autoRecordToggle.enabled   = NO;
    _autoTranscriptToggle.enabled = NO;
    _allowCoHostLocalRecordingToggle.enabled = NO;
}

// ---------------------------------------------------------------------------
// MARK: - Actions
// ---------------------------------------------------------------------------

- (void)_passwordToggleChanged:(NSButton *)sender {
    _passwordField.hidden = (sender.state == NSControlStateValueOff);
    if (sender.state == NSControlStateValueOff) {
        _passwordField.stringValue = @"";
    }
}

- (void)_cancelTapped:(id)sender {
    [self.delegate preMeetingPanelDidCancel:self];
}

- (void)_startTapped:(id)sender {
    // In compact mode (not yet expanded to Advanced), mirror the compact
    // name/password into the canonical controls so the single -_collectSettings
    // path reads them. The advanced controls already hold the saved defaults.
    if (_compactMode && !_advancedExpanded) {
        if (![self _mirrorCompactIntoCanonical]) {
            // Password enabled but empty — don't create a falsely "protected" room.
            [self.window makeFirstResponder:_compactPasswordField];
            NSBeep();
            return;
        }
    }
    if (_passwordToggle.state == NSControlStateValueOn &&
        _passwordField.stringValue.length == 0) {
        [self.window makeFirstResponder:_passwordField];
        NSBeep();
        return;
    }
    InterPreMeetingSettings *s = [self _collectSettings];
    [s saveToUserDefaults];
    if (_defaultsEditorMode) {
        if ([self.delegate respondsToSelector:@selector(preMeetingPanelDidSaveDefaults:)]) {
            [self.delegate preMeetingPanelDidSaveDefaults:self];
        }
        return;
    }
    [self.delegate preMeetingPanel:self didStartWithSettings:s];
}

// ---------------------------------------------------------------------------
// MARK: - Collect settings
// ---------------------------------------------------------------------------

- (InterPreMeetingSettings *)_collectSettings {
    InterPreMeetingSettings *s = [[InterPreMeetingSettings alloc] init];

    s.meetingDisplayName = _meetingNameField.stringValue;

    s.muteOnJoin         = (_muteMicToggle.state == NSControlStateValueOn);
    s.cameraOffOnJoin    = (_cameraOffToggle.state == NSControlStateValueOn);
    s.lobbyEnabled       = (_lobbyToggle.state == NSControlStateValueOn);
    s.joinBeforeHost     = (_joinBeforeHostToggle.state == NSControlStateValueOn);
    s.allowUnmuting      = (_allowUnmutingToggle.state == NSControlStateValueOn);
    s.autoRecord         = (_autoRecordToggle.state == NSControlStateValueOn) && _isPro;
    s.autoTranscript     = (_autoTranscriptToggle.state == NSControlStateValueOn) && _isPro;
    s.allowCoHostLocalRecording = (_allowCoHostLocalRecordingToggle.state == NSControlStateValueOn) && _isPro;

    // Password — only include when toggle is on and field has content
    if (_passwordToggle.state == NSControlStateValueOn &&
        _passwordField.stringValue.length > 0) {
        s.meetingPassword = _passwordField.stringValue;
    } else {
        s.meetingPassword = @"";
    }

    // Chat permissions
    NSArray<NSString *> *chatKeys = @[
        InterChatPermissionsEveryone,
        InterChatPermissionsHostOnly,
        InterChatPermissionsDisabled
    ];
    NSInteger chatIdx = _chatPermissionsPopup.indexOfSelectedItem;
    s.chatPermissions = (chatIdx >= 0 && chatIdx < (NSInteger)chatKeys.count)
        ? chatKeys[chatIdx] : InterChatPermissionsEveryone;

    // Sharing permissions
    NSArray<NSString *> *shareKeys = @[
        InterSharingPermissionsHostOnly,
        InterSharingPermissionsEveryone,
        InterSharingPermissionsRequest
    ];
    NSInteger shareIdx = _sharingPermissionsPopup.indexOfSelectedItem;
    s.sharingPermissions = (shareIdx >= 0 && shareIdx < (NSInteger)shareKeys.count)
        ? shareKeys[shareIdx] : InterSharingPermissionsHostOnly;

    // Share-conflict policy
    NSArray<NSString *> *conflictKeys = @[
        InterSharingConflictOneAtATime,
        InterSharingConflictHostCanPreempt,
        InterSharingConflictAnyCanPreempt
    ];
    NSInteger conflictIdx = _shareConflictPopup.indexOfSelectedItem;
    s.shareConflictPolicy = (conflictIdx >= 0 && conflictIdx < (NSInteger)conflictKeys.count)
        ? conflictKeys[conflictIdx] : InterSharingConflictOneAtATime;

    return s;
}

// ---------------------------------------------------------------------------
// MARK: - Appearance
// ---------------------------------------------------------------------------

- (BOOL)isFlipped { return NO; }

@end
