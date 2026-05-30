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
static NSString *const kUDAutoRecord           = @"InterPreMeeting_AutoRecord";
static NSString *const kUDAutoTranscript       = @"InterPreMeeting_AutoTranscript";

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
    s.autoRecord           = [ud boolForKey:kUDAutoRecord];
    s.autoTranscript       = [ud boolForKey:kUDAutoTranscript];
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
    [ud setBool:self.autoRecord         forKey:kUDAutoRecord];
    [ud setBool:self.autoTranscript     forKey:kUDAutoTranscript];
    [ud synchronize];
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
    c.autoRecord           = self.autoRecord;
    c.autoTranscript       = self.autoTranscript;
    return c;
}

@end

// ---------------------------------------------------------------------------
// MARK: - Layout helpers
// ---------------------------------------------------------------------------

/// Height of the scrollable content.
static const CGFloat kContentH = 720.0;
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

    // Pro features
    NSButton     *_autoRecordToggle;
    NSButton     *_autoTranscriptToggle;
    NSTextField  *_proNoteLabel;

    // Bottom buttons
    NSButton     *_cancelButton;
    NSButton     *_startButton;

    BOOL _isPro;
}
@end

@implementation InterPreMeetingPanel

// ---------------------------------------------------------------------------
// MARK: - Init
// ---------------------------------------------------------------------------

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self _buildUI];
    [self _loadDefaults];
    return self;
}

// ---------------------------------------------------------------------------
// MARK: - Public API
// ---------------------------------------------------------------------------

- (void)setDisplayName:(NSString *)displayName {
    if (displayName.length > 0) {
        _meetingNameField.stringValue =
            [NSString stringWithFormat:@"%@'s Meeting", displayName];
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

    // Password row: toggle + inline text field
    y = [self _addPasswordRowAt:y inView:_contentView];

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
    y = [self _addSeparatorAt:y inView:_contentView];
    y = [self _addMeetingNameRowAt:y inView:_contentView];
    y = [self _addSectionHeader:@"GENERAL" y:y inView:_contentView];

    // ---- Title ----
    y = [self _addSeparatorAt:y inView:_contentView];
    _titleLabel = [self _makeLabel:@"New Meeting"
                          fontSize:17.0
                            isBold:YES];
    _titleLabel.frame = NSMakeRect(kMarginL, y, kPanelW - kMarginL * 2, 28.0);
    [_contentView addSubview:_titleLabel];
    y += 34.0;
    y = [self _addSeparatorAt:y inView:_contentView];

    // Scroll to top after building so the title area is visible first
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_scrollView.documentView
            scrollPoint:NSMakePoint(0, kContentH - self->_scrollView.bounds.size.height)];
    });
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
    _proNoteLabel.hidden = _isPro;

    // Reset pro toggles when user is not pro so they can't be activated
    if (!_isPro) {
        _autoRecordToggle.state    = NSControlStateValueOff;
        _autoTranscriptToggle.state = NSControlStateValueOff;
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

    // Disable pro toggles initially (until setUserTier: is called)
    _autoRecordToggle.enabled   = NO;
    _autoTranscriptToggle.enabled = NO;
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
    InterPreMeetingSettings *s = [self _collectSettings];
    [s saveToUserDefaults];
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

    return s;
}

// ---------------------------------------------------------------------------
// MARK: - Appearance
// ---------------------------------------------------------------------------

- (BOOL)isFlipped { return NO; }

@end
