#import "InterScreenShareQueuePanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

static const CGFloat InterSSQueuePanelWidth  = 280.0;
static const CGFloat InterSSQueueHeaderHeight = 36.0;
static const CGFloat InterSSQueueRowHeight    = 44.0;
static const CGFloat InterSSQueuePadding      = 8.0;

@interface InterScreenShareQueuePanel ()

@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) NSTextField *headerLabel;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSMutableArray<InterScreenShareEntry *> *queueEntries;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, strong) NSButton *approveAllButton;
@property (nonatomic, strong) NSButton *denyAllButton;

@end

@implementation InterScreenShareQueuePanel

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _queueEntries = [NSMutableArray array];
        _panelVisible = NO;
        [self setupViews];
    }
    return self;
}

/// Pass through mouse events when hidden.
- (NSView *)hitTest:(NSPoint)point {
    if (!self.panelVisible) {
        return nil;
    }
    return [super hitTest:point];
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

    // Header bar background
    NSView *headerBar = [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                                  self.bounds.size.height - InterSSQueueHeaderHeight,
                                                                  self.bounds.size.width,
                                                                  InterSSQueueHeaderHeight)];
    headerBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [headerBar setWantsLayer:YES];
    headerBar.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;
    [self addSubview:headerBar];

    // Header label
    self.headerLabel = [NSTextField labelWithString:@"📺 Share Requests"];
    self.headerLabel.frame = NSMakeRect(InterSSQueuePadding, 8,
                                        self.bounds.size.width - InterSSQueuePadding * 2 - 36,
                                        20);
    self.headerLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.headerLabel.font = [NSFont boldSystemFontOfSize:13];
    self.headerLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    [headerBar addSubview:self.headerLabel];

    // Close button
    NSButton *closeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(self.bounds.size.width - 36, 6, 28, 24)];
    closeBtn.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [closeBtn setImage:[NSImage imageWithSystemSymbolName:@"xmark"
                                accessibilityDescription:@"Close"]];
    [closeBtn setImagePosition:NSImageOnly];
    [closeBtn setBordered:NO];
    closeBtn.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [closeBtn setTarget:self];
    [closeBtn setAction:@selector(closeAction:)];
    closeBtn.toolTip = @"Close panel";
    [headerBar addSubview:closeBtn];

    // Approve All / Deny All buttons row below header
    CGFloat actionRowY = self.bounds.size.height - InterSSQueueHeaderHeight - 28;
    CGFloat halfWidth = (self.bounds.size.width - InterSSQueuePadding * 3) / 2.0;

    self.approveAllButton = [[NSButton alloc] initWithFrame:NSMakeRect(InterSSQueuePadding, actionRowY,
                                                                       halfWidth, 22)];
    self.approveAllButton.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.approveAllButton setTitle:@"Approve All"];
    self.approveAllButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.approveAllButton.contentTintColor = [NSColor systemGreenColor];
    [self.approveAllButton setBordered:NO];
    self.approveAllButton.alignment = NSTextAlignmentLeft;
    [self.approveAllButton setTarget:self];
    [self.approveAllButton setAction:@selector(approveAllAction:)];
    self.approveAllButton.toolTip = @"Approve all share requests";
    self.approveAllButton.hidden = YES;
    [self addSubview:self.approveAllButton];

    self.denyAllButton = [[NSButton alloc] initWithFrame:NSMakeRect(InterSSQueuePadding * 2 + halfWidth, actionRowY,
                                                                    halfWidth, 22)];
    self.denyAllButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.denyAllButton setTitle:@"Deny All"];
    self.denyAllButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.denyAllButton.contentTintColor = [NSColor systemRedColor];
    [self.denyAllButton setBordered:NO];
    self.denyAllButton.alignment = NSTextAlignmentRight;
    [self.denyAllButton setTarget:self];
    [self.denyAllButton setAction:@selector(denyAllAction:)];
    self.denyAllButton.toolTip = @"Deny all share requests";
    self.denyAllButton.hidden = YES;
    [self addSubview:self.denyAllButton];

    // Empty state label
    self.emptyLabel = [NSTextField labelWithString:@"No share requests"];
    self.emptyLabel.frame = NSMakeRect(InterSSQueuePadding, self.bounds.size.height / 2 - 10,
                                       self.bounds.size.width - InterSSQueuePadding * 2, 20);
    self.emptyLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
    self.emptyLabel.font = [NSFont systemFontOfSize:11];
    self.emptyLabel.textColor = [NSColor colorWithWhite:0.5 alpha:1.0];
    self.emptyLabel.alignment = NSTextAlignmentCenter;
    [self addSubview:self.emptyLabel];

    // Scroll + Table
    CGFloat actionRowBarHeight = 28.0;
    CGFloat scrollHeight = self.bounds.size.height - InterSSQueueHeaderHeight - actionRowBarHeight - InterSSQueuePadding;
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
    self.tableView.rowHeight = InterSSQueueRowHeight;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"ssEntry"];
    column.width = self.bounds.size.width;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:column];

    self.tableView.dataSource = self;
    self.tableView.delegate = self;

    self.scrollView.documentView = self.tableView;
}

#pragma mark - Public API

- (void)setEntries:(NSArray<InterScreenShareEntry *> *)entries {
    [self.queueEntries removeAllObjects];
    [self.queueEntries addObjectsFromArray:entries];
    [self.tableView reloadData];
    BOOL hasEntries = (self.queueEntries.count > 0);
    self.emptyLabel.hidden = hasEntries;
    self.approveAllButton.hidden = !hasEntries;
    self.denyAllButton.hidden = !hasEntries;
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

    InterScreenShareEntry *entry = self.queueEntries[row];
    NSString *cellId = @"SSQueueEntryCell";

    NSTableCellView *cell = [tableView makeViewWithIdentifier:cellId owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, InterSSQueuePanelWidth, InterSSQueueRowHeight)];
        cell.identifier = cellId;

        // Screen share icon
        NSTextField *iconLabel = [NSTextField labelWithString:@"📺"];
        iconLabel.tag = 300;
        iconLabel.font = [NSFont systemFontOfSize:16];
        iconLabel.frame = NSMakeRect(InterSSQueuePadding, 11, 22, 22);
        [cell addSubview:iconLabel];

        // Name label
        NSTextField *nameLabel = [NSTextField labelWithString:@""];
        nameLabel.tag = 301;
        nameLabel.font = [NSFont systemFontOfSize:12];
        nameLabel.textColor = [NSColor colorWithWhite:0.9 alpha:1.0];
        nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        nameLabel.frame = NSMakeRect(34, 13, 110, 18);
        [cell addSubview:nameLabel];

        // Approve button
        NSButton *approveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(InterSSQueuePanelWidth - 148, 10, 64, 24)];
        approveBtn.tag = 302;
        [approveBtn setTitle:@"Approve"];
        approveBtn.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
        approveBtn.contentTintColor = [NSColor systemGreenColor];
        approveBtn.autoresizingMask = NSViewMinXMargin;
        [approveBtn setTarget:self];
        [approveBtn setAction:@selector(approveAction:)];
        [cell addSubview:approveBtn];

        // Deny button
        NSButton *denyBtn = [[NSButton alloc] initWithFrame:NSMakeRect(InterSSQueuePanelWidth - 78, 10, 64, 24)];
        denyBtn.tag = 303;
        [denyBtn setTitle:@"Deny"];
        denyBtn.font = [NSFont systemFontOfSize:10];
        denyBtn.autoresizingMask = NSViewMinXMargin;
        [denyBtn setTarget:self];
        [denyBtn setAction:@selector(denyAction:)];
        [cell addSubview:denyBtn];
    }

    NSTextField *nameLabel  = [cell viewWithTag:301];
    NSButton    *approveBtn = [cell viewWithTag:302];
    NSButton    *denyBtn    = [cell viewWithTag:303];

    nameLabel.stringValue = entry.displayName;
    approveBtn.cell.representedObject = entry.participantIdentity;
    denyBtn.cell.representedObject    = entry.participantIdentity;

    return cell;
}

- (void)approveAction:(NSButton *)sender {
    NSString *identity = sender.cell.representedObject;
    if (identity && [self.delegate respondsToSelector:@selector(screenShareQueuePanel:didApproveParticipant:)]) {
        [self.delegate screenShareQueuePanel:self didApproveParticipant:identity];
    }
}

- (void)denyAction:(NSButton *)sender {
    NSString *identity = sender.cell.representedObject;
    if (identity && [self.delegate respondsToSelector:@selector(screenShareQueuePanel:didDenyParticipant:)]) {
        [self.delegate screenShareQueuePanel:self didDenyParticipant:identity];
    }
}

- (void)closeAction:(id)sender {
#pragma unused(sender)
    [self hidePanel];
}

- (void)approveAllAction:(id)sender {
#pragma unused(sender)
    if (self.queueEntries.count == 0) return;
    if ([self.delegate respondsToSelector:@selector(screenShareQueuePanelDidApproveAll:)]) {
        [self.delegate screenShareQueuePanelDidApproveAll:self];
    }
}

- (void)denyAllAction:(id)sender {
#pragma unused(sender)
    if (self.queueEntries.count == 0) return;
    if ([self.delegate respondsToSelector:@selector(screenShareQueuePanelDidDenyAll:)]) {
        [self.delegate screenShareQueuePanelDidDenyAll:self];
    }
}

@end
