#import "InterPollPanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// ============================================================================
// InterPollPanel.m
// inter
//
// Phase 8.5.3–8.5.5 — Poll creation, voting, and results UI.
//
// LAYOUT:
//   Slide-in panel (300pt wide) from the right edge, matching InterChatPanel.
//   Two modes:
//     Host: Create form → Active (live results + end button) → Ended (final + new poll)
//     Participant: Waiting → Vote → Submitted/Results → Ended
//
// THREADING:
//   All methods must be called on the main queue. UI-only, zero networking.
//
// ISOLATION INVARIANT [G8]:
//   This is a pure UI component. All actions are forwarded to the delegate.
//   No direct references to rooms, controllers, or media.
// ============================================================================

static const CGFloat InterPollPanelWidth = 300.0;
static const CGFloat InterPollHeaderHeight = 38.0;
static const CGFloat InterPollPadding = 8.0;
static const NSInteger InterPollMaxOptions = 10;
static const NSInteger InterPollMinOptions = 2;

// MARK: - View Mode

typedef NS_ENUM(NSUInteger, InterPollViewMode) {
    /// Host: show the create-poll form.
    InterPollViewModeCreate = 0,
    /// Active poll: host sees live results, participant sees vote UI.
    InterPollViewModeActive,
    /// Poll ended: both see final results.
    InterPollViewModeEnded,
};

// MARK: - Private Interface

@interface InterPollPanel ()

@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) NSTextField *headerLabel;
@property (nonatomic, strong) NSButton *closeButton;
@property (nonatomic, assign) InterPollViewMode viewMode;

// Create form components
@property (nonatomic, strong) NSScrollView *createScrollView;
@property (nonatomic, strong) NSView *createContentView;
@property (nonatomic, strong) NSTextField *questionField;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *optionFields;
@property (nonatomic, strong) NSButton *addOptionButton;
@property (nonatomic, strong) NSButton *anonymousToggle;
@property (nonatomic, strong) NSButton *multiSelectToggle;
@property (nonatomic, strong) NSButton *launchButton;

// Active/Results components
@property (nonatomic, strong) NSScrollView *resultsScrollView;
@property (nonatomic, strong) NSView *resultsContentView;
@property (nonatomic, strong) NSTextField *pollQuestionLabel;
@property (nonatomic, strong) NSTextField *pollStatusLabel;
@property (nonatomic, strong) NSMutableArray<NSButton *> *voteButtons;
@property (nonatomic, strong) NSMutableArray<NSView *> *resultBars;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *resultLabels;
@property (nonatomic, strong) NSButton *submitVoteButton;
@property (nonatomic, strong) NSButton *endPollButton;
@property (nonatomic, strong) NSButton *shareResultsButton;
@property (nonatomic, strong) NSButton *createPollButton;
@property (nonatomic, strong) NSTextField *totalVotesLabel;

// State
@property (nonatomic, strong, nullable) InterPollInfo *currentPoll;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selectedIndices;
@property (nonatomic, assign) BOOL hasVoted;

@end

@implementation InterPollPanel

// MARK: - Init

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _optionFields = [NSMutableArray array];
        _voteButtons = [NSMutableArray array];
        _resultBars = [NSMutableArray array];
        _resultLabels = [NSMutableArray array];
        _selectedIndices = [NSMutableSet set];
        _viewMode = InterPollViewModeCreate;
        _hasVoted = NO;
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
    [self setupCreateForm];
    [self setupResultsView];

    // Start in create mode
    [self showViewMode:InterPollViewModeCreate];
}

- (void)setupHeader {
    CGFloat containerW = InterPollPanelWidth;
    CGFloat containerH = self.containerView.bounds.size.height;

    NSView *headerBar = [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                                  containerH - InterPollHeaderHeight,
                                                                  containerW,
                                                                  InterPollHeaderHeight)];
    headerBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [headerBar setWantsLayer:YES];
    headerBar.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;
    [self.containerView addSubview:headerBar];

    self.headerLabel = [NSTextField labelWithString:@"📊 Polls"];
    self.headerLabel.frame = NSMakeRect(InterPollPadding, 8, 120, 20);
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

// MARK: - Create Form

- (void)setupCreateForm {
    CGFloat containerW = InterPollPanelWidth;
    CGFloat containerH = self.containerView.bounds.size.height;
    CGFloat topOffset = InterPollHeaderHeight + 4;
    CGFloat availableH = containerH - topOffset;

    self.createScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, containerW, availableH)];
    self.createScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.createScrollView.hasVerticalScroller = YES;
    self.createScrollView.drawsBackground = NO;
    self.createScrollView.borderType = NSNoBorder;
    [self.containerView addSubview:self.createScrollView];

    self.createContentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, containerW, 500)];
    self.createScrollView.documentView = self.createContentView;

    CGFloat y = 460; // Top-down layout inside the content view
    CGFloat inset = InterPollPadding;
    CGFloat fieldW = containerW - inset * 2;

    // Question label
    NSTextField *questionLabel = [NSTextField labelWithString:@"Question"];
    questionLabel.frame = NSMakeRect(inset, y, fieldW, 16);
    questionLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    questionLabel.textColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.createContentView addSubview:questionLabel];
    y -= 32;

    self.questionField = [[NSTextField alloc] initWithFrame:NSMakeRect(inset, y, fieldW, 28)];
    self.questionField.placeholderString = @"Type your question here…";
    self.questionField.font = [NSFont systemFontOfSize:12];
    self.questionField.drawsBackground = YES;
    self.questionField.backgroundColor = [NSColor colorWithWhite:0.18 alpha:1.0];
    self.questionField.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    self.questionField.bordered = YES;
    [self.createContentView addSubview:self.questionField];
    y -= 28;

    // Options label
    NSTextField *optionsLabel = [NSTextField labelWithString:@"Options"];
    optionsLabel.frame = NSMakeRect(inset, y, fieldW, 16);
    optionsLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    optionsLabel.textColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.createContentView addSubview:optionsLabel];
    y -= 4;

    // Start with 2 option fields
    for (int i = 0; i < InterPollMinOptions; i++) {
        y -= 30;
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(inset, y, fieldW, 24)];
        field.placeholderString = [NSString stringWithFormat:@"Option %d", i + 1];
        field.font = [NSFont systemFontOfSize:12];
        field.drawsBackground = YES;
        field.backgroundColor = [NSColor colorWithWhite:0.18 alpha:1.0];
        field.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
        field.bordered = YES;
        [self.createContentView addSubview:field];
        [self.optionFields addObject:field];
    }

    y -= 30;
    self.addOptionButton = [[NSButton alloc] initWithFrame:NSMakeRect(inset, y, 120, 24)];
    [self.addOptionButton setTitle:@"+ Add Option"];
    self.addOptionButton.font = [NSFont systemFontOfSize:11];
    self.addOptionButton.bordered = NO;
    self.addOptionButton.contentTintColor = [NSColor systemBlueColor];
    [self.addOptionButton setTarget:self];
    [self.addOptionButton setAction:@selector(addOptionAction:)];
    [self.createContentView addSubview:self.addOptionButton];

    y -= 32;
    // Anonymous toggle
    self.anonymousToggle = [NSButton checkboxWithTitle:@"Anonymous voting"
                                               target:nil
                                               action:nil];
    self.anonymousToggle.frame = NSMakeRect(inset, y, fieldW, 20);
    self.anonymousToggle.font = [NSFont systemFontOfSize:11];
    [self.anonymousToggle setContentTintColor:[NSColor colorWithWhite:0.85 alpha:1.0]];
    [self.createContentView addSubview:self.anonymousToggle];

    y -= 22;
    // Multi-select toggle
    self.multiSelectToggle = [NSButton checkboxWithTitle:@"Allow multiple selections"
                                                 target:nil
                                                 action:nil];
    self.multiSelectToggle.frame = NSMakeRect(inset, y, fieldW, 20);
    self.multiSelectToggle.font = [NSFont systemFontOfSize:11];
    [self.multiSelectToggle setContentTintColor:[NSColor colorWithWhite:0.85 alpha:1.0]];
    [self.createContentView addSubview:self.multiSelectToggle];

    y -= 40;
    // Launch button
    self.launchButton = [[NSButton alloc] initWithFrame:NSMakeRect(inset, y, fieldW, 32)];
    [self.launchButton setTitle:@"Launch Poll"];
    self.launchButton.font = [NSFont boldSystemFontOfSize:12];
    [self.launchButton setWantsLayer:YES];
    self.launchButton.layer.backgroundColor = [NSColor systemBlueColor].CGColor;
    self.launchButton.layer.cornerRadius = 6.0;
    self.launchButton.bordered = NO;
    self.launchButton.contentTintColor = [NSColor whiteColor];
    [self.launchButton setTarget:self];
    [self.launchButton setAction:@selector(launchAction:)];
    [self.createContentView addSubview:self.launchButton];
}

// MARK: - Results View

- (void)setupResultsView {
    CGFloat containerW = InterPollPanelWidth;
    CGFloat containerH = self.containerView.bounds.size.height;
    CGFloat topOffset = InterPollHeaderHeight + 4;
    CGFloat availableH = containerH - topOffset;

    self.resultsScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, containerW, availableH)];
    self.resultsScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.resultsScrollView.hasVerticalScroller = YES;
    self.resultsScrollView.drawsBackground = NO;
    self.resultsScrollView.borderType = NSNoBorder;
    [self.containerView addSubview:self.resultsScrollView];

    self.resultsContentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, containerW, 600)];
    self.resultsScrollView.documentView = self.resultsContentView;

    // These are populated dynamically by showActivePoll: / updateResults:
    self.pollQuestionLabel = [NSTextField labelWithString:@""];
    self.pollQuestionLabel.frame = NSMakeRect(InterPollPadding, 560, containerW - InterPollPadding * 2, 32);
    self.pollQuestionLabel.font = [NSFont boldSystemFontOfSize:14];
    self.pollQuestionLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    self.pollQuestionLabel.maximumNumberOfLines = 3;
    self.pollQuestionLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.pollQuestionLabel.preferredMaxLayoutWidth = containerW - InterPollPadding * 2;
    [self.resultsContentView addSubview:self.pollQuestionLabel];

    self.pollStatusLabel = [NSTextField labelWithString:@""];
    self.pollStatusLabel.frame = NSMakeRect(InterPollPadding, 538, containerW - InterPollPadding * 2, 16);
    self.pollStatusLabel.font = [NSFont systemFontOfSize:10];
    self.pollStatusLabel.textColor = [NSColor colorWithWhite:0.5 alpha:1.0];
    [self.resultsContentView addSubview:self.pollStatusLabel];

    self.totalVotesLabel = [NSTextField labelWithString:@""];
    self.totalVotesLabel.frame = NSMakeRect(InterPollPadding, 520, containerW - InterPollPadding * 2, 14);
    self.totalVotesLabel.font = [NSFont systemFontOfSize:10];
    self.totalVotesLabel.textColor = [NSColor colorWithWhite:0.5 alpha:1.0];
    [self.resultsContentView addSubview:self.totalVotesLabel];

    self.resultsScrollView.hidden = YES;
}

// MARK: - Public API

- (void)showActivePoll:(InterPollInfo *)poll {
    self.currentPoll = poll;
    self.hasVoted = poll.hasLocalUserVoted;
    [self.selectedIndices removeAllObjects];
    for (NSNumber *idx in poll.localVoteIndices) {
        [self.selectedIndices addObject:idx];
    }
    self.viewMode = InterPollViewModeActive;
    [self rebuildResultsView];
    [self showViewMode:InterPollViewModeActive];
}

- (void)updateResults:(InterPollInfo *)poll {
    self.currentPoll = poll;
    self.hasVoted = poll.hasLocalUserVoted;
    [self updateResultBars];
}

- (void)showEndedPoll:(InterPollInfo *)poll {
    self.currentPoll = poll;
    self.hasVoted = poll.hasLocalUserVoted;
    self.viewMode = InterPollViewModeEnded;
    [self rebuildResultsView];
    [self showViewMode:InterPollViewModeEnded];
}

- (void)resetToCreateForm {
    self.currentPoll = nil;
    self.hasVoted = NO;
    [self.selectedIndices removeAllObjects];
    [self resetCreateFormFields];
    [self showViewMode:InterPollViewModeCreate];
}

// MARK: - View Mode Switching

- (void)showViewMode:(InterPollViewMode)mode {
    self.viewMode = mode;
    switch (mode) {
        case InterPollViewModeCreate:
            self.createScrollView.hidden = NO;
            self.resultsScrollView.hidden = YES;
            break;
        case InterPollViewModeActive:
        case InterPollViewModeEnded:
            self.createScrollView.hidden = YES;
            self.resultsScrollView.hidden = NO;
            break;
    }
}

// MARK: - Results View Dynamic Rebuild

- (void)rebuildResultsView {
    InterPollInfo *poll = self.currentPoll;
    if (!poll) return;

    // Remove old dynamic subviews
    [self.voteButtons removeAllObjects];
    [self.resultBars removeAllObjects];
    [self.resultLabels removeAllObjects];

    // Remove all subviews except the static header labels
    NSArray<NSView *> *subviews = [self.resultsContentView.subviews copy];
    for (NSView *sub in subviews) {
        if (sub != self.pollQuestionLabel && sub != self.pollStatusLabel && sub != self.totalVotesLabel) {
            [sub removeFromSuperview];
        }
    }

    // Remove old action buttons
    self.submitVoteButton = nil;
    self.endPollButton = nil;
    self.shareResultsButton = nil;
    self.createPollButton = nil;

    CGFloat containerW = InterPollPanelWidth;
    CGFloat inset = InterPollPadding;
    CGFloat fieldW = containerW - inset * 2;

    // Update question
    self.pollQuestionLabel.stringValue = poll.question;

    // Status
    if (poll.isActive) {
        self.pollStatusLabel.stringValue = @"🟢 Poll is active";
    } else if (poll.isEnded) {
        self.pollStatusLabel.stringValue = @"🔴 Poll ended";
    }

    self.totalVotesLabel.stringValue = [NSString stringWithFormat:@"Total votes: %ld", (long)poll.totalVotes];

    // Build option rows
    CGFloat y = 500;
    BOOL showVoteUI = poll.isActive && !self.hasVoted && !self.isHost;
    BOOL showResults = self.hasVoted || self.isHost || poll.isEnded;

    for (NSInteger i = 0; i < poll.optionLabels.count; i++) {
        NSString *label = poll.optionLabels[i];

        if (showVoteUI) {
            // Vote button (checkbox/radio style)
            NSButton *btn;
            if (poll.allowMultiSelect) {
                btn = [NSButton checkboxWithTitle:label target:self action:@selector(voteOptionToggled:)];
            } else {
                btn = [NSButton radioButtonWithTitle:label target:self action:@selector(voteOptionToggled:)];
            }
            btn.frame = NSMakeRect(inset, y, fieldW, 22);
            btn.font = [NSFont systemFontOfSize:12];
            [btn setContentTintColor:[NSColor colorWithWhite:0.9 alpha:1.0]];
            btn.tag = i;
            [self.resultsContentView addSubview:btn];
            [self.voteButtons addObject:btn];
            y -= 28;
        } else if (showResults) {
            // Option label
            NSInteger count = (i < poll.optionVoteCounts.count)
                ? [poll.optionVoteCounts[i] integerValue]
                : 0;
            double pct = [poll votePercentageAt:i];

            NSTextField *optLabel = [NSTextField labelWithString:
                [NSString stringWithFormat:@"%@ — %ld (%d%%)", label, (long)count, (int)(pct * 100)]];
            optLabel.frame = NSMakeRect(inset, y, fieldW, 16);
            optLabel.font = [NSFont systemFontOfSize:11];
            optLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
            [self.resultsContentView addSubview:optLabel];
            [self.resultLabels addObject:optLabel];
            y -= 18;

            // Bar chart
            NSView *barBg = [[NSView alloc] initWithFrame:NSMakeRect(inset, y, fieldW, 12)];
            [barBg setWantsLayer:YES];
            barBg.layer.backgroundColor = [NSColor colorWithWhite:0.2 alpha:1.0].CGColor;
            barBg.layer.cornerRadius = 3.0;
            [self.resultsContentView addSubview:barBg];

            CGFloat barW = (CGFloat)(pct * fieldW);
            if (barW < 2.0 && count > 0) barW = 2.0; // Minimum visible width
            NSView *barFill = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, barW, 12)];
            [barFill setWantsLayer:YES];

            // Highlight the option(s) the local user voted for
            BOOL isLocalVote = [self.selectedIndices containsObject:@(i)];
            barFill.layer.backgroundColor = isLocalVote
                ? [NSColor systemGreenColor].CGColor
                : [NSColor systemBlueColor].CGColor;
            barFill.layer.cornerRadius = 3.0;
            [barBg addSubview:barFill];

            [self.resultBars addObject:barBg];
            y -= 20;
        }
    }

    y -= 12;

    // Action buttons
    if (showVoteUI) {
        self.submitVoteButton = [[NSButton alloc] initWithFrame:NSMakeRect(inset, y, fieldW, 28)];
        [self.submitVoteButton setTitle:@"Submit Vote"];
        self.submitVoteButton.font = [NSFont boldSystemFontOfSize:12];
        [self.submitVoteButton setWantsLayer:YES];
        self.submitVoteButton.layer.backgroundColor = [NSColor systemGreenColor].CGColor;
        self.submitVoteButton.layer.cornerRadius = 6.0;
        self.submitVoteButton.bordered = NO;
        self.submitVoteButton.contentTintColor = [NSColor whiteColor];
        [self.submitVoteButton setTarget:self];
        [self.submitVoteButton setAction:@selector(submitVoteAction:)];
        [self.resultsContentView addSubview:self.submitVoteButton];
        y -= 36;
    }

    if (self.isHost && poll.isActive) {
        self.shareResultsButton = [[NSButton alloc] initWithFrame:NSMakeRect(inset, y, fieldW, 28)];
        [self.shareResultsButton setTitle:@"Share Results"];
        self.shareResultsButton.font = [NSFont systemFontOfSize:11];
        self.shareResultsButton.bordered = YES;
        self.shareResultsButton.contentTintColor = [NSColor systemBlueColor];
        [self.shareResultsButton setTarget:self];
        [self.shareResultsButton setAction:@selector(shareResultsAction:)];
        [self.resultsContentView addSubview:self.shareResultsButton];
        y -= 34;

        self.endPollButton = [[NSButton alloc] initWithFrame:NSMakeRect(inset, y, fieldW, 28)];
        [self.endPollButton setTitle:@"End Poll"];
        self.endPollButton.font = [NSFont boldSystemFontOfSize:12];
        [self.endPollButton setWantsLayer:YES];
        self.endPollButton.layer.backgroundColor = [NSColor systemRedColor].CGColor;
        self.endPollButton.layer.cornerRadius = 6.0;
        self.endPollButton.bordered = NO;
        self.endPollButton.contentTintColor = [NSColor whiteColor];
        [self.endPollButton setTarget:self];
        [self.endPollButton setAction:@selector(endPollAction:)];
        [self.resultsContentView addSubview:self.endPollButton];
        y -= 36;
    }

    if (poll.isEnded && self.isHost) {
        self.createPollButton = [[NSButton alloc] initWithFrame:NSMakeRect(inset, y, fieldW, 28)];
        [self.createPollButton setTitle:@"New Poll"];
        self.createPollButton.font = [NSFont systemFontOfSize:11];
        self.createPollButton.bordered = YES;
        self.createPollButton.contentTintColor = [NSColor systemBlueColor];
        [self.createPollButton setTarget:self];
        [self.createPollButton setAction:@selector(newPollAction:)];
        [self.resultsContentView addSubview:self.createPollButton];
        y -= 36;
    }

    // Adjust content view height
    CGFloat contentH = 600 - y;
    if (contentH < 600) contentH = 600;
    self.resultsContentView.frame = NSMakeRect(0, 0, containerW, contentH);
}

- (void)updateResultBars {
    // Fast path: update bar widths and labels without full rebuild
    InterPollInfo *poll = self.currentPoll;
    if (!poll) return;

    CGFloat fieldW = InterPollPanelWidth - InterPollPadding * 2;

    for (NSInteger i = 0; i < self.resultBars.count && i < poll.optionLabels.count; i++) {
        NSView *barBg = self.resultBars[i];
        double pct = [poll votePercentageAt:i];
        CGFloat barW = (CGFloat)(pct * fieldW);
        NSInteger count = (i < poll.optionVoteCounts.count)
            ? [poll.optionVoteCounts[i] integerValue]
            : 0;
        if (barW < 2.0 && count > 0) barW = 2.0;

        // Update fill bar
        if (barBg.subviews.count > 0) {
            NSView *fill = barBg.subviews[0];
            fill.frame = NSMakeRect(0, 0, barW, fill.frame.size.height);
        }

        // Update label
        if (i < self.resultLabels.count) {
            NSString *label = poll.optionLabels[i];
            self.resultLabels[i].stringValue = [NSString stringWithFormat:@"%@ — %ld (%d%%)",
                                                label, (long)count, (int)(pct * 100)];
        }
    }

    self.totalVotesLabel.stringValue = [NSString stringWithFormat:@"Total votes: %ld", (long)poll.totalVotes];
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

- (void)addOptionAction:(id)sender {
    if (self.optionFields.count >= InterPollMaxOptions) return;

    // Find the last option field's frame and add below it
    NSTextField *lastField = self.optionFields.lastObject;
    CGFloat y = lastField.frame.origin.y - 30;
    CGFloat inset = InterPollPadding;
    CGFloat fieldW = InterPollPanelWidth - inset * 2;

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(inset, y, fieldW, 24)];
    field.placeholderString = [NSString stringWithFormat:@"Option %ld", (long)(self.optionFields.count + 1)];
    field.font = [NSFont systemFontOfSize:12];
    field.drawsBackground = YES;
    field.backgroundColor = [NSColor colorWithWhite:0.18 alpha:1.0];
    field.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    field.bordered = YES;
    [self.createContentView addSubview:field];
    [self.optionFields addObject:field];

    // Shift the add button, toggles, and launch button down
    self.addOptionButton.frame = NSMakeRect(self.addOptionButton.frame.origin.x,
                                            self.addOptionButton.frame.origin.y - 30,
                                            self.addOptionButton.frame.size.width,
                                            self.addOptionButton.frame.size.height);
    self.anonymousToggle.frame = NSMakeRect(self.anonymousToggle.frame.origin.x,
                                            self.anonymousToggle.frame.origin.y - 30,
                                            self.anonymousToggle.frame.size.width,
                                            self.anonymousToggle.frame.size.height);
    self.multiSelectToggle.frame = NSMakeRect(self.multiSelectToggle.frame.origin.x,
                                              self.multiSelectToggle.frame.origin.y - 30,
                                              self.multiSelectToggle.frame.size.width,
                                              self.multiSelectToggle.frame.size.height);
    self.launchButton.frame = NSMakeRect(self.launchButton.frame.origin.x,
                                         self.launchButton.frame.origin.y - 30,
                                         self.launchButton.frame.size.width,
                                         self.launchButton.frame.size.height);

    if (self.optionFields.count >= InterPollMaxOptions) {
        self.addOptionButton.enabled = NO;
        self.addOptionButton.alphaValue = 0.5;
    }
}

- (void)launchAction:(id)sender {
    NSString *question = self.questionField.stringValue;
    if ([question stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) {
        return;
    }

    NSMutableArray<NSString *> *options = [NSMutableArray array];
    for (NSTextField *field in self.optionFields) {
        NSString *trimmed = [field.stringValue stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            [options addObject:trimmed];
        }
    }

    if (options.count < InterPollMinOptions) return;

    BOOL isAnonymous = (self.anonymousToggle.state == NSControlStateValueOn);
    BOOL allowMulti = (self.multiSelectToggle.state == NSControlStateValueOn);

    [self.delegate pollPanel:self
     didLaunchPollWithQuestion:question
                       options:options
                   isAnonymous:isAnonymous
              allowMultiSelect:allowMulti];
}

- (void)voteOptionToggled:(NSButton *)sender {
    NSInteger index = sender.tag;

    if (!self.currentPoll.allowMultiSelect) {
        // Radio button: clear all other selections
        [self.selectedIndices removeAllObjects];
        [self.selectedIndices addObject:@(index)];

        // Manually enforce mutual exclusion — individual NSButtons don't auto-group
        for (NSButton *btn in self.voteButtons) {
            btn.state = (btn == sender) ? NSControlStateValueOn : NSControlStateValueOff;
        }
    } else {
        // Checkbox: toggle this selection
        NSNumber *idx = @(index);
        if ([self.selectedIndices containsObject:idx]) {
            [self.selectedIndices removeObject:idx];
        } else {
            [self.selectedIndices addObject:idx];
        }
    }
}

- (void)submitVoteAction:(id)sender {
    if (self.selectedIndices.count == 0) return;

    NSArray<NSNumber *> *indices = [self.selectedIndices allObjects];
    self.hasVoted = YES;

    [self.delegate pollPanel:self didSubmitVoteWithIndices:indices];
}

- (void)endPollAction:(id)sender {
    [self.delegate pollPanelDidEndPoll:self];
}

- (void)shareResultsAction:(id)sender {
    [self.delegate pollPanelDidRequestShareResults:self];
}

- (void)newPollAction:(id)sender {
    [self resetToCreateForm];
}

// MARK: - Create Form Reset

- (void)resetCreateFormFields {
    self.questionField.stringValue = @"";

    // Remove extra option fields beyond the initial 2, undoing the cumulative
    // 30pt downward shift applied by addOptionAction: for each extra field.
    NSInteger extraCount = (NSInteger)self.optionFields.count - InterPollMinOptions;
    while (self.optionFields.count > InterPollMinOptions) {
        NSTextField *field = self.optionFields.lastObject;
        [field removeFromSuperview];
        [self.optionFields removeLastObject];
    }

    if (extraCount > 0) {
        CGFloat totalShift = extraCount * 30.0;
        NSRect af = self.addOptionButton.frame;
        af.origin.y += totalShift;
        self.addOptionButton.frame = af;

        NSRect anf = self.anonymousToggle.frame;
        anf.origin.y += totalShift;
        self.anonymousToggle.frame = anf;

        NSRect mf = self.multiSelectToggle.frame;
        mf.origin.y += totalShift;
        self.multiSelectToggle.frame = mf;

        NSRect lf = self.launchButton.frame;
        lf.origin.y += totalShift;
        self.launchButton.frame = lf;
    }

    // Clear remaining fields
    for (NSTextField *field in self.optionFields) {
        field.stringValue = @"";
    }

    self.anonymousToggle.state = NSControlStateValueOff;
    self.multiSelectToggle.state = NSControlStateValueOff;
    self.addOptionButton.enabled = YES;
    self.addOptionButton.alphaValue = 1.0;
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate (unused — using direct views)

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return 0;
}

@end
