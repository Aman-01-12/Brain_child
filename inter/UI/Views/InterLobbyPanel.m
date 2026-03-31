#import "InterLobbyPanel.h"

// ============================================================================
// InterLobbyPanel.m
// inter
//
// Phase 9.3.6 — Host-side lobby management panel.
//
// Shows a list of participants waiting in the lobby with per-participant
// Admit/Deny buttons and a global "Admit All" button.
// ============================================================================

/// Model for a waiting participant.
@interface InterLobbyWaitingEntry : NSObject
@property (nonatomic, copy) NSString *identity;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong) NSDate *joinTime;
@end

@implementation InterLobbyWaitingEntry
@end

// ============================================================================

@interface InterLobbyPanel () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSButton *lobbyToggle;
@property (nonatomic, strong) NSButton *admitAllButton;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSMutableArray<InterLobbyWaitingEntry *> *waitingList;

@end

@implementation InterLobbyPanel

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _waitingList = [NSMutableArray array];
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [[NSColor colorWithWhite:0.12 alpha:0.95] CGColor];
    self.layer.cornerRadius = 12;

    // Title
    _titleLabel = [NSTextField labelWithString:@"Waiting Room"];
    _titleLabel.font = [NSFont boldSystemFontOfSize:16];
    _titleLabel.textColor = [NSColor whiteColor];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_titleLabel];

    // Lobby toggle
    _lobbyToggle = [NSButton checkboxWithTitle:@"  Enable Waiting Room" target:self action:@selector(lobbyToggleClicked:)];
    _lobbyToggle.translatesAutoresizingMaskIntoConstraints = NO;
    _lobbyToggle.contentTintColor = [NSColor whiteColor];
    [self addSubview:_lobbyToggle];

    // Admit All button
    _admitAllButton = [NSButton buttonWithTitle:@"Admit All" target:self action:@selector(admitAllClicked:)];
    _admitAllButton.translatesAutoresizingMaskIntoConstraints = NO;
    _admitAllButton.bezelStyle = NSBezelStyleRounded;
    _admitAllButton.contentTintColor = [NSColor systemGreenColor];
    _admitAllButton.enabled = NO;
    [self addSubview:_admitAllButton];

    // Empty state label
    _emptyLabel = [NSTextField labelWithString:@"No one is waiting"];
    _emptyLabel.font = [NSFont systemFontOfSize:13];
    _emptyLabel.textColor = [NSColor secondaryLabelColor];
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_emptyLabel];

    // Table view
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"lobby"];
    column.width = 260;

    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.headerView = nil;
    _tableView.backgroundColor = [NSColor clearColor];
    _tableView.rowHeight = 50;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    _tableView.intercellSpacing = NSMakeSize(0, 4);
    [_tableView addTableColumn:column];

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.documentView = _tableView;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.drawsBackground = NO;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],

        [_lobbyToggle.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:8],
        [_lobbyToggle.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_lobbyToggle.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],

        [_admitAllButton.topAnchor constraintEqualToAnchor:_lobbyToggle.bottomAnchor constant:8],
        [_admitAllButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],

        [_scrollView.topAnchor constraintEqualToAnchor:_admitAllButton.bottomAnchor constant:8],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:20],
    ]];

    [self updateEmptyState];
}

// MARK: - Public API

- (void)addWaitingParticipant:(NSString *)identity displayName:(NSString *)displayName {
    // Dedup
    for (InterLobbyWaitingEntry *entry in _waitingList) {
        if ([entry.identity isEqualToString:identity]) return;
    }

    InterLobbyWaitingEntry *entry = [[InterLobbyWaitingEntry alloc] init];
    entry.identity = identity;
    entry.displayName = displayName;
    entry.joinTime = [NSDate date];
    [_waitingList addObject:entry];

    [_tableView reloadData];
    [self updateEmptyState];
}

- (void)removeWaitingParticipant:(NSString *)identity {
    NSMutableIndexSet *toRemove = [NSMutableIndexSet indexSet];
    [_waitingList enumerateObjectsUsingBlock:^(InterLobbyWaitingEntry *entry, NSUInteger idx, BOOL *stop) {
        if ([entry.identity isEqualToString:identity]) {
            [toRemove addIndex:idx];
        }
    }];
    [_waitingList removeObjectsAtIndexes:toRemove];
    [_tableView reloadData];
    [self updateEmptyState];
}

- (void)clearWaitingList {
    [_waitingList removeAllObjects];
    [_tableView reloadData];
    [self updateEmptyState];
}

- (NSUInteger)waitingCount {
    return _waitingList.count;
}

- (void)setLobbyEnabled:(BOOL)lobbyEnabled {
    _lobbyEnabled = lobbyEnabled;
    _lobbyToggle.state = lobbyEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

// MARK: - Actions

- (void)lobbyToggleClicked:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    _lobbyEnabled = enabled;
    if ([_delegate respondsToSelector:@selector(lobbyPanel:didToggleLobbyEnabled:)]) {
        [_delegate lobbyPanel:self didToggleLobbyEnabled:enabled];
    }
}

- (void)admitAllClicked:(NSButton *)sender {
    if ([_delegate respondsToSelector:@selector(lobbyPanelDidAdmitAll:)]) {
        [_delegate lobbyPanelDidAdmitAll:self];
    }
}

- (void)admitClicked:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_waitingList.count) return;

    InterLobbyWaitingEntry *entry = _waitingList[row];
    if ([_delegate respondsToSelector:@selector(lobbyPanel:didAdmitParticipant:displayName:)]) {
        [_delegate lobbyPanel:self didAdmitParticipant:entry.identity displayName:entry.displayName];
    }
}

- (void)denyClicked:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_waitingList.count) return;

    InterLobbyWaitingEntry *entry = _waitingList[row];
    if ([_delegate respondsToSelector:@selector(lobbyPanel:didDenyParticipant:)]) {
        [_delegate lobbyPanel:self didDenyParticipant:entry.identity];
    }
}

// MARK: - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_waitingList.count;
}

// MARK: - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *identifier = @"LobbyWaitingCell";
    NSTableCellView *cell = [tableView makeViewWithIdentifier:identifier owner:self];

    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 260, 46)];
        cell.identifier = identifier;
        cell.wantsLayer = YES;
        cell.layer.cornerRadius = 8;
        cell.layer.backgroundColor = [[NSColor colorWithWhite:0.18 alpha:1.0] CGColor];

        // Name label
        NSTextField *nameLabel = [NSTextField labelWithString:@""];
        nameLabel.tag = 100;
        nameLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        nameLabel.textColor = [NSColor whiteColor];
        nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:nameLabel];

        // Time label
        NSTextField *timeLabel = [NSTextField labelWithString:@""];
        timeLabel.tag = 101;
        timeLabel.font = [NSFont systemFontOfSize:11];
        timeLabel.textColor = [NSColor secondaryLabelColor];
        timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:timeLabel];

        // Admit button
        NSButton *admitBtn = [NSButton buttonWithTitle:@"✓" target:self action:@selector(admitClicked:)];
        admitBtn.tag = row;
        admitBtn.bezelStyle = NSBezelStyleRounded;
        admitBtn.contentTintColor = [NSColor systemGreenColor];
        admitBtn.toolTip = @"Admit";
        admitBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [admitBtn setIdentifier:@"admitBtn"];
        [cell addSubview:admitBtn];

        // Deny button
        NSButton *denyBtn = [NSButton buttonWithTitle:@"✕" target:self action:@selector(denyClicked:)];
        denyBtn.tag = row;
        denyBtn.bezelStyle = NSBezelStyleRounded;
        denyBtn.contentTintColor = [NSColor systemRedColor];
        denyBtn.toolTip = @"Deny";
        denyBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [denyBtn setIdentifier:@"denyBtn"];
        [cell addSubview:denyBtn];

        [NSLayoutConstraint activateConstraints:@[
            [nameLabel.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
            [nameLabel.topAnchor constraintEqualToAnchor:cell.topAnchor constant:6],
            [nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:admitBtn.leadingAnchor constant:-8],

            [timeLabel.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
            [timeLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2],

            [denyBtn.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
            [denyBtn.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [denyBtn.widthAnchor constraintEqualToConstant:30],

            [admitBtn.trailingAnchor constraintEqualToAnchor:denyBtn.leadingAnchor constant:-4],
            [admitBtn.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [admitBtn.widthAnchor constraintEqualToConstant:30],
        ]];
    }

    InterLobbyWaitingEntry *entry = _waitingList[row];

    NSTextField *nameLabel = [cell viewWithTag:100];
    nameLabel.stringValue = entry.displayName ?: entry.identity;

    NSTextField *timeLabel = [cell viewWithTag:101];
    NSTimeInterval elapsed = -[entry.joinTime timeIntervalSinceNow];
    if (elapsed < 60) {
        timeLabel.stringValue = @"Just now";
    } else {
        NSInteger minutes = (NSInteger)(elapsed / 60.0);
        timeLabel.stringValue = [NSString stringWithFormat:@"%ld min ago", (long)minutes];
    }

    // Update button tags
    for (NSView *subview in cell.subviews) {
        if ([subview isKindOfClass:[NSButton class]]) {
            ((NSButton *)subview).tag = row;
        }
    }

    return cell;
}

// MARK: - Helpers

- (void)updateEmptyState {
    BOOL empty = (_waitingList.count == 0);
    _emptyLabel.hidden = !empty;
    _scrollView.hidden = empty;
    _admitAllButton.enabled = !empty;

    // Update title badge
    if (_waitingList.count > 0) {
        _titleLabel.stringValue = [NSString stringWithFormat:@"Waiting Room (%lu)", (unsigned long)_waitingList.count];
    } else {
        _titleLabel.stringValue = @"Waiting Room";
    }
}

@end
