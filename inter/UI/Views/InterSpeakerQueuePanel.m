#import "InterSpeakerQueuePanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

static const CGFloat InterQueuePanelWidth = 260.0;
static const CGFloat InterQueueHeaderHeight = 36.0;
static const CGFloat InterQueueRowHeight = 40.0;
static const CGFloat InterQueuePadding = 8.0;

@interface InterSpeakerQueuePanel ()

@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) NSTextField *headerLabel;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSMutableArray<InterRaisedHandEntry *> *queueEntries;
@property (nonatomic, assign) BOOL panelVisible;

@end

@implementation InterSpeakerQueuePanel

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _queueEntries = [NSMutableArray array];
        _panelVisible = NO;
        [self setupViews];
    }
    return self;
}

- (BOOL)isVisible {
    return self.panelVisible;
}

#pragma mark - Setup

- (void)setupViews {
    [self setWantsLayer:YES];
    self.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.95].CGColor;
    self.layer.cornerRadius = 8.0;
    self.layer.borderColor = [NSColor colorWithWhite:0.25 alpha:1.0].CGColor;
    self.layer.borderWidth = 1.0;
    self.hidden = YES;

    // Header
    self.headerLabel = [NSTextField labelWithString:@"✋ Raised Hands"];
    self.headerLabel.frame = NSMakeRect(InterQueuePadding,
                                        self.bounds.size.height - InterQueueHeaderHeight,
                                        self.bounds.size.width - InterQueuePadding * 2,
                                        InterQueueHeaderHeight);
    self.headerLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.headerLabel.font = [NSFont boldSystemFontOfSize:13];
    self.headerLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    [self addSubview:self.headerLabel];

    // Empty state
    self.emptyLabel = [NSTextField labelWithString:@"No raised hands"];
    self.emptyLabel.frame = NSMakeRect(InterQueuePadding, self.bounds.size.height / 2 - 10,
                                       self.bounds.size.width - InterQueuePadding * 2, 20);
    self.emptyLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
    self.emptyLabel.font = [NSFont systemFontOfSize:11];
    self.emptyLabel.textColor = [NSColor colorWithWhite:0.5 alpha:1.0];
    self.emptyLabel.alignment = NSTextAlignmentCenter;
    [self addSubview:self.emptyLabel];

    // Scroll + Table
    CGFloat scrollHeight = self.bounds.size.height - InterQueueHeaderHeight - InterQueuePadding;
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0,
                                                                      self.bounds.size.width,
                                                                      scrollHeight)];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.drawsBackground = NO;
    self.scrollView.borderType = NSNoBorder;
    [self addSubview:self.scrollView];

    self.tableView = [[NSTableView alloc] initWithFrame:self.scrollView.bounds];
    self.tableView.headerView = nil;
    self.tableView.backgroundColor = [NSColor clearColor];
    self.tableView.usesAlternatingRowBackgroundColors = NO;
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    self.tableView.rowHeight = InterQueueRowHeight;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"entry"];
    column.width = self.bounds.size.width;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:column];

    self.tableView.dataSource = self;
    self.tableView.delegate = self;

    self.scrollView.documentView = self.tableView;
}

#pragma mark - Public API

- (void)setEntries:(NSArray<InterRaisedHandEntry *> *)entries {
    [self.queueEntries removeAllObjects];
    [self.queueEntries addObjectsFromArray:entries];
    [self.tableView reloadData];
    self.emptyLabel.hidden = (self.queueEntries.count > 0);
}

- (void)showPanel {
    if (self.panelVisible) return;
    self.panelVisible = YES;
    self.hidden = NO;
    self.alphaValue = 0.0;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        self.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)hidePanel {
    if (!self.panelVisible) return;
    self.panelVisible = NO;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        self.animator.alphaValue = 0.0;
    } completionHandler:^{
        self.hidden = YES;
    }];
}

- (void)togglePanel {
    if (self.panelVisible) {
        [self hidePanel];
    } else {
        [self showPanel];
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
#pragma unused(tableView)
    return (NSInteger)self.queueEntries.count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
#pragma unused(tableColumn)

    static NSString *const kCellId = @"QueueEntryCell";

    NSTableCellView *cell = [tableView makeViewWithIdentifier:kCellId owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, InterQueuePanelWidth, InterQueueRowHeight)];
        cell.identifier = kCellId;

        // Position badge
        NSTextField *posLabel = [NSTextField labelWithString:@""];
        posLabel.tag = 200;
        posLabel.font = [NSFont boldSystemFontOfSize:12];
        posLabel.textColor = [NSColor systemOrangeColor];
        posLabel.frame = NSMakeRect(InterQueuePadding, 12, 24, 18);
        [cell addSubview:posLabel];

        // Hand emoji
        NSTextField *handEmoji = [NSTextField labelWithString:@"✋"];
        handEmoji.tag = 201;
        handEmoji.font = [NSFont systemFontOfSize:16];
        handEmoji.frame = NSMakeRect(32, 10, 22, 22);
        [cell addSubview:handEmoji];

        // Name label
        NSTextField *nameLabel = [NSTextField labelWithString:@""];
        nameLabel.tag = 202;
        nameLabel.font = [NSFont systemFontOfSize:12];
        nameLabel.textColor = [NSColor colorWithWhite:0.9 alpha:1.0];
        nameLabel.frame = NSMakeRect(58, 12, 120, 18);
        nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:nameLabel];

        // Dismiss button
        NSButton *dismissBtn = [[NSButton alloc] initWithFrame:NSMakeRect(InterQueuePanelWidth - 80, 8, 68, 24)];
        dismissBtn.tag = 203;
        [dismissBtn setTitle:@"Dismiss"];
        dismissBtn.font = [NSFont systemFontOfSize:10];
        dismissBtn.autoresizingMask = NSViewMinXMargin;
        [dismissBtn setTarget:self];
        [dismissBtn setAction:@selector(dismissAction:)];
        [cell addSubview:dismissBtn];
    }

    InterRaisedHandEntry *entry = self.queueEntries[row];

    NSTextField *posLabel = [cell viewWithTag:200];
    NSTextField *nameLabel = [cell viewWithTag:202];
    NSButton *dismissBtn = [cell viewWithTag:203];

    posLabel.stringValue = [NSString stringWithFormat:@"#%ld", (long)(row + 1)];
    nameLabel.stringValue = entry.displayName;

    // Store identity on the button for the action
    dismissBtn.cell.representedObject = entry.participantIdentity;

    return cell;
}

- (void)dismissAction:(NSButton *)sender {
    NSString *identity = sender.cell.representedObject;
    if (identity && [self.delegate respondsToSelector:@selector(speakerQueuePanel:didDismissParticipant:)]) {
        [self.delegate speakerQueuePanel:self didDismissParticipant:identity];
    }
}

@end
