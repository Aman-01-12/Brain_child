#import "InterChatPanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

static const CGFloat InterChatPanelWidth = 300.0;
static const CGFloat InterChatInputHeight = 36.0;
static const CGFloat InterChatHeaderHeight = 38.0;
static const CGFloat InterChatPadding = 8.0;
static const CGFloat InterChatRecipientHeight = 28.0;
static const CGFloat InterChatMessageRowMinHeight = 32.0;
static const CGFloat InterChatAnimationDuration = 0.25;

@interface InterChatPanel ()

@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) NSTextField *headerLabel;
@property (nonatomic, strong) NSButton *closeButton;
@property (nonatomic, strong) NSButton *exportButton;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *inputField;
@property (nonatomic, strong) NSButton *sendButton;
@property (nonatomic, strong) NSPopUpButton *recipientSelector;
@property (nonatomic, strong) NSView *unreadBadgeView;
@property (nonatomic, strong) NSTextField *unreadLabel;
@property (nonatomic, strong) NSMutableArray<InterChatMessageInfo *> *displayMessages;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, copy, nullable) NSString *selectedRecipient;

@end

@implementation InterChatPanel

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _displayMessages = [NSMutableArray array];
        _expanded = NO;
        [self setupViews];
    }
    return self;
}

- (BOOL)isExpanded {
    return self.expanded;
}

/// Pass through mouse events when collapsed. Only forward hits that land
/// inside the visible container view when expanded.
- (NSView *)hitTest:(NSPoint)point {
    if (!self.expanded) {
        return nil;  // Fully transparent to clicks when collapsed
    }
    // point is in superview coordinates — convert to self's coords for child hit-testing
    NSPoint pointInSelf = [self convertPoint:point fromView:self.superview];
    // Check if the point falls inside the container
    NSPoint containerPoint = [self.containerView convertPoint:pointInSelf fromView:self];
    if (NSPointInRect(containerPoint, self.containerView.bounds)) {
        // hitTest: expects the point in the *superview's* coordinate system,
        // so pass pointInSelf (self is containerView's superview).
        return [self.containerView hitTest:pointInSelf];
    }
    return nil;  // Click is outside the panel slide-in area
}

#pragma mark - Setup

- (void)setupViews {
    [self setWantsLayer:YES];
    self.layer.backgroundColor = [NSColor clearColor].CGColor;

    // Container: the actual panel content
    self.containerView = [[NSView alloc] initWithFrame:NSMakeRect(self.bounds.size.width,
                                                                   0,
                                                                   InterChatPanelWidth,
                                                                   self.bounds.size.height)];
    self.containerView.autoresizingMask = NSViewHeightSizable;
    [self.containerView setWantsLayer:YES];
    self.containerView.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.95].CGColor;
    self.containerView.layer.borderColor = [NSColor colorWithWhite:0.25 alpha:1.0].CGColor;
    self.containerView.layer.borderWidth = 1.0;
    [self addSubview:self.containerView];

    [self setupHeader];
    [self setupRecipientSelector];
    [self setupMessageList];
    [self setupInputArea];
    [self setupUnreadBadge];
}

- (void)setupHeader {
    CGFloat containerW = InterChatPanelWidth;
    CGFloat containerH = self.containerView.bounds.size.height;

    // Header bar
    NSView *headerBar = [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                                  containerH - InterChatHeaderHeight,
                                                                  containerW,
                                                                  InterChatHeaderHeight)];
    headerBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [headerBar setWantsLayer:YES];
    headerBar.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;
    [self.containerView addSubview:headerBar];

    self.headerLabel = [NSTextField labelWithString:@"Chat"];
    self.headerLabel.frame = NSMakeRect(InterChatPadding, 8, 100, 20);
    self.headerLabel.font = [NSFont boldSystemFontOfSize:13];
    self.headerLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    self.headerLabel.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [headerBar addSubview:self.headerLabel];

    self.exportButton = [[NSButton alloc] initWithFrame:NSMakeRect(containerW - 82, 6, 36, 24)];
    self.exportButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.exportButton setImage:[NSImage imageWithSystemSymbolName:@"square.and.arrow.up"
                                         accessibilityDescription:@"Export"]];
    [self.exportButton setImagePosition:NSImageOnly];
    [self.exportButton setBordered:NO];
    self.exportButton.contentTintColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    [self.exportButton setTarget:self];
    [self.exportButton setAction:@selector(exportAction:)];
    self.exportButton.toolTip = @"Export chat transcript";
    [headerBar addSubview:self.exportButton];

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

- (void)setupRecipientSelector {
    CGFloat containerW = InterChatPanelWidth;
    CGFloat containerH = self.containerView.bounds.size.height;
    CGFloat y = containerH - InterChatHeaderHeight - InterChatRecipientHeight - 4;

    self.recipientSelector = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(InterChatPadding, y,
                                                                             containerW - InterChatPadding * 2,
                                                                             InterChatRecipientHeight)
                                                        pullsDown:NO];
    self.recipientSelector.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.recipientSelector addItemWithTitle:@"Everyone"];
    self.recipientSelector.font = [NSFont systemFontOfSize:11];
    [self.recipientSelector setTarget:self];
    [self.recipientSelector setAction:@selector(recipientChanged:)];
    [self.containerView addSubview:self.recipientSelector];
}

- (void)setupMessageList {
    CGFloat containerW = InterChatPanelWidth;
    CGFloat containerH = self.containerView.bounds.size.height;
    CGFloat topOffset = InterChatHeaderHeight + InterChatRecipientHeight + 8;
    CGFloat bottomOffset = InterChatInputHeight + InterChatPadding * 2;
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
    self.tableView.intercellSpacing = NSMakeSize(0, 2);
    self.tableView.rowHeight = InterChatMessageRowMinHeight;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"message"];
    column.width = containerW;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:column];

    self.tableView.dataSource = self;
    self.tableView.delegate = self;

    self.scrollView.documentView = self.tableView;
}

- (void)setupInputArea {
    CGFloat containerW = InterChatPanelWidth;
    CGFloat sendW = 48.0;
    CGFloat inputW = containerW - InterChatPadding * 3 - sendW;

    self.inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(InterChatPadding,
                                                                     InterChatPadding,
                                                                     inputW,
                                                                     InterChatInputHeight)];
    self.inputField.placeholderString = @"Type a message…";
    self.inputField.font = [NSFont systemFontOfSize:12];
    self.inputField.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    self.inputField.backgroundColor = [NSColor colorWithWhite:0.18 alpha:1.0];
    self.inputField.drawsBackground = YES;
    [self.inputField setWantsLayer:YES];
    self.inputField.layer.cornerRadius = 4.0;
    self.inputField.focusRingType = NSFocusRingTypeNone;
    self.inputField.delegate = self;
    self.inputField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.containerView addSubview:self.inputField];

    self.sendButton = [[NSButton alloc] initWithFrame:NSMakeRect(InterChatPadding * 2 + inputW,
                                                                  InterChatPadding,
                                                                  sendW,
                                                                  InterChatInputHeight)];
    [self.sendButton setTitle:@"Send"];
    self.sendButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.sendButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self.sendButton setTarget:self];
    [self.sendButton setAction:@selector(sendAction:)];
    [self.containerView addSubview:self.sendButton];
}

- (void)setupUnreadBadge {
    // Badge sits next to the panel toggle button (positioned by the container)
    self.unreadBadgeView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 22, 22)];
    [self.unreadBadgeView setWantsLayer:YES];
    self.unreadBadgeView.layer.backgroundColor = [NSColor systemRedColor].CGColor;
    self.unreadBadgeView.layer.cornerRadius = 11.0;
    self.unreadBadgeView.hidden = YES;

    self.unreadLabel = [NSTextField labelWithString:@"0"];
    self.unreadLabel.frame = NSMakeRect(0, 2, 22, 16);
    self.unreadLabel.font = [NSFont boldSystemFontOfSize:10];
    self.unreadLabel.textColor = [NSColor whiteColor];
    self.unreadLabel.alignment = NSTextAlignmentCenter;
    [self.unreadBadgeView addSubview:self.unreadLabel];
    [self addSubview:self.unreadBadgeView];
}

#pragma mark - Public API

- (void)appendMessage:(InterChatMessageInfo *)message {
    [self.displayMessages addObject:message];

    [self.tableView beginUpdates];
    NSIndexSet *indexSet = [NSIndexSet indexSetWithIndex:self.displayMessages.count - 1];
    [self.tableView insertRowsAtIndexes:indexSet withAnimation:NSTableViewAnimationEffectNone];
    [self.tableView endUpdates];

    // Auto-scroll to bottom
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView scrollRowToVisible:self.displayMessages.count - 1];
    });
}

- (void)setUnreadBadge:(NSInteger)count {
    if (count <= 0) {
        self.unreadBadgeView.hidden = YES;
        return;
    }

    self.unreadBadgeView.hidden = NO;
    NSString *text = count > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];
    self.unreadLabel.stringValue = text;

    // Resize badge for wide numbers
    CGFloat badgeW = count > 9 ? 28.0 : 22.0;
    NSRect badgeFrame = self.unreadBadgeView.frame;
    badgeFrame.size.width = badgeW;
    self.unreadBadgeView.frame = badgeFrame;
    self.unreadBadgeView.layer.cornerRadius = badgeW / 2.0;
    self.unreadLabel.frame = NSMakeRect(0, 2, badgeW, 16);
}

- (void)setParticipantList:(nullable NSArray<NSDictionary<NSString *, NSString *> *> *)participants {
    // Remove all items except "Everyone"
    while (self.recipientSelector.numberOfItems > 1) {
        [self.recipientSelector removeItemAtIndex:self.recipientSelector.numberOfItems - 1];
    }

    if (!participants || participants.count == 0) {
        return;
    }

    // Add separator
    [self.recipientSelector.menu addItem:[NSMenuItem separatorItem]];

    for (NSDictionary<NSString *, NSString *> *participant in participants) {
        NSString *name = participant[@"name"] ?: @"Unknown";
        NSString *identity = participant[@"identity"] ?: @"";
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:nil keyEquivalent:@""];
        item.representedObject = identity;
        [self.recipientSelector.menu addItem:item];
    }
}

#pragma mark - Panel Toggle

- (void)togglePanel {
    if (self.expanded) {
        [self collapsePanel];
    } else {
        [self expandPanel];
    }
}

- (void)expandPanel {
    if (self.expanded) return;
    self.expanded = YES;
    self.hidden = NO;

    CGFloat targetX = self.bounds.size.width - InterChatPanelWidth;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = InterChatAnimationDuration;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self.containerView.animator.frame = NSMakeRect(targetX, 0,
                                                        InterChatPanelWidth,
                                                        self.bounds.size.height);
    } completionHandler:^{
        [self.inputField becomeFirstResponder];
    }];
}

- (void)collapsePanel {
    if (!self.expanded) return;
    self.expanded = NO;

    CGFloat offscreenX = self.bounds.size.width;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = InterChatAnimationDuration;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self.containerView.animator.frame = NSMakeRect(offscreenX, 0,
                                                        InterChatPanelWidth,
                                                        self.bounds.size.height);
    } completionHandler:nil];
}

#pragma mark - Actions

- (void)sendAction:(id)sender {
#pragma unused(sender)
    NSString *text = self.inputField.stringValue;
    if (text.length == 0) return;

    self.inputField.stringValue = @"";
    [self.delegate chatPanel:self didSubmitMessage:text];
}

- (void)closeAction:(id)sender {
#pragma unused(sender)
    [self collapsePanel];
}

- (void)exportAction:(id)sender {
#pragma unused(sender)
    [self.delegate chatPanelDidRequestExport:self];
}

- (void)recipientChanged:(id)sender {
#pragma unused(sender)
    NSInteger index = self.recipientSelector.indexOfSelectedItem;
    if (index <= 0) {
        // "Everyone" selected
        self.selectedRecipient = nil;
        self.inputField.placeholderString = @"Type a message…";
        [self.delegate chatPanel:self didSelectRecipient:nil];
    } else {
        NSMenuItem *item = [self.recipientSelector selectedItem];
        NSString *identity = item.representedObject;
        self.selectedRecipient = identity;
        self.inputField.placeholderString = [NSString stringWithFormat:@"DM to %@…", item.title];
        [self.delegate chatPanel:self didSelectRecipient:identity];
    }
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    // Check if the user pressed Enter (Return key)
    NSEvent *event = [NSApp currentEvent];
    if (event.type == NSEventTypeKeyDown && event.keyCode == 36) {
        [self sendAction:nil];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(insertNewline:)) {
        [self sendAction:nil];
        return YES;
    }
    return NO;
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
#pragma unused(tableView)
    return (NSInteger)self.displayMessages.count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
#pragma unused(tableColumn)

    static NSString *const kCellIdentifier = @"ChatMessageCell";

    NSTableCellView *cell = [tableView makeViewWithIdentifier:kCellIdentifier owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, InterChatPanelWidth, InterChatMessageRowMinHeight)];
        cell.identifier = kCellIdentifier;

        // Name + time label
        NSTextField *nameLabel = [NSTextField labelWithString:@""];
        nameLabel.tag = 100;
        nameLabel.font = [NSFont boldSystemFontOfSize:10];
        nameLabel.textColor = [NSColor colorWithWhite:0.6 alpha:1.0];
        nameLabel.frame = NSMakeRect(InterChatPadding, 0, InterChatPanelWidth - InterChatPadding * 2, 14);
        nameLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [cell addSubview:nameLabel];

        // Message text label
        NSTextField *textLabel = [NSTextField labelWithString:@""];
        textLabel.tag = 101;
        textLabel.font = [NSFont systemFontOfSize:12];
        textLabel.textColor = [NSColor colorWithWhite:0.9 alpha:1.0];
        textLabel.frame = NSMakeRect(InterChatPadding, 0, InterChatPanelWidth - InterChatPadding * 2, 18);
        textLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
        textLabel.maximumNumberOfLines = 0;
        textLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [cell addSubview:textLabel];
    }

    InterChatMessageInfo *message = self.displayMessages[row];

    NSTextField *nameLabel = [cell viewWithTag:100];
    NSTextField *textLabel = [cell viewWithTag:101];

    // Format header line
    switch (message.messageType) {
        case InterChatMessageTypePublicMessage: {
            NSString *header = [NSString stringWithFormat:@"%@ · %@",
                                message.senderName, message.formattedTime];
            nameLabel.stringValue = header;
            nameLabel.textColor = message.isFromLocalUser
                ? [NSColor systemBlueColor]
                : [NSColor colorWithWhite:0.6 alpha:1.0];
            textLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
            break;
        }
        case InterChatMessageTypeDirectMessage: {
            NSString *dmPrefix = message.isFromLocalUser
                ? [NSString stringWithFormat:@"To %@", message.recipientIdentity]
                : [NSString stringWithFormat:@"DM from %@", message.senderName];
            NSString *header = [NSString stringWithFormat:@"%@ · %@", dmPrefix, message.formattedTime];
            nameLabel.stringValue = header;
            nameLabel.textColor = [NSColor systemPurpleColor];
            textLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
            break;
        }
        case InterChatMessageTypeSystem: {
            nameLabel.stringValue = message.formattedTime;
            nameLabel.textColor = [NSColor colorWithWhite:0.45 alpha:1.0];
            textLabel.textColor = [NSColor colorWithWhite:0.55 alpha:1.0];
            break;
        }
    }

    textLabel.stringValue = message.text;

    // Layout
    CGFloat cellW = tableView.bounds.size.width;
    CGFloat textW = cellW - InterChatPadding * 2;
    nameLabel.frame = NSMakeRect(InterChatPadding, cell.bounds.size.height - 14, textW, 14);
    textLabel.frame = NSMakeRect(InterChatPadding, 2, textW, cell.bounds.size.height - 16);

    return cell;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
#pragma unused(tableView)

    InterChatMessageInfo *message = self.displayMessages[row];
    CGFloat textW = InterChatPanelWidth - InterChatPadding * 2;

    // Estimate text height
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12]};
    NSRect boundingRect = [message.text boundingRectWithSize:NSMakeSize(textW, CGFLOAT_MAX)
                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                  attributes:attrs
                                                     context:nil];
    CGFloat textHeight = ceil(boundingRect.size.height);
    return MAX(InterChatMessageRowMinHeight, textHeight + 20.0); // 14 for header + 6 padding
}

#pragma mark - Layout

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];

    if (self.expanded) {
        CGFloat targetX = self.bounds.size.width - InterChatPanelWidth;
        self.containerView.frame = NSMakeRect(targetX, 0,
                                               InterChatPanelWidth,
                                               self.bounds.size.height);
    } else {
        self.containerView.frame = NSMakeRect(self.bounds.size.width, 0,
                                               InterChatPanelWidth,
                                               self.bounds.size.height);
    }
}

#pragma mark - Phase 9: Moderation

- (void)setChatInputEnabled:(BOOL)enabled {
    self.inputField.enabled = enabled;
    self.sendButton.enabled = enabled;
    if (!enabled) {
        self.inputField.placeholderString = @"Chat is disabled";
    } else if (self.selectedRecipient) {
        NSString *displayName = self.recipientSelector.selectedItem.title ?: self.selectedRecipient;
        self.inputField.placeholderString = [NSString stringWithFormat:@"DM to %@…", displayName];
    } else {
        self.inputField.placeholderString = @"Type a message…";
    }
}

- (void)displaySystemMessage:(NSString *)text {
    InterChatMessageInfo *sysMessage = [[InterChatMessageInfo alloc] initWithSystemText:text];
    [self appendMessage:sysMessage];
}

@end
