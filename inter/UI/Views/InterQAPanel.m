#import "InterQAPanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// ============================================================================
// InterQAPanel.m
// inter
//
// Phase 8.6.3–8.6.4 — Q&A questions list, upvoting, and host moderation UI.
//
// LAYOUT:
//   Slide-in panel (300pt wide) from the right edge, matching InterChatPanel.
//   Content:
//     - Header with title + close button
//     - Question list (NSTableView, sorted by upvotes)
//     - Input area: text field + anonymous toggle + submit button
//
// Each question row shows:
//   - Asker name (or "Anonymous") + timestamp
//   - Question text (multi-line wrapped)
//   - Upvote button + count
//   - Host actions: Highlight / Mark Answered / Dismiss
//
// THREADING:
//   All methods on main queue. Pure UI component.
//
// ISOLATION INVARIANT [G8]:
//   No direct references to rooms, controllers, or media.
// ============================================================================

static const CGFloat InterQAPanelWidth = 300.0;
static const CGFloat InterQAHeaderHeight = 38.0;
static const CGFloat InterQAInputHeight = 36.0;
static const CGFloat InterQAPadding = 8.0;
static const CGFloat InterQARowMinHeight = 80.0;

// Subview tags for cell reuse — unique within each reused cell
static NSString * const InterQACellIdentifier = @"InterQAQuestionCell";
static const NSInteger InterQATagMetaLabel     = 200;
static const NSInteger InterQATagTextLabel     = 201;
static const NSInteger InterQATagUpvoteButton  = 202;
static const NSInteger InterQATagHighlightBtn  = 203;
static const NSInteger InterQATagAnsweredBtn   = 204;
static const NSInteger InterQATagDismissBtn    = 205;

// MARK: - Private Interface

@interface InterQAPanel ()

@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) NSTextField *headerLabel;
@property (nonatomic, strong) NSButton *closeButton;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *inputField;
@property (nonatomic, strong) NSButton *submitButton;
@property (nonatomic, strong) NSButton *anonymousToggle;
@property (nonatomic, strong) NSView *unreadBadgeView;
@property (nonatomic, strong) NSTextField *unreadLabel;
@property (nonatomic, strong) NSMutableArray<InterQuestionInfo *> *displayQuestions;

@end

@implementation InterQAPanel

// MARK: - Init

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _displayQuestions = [NSMutableArray array];
        [self setupViews];
    }
    return self;
}

- (BOOL)isExpanded {
    return self.window != nil && self.window.isVisible;
}

// MARK: - Setup

- (void)setupViews {
    [self setWantsLayer:YES];
    self.layer.backgroundColor = [NSColor clearColor].CGColor;

    self.containerView = [[NSView alloc] initWithFrame:self.bounds];
    self.containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.containerView setWantsLayer:YES];
    self.containerView.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.95].CGColor;
    self.containerView.layer.borderColor = [NSColor colorWithWhite:0.25 alpha:1.0].CGColor;
    self.containerView.layer.borderWidth = 1.0;
    [self addSubview:self.containerView];

    [self setupHeader];
    [self setupQuestionList];
    [self setupInputArea];
    [self setupUnreadBadge];
}

- (void)setupHeader {
    CGFloat containerW = InterQAPanelWidth;
    CGFloat containerH = self.containerView.bounds.size.height;

    NSView *headerBar = [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                                  containerH - InterQAHeaderHeight,
                                                                  containerW,
                                                                  InterQAHeaderHeight)];
    headerBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [headerBar setWantsLayer:YES];
    headerBar.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;
    [self.containerView addSubview:headerBar];

    self.headerLabel = [NSTextField labelWithString:@"❓ Q&A"];
    self.headerLabel.frame = NSMakeRect(InterQAPadding, 8, 120, 20);
    self.headerLabel.font = [NSFont boldSystemFontOfSize:13];
    self.headerLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    self.headerLabel.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [headerBar addSubview:self.headerLabel];

    self.closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(containerW - 42, 6, 36, 24)];
    self.closeButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.closeButton setImage:[NSImage imageWithSystemSymbolName:@"xmark"
                                        accessibilityDescription:@"Close"]];
    [self.closeButton setImagePosition:NSImageOnly];
    [self.closeButton setBordered:NO];
    self.closeButton.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.closeButton setTarget:self];
    [self.closeButton setAction:@selector(closeAction:)];
    [headerBar addSubview:self.closeButton];
}

- (void)setupQuestionList {
    CGFloat containerW = InterQAPanelWidth;
    CGFloat containerH = self.containerView.bounds.size.height;
    CGFloat topOffset = InterQAHeaderHeight;
    CGFloat bottomOffset = InterQAInputHeight + InterQAPadding * 2 + 24; // Input + anon toggle
    CGFloat scrollHeight = containerH - topOffset - bottomOffset;

    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0,
                                                                      bottomOffset,
                                                                      containerW,
                                                                      scrollHeight)];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.drawsBackground = NO;
    self.scrollView.borderType = NSNoBorder;
    [self.containerView addSubview:self.scrollView];

    self.tableView = [[NSTableView alloc] initWithFrame:self.scrollView.bounds];
    self.tableView.headerView = nil;
    self.tableView.backgroundColor = [NSColor clearColor];
    self.tableView.usesAlternatingRowBackgroundColors = NO;
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    self.tableView.intercellSpacing = NSMakeSize(0, 4);
    self.tableView.rowHeight = InterQARowMinHeight;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"question"];
    column.width = containerW;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:column];

    self.tableView.dataSource = self;
    self.tableView.delegate = self;

    self.scrollView.documentView = self.tableView;
}

- (void)setupInputArea {
    CGFloat containerW = InterQAPanelWidth;

    // Anonymous toggle (above the input field)
    self.anonymousToggle = [NSButton checkboxWithTitle:@"Ask anonymously"
                                               target:nil
                                               action:nil];
    self.anonymousToggle.frame = NSMakeRect(InterQAPadding,
                                            InterQAPadding + InterQAInputHeight + 4,
                                            containerW - InterQAPadding * 2, 18);
    self.anonymousToggle.font = [NSFont systemFontOfSize:10];
    [self.anonymousToggle setContentTintColor:[NSColor colorWithWhite:0.7 alpha:1.0]];
    [self.containerView addSubview:self.anonymousToggle];

    // Input field
    CGFloat submitW = 56.0;
    CGFloat inputW = containerW - InterQAPadding * 3 - submitW;

    self.inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(InterQAPadding,
                                                                     InterQAPadding,
                                                                     inputW,
                                                                     InterQAInputHeight)];
    self.inputField.placeholderString = @"Ask a question…";
    self.inputField.font = [NSFont systemFontOfSize:12];
    self.inputField.drawsBackground = YES;
    self.inputField.backgroundColor = [NSColor colorWithWhite:0.18 alpha:1.0];
    self.inputField.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    self.inputField.bordered = YES;
    self.inputField.delegate = (id<NSTextFieldDelegate>)self;
    [self.containerView addSubview:self.inputField];

    self.submitButton = [[NSButton alloc] initWithFrame:NSMakeRect(InterQAPadding * 2 + inputW,
                                                                    InterQAPadding,
                                                                    submitW,
                                                                    InterQAInputHeight)];
    [self.submitButton setTitle:@"Ask"];
    self.submitButton.font = [NSFont boldSystemFontOfSize:11];
    [self.submitButton setTarget:self];
    [self.submitButton setAction:@selector(submitAction:)];
    [self.containerView addSubview:self.submitButton];
}

- (void)setupUnreadBadge {
    self.unreadBadgeView = [[NSView alloc] initWithFrame:NSMakeRect(InterQAPanelWidth - 28, self.containerView.bounds.size.height - 14, 24, 18)];
    [self.unreadBadgeView setWantsLayer:YES];
    self.unreadBadgeView.layer.backgroundColor = [NSColor systemRedColor].CGColor;
    self.unreadBadgeView.layer.cornerRadius = 9.0;
    self.unreadBadgeView.hidden = YES;
    [self.containerView addSubview:self.unreadBadgeView];

    self.unreadLabel = [NSTextField labelWithString:@"0"];
    self.unreadLabel.frame = NSMakeRect(0, 0, 24, 16);
    self.unreadLabel.font = [NSFont boldSystemFontOfSize:10];
    self.unreadLabel.textColor = [NSColor whiteColor];
    self.unreadLabel.alignment = NSTextAlignmentCenter;
    [self.unreadBadgeView addSubview:self.unreadLabel];
}

// MARK: - Public API

- (void)setQuestions:(NSArray<InterQuestionInfo *> *)questions {
    [self.displayQuestions removeAllObjects];
    [self.displayQuestions addObjectsFromArray:questions];
    [self.tableView reloadData];
}

- (void)setUnreadBadge:(NSInteger)count {
    if (count <= 0) {
        self.unreadBadgeView.hidden = YES;
    } else {
        self.unreadBadgeView.hidden = NO;
        self.unreadLabel.stringValue = (count > 99)
            ? @"99+"
            : [NSString stringWithFormat:@"%ld", (long)count];
    }
}

// MARK: - Toggle / Expand / Collapse

- (void)togglePanel {
    if (self.isExpanded) {
        [self collapsePanel];
    } else {
        [self expandPanel];
    }
}

- (void)expandPanel {
    [self.window makeKeyAndOrderFront:nil];
}

- (void)collapsePanel {
    [self.window orderOut:nil];
}

// MARK: - Actions

- (void)closeAction:(id)sender {
#pragma unused(sender)
    [self.window orderOut:nil];
}

- (void)submitAction:(id)sender {
    NSString *text = self.inputField.stringValue;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;

    BOOL isAnonymous = (self.anonymousToggle.state == NSControlStateValueOn);
    [self.delegate qaPanel:self didSubmitQuestion:trimmed isAnonymous:isAnonymous];
    self.inputField.stringValue = @"";
}

- (void)upvoteAction:(NSButton *)sender {
    NSInteger row = [self.tableView rowForView:sender];
    if (row < 0 || row >= (NSInteger)self.displayQuestions.count) return;

    InterQuestionInfo *question = self.displayQuestions[row];
    [self.delegate qaPanel:self didUpvoteQuestion:question.questionId];
}

- (void)markAnsweredAction:(NSButton *)sender {
    NSInteger row = [self.tableView rowForView:sender];
    if (row < 0 || row >= (NSInteger)self.displayQuestions.count) return;

    InterQuestionInfo *question = self.displayQuestions[row];
    [self.delegate qaPanel:self didMarkAnswered:question.questionId];
}

- (void)highlightAction:(NSButton *)sender {
    NSInteger row = [self.tableView rowForView:sender];
    if (row < 0 || row >= (NSInteger)self.displayQuestions.count) return;

    InterQuestionInfo *question = self.displayQuestions[row];
    [self.delegate qaPanel:self didHighlightQuestion:question.questionId];
}

- (void)dismissAction:(NSButton *)sender {
    NSInteger row = [self.tableView rowForView:sender];
    if (row < 0 || row >= (NSInteger)self.displayQuestions.count) return;

    InterQuestionInfo *question = self.displayQuestions[row];
    [self.delegate qaPanel:self didDismissQuestion:question.questionId];
}

// MARK: - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.displayQuestions.count;
}

// MARK: - Cell Creation & Configuration (reuse support)

/// Creates the cell view once with all possible subviews pre-allocated.
/// Subviews are found via tags during configuration — no per-row allocation.
- (NSView *)createQuestionCellWithWidth:(CGFloat)cellW {
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, cellW, InterQARowMinHeight)];
    cell.identifier = InterQACellIdentifier;
    [cell setWantsLayer:YES];
    cell.layer.cornerRadius = 4.0;

    CGFloat inset = 6.0;
    CGFloat contentW = cellW - inset * 2;
    CGFloat y = InterQARowMinHeight - 4;

    // Row 1: Meta label (asker name + timestamp)
    y -= 14;
    NSTextField *metaLabel = [NSTextField labelWithString:@""];
    metaLabel.tag = InterQATagMetaLabel;
    metaLabel.frame = NSMakeRect(inset, y, contentW, 12);
    metaLabel.font = [NSFont systemFontOfSize:9 weight:NSFontWeightMedium];
    metaLabel.textColor = [NSColor colorWithWhite:0.55 alpha:1.0];
    metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [cell addSubview:metaLabel];

    // Row 2: Question text
    y -= 28;
    NSTextField *textLabel = [NSTextField labelWithString:@""];
    textLabel.tag = InterQATagTextLabel;
    textLabel.frame = NSMakeRect(inset, y, contentW, 26);
    textLabel.font = [NSFont systemFontOfSize:12];
    textLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    textLabel.maximumNumberOfLines = 2;
    textLabel.lineBreakMode = NSLineBreakByWordWrapping;
    textLabel.preferredMaxLayoutWidth = contentW;
    [cell addSubview:textLabel];

    // Row 3: Buttons (always created; hidden/shown during configuration)
    y -= 22;
    CGFloat btnX = inset;

    NSButton *upvoteBtn = [[NSButton alloc] initWithFrame:NSMakeRect(btnX, y, 50, 18)];
    upvoteBtn.tag = InterQATagUpvoteButton;
    upvoteBtn.font = [NSFont systemFontOfSize:10];
    upvoteBtn.bordered = NO;
    [upvoteBtn setTarget:self];
    [upvoteBtn setAction:@selector(upvoteAction:)];
    [cell addSubview:upvoteBtn];
    btnX += 54;

    NSButton *highlightBtn = [[NSButton alloc] initWithFrame:NSMakeRect(btnX, y, 20, 18)];
    highlightBtn.tag = InterQATagHighlightBtn;
    [highlightBtn setTitle:@"📌"];
    highlightBtn.font = [NSFont systemFontOfSize:10];
    highlightBtn.bordered = NO;
    highlightBtn.toolTip = @"Highlight";
    [highlightBtn setAccessibilityLabel:@"Highlight"];
    [highlightBtn setTarget:self];
    [highlightBtn setAction:@selector(highlightAction:)];
    highlightBtn.hidden = YES;
    [cell addSubview:highlightBtn];

    NSButton *answeredBtn = [[NSButton alloc] initWithFrame:NSMakeRect(btnX, y, 20, 18)];
    answeredBtn.tag = InterQATagAnsweredBtn;
    [answeredBtn setTitle:@"✅"];
    answeredBtn.font = [NSFont systemFontOfSize:10];
    answeredBtn.bordered = NO;
    answeredBtn.toolTip = @"Mark Answered";
    [answeredBtn setAccessibilityLabel:@"Mark Answered"];
    [answeredBtn setTarget:self];
    [answeredBtn setAction:@selector(markAnsweredAction:)];
    answeredBtn.hidden = YES;
    [cell addSubview:answeredBtn];

    NSButton *dismissBtn = [[NSButton alloc] initWithFrame:NSMakeRect(btnX, y, 20, 18)];
    dismissBtn.tag = InterQATagDismissBtn;
    [dismissBtn setTitle:@"✕"];
    dismissBtn.font = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
    dismissBtn.bordered = NO;
    dismissBtn.contentTintColor = [NSColor systemRedColor];
    dismissBtn.toolTip = @"Dismiss";
    [dismissBtn setAccessibilityLabel:@"Dismiss"];
    [dismissBtn setTarget:self];
    [dismissBtn setAction:@selector(dismissAction:)];
    dismissBtn.hidden = YES;
    [cell addSubview:dismissBtn];

    return cell;
}

/// Configures a reused cell's subviews with data from the given question.
- (void)configureCell:(NSView *)cell withQuestion:(InterQuestionInfo *)question atRow:(NSInteger)row {
    // Background
    if (question.isHighlighted) {
        cell.layer.backgroundColor = [NSColor colorWithRed:0.15 green:0.18 blue:0.25 alpha:1.0].CGColor;
    } else if (question.isAnswered) {
        cell.layer.backgroundColor = [NSColor colorWithRed:0.12 green:0.20 blue:0.14 alpha:1.0].CGColor;
    } else {
        cell.layer.backgroundColor = [NSColor colorWithWhite:0.14 alpha:1.0].CGColor;
    }

    // Meta label
    NSTextField *metaLabel = [cell viewWithTag:InterQATagMetaLabel];
    NSString *displayName = [question displayNameWithIsViewerHost:self.isHost];
    NSString *meta = [NSString stringWithFormat:@"%@ · %@", displayName, question.formattedTime];
    if (question.isHighlighted) meta = [NSString stringWithFormat:@"📌 %@", meta];
    if (question.isAnswered)    meta = [NSString stringWithFormat:@"✅ %@", meta];
    metaLabel.stringValue = meta;

    // Question text
    NSTextField *textLabel = [cell viewWithTag:InterQATagTextLabel];
    textLabel.stringValue = question.text;

    // Upvote button
    NSButton *upvoteBtn = [cell viewWithTag:InterQATagUpvoteButton];
    upvoteBtn.title = [NSString stringWithFormat:@"▲ %ld", (long)question.upvoteCount];
    upvoteBtn.tag = InterQATagUpvoteButton; // keep stable tag for viewWithTag lookup
    // Store the row in the cell's own tag so action handlers can recover it
    // (upvote action retrieves row from the button's superview — see below)
    if (question.hasLocalUserUpvoted) {
        upvoteBtn.contentTintColor = [NSColor systemBlueColor];
        upvoteBtn.enabled = NO;
    } else {
        upvoteBtn.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
        upvoteBtn.enabled = YES;
    }

    // Host action buttons — reposition dynamically based on visibility
    NSButton *highlightBtn = [cell viewWithTag:InterQATagHighlightBtn];
    NSButton *answeredBtn  = [cell viewWithTag:InterQATagAnsweredBtn];
    NSButton *dismissBtn   = [cell viewWithTag:InterQATagDismissBtn];

    CGFloat inset = 6.0;
    CGFloat btnX = inset + 54; // after upvote button

    if (self.isHost) {
        BOOL showHighlight = !question.isHighlighted;
        highlightBtn.hidden = !showHighlight;
        if (showHighlight) {
            NSRect hf = highlightBtn.frame;
            hf.origin.x = btnX;
            highlightBtn.frame = hf;
            btnX += 24;
        }

        BOOL showAnswered = !question.isAnswered;
        answeredBtn.hidden = !showAnswered;
        if (showAnswered) {
            NSRect af = answeredBtn.frame;
            af.origin.x = btnX;
            answeredBtn.frame = af;
            btnX += 24;
        }

        dismissBtn.hidden = NO;
        NSRect df = dismissBtn.frame;
        df.origin.x = btnX;
        dismissBtn.frame = df;
    } else {
        highlightBtn.hidden = YES;
        answeredBtn.hidden  = YES;
        dismissBtn.hidden   = YES;
    }
}

// MARK: - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.displayQuestions.count) return nil;

    InterQuestionInfo *question = self.displayQuestions[row];
    CGFloat cellW = InterQAPanelWidth - 4; // Slight inset

    NSView *cell = [tableView makeViewWithIdentifier:InterQACellIdentifier owner:self];
    if (!cell) {
        cell = [self createQuestionCellWithWidth:cellW];
    }

    [self configureCell:cell withQuestion:question atRow:row];
    return cell;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return InterQARowMinHeight;
}

@end
