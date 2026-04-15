#import "InterSchedulePanel.h"

// ── Model ──────────────────────────────────────────────────────────────
@implementation InterScheduledMeeting
@end

// ── Constants ──────────────────────────────────────────────────────────
static const CGFloat kPanelPad       = 16.0;
static const CGFloat kFieldHeight    = 24.0;
static const CGFloat kLabelHeight    = 16.0;
static const CGFloat kRowSpacing     = 6.0;
static const CGFloat kSectionSpacing = 14.0;
static const CGFloat kButtonHeight   = 30.0;
static const CGFloat kRowCellHeight  = 52.0;

static NSString *const kMeetingCellID = @"MeetingCell";

// ── Private ────────────────────────────────────────────────────────────
@interface InterSchedulePanel ()
@property (nonatomic, strong, readwrite) NSButton *scheduleButton;

// Form controls
@property (nonatomic, strong) NSTextField        *titleField;
@property (nonatomic, strong) NSDatePicker       *datePicker;
@property (nonatomic, strong) NSPopUpButton      *durationPopUp;
@property (nonatomic, strong) NSPopUpButton      *roomTypePopUp;
@property (nonatomic, strong) NSTextField        *passwordField;
@property (nonatomic, strong) NSTextField        *inviteEmailsField;
@property (nonatomic, strong) NSButton           *lobbyCheckbox;
@property (nonatomic, strong) NSTextField        *statusLabel;

// Upcoming list
@property (nonatomic, strong) NSScrollView       *scrollView;
@property (nonatomic, strong) NSTableView        *tableView;
@property (nonatomic, strong) NSSegmentedControl *listSegment;  // Hosted / Invited

@property (nonatomic, strong) NSArray<InterScheduledMeeting *> *hostedMeetings;
@property (nonatomic, strong) NSArray<InterScheduledMeeting *> *invitedMeetings;

@property (nonatomic, strong) NSDateFormatter *rowDateFormatter;
@end

@implementation InterSchedulePanel

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;

    _hostedMeetings  = @[];
    _invitedMeetings = @[];
    _rowDateFormatter = [[NSDateFormatter alloc] init];
    _rowDateFormatter.dateStyle = NSDateFormatterMediumStyle;
    _rowDateFormatter.timeStyle = NSDateFormatterShortStyle;

    [self buildUI];
    return self;
}

- (BOOL)isFlipped { return YES; }

#pragma mark - Public

- (void)setUpcomingMeetings:(NSArray<InterScheduledMeeting *> *)meetings {
    _hostedMeetings = meetings ?: @[];
    [self.tableView reloadData];
}

- (void)setInvitedMeetings:(NSArray<InterScheduledMeeting *> *)meetings {
    _invitedMeetings = meetings ?: @[];
    [self.tableView reloadData];
}

- (void)resetForm {
    self.titleField.stringValue  = @"";
    self.passwordField.stringValue = @"";
    self.inviteEmailsField.stringValue = @"";
    self.datePicker.dateValue    = [NSDate dateWithTimeIntervalSinceNow:3600];
    [self.durationPopUp selectItemAtIndex:2];  // 30 min default
    [self.roomTypePopUp selectItemAtIndex:0];
    self.lobbyCheckbox.state     = NSControlStateValueOff;
    self.statusLabel.stringValue = @"";
}

- (void)setStatusText:(NSString *)text {
    self.statusLabel.stringValue = text ?: @"";
}

#pragma mark - UI Construction

- (void)buildUI {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [[NSColor colorWithWhite:0.08 alpha:0.92] CGColor];
    self.layer.cornerRadius = 14.0;
    self.layer.borderWidth  = 1.0;
    self.layer.borderColor  = [[NSColor colorWithWhite:1.0 alpha:0.12] CGColor];

    CGFloat W = self.bounds.size.width;
    CGFloat fieldW = W - 2 * kPanelPad;
    CGFloat y = kPanelPad;

    // ── Section: Schedule a Meeting ─────────────────────────────────
    NSTextField *header = [self makeLabelWithText:@"Schedule a Meeting" bold:YES];
    header.frame = NSMakeRect(kPanelPad, y, fieldW, 20);
    [self addSubview:header];
    y += 20 + kRowSpacing;

    // Title
    [self addSubview:[self makeLabelWithText:@"Title" bold:NO atX:kPanelPad y:y width:fieldW]];
    y += kLabelHeight + 2;
    self.titleField = [self makeTextFieldAtX:kPanelPad y:y width:fieldW placeholder:@"e.g. Sprint Planning"];
    [self addSubview:self.titleField];
    y += kFieldHeight + kRowSpacing;

    // Date / Time
    [self addSubview:[self makeLabelWithText:@"Date & Time" bold:NO atX:kPanelPad y:y width:fieldW]];
    y += kLabelHeight + 2;
    self.datePicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(kPanelPad, y, fieldW, kFieldHeight)];
    self.datePicker.datePickerStyle   = NSDatePickerStyleTextField;
    self.datePicker.datePickerElements = NSDatePickerElementFlagYearMonthDay | NSDatePickerElementFlagHourMinute;
    self.datePicker.dateValue         = [NSDate dateWithTimeIntervalSinceNow:3600];
    self.datePicker.minDate           = [NSDate date];
    self.datePicker.autoresizingMask  = NSViewWidthSizable;
    [self addSubview:self.datePicker];
    y += kFieldHeight + kRowSpacing;

    // Duration + Room Type (side by side)
    CGFloat halfW = (fieldW - 8) / 2.0;

    [self addSubview:[self makeLabelWithText:@"Duration" bold:NO atX:kPanelPad y:y width:halfW]];
    [self addSubview:[self makeLabelWithText:@"Room Type" bold:NO atX:kPanelPad + halfW + 8 y:y width:halfW]];
    y += kLabelHeight + 2;

    self.durationPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(kPanelPad, y, halfW, kFieldHeight) pullsDown:NO];
    NSArray *durations = @[@"15 min", @"20 min", @"30 min", @"45 min", @"60 min", @"90 min", @"120 min"];
    [self.durationPopUp addItemsWithTitles:durations];
    [self.durationPopUp selectItemAtIndex:2]; // 30 min
    self.durationPopUp.autoresizingMask = NSViewMaxXMargin;
    [self addSubview:self.durationPopUp];

    self.roomTypePopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(kPanelPad + halfW + 8, y, halfW, kFieldHeight) pullsDown:NO];
    [self.roomTypePopUp addItemsWithTitles:@[@"Call", @"Interview"]];
    self.roomTypePopUp.autoresizingMask = NSViewMinXMargin;
    [self addSubview:self.roomTypePopUp];
    y += kFieldHeight + kRowSpacing;

    // Password
    [self addSubview:[self makeLabelWithText:@"Password (optional)" bold:NO atX:kPanelPad y:y width:fieldW]];
    y += kLabelHeight + 2;
    self.passwordField = [self makeTextFieldAtX:kPanelPad y:y width:fieldW placeholder:@"Leave blank for none"];
    [self addSubview:self.passwordField];
    y += kFieldHeight + kRowSpacing;

    // Invite emails
    [self addSubview:[self makeLabelWithText:@"Invite (comma-separated emails)" bold:NO atX:kPanelPad y:y width:fieldW]];
    y += kLabelHeight + 2;
    self.inviteEmailsField = [self makeTextFieldAtX:kPanelPad y:y width:fieldW placeholder:@"e.g. alice@example.com, bob@example.com"];
    [self addSubview:self.inviteEmailsField];
    y += kFieldHeight + kRowSpacing;

    // Lobby checkbox
    self.lobbyCheckbox = [NSButton checkboxWithTitle:@"Enable lobby (waiting room)" target:nil action:nil];
    self.lobbyCheckbox.frame = NSMakeRect(kPanelPad, y, fieldW, 18);
    self.lobbyCheckbox.autoresizingMask = NSViewWidthSizable;
    [self.lobbyCheckbox setContentTintColor:[NSColor colorWithWhite:0.85 alpha:1.0]];
    [self addSubview:self.lobbyCheckbox];
    y += 18 + kRowSpacing;

    // Schedule button
    self.scheduleButton = [[NSButton alloc] initWithFrame:NSMakeRect(kPanelPad, y, fieldW, kButtonHeight)];
    self.scheduleButton.title   = @"Schedule Meeting";
    self.scheduleButton.bezelStyle = NSBezelStyleRounded;
    self.scheduleButton.target  = self;
    self.scheduleButton.action  = @selector(handleSchedule:);
    self.scheduleButton.autoresizingMask = NSViewWidthSizable;
    self.scheduleButton.keyEquivalent = @"\r";
    [self addSubview:self.scheduleButton];
    y += kButtonHeight + 4;

    // Status label
    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.frame = NSMakeRect(kPanelPad, y, fieldW, kLabelHeight);
    self.statusLabel.font  = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor systemGreenColor];
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.autoresizingMask = NSViewWidthSizable;
    [self addSubview:self.statusLabel];
    y += kLabelHeight + kSectionSpacing;

    // ── Divider ─────────────────────────────────────────────────────
    NSBox *divider = [[NSBox alloc] initWithFrame:NSMakeRect(kPanelPad, y, fieldW, 1)];
    divider.boxType = NSBoxSeparator;
    divider.autoresizingMask = NSViewWidthSizable;
    [self addSubview:divider];
    y += 1 + kSectionSpacing;

    // ── Section: Upcoming Meetings ──────────────────────────────────
    NSTextField *upcomingHeader = [self makeLabelWithText:@"Upcoming Meetings" bold:YES];
    upcomingHeader.frame = NSMakeRect(kPanelPad, y, fieldW * 0.5, 20);
    [self addSubview:upcomingHeader];

    // Segmented control: Hosted / Invited
    self.listSegment = [NSSegmentedControl segmentedControlWithLabels:@[@"Hosted", @"Invited"]
                                                         trackingMode:NSSegmentSwitchTrackingSelectOne
                                                               target:self
                                                               action:@selector(handleSegmentSwitch:)];
    self.listSegment.frame = NSMakeRect(kPanelPad + fieldW * 0.5, y - 2, fieldW * 0.5, 22);
    self.listSegment.autoresizingMask = NSViewMinXMargin;
    [self.listSegment setSelectedSegment:0];
    [self addSubview:self.listSegment];
    y += 24 + kRowSpacing;

    // Table inside scroll view — fills remaining height
    CGFloat tableHeight = self.bounds.size.height - y - kPanelPad;
    if (tableHeight < 80) tableHeight = 80;

    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(kPanelPad, y, fieldW, tableHeight)];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.borderType = NSLineBorder;
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.drawsBackground = NO;

    self.tableView = [[NSTableView alloc] initWithFrame:self.scrollView.bounds];
    self.tableView.dataSource = self;
    self.tableView.delegate   = self;
    self.tableView.headerView = nil;
    self.tableView.rowHeight  = kRowCellHeight;
    self.tableView.backgroundColor = [NSColor clearColor];
    self.tableView.usesAlternatingRowBackgroundColors = NO;
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"meeting"];
    col.width   = fieldW - 20;
    col.minWidth = 100;
    col.maxWidth = 2000;
    [self.tableView addTableColumn:col];

    self.scrollView.documentView = self.tableView;
    [self addSubview:self.scrollView];
}

#pragma mark - Actions

- (void)handleSchedule:(id)sender {
#pragma unused(sender)

    NSString *title = [self.titleField.stringValue stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (title.length == 0) {
        [self setStatusText:@"Title is required."];
        self.statusLabel.textColor = [NSColor systemRedColor];
        return;
    }

    NSDate *date = self.datePicker.dateValue;
    if ([date compare:[NSDate date]] == NSOrderedAscending) {
        [self setStatusText:@"Date must be in the future."];
        self.statusLabel.textColor = [NSColor systemRedColor];
        return;
    }

    NSInteger durationMinutes = [self parseDuration:self.durationPopUp.titleOfSelectedItem];
    NSString *roomType = [[self.roomTypePopUp.titleOfSelectedItem lowercaseString] isEqualToString:@"interview"]
                         ? @"interview" : @"call";
    NSString *password = self.passwordField.stringValue.length > 0 ? self.passwordField.stringValue : nil;
    BOOL lobbyEnabled  = (self.lobbyCheckbox.state == NSControlStateValueOn);

    NSString *hostTimezone = [[NSTimeZone localTimeZone] name];

    // Parse comma-separated invite emails
    NSString *rawEmails = [self.inviteEmailsField.stringValue stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *emails = [NSMutableArray array];
    if (rawEmails.length > 0) {
        for (NSString *part in [rawEmails componentsSeparatedByString:@","]) {
            NSString *trimmed = [part stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0) {
                [emails addObject:trimmed];
            }
        }
    }

    self.statusLabel.textColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self setStatusText:@"Scheduling…"];
    self.scheduleButton.enabled = NO;

    id<InterSchedulePanelDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(schedulePanel:didScheduleMeetingWithTitle:description:scheduledAt:durationMinutes:roomType:hostTimezone:password:lobbyEnabled:inviteeEmails:)]) {
        [d schedulePanel:self
            didScheduleMeetingWithTitle:title
                           description:nil
                           scheduledAt:date
                       durationMinutes:durationMinutes
                              roomType:roomType
                          hostTimezone:hostTimezone
                              password:password
                          lobbyEnabled:lobbyEnabled
                         inviteeEmails:[emails copy]];
    }
}

- (void)handleSegmentSwitch:(id)sender {
#pragma unused(sender)
    [self.tableView reloadData];
}

#pragma mark - NSTableViewDataSource

- (NSArray<InterScheduledMeeting *> *)activeMeetings {
    return (self.listSegment.selectedSegment == 0) ? self.hostedMeetings : self.invitedMeetings;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
#pragma unused(tableView)
    return (NSInteger)[self activeMeetings].count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
#pragma unused(tableColumn)

    NSTableCellView *cell = [tableView makeViewWithIdentifier:kMeetingCellID owner:self];
    if (!cell) {
        cell = [self buildMeetingCell];
    }

    NSArray *meetings = [self activeMeetings];
    if (row < 0 || row >= (NSInteger)meetings.count) return cell;
    InterScheduledMeeting *mtg = meetings[(NSUInteger)row];

    // Title label (tag 100)
    NSTextField *titleLabel = [cell viewWithTag:100];
    titleLabel.stringValue = mtg.title ?: @"(untitled)";

    // Subtitle label (tag 101)
    NSTextField *subLabel = [cell viewWithTag:101];
    NSString *dateStr = [self.rowDateFormatter stringFromDate:mtg.scheduledAt];
    subLabel.stringValue = [NSString stringWithFormat:@"%@  •  %ld min  •  %ld invitee%@",
                            dateStr, (long)mtg.durationMinutes, (long)mtg.inviteeCount,
                            mtg.inviteeCount == 1 ? @"" : @"s"];

    // Join button (tag 200) — visible if roomCode is set
    NSButton *joinBtn = [cell viewWithTag:200];
    joinBtn.hidden = (mtg.roomCode.length == 0);

    // Cancel button (tag 201) — only for hosted tab
    NSButton *cancelBtn = [cell viewWithTag:201];
    cancelBtn.hidden = (self.listSegment.selectedSegment != 0);

    return cell;
}

#pragma mark - Row Cell Builder

- (NSTableCellView *)buildMeetingCell {
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 300, kRowCellHeight)];
    cell.identifier = kMeetingCellID;

    NSTextField *titleLabel = [NSTextField labelWithString:@""];
    titleLabel.tag   = 100;
    titleLabel.frame = NSMakeRect(8, 28, 180, 18);
    titleLabel.font  = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    titleLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    titleLabel.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:titleLabel];

    NSTextField *subLabel = [NSTextField labelWithString:@""];
    subLabel.tag   = 101;
    subLabel.frame = NSMakeRect(8, 8, 180, 14);
    subLabel.font  = [NSFont systemFontOfSize:10];
    subLabel.textColor = [NSColor colorWithWhite:0.6 alpha:1.0];
    subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    subLabel.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:subLabel];

    NSButton *joinBtn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 14, 50, 24)];
    joinBtn.tag    = 200;
    joinBtn.title  = @"Join";
    joinBtn.bezelStyle = NSBezelStyleRounded;
    joinBtn.target = self;
    joinBtn.action = @selector(handleJoinRow:);
    joinBtn.autoresizingMask = NSViewMinXMargin;
    [cell addSubview:joinBtn];

    NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 14, 56, 24)];
    cancelBtn.tag    = 201;
    cancelBtn.title  = @"Cancel";
    cancelBtn.bezelStyle = NSBezelStyleRounded;
    cancelBtn.target = self;
    cancelBtn.action = @selector(handleCancelRow:);
    cancelBtn.autoresizingMask = NSViewMinXMargin;
    [cell addSubview:cancelBtn];

    // Position buttons from right edge
    CGFloat cellW = cell.bounds.size.width;
    cancelBtn.frame = NSMakeRect(cellW - 56 - 8, 14, 56, 24);
    joinBtn.frame   = NSMakeRect(cellW - 56 - 8 - 50 - 6, 14, 50, 24);

    return cell;
}

#pragma mark - Row Actions

- (void)handleJoinRow:(NSButton *)sender {
    NSInteger row = [self.tableView rowForView:sender];
    if (row < 0) return;
    NSArray *meetings = [self activeMeetings];
    if (row >= (NSInteger)meetings.count) return;
    InterScheduledMeeting *mtg = meetings[(NSUInteger)row];

    id<InterSchedulePanelDelegate> d = self.delegate;
    if (mtg.roomCode && [d respondsToSelector:@selector(schedulePanel:didRequestJoin:meetingId:)]) {
        [d schedulePanel:self didRequestJoin:mtg.roomCode meetingId:mtg.meetingId];
    }
}

- (void)handleCancelRow:(NSButton *)sender {
    NSInteger row = [self.tableView rowForView:sender];
    if (row < 0) return;
    NSArray *meetings = [self activeMeetings];
    if (row >= (NSInteger)meetings.count) return;
    InterScheduledMeeting *mtg = meetings[(NSUInteger)row];

    id<InterSchedulePanelDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(schedulePanel:didRequestCancel:)]) {
        [d schedulePanel:self didRequestCancel:mtg.meetingId];
    }
}

#pragma mark - Helpers

- (NSInteger)parseDuration:(NSString *)title {
    NSScanner *scanner = [NSScanner scannerWithString:title ?: @"30"];
    NSInteger val = 30;
    [scanner scanInteger:&val];
    return val;
}

- (NSTextField *)makeLabelWithText:(NSString *)text bold:(BOOL)bold {
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.font = bold ? [NSFont boldSystemFontOfSize:13] : [NSFont systemFontOfSize:11];
    lbl.textColor = bold ? [NSColor colorWithWhite:0.92 alpha:1.0]
                         : [NSColor colorWithWhite:0.65 alpha:1.0];
    return lbl;
}

- (NSTextField *)makeLabelWithText:(NSString *)text bold:(BOOL)bold atX:(CGFloat)x y:(CGFloat)y width:(CGFloat)w {
    NSTextField *lbl = [self makeLabelWithText:text bold:bold];
    lbl.frame = NSMakeRect(x, y, w, kLabelHeight);
    lbl.autoresizingMask = NSViewWidthSizable;
    return lbl;
}

- (NSTextField *)makeTextFieldAtX:(CGFloat)x y:(CGFloat)y width:(CGFloat)w placeholder:(NSString *)placeholder {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(x, y, w, kFieldHeight)];
    field.placeholderString = placeholder;
    field.bezeled   = YES;
    field.bezelStyle = NSTextFieldSquareBezel;
    field.font      = [NSFont systemFontOfSize:12];
    field.textColor = [NSColor controlTextColor];
    field.autoresizingMask = NSViewWidthSizable;
    return field;
}

@end
