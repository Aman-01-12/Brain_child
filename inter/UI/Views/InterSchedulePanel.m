#import "InterSchedulePanel.h"
#import <QuartzCore/QuartzCore.h>

// -- Layout constants
static const CGFloat kCalPaneW  = 302.0;
static const CGFloat kTopH      = 400.0;
static const CGFloat kFormPadV  =  14.0;
static const CGFloat kFormPadH  =  16.0;
static const CGFloat kFieldH    =  24.0;
static const CGFloat kLabelH    =  14.0;
static const CGFloat kRowGap    =   8.0;
static const CGFloat kButtonH   =  30.0;
static const CGFloat kListRowH  =  52.0;

static NSString *const kCellID = @"MeetingCell";

// -- Calendar pane delegate (file-private)
@protocol _InterCalPaneDelegate <NSObject>
@required
- (void)calendarPane:(NSView *)pane didSelectDate:(NSDate *)date;
@end

// -- Calendar grid pane (file-private)
@interface _InterCalPane : NSView {
    NSCalendar      *_cal;
    NSDate          *_displayMonth;
    NSDate          *_today;
    NSDate          *_selectedDate;
    NSSet<NSDate *> *_meetingDays;
    NSButton        *_prevBtn;
    NSButton        *_nextBtn;
    NSTextField     *_monthLabel;
}
@property (nonatomic, weak, nullable)   id<_InterCalPaneDelegate> calDelegate;
@property (nonatomic, strong, readonly, nullable) NSDate *selectedDate;
- (void)setMeetingDays:(NSSet<NSDate *> *)days;
@end

@implementation _InterCalPane

@synthesize selectedDate = _selectedDate;

static const CGFloat kCalGridTop = 78.0;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor clearColor].CGColor;
    _cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    _cal.locale = [NSLocale currentLocale];
    _today = [_cal startOfDayForDate:[NSDate date]];
    _meetingDays = [NSSet set];
    NSDateComponents *c = [_cal components:(NSCalendarUnitYear | NSCalendarUnitMonth)
                                  fromDate:_today];
    c.day = 1;
    _displayMonth = [_cal dateFromComponents:c];
    [self _buildHeader];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)_buildHeader {
    CGFloat W = self.bounds.size.width;
    _prevBtn = [NSButton buttonWithTitle:@"\u2039" target:self action:@selector(_prevMonth:)];
    _prevBtn.font = [NSFont systemFontOfSize:17 weight:NSFontWeightLight];
    _prevBtn.bezelStyle = NSBezelStyleInline;
    _prevBtn.bordered = NO;
    _prevBtn.frame = NSMakeRect(12, 10, 26, 26);
    _prevBtn.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self addSubview:_prevBtn];

    _nextBtn = [NSButton buttonWithTitle:@"\u203a" target:self action:@selector(_nextMonth:)];
    _nextBtn.font = [NSFont systemFontOfSize:17 weight:NSFontWeightLight];
    _nextBtn.bezelStyle = NSBezelStyleInline;
    _nextBtn.bordered = NO;
    _nextBtn.frame = NSMakeRect(W - 38, 10, 26, 26);
    _nextBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self addSubview:_nextBtn];

    _monthLabel = [NSTextField labelWithString:@""];
    _monthLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _monthLabel.textColor = [NSColor colorWithWhite:0.90 alpha:1.0];
    _monthLabel.alignment = NSTextAlignmentCenter;
    _monthLabel.frame = NSMakeRect(42, 12, W - 84, 22);
    _monthLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self addSubview:_monthLabel];
    [self _updateMonthLabel];
}

- (void)_updateMonthLabel {
    static NSDateFormatter *_fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _fmt = [[NSDateFormatter alloc] init];
        _fmt.dateFormat = @"MMMM yyyy";
    });
    _monthLabel.stringValue = [_fmt stringFromDate:_displayMonth];
}

- (void)_prevMonth:(id)sender {
#pragma unused(sender)
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.month = -1;
    _displayMonth = [_cal dateByAddingComponents:c toDate:_displayMonth options:0];
    _selectedDate = nil;
    [self _updateMonthLabel];
    [self setNeedsDisplay:YES];
}

- (void)_nextMonth:(id)sender {
#pragma unused(sender)
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.month = 1;
    _displayMonth = [_cal dateByAddingComponents:c toDate:_displayMonth options:0];
    _selectedDate = nil;
    [self _updateMonthLabel];
    [self setNeedsDisplay:YES];
}

- (void)setMeetingDays:(NSSet<NSDate *> *)days {
    _meetingDays = days ?: [NSSet set];
    [self setNeedsDisplay:YES];
}

- (CGFloat)_cellWidth  { return floor(self.bounds.size.width / 7.0); }
- (CGFloat)_cellHeight { return floor((self.bounds.size.height - kCalGridTop - 8.0) / 6.0); }

- (nullable NSDate *)_dateForRow:(NSInteger)row col:(NSInteger)col {
    NSInteger fw = (NSInteger)[_cal component:NSCalendarUnitWeekday fromDate:_displayMonth];
    NSInteger offset = (row * 7 + col) - (fw - 1);
    if (offset == 0) return _displayMonth;
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.day = offset;
    return [_cal dateByAddingComponents:c toDate:_displayMonth options:0];
}

- (void)drawRect:(NSRect)dirtyRect {
#pragma unused(dirtyRect)
    CGFloat cw = [self _cellWidth];
    CGFloat ch = [self _cellHeight];
    CGFloat W  = self.bounds.size.width;

    NSMutableParagraphStyle *centerPS = [[NSMutableParagraphStyle alloc] init];
    centerPS.alignment = NSTextAlignmentCenter;

    static NSArray<NSString *> *_wdLabels = nil;
    if (!_wdLabels) _wdLabels = @[@"S",@"M",@"T",@"W",@"T",@"F",@"S"];

    NSDictionary *wdAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.50 alpha:1.0],
        NSParagraphStyleAttributeName:  centerPS,
    };
    for (NSInteger col = 0; col < 7; col++) {
        [_wdLabels[(NSUInteger)col] drawInRect:NSMakeRect(col * cw, 52.0, cw, 18.0)
                                withAttributes:wdAttrs];
    }

    [[NSColor colorWithWhite:0.22 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(10.0, 74.0, W - 20.0, 0.5));

    NSInteger displayedMonth = [_cal component:NSCalendarUnitMonth fromDate:_displayMonth];

    for (NSInteger row = 0; row < 6; row++) {
        for (NSInteger col = 0; col < 7; col++) {
            NSDate *cellDate = [self _dateForRow:row col:col];
            if (!cellDate) continue;
            NSDate   *cellDay  = [_cal startOfDayForDate:cellDate];
            NSInteger cellMon  = [_cal component:NSCalendarUnitMonth fromDate:cellDate];
            BOOL isCurrentMonth = (cellMon == displayedMonth);
            BOOL isToday    = [cellDay isEqualToDate:_today];
            BOOL isSelected = (_selectedDate && [cellDay isEqualToDate:_selectedDate]);
            BOOL hasMeeting = (isCurrentMonth && [_meetingDays containsObject:cellDay]);
            BOOL isPast     = ([cellDay compare:_today] == NSOrderedAscending);

            NSRect cellRect = NSMakeRect(col * cw, kCalGridTop + row * ch, cw, ch);
            CGFloat circleD = MIN(cw, ch) * 0.68;
            CGFloat vertOff = hasMeeting ? 3.5 : 0.0;
            NSRect circleRect = NSMakeRect(NSMidX(cellRect) - circleD / 2.0,
                                           NSMidY(cellRect) - circleD / 2.0 - vertOff,
                                           circleD, circleD);
            if (isSelected) {
                [[NSColor colorWithCalibratedRed:0.20 green:0.50 blue:1.00 alpha:1.0] setFill];
                [[NSBezierPath bezierPathWithOvalInRect:circleRect] fill];
            } else if (isToday) {
                [[NSColor colorWithWhite:0.30 alpha:1.0] setFill];
                [[NSBezierPath bezierPathWithOvalInRect:circleRect] fill];
            }

            NSColor *textColor;
            if (isSelected)                     { textColor = [NSColor whiteColor]; }
            else if (isPast || !isCurrentMonth)  { textColor = [NSColor colorWithWhite:0.32 alpha:1.0]; }
            else if (isToday)                   { textColor = [NSColor colorWithWhite:0.94 alpha:1.0]; }
            else                                { textColor = [NSColor colorWithWhite:0.80 alpha:1.0]; }

            NSFontWeight weight = (isToday || isSelected) ? NSFontWeightSemibold : NSFontWeightRegular;
            NSDictionary *numAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:12 weight:weight],
                NSForegroundColorAttributeName: textColor,
                NSParagraphStyleAttributeName:  centerPS,
            };
            NSInteger dayNum = [_cal component:NSCalendarUnitDay fromDate:cellDate];
            NSString  *dayStr = [NSString stringWithFormat:@"%ld", (long)dayNum];
            CGFloat numH     = 16.0;
            CGFloat numRectY = NSMidY(cellRect) - numH / 2.0 - vertOff;
            [dayStr drawInRect:NSMakeRect(col * cw, numRectY, cw, numH) withAttributes:numAttrs];

            if (hasMeeting) {
                NSColor *dotColor = isSelected
                    ? [NSColor colorWithWhite:0.90 alpha:0.85]
                    : [NSColor colorWithCalibratedRed:0.28 green:0.58 blue:1.00 alpha:1.0];
                [dotColor setFill];
                CGFloat dotD = 3.5;
                [[NSBezierPath bezierPathWithOvalInRect:
                    NSMakeRect(NSMidX(cellRect) - dotD / 2.0,
                               numRectY + numH + 2.0, dotD, dotD)] fill];
            }
        }
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat cw = [self _cellWidth];
    CGFloat ch = [self _cellHeight];
    if (pt.y < kCalGridTop || pt.x < 0 || pt.x >= self.bounds.size.width) return;
    NSInteger col = (NSInteger)(pt.x / cw);
    NSInteger row = (NSInteger)((pt.y - kCalGridTop) / ch);
    if (col < 0 || col > 6 || row < 0 || row > 5) return;
    NSDate *cellDate = [self _dateForRow:row col:col];
    if (!cellDate) return;
    NSDate *cellDay = [_cal startOfDayForDate:cellDate];
    if ([cellDay compare:_today] == NSOrderedAscending) return;
    _selectedDate = cellDay;
    [self setNeedsDisplay:YES];
    [self.calDelegate calendarPane:self didSelectDate:cellDay];
}

@end

// -- Model
@implementation InterScheduledMeeting
@end

// -- InterSchedulePanel private interface
@interface InterSchedulePanel () <NSTableViewDataSource, NSTableViewDelegate, _InterCalPaneDelegate>
@property (nonatomic, strong) _InterCalPane      *calendarPane;
@property (nonatomic, strong) NSView             *formPane;
@property (nonatomic, strong) NSTextField        *formDateHeader;
@property (nonatomic, strong) NSDatePicker       *timePicker;
@property (nonatomic, strong) NSTextField        *titleField;
@property (nonatomic, strong) NSPopUpButton      *durationPopUp;
@property (nonatomic, strong) NSPopUpButton      *roomTypePopUp;
@property (nonatomic, strong) NSTextField        *passwordField;
@property (nonatomic, strong) NSTextField        *inviteEmailsField;
@property (nonatomic, strong) NSButton           *lobbyCheckbox;
@property (nonatomic, strong, readwrite) NSButton *scheduleButton;
@property (nonatomic, strong) NSTextField        *statusLabel;
@property (nonatomic, strong) NSScrollView       *listScrollView;
@property (nonatomic, strong) NSTableView        *tableView;
@property (nonatomic, strong) NSSegmentedControl *listSegment;
@property (nonatomic, strong) NSArray<InterScheduledMeeting *> *hostedMeetings;
@property (nonatomic, strong) NSArray<InterScheduledMeeting *> *invitedMeetings;
@property (nonatomic, strong) NSDate             *selectedDate;
@property (nonatomic, strong) NSDateFormatter    *rowDateFormatter;
@end

@implementation InterSchedulePanel

// MARK: - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    _hostedMeetings  = @[];
    _invitedMeetings = @[];
    _rowDateFormatter = [[NSDateFormatter alloc] init];
    _rowDateFormatter.dateStyle = NSDateFormatterMediumStyle;
    _rowDateFormatter.timeStyle = NSDateFormatterShortStyle;
    [self _buildUI];
    return self;
}

- (BOOL)isFlipped { return YES; }

// MARK: - Public API

- (void)setUpcomingMeetings:(NSArray<InterScheduledMeeting *> *)meetings {
    _hostedMeetings = meetings ?: @[];
    [self _refreshCalendarDots];
    [self.tableView reloadData];
}

- (void)setInvitedMeetings:(NSArray<InterScheduledMeeting *> *)meetings {
    _invitedMeetings = meetings ?: @[];
    [self _refreshCalendarDots];
    [self.tableView reloadData];
}

- (void)resetForm {
    self.titleField.stringValue        = @"";
    self.passwordField.stringValue     = @"";
    self.inviteEmailsField.stringValue = @"";
    self.timePicker.dateValue          = [NSDate dateWithTimeIntervalSinceNow:3600];
    [self.durationPopUp selectItemAtIndex:2];
    [self.roomTypePopUp selectItemAtIndex:0];
    self.lobbyCheckbox.state           = NSControlStateValueOff;
    self.statusLabel.stringValue       = @"";
}

- (void)setStatusText:(NSString *)text {
    self.statusLabel.stringValue = text ?: @"";
}

// MARK: - Meeting dots

- (void)_refreshCalendarDots {
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSMutableSet<NSDate *> *days = [NSMutableSet set];
    for (InterScheduledMeeting *m in _hostedMeetings) {
        if (m.scheduledAt) [days addObject:[cal startOfDayForDate:m.scheduledAt]];
    }
    for (InterScheduledMeeting *m in _invitedMeetings) {
        if (m.scheduledAt) [days addObject:[cal startOfDayForDate:m.scheduledAt]];
    }
    [self.calendarPane setMeetingDays:[days copy]];
}

// MARK: - UI construction

- (void)_buildUI {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [[NSColor colorWithWhite:0.08 alpha:0.95] CGColor];
    self.layer.cornerRadius = 14.0;
    self.layer.borderWidth  =  1.0;
    self.layer.borderColor  = [[NSColor colorWithWhite:1.0 alpha:0.10] CGColor];

    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;

    self.calendarPane = [[_InterCalPane alloc] initWithFrame:NSMakeRect(0, 0, kCalPaneW, kTopH)];
    self.calendarPane.calDelegate = self;
    self.calendarPane.autoresizingMask = NSViewMaxXMargin;
    [self addSubview:self.calendarPane];

    NSBox *vDiv = [[NSBox alloc] initWithFrame:NSMakeRect(kCalPaneW, 0, 1, kTopH)];
    vDiv.boxType = NSBoxSeparator;
    vDiv.autoresizingMask = NSViewMaxXMargin;
    [self addSubview:vDiv];

    CGFloat formX = kCalPaneW + 1.0;
    self.formPane = [[NSView alloc] initWithFrame:NSMakeRect(formX, 0, W - formX, kTopH)];
    self.formPane.wantsLayer = YES;
    self.formPane.layer.backgroundColor = [NSColor clearColor].CGColor;
    self.formPane.alphaValue = 0.0;
    self.formPane.hidden     = YES;
    self.formPane.autoresizingMask = NSViewWidthSizable;
    [self addSubview:self.formPane];
    [self _buildFormPane];

    NSBox *hDiv = [[NSBox alloc] initWithFrame:NSMakeRect(0, kTopH, W, 1)];
    hDiv.boxType = NSBoxSeparator;
    hDiv.autoresizingMask = NSViewWidthSizable;
    [self addSubview:hDiv];

    CGFloat listTop = kTopH + 1.0;

    NSTextField *listHeader = [NSTextField labelWithString:@"Upcoming Meetings"];
    listHeader.font = [NSFont boldSystemFontOfSize:12];
    listHeader.textColor = [NSColor colorWithWhite:0.78 alpha:1.0];
    listHeader.frame = NSMakeRect(kFormPadH, listTop + 8.0, 200, 18);
    listHeader.autoresizingMask = NSViewMaxXMargin;
    [self addSubview:listHeader];

    self.listSegment = [NSSegmentedControl
        segmentedControlWithLabels:@[@"Hosted", @"Invited"]
                      trackingMode:NSSegmentSwitchTrackingSelectOne
                            target:self
                            action:@selector(_segmentChanged:)];
    self.listSegment.frame = NSMakeRect(W - 164.0 - kFormPadH, listTop + 6.0, 164, 22);
    self.listSegment.autoresizingMask = NSViewMinXMargin;
    [self.listSegment setSelectedSegment:0];
    [self addSubview:self.listSegment];

    CGFloat tableTop = listTop + 34.0;
    CGFloat tableH   = H - tableTop - 6.0;
    if (tableH < 60) tableH = 60;

    self.listScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, tableTop, W, tableH)];
    self.listScrollView.hasVerticalScroller = YES;
    self.listScrollView.borderType = NSNoBorder;
    self.listScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.listScrollView.drawsBackground = NO;

    self.tableView = [[NSTableView alloc] initWithFrame:self.listScrollView.bounds];
    self.tableView.dataSource  = self;
    self.tableView.delegate    = self;
    self.tableView.headerView  = nil;
    self.tableView.rowHeight   = kListRowH;
    self.tableView.backgroundColor = [NSColor clearColor];
    self.tableView.usesAlternatingRowBackgroundColors = NO;
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"meeting"];
    col.width    = W - 20;
    col.minWidth = 100;
    col.maxWidth = 2000;
    [self.tableView addTableColumn:col];
    self.listScrollView.documentView = self.tableView;
    [self addSubview:self.listScrollView];
}

- (void)_buildFormPane {
    NSView  *pane   = self.formPane;
    CGFloat  W      = pane.bounds.size.width;
    CGFloat  fieldW = W - 2.0 * kFormPadH;
    CGFloat  y      = kFormPadV;

    self.formDateHeader = [NSTextField labelWithString:@"New Meeting"];
    self.formDateHeader.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    self.formDateHeader.textColor = [NSColor colorWithWhite:0.94 alpha:1.0];
    self.formDateHeader.frame = NSMakeRect(kFormPadH, y, fieldW - 28.0, 22);
    self.formDateHeader.autoresizingMask = NSViewWidthSizable;
    [pane addSubview:self.formDateHeader];

    NSButton *closeBtn = [NSButton buttonWithTitle:@"\u2715" target:self action:@selector(_hideFormPane:)];
    closeBtn.font = [NSFont systemFontOfSize:10];
    closeBtn.bezelStyle = NSBezelStyleInline;
    closeBtn.bordered = NO;
    closeBtn.contentTintColor = [NSColor colorWithWhite:0.45 alpha:1.0];
    closeBtn.frame = NSMakeRect(W - 28.0, y, 20, 20);
    closeBtn.autoresizingMask = NSViewMinXMargin;
    [pane addSubview:closeBtn];
    y += 22.0 + kRowGap;

    [pane addSubview:[self _formLabel:@"Time" x:kFormPadH y:y w:fieldW]];
    y += kLabelH + 2.0;
    self.timePicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(kFormPadH, y, fieldW, kFieldH)];
    self.timePicker.datePickerStyle    = NSDatePickerStyleTextField;
    self.timePicker.datePickerElements = NSDatePickerElementFlagHourMinute;
    self.timePicker.dateValue          = [NSDate dateWithTimeIntervalSinceNow:3600];
    self.timePicker.autoresizingMask   = NSViewWidthSizable;
    [pane addSubview:self.timePicker];
    y += kFieldH + kRowGap;

    [pane addSubview:[self _formLabel:@"Title" x:kFormPadH y:y w:fieldW]];
    y += kLabelH + 2.0;
    self.titleField = [self _formTextField:@"e.g. Sprint Planning" x:kFormPadH y:y w:fieldW];
    [pane addSubview:self.titleField];
    y += kFieldH + kRowGap;

    CGFloat halfW = (fieldW - 8.0) / 2.0;
    [pane addSubview:[self _formLabel:@"Duration"  x:kFormPadH             y:y w:halfW]];
    [pane addSubview:[self _formLabel:@"Room Type" x:kFormPadH + halfW + 8 y:y w:halfW]];
    y += kLabelH + 2.0;

    self.durationPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(kFormPadH, y, halfW, kFieldH) pullsDown:NO];
    [self.durationPopUp addItemsWithTitles:@[@"15 min",@"20 min",@"30 min",@"45 min",@"60 min",@"90 min",@"120 min"]];
    [self.durationPopUp selectItemAtIndex:2];
    self.durationPopUp.autoresizingMask = NSViewMaxXMargin;
    [pane addSubview:self.durationPopUp];

    self.roomTypePopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(kFormPadH + halfW + 8, y, halfW, kFieldH) pullsDown:NO];
    [self.roomTypePopUp addItemsWithTitles:@[@"Call", @"Interview"]];
    self.roomTypePopUp.autoresizingMask = NSViewMinXMargin;
    [pane addSubview:self.roomTypePopUp];
    y += kFieldH + kRowGap;

    [pane addSubview:[self _formLabel:@"Password (optional)" x:kFormPadH y:y w:fieldW]];
    y += kLabelH + 2.0;
    self.passwordField = [self _formTextField:@"Leave blank for none" x:kFormPadH y:y w:fieldW];
    [pane addSubview:self.passwordField];
    y += kFieldH + kRowGap;

    [pane addSubview:[self _formLabel:@"Invite (comma-separated emails)" x:kFormPadH y:y w:fieldW]];
    y += kLabelH + 2.0;
    self.inviteEmailsField = [self _formTextField:@"alice@example.com, bob@example.com" x:kFormPadH y:y w:fieldW];
    [pane addSubview:self.inviteEmailsField];
    y += kFieldH + kRowGap;

    self.lobbyCheckbox = [NSButton checkboxWithTitle:@"Enable lobby (waiting room)" target:nil action:nil];
    self.lobbyCheckbox.frame = NSMakeRect(kFormPadH, y, fieldW, 18);
    self.lobbyCheckbox.font  = [NSFont systemFontOfSize:12];
    self.lobbyCheckbox.autoresizingMask = NSViewWidthSizable;
    [self.lobbyCheckbox setContentTintColor:[NSColor colorWithWhite:0.80 alpha:1.0]];
    [pane addSubview:self.lobbyCheckbox];
    y += 18.0 + 10.0;

    self.scheduleButton = [[NSButton alloc] initWithFrame:NSMakeRect(kFormPadH, y, fieldW, kButtonH)];
    self.scheduleButton.title         = @"Schedule Meeting";
    self.scheduleButton.bezelStyle    = NSBezelStyleRounded;
    self.scheduleButton.target        = self;
    self.scheduleButton.action        = @selector(_scheduleTapped:);
    self.scheduleButton.keyEquivalent = @"\r";
    self.scheduleButton.autoresizingMask = NSViewWidthSizable;
    [pane addSubview:self.scheduleButton];
    y += kButtonH + 4.0;

    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.frame = NSMakeRect(kFormPadH, y, fieldW, kLabelH);
    self.statusLabel.font  = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor systemGreenColor];
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.autoresizingMask = NSViewWidthSizable;
    [pane addSubview:self.statusLabel];
}

// MARK: - _InterCalPaneDelegate

- (void)calendarPane:(NSView *)pane didSelectDate:(NSDate *)date {
#pragma unused(pane)
    self.selectedDate = date;
    static NSDateFormatter *_hdrFmt = nil;
    static dispatch_once_t hdrOnce;
    dispatch_once(&hdrOnce, ^{
        _hdrFmt = [[NSDateFormatter alloc] init];
        _hdrFmt.dateFormat = @"EEE, MMM d";
    });
    self.formDateHeader.stringValue =
        [NSString stringWithFormat:@"New Meeting \u2014 %@", [_hdrFmt stringFromDate:date]];

    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents *timePart = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute)
                                        fromDate:self.timePicker.dateValue];
    NSDateComponents *datePart = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                        fromDate:date];
    datePart.hour   = timePart.hour;
    datePart.minute = timePart.minute;
    NSDate *combined = [cal dateFromComponents:datePart];
    if (combined) self.timePicker.dateValue = combined;
    self.statusLabel.stringValue = @"";
    [self _revealFormPane];
}

// MARK: - Form pane animation

- (void)_revealFormPane {
    if (!self.formPane.hidden) return;
    self.formPane.hidden = NO;
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.fromValue      = @(18.0);
    slide.toValue        = @(0.0);
    slide.duration       = 0.22;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.formPane.layer addAnimation:slide forKey:@"formSlideIn"];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.22;
        [self.formPane animator].alphaValue = 1.0;
    }];
}

- (void)_hideFormPane:(id)sender {
#pragma unused(sender)
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.18;
        [self.formPane animator].alphaValue = 0.0;
    } completionHandler:^{
        self.formPane.hidden = YES;
    }];
}

// MARK: - Schedule action

- (void)_scheduleTapped:(id)sender {
#pragma unused(sender)
    NSString *title = [self.titleField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (title.length == 0) {
        self.statusLabel.textColor = [NSColor systemRedColor];
        [self setStatusText:@"Title is required."];
        return;
    }
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDate *baseDay = self.selectedDate ?: [cal startOfDayForDate:[NSDate date]];
    NSDateComponents *timePart = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute)
                                        fromDate:self.timePicker.dateValue];
    NSDateComponents *datePart = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                        fromDate:baseDay];
    datePart.hour   = timePart.hour;
    datePart.minute = timePart.minute;
    NSDate *scheduled = [cal dateFromComponents:datePart];
    if (!scheduled || [scheduled compare:[NSDate date]] == NSOrderedAscending) {
        self.statusLabel.textColor = [NSColor systemRedColor];
        [self setStatusText:@"Scheduled time must be in the future."];
        return;
    }
    NSInteger duration = [self _parseDuration:self.durationPopUp.titleOfSelectedItem];
    NSString *roomType = [[self.roomTypePopUp.titleOfSelectedItem lowercaseString]
                             isEqualToString:@"interview"] ? @"interview" : @"call";
    NSString *password = self.passwordField.stringValue.length > 0
        ? self.passwordField.stringValue : nil;
    BOOL lobbyEnabled  = (self.lobbyCheckbox.state == NSControlStateValueOn);
    NSString *timezone = [[NSTimeZone localTimeZone] name];
    NSMutableArray<NSString *> *emails = [NSMutableArray array];
    NSString *rawEmails = [self.inviteEmailsField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (rawEmails.length > 0) {
        for (NSString *part in [rawEmails componentsSeparatedByString:@","]) {
            NSString *trimmed = [part stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0) [emails addObject:trimmed];
        }
    }
    self.statusLabel.textColor = [NSColor colorWithWhite:0.70 alpha:1.0];
    [self setStatusText:@"Scheduling\u2026"];
    self.scheduleButton.enabled = NO;
    id<InterSchedulePanelDelegate> d = self.delegate;
    if ([d respondsToSelector:
            @selector(schedulePanel:didScheduleMeetingWithTitle:description:scheduledAt:
                      durationMinutes:roomType:hostTimezone:password:lobbyEnabled:inviteeEmails:)]) {
        [d schedulePanel:self
            didScheduleMeetingWithTitle:title
                            description:nil
                            scheduledAt:scheduled
                        durationMinutes:duration
                               roomType:roomType
                           hostTimezone:timezone
                               password:password
                           lobbyEnabled:lobbyEnabled
                          inviteeEmails:[emails copy]];
    }
}

// MARK: - Segment action

- (void)_segmentChanged:(id)sender {
#pragma unused(sender)
    [self.tableView reloadData];
}

// MARK: - NSTableViewDataSource

- (NSArray<InterScheduledMeeting *> *)_activeMeetings {
    return self.listSegment.selectedSegment == 0
        ? self.hostedMeetings : self.invitedMeetings;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
#pragma unused(tableView)
    return (NSInteger)[self _activeMeetings].count;
}

// MARK: - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
#pragma unused(tableColumn)
    NSTableCellView *cell = [tableView makeViewWithIdentifier:kCellID owner:self];
    if (!cell) cell = [self _buildMeetingCell];
    NSArray<InterScheduledMeeting *> *meetings = [self _activeMeetings];
    if (row < 0 || row >= (NSInteger)meetings.count) return cell;
    InterScheduledMeeting *m = meetings[(NSUInteger)row];
    ((NSTextField *)[cell viewWithTag:100]).stringValue = m.title ?: @"(untitled)";
    NSString *dateStr = [self.rowDateFormatter stringFromDate:m.scheduledAt];
    ((NSTextField *)[cell viewWithTag:101]).stringValue =
        [NSString stringWithFormat:@"%@  \u2022  %ld min  \u2022  %ld invitee%@",
         dateStr, (long)m.durationMinutes, (long)m.inviteeCount,
         m.inviteeCount == 1 ? @"" : @"s"];
    ((NSButton *)[cell viewWithTag:200]).hidden = (m.roomCode.length == 0);
    ((NSButton *)[cell viewWithTag:201]).hidden = (self.listSegment.selectedSegment != 0);
    return cell;
}

// MARK: - Meeting cell builder

- (NSTableCellView *)_buildMeetingCell {
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 300, kListRowH)];
    cell.identifier = kCellID;

    NSTextField *titleLabel = [NSTextField labelWithString:@""];
    titleLabel.tag  = 100;
    titleLabel.frame = NSMakeRect(12, 28, 180, 18);
    titleLabel.font  = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    titleLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    titleLabel.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:titleLabel];

    NSTextField *subLabel = [NSTextField labelWithString:@""];
    subLabel.tag  = 101;
    subLabel.frame = NSMakeRect(12, 8, 180, 14);
    subLabel.font  = [NSFont systemFontOfSize:10];
    subLabel.textColor = [NSColor colorWithWhite:0.60 alpha:1.0];
    subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    subLabel.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:subLabel];

    CGFloat cellW = cell.bounds.size.width;
    NSButton *joinBtn = [[NSButton alloc] initWithFrame:NSMakeRect(cellW - 118, 14, 50, 24)];
    joinBtn.tag  = 200;
    joinBtn.title = @"Join";
    joinBtn.bezelStyle = NSBezelStyleRounded;
    joinBtn.target = self;
    joinBtn.action = @selector(_joinRow:);
    joinBtn.autoresizingMask = NSViewMinXMargin;
    [cell addSubview:joinBtn];

    NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(cellW - 62, 14, 56, 24)];
    cancelBtn.tag  = 201;
    cancelBtn.title = @"Cancel";
    cancelBtn.bezelStyle = NSBezelStyleRounded;
    cancelBtn.target = self;
    cancelBtn.action = @selector(_cancelRow:);
    cancelBtn.autoresizingMask = NSViewMinXMargin;
    [cell addSubview:cancelBtn];
    return cell;
}

// MARK: - Row actions

- (void)_joinRow:(NSButton *)sender {
    NSInteger row = [self.tableView rowForView:sender];
    if (row < 0) return;
    NSArray<InterScheduledMeeting *> *meetings = [self _activeMeetings];
    if (row >= (NSInteger)meetings.count) return;
    InterScheduledMeeting *m = meetings[(NSUInteger)row];
    id<InterSchedulePanelDelegate> d = self.delegate;
    if (m.roomCode.length > 0 &&
        [d respondsToSelector:@selector(schedulePanel:didRequestJoin:meetingId:)]) {
        [d schedulePanel:self didRequestJoin:m.roomCode meetingId:m.meetingId];
    }
}

- (void)_cancelRow:(NSButton *)sender {
    NSInteger row = [self.tableView rowForView:sender];
    if (row < 0) return;
    NSArray<InterScheduledMeeting *> *meetings = [self _activeMeetings];
    if (row >= (NSInteger)meetings.count) return;
    InterScheduledMeeting *m = meetings[(NSUInteger)row];
    id<InterSchedulePanelDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(schedulePanel:didRequestCancel:)]) {
        [d schedulePanel:self didRequestCancel:m.meetingId];
    }
}

// MARK: - Helpers

- (NSInteger)_parseDuration:(NSString *)title {
    NSScanner *scanner = [NSScanner scannerWithString:title ?: @"30"];
    NSInteger val = 30;
    [scanner scanInteger:&val];
    return val;
}

- (NSTextField *)_formLabel:(NSString *)text x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w {
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.font = [NSFont systemFontOfSize:11];
    lbl.textColor = [NSColor colorWithWhite:0.58 alpha:1.0];
    lbl.frame = NSMakeRect(x, y, w, kLabelH);
    lbl.autoresizingMask = NSViewWidthSizable;
    return lbl;
}

- (NSTextField *)_formTextField:(NSString *)placeholder x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(x, y, w, kFieldH)];
    field.placeholderString = placeholder;
    field.bezeled    = YES;
    field.bezelStyle = NSTextFieldSquareBezel;
    field.font       = [NSFont systemFontOfSize:12];
    field.textColor  = [NSColor controlTextColor];
    field.autoresizingMask = NSViewWidthSizable;
    return field;
}

@end
