// ============================================================================
// InterTeamsPanel.m
// inter
//
// Phase 11.4 — Teams management UI panel implementation.
// ============================================================================

#import "InterTeamsPanel.h"

// ---- Layout constants -------------------------------------------------------
static const CGFloat kPanelWidth        = 640.0;
static const CGFloat kPanelHeight       = 460.0;
static const CGFloat kSidebarWidth      = 220.0;
static const CGFloat kPadding           = 16.0;
static const CGFloat kRowHeight         = 40.0;
static const CGFloat kHeaderHeight      = 32.0;
static const CGFloat kButtonHeight      = 28.0;

// ---- Private category -------------------------------------------------------

@interface InterTeamsPanel () <NSTableViewDelegate, NSTableViewDataSource>

// Sidebar (teams list)
@property (nonatomic, strong) NSScrollView        *teamsScrollView;
@property (nonatomic, strong) NSTableView         *teamsTable;

// Detail area
@property (nonatomic, strong) NSTextField         *detailTitle;
@property (nonatomic, strong) NSTextField         *detailDescription;
@property (nonatomic, strong) NSScrollView        *membersScrollView;
@property (nonatomic, strong) NSTableView         *membersTable;
@property (nonatomic, strong) NSTextField         *inviteField;
@property (nonatomic, strong) NSButton            *inviteButton;
@property (nonatomic, strong) NSButton            *acceptButton;    // pending invite row
@property (nonatomic, strong) NSButton            *deleteTeamButton;

// Create-team area (below sidebar)
@property (nonatomic, strong) NSTextField         *createNameField;
@property (nonatomic, strong) NSTextField         *createDescField;
@property (nonatomic, strong) NSButton            *createButton;

// Toolbar
@property (nonatomic, strong) NSButton            *refreshButton;
@property (nonatomic, strong) NSProgressIndicator *spinner;

// Status bar
@property (nonatomic, strong) NSTextField         *statusLabel;

// Data
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *teams;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *currentMembers;
@property (nonatomic, copy)   NSString            *callerRole;

@end

// ---- Helpers ----------------------------------------------------------------

static NSColor *darkBackground(void) {
    return [NSColor colorWithWhite:0.12 alpha:1.0];
}
static NSColor *secondaryBackground(void) {
    return [NSColor colorWithWhite:0.17 alpha:1.0];
}
static NSColor *separatorColor(void) {
    return [NSColor colorWithWhite:0.25 alpha:1.0];
}
static NSColor *primaryText(void) {
    return [NSColor colorWithWhite:0.95 alpha:1.0];
}
static NSColor *secondaryText(void) {
    return [NSColor colorWithWhite:0.60 alpha:1.0];
}
static NSColor *accentColor(void) {
    return [NSColor colorWithRed:0.25 green:0.55 blue:1.00 alpha:1.0];
}

static NSTextField *makeLabel(NSString *s, CGFloat size, NSColor *color) {
    NSTextField *f = [NSTextField labelWithString:s];
    f.font = [NSFont systemFontOfSize:size];
    f.textColor = color;
    f.cell.wraps = YES;
    return f;
}

static NSButton *makePushButton(NSString *title, CGFloat fontSize) {
    NSButton *b = [[NSButton alloc] init];
    b.title = title;
    b.bezelStyle = NSBezelStyleRounded;
    b.font = [NSFont systemFontOfSize:fontSize];
    b.wantsLayer = YES;
    b.layer.cornerRadius = 4.0;
    return b;
}

static NSTextField *makePlaceholderField(NSString *placeholder, CGFloat size) {
    NSTextField *f = [[NSTextField alloc] init];
    f.placeholderString = placeholder;
    f.font = [NSFont systemFontOfSize:size];
    f.backgroundColor = [NSColor colorWithWhite:0.20 alpha:1.0];
    f.textColor = primaryText();
    f.bezeled = YES;
    f.bezelStyle = NSTextFieldSquareBezel;
    f.editable = YES;
    return f;
}

// ============================================================================
@implementation InterTeamsPanel {
    NSInteger _selectedTeamRow;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect.size.width == 0
                                    ? NSMakeRect(0, 0, kPanelWidth, kPanelHeight)
                                    : frameRect];
    if (!self) return nil;
    _teams = @[];
    _currentMembers = @[];
    _callerRole = @"";
    _selectedTeamRow = -1;
    [self buildUI];
    return self;
}

#pragma mark - UI Construction

- (void)buildUI {
    self.wantsLayer = YES;
    self.layer.backgroundColor = darkBackground().CGColor;

    CGFloat fullW = NSWidth(self.bounds);
    CGFloat fullH = NSHeight(self.bounds);

    // ---- Toolbar row --------------------------------------------------------
    CGFloat toolbarY = fullH - 44.0;

    self.refreshButton = makePushButton(@"↻ Refresh", 12.0);
    self.refreshButton.frame = NSMakeRect(fullW - kPadding - 80.0, toolbarY + 6.0, 80.0, kButtonHeight);
    self.refreshButton.target = self;
    self.refreshButton.action = @selector(handleRefresh:);
    [self addSubview:self.refreshButton];

    NSTextField *titleLabel = makeLabel(@"Teams", 15.0, primaryText());
    titleLabel.frame = NSMakeRect(kPadding, toolbarY + 8.0, 120.0, 20.0);
    titleLabel.font = [NSFont boldSystemFontOfSize:15.0];
    [self addSubview:titleLabel];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(fullW - kPadding - 110.0, toolbarY + 10.0, 16.0, 16.0)];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.hidden = YES;
    [self addSubview:self.spinner];

    // Separator under toolbar
    NSBox *toolSep = [[NSBox alloc] initWithFrame:NSMakeRect(0, toolbarY, fullW, 1.0)];
    toolSep.boxType = NSBoxSeparator;
    [self addSubview:toolSep];

    // ---- Status bar ---------------------------------------------------------
    self.statusLabel = makeLabel(@"", 11.0, secondaryText());
    self.statusLabel.frame = NSMakeRect(kPadding, 6.0, fullW - 2.0 * kPadding, 16.0);
    [self addSubview:self.statusLabel];

    CGFloat statusBarH = 28.0;

    // ---- Content area (between toolbar and status bar) ----------------------
    CGFloat contentY = statusBarH;
    CGFloat contentH = toolbarY - statusBarH;

    // ---- Sidebar (left) - teams list + create form --------------------------
    CGFloat createAreaH = 120.0;
    CGFloat sidebarListH = contentH - createAreaH - 1.0;

    // Teams table scroll view
    self.teamsScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, contentY + createAreaH, kSidebarWidth, sidebarListH)];
    self.teamsScrollView.hasVerticalScroller = YES;
    self.teamsScrollView.autohidesScrollers = YES;
    self.teamsScrollView.borderType = NSNoBorder;
    self.teamsScrollView.backgroundColor = secondaryBackground();
    self.teamsScrollView.wantsLayer = YES;
    [self addSubview:self.teamsScrollView];

    self.teamsTable = [[NSTableView alloc] init];
    self.teamsTable.backgroundColor = secondaryBackground();
    self.teamsTable.headerView = nil;
    self.teamsTable.rowHeight = kRowHeight;
    self.teamsTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.teamsTable.intercellSpacing = NSMakeSize(0, 0);

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"team"];
    col.width = kSidebarWidth;
    [self.teamsTable addTableColumn:col];
    self.teamsTable.delegate = self;
    self.teamsTable.dataSource = self;
    self.teamsTable.target = self;
    self.teamsTable.action = @selector(handleTeamSelection:);

    self.teamsScrollView.documentView = self.teamsTable;

    // Separator between sidebar and detail
    NSBox *sideSep = [[NSBox alloc] initWithFrame:NSMakeRect(kSidebarWidth, contentY, 1.0, contentH)];
    sideSep.boxType = NSBoxSeparator;
    [self addSubview:sideSep];

    // ---- Create-team form (bottom of sidebar) --------------------------------
    CGFloat createY = contentY;
    NSBox *createTopSep = [[NSBox alloc] initWithFrame:NSMakeRect(0, createY + createAreaH - 1.0, kSidebarWidth, 1.0)];
    createTopSep.boxType = NSBoxSeparator;
    [self addSubview:createTopSep];

    NSTextField *createHeader = makeLabel(@"New Team", 11.0, secondaryText());
    createHeader.frame = NSMakeRect(kPadding, createY + createAreaH - kHeaderHeight + 4.0, kSidebarWidth - 2.0 * kPadding, 16.0);
    createHeader.font = [NSFont boldSystemFontOfSize:11.0];
    [self addSubview:createHeader];

    self.createNameField = makePlaceholderField(@"Team name", 12.0);
    self.createNameField.frame = NSMakeRect(kPadding, createY + 58.0, kSidebarWidth - 2.0 * kPadding, 22.0);
    [self addSubview:self.createNameField];

    self.createDescField = makePlaceholderField(@"Description (optional)", 11.0);
    self.createDescField.frame = NSMakeRect(kPadding, createY + 32.0, kSidebarWidth - 2.0 * kPadding, 22.0);
    [self addSubview:self.createDescField];

    self.createButton = makePushButton(@"Create", 12.0);
    self.createButton.frame = NSMakeRect(kSidebarWidth - kPadding - 70.0, createY + 6.0, 70.0, kButtonHeight);
    self.createButton.target = self;
    self.createButton.action = @selector(handleCreate:);
    [self addSubview:self.createButton];

    // ---- Detail area (right) ------------------------------------------------
    CGFloat detailX = kSidebarWidth + 1.0;
    CGFloat detailW = fullW - detailX;
    CGFloat detailInnerW = detailW - 2.0 * kPadding;

    // Team name heading
    self.detailTitle = makeLabel(@"Select a team", 16.0, primaryText());
    self.detailTitle.frame = NSMakeRect(detailX + kPadding, contentY + contentH - 40.0, detailInnerW - 100.0, 28.0);
    self.detailTitle.font = [NSFont boldSystemFontOfSize:16.0];
    [self addSubview:self.detailTitle];

    // Delete team button (owner only)
    self.deleteTeamButton = makePushButton(@"Delete Team", 11.0);
    self.deleteTeamButton.frame = NSMakeRect(detailX + detailW - kPadding - 90.0, contentY + contentH - 36.0, 90.0, kButtonHeight);
    self.deleteTeamButton.target = self;
    self.deleteTeamButton.action = @selector(handleDeleteTeam:);
    self.deleteTeamButton.hidden = YES;
    [self addSubview:self.deleteTeamButton];

    // Description
    self.detailDescription = makeLabel(@"", 12.0, secondaryText());
    self.detailDescription.frame = NSMakeRect(detailX + kPadding, contentY + contentH - 60.0, detailInnerW, 16.0);
    [self addSubview:self.detailDescription];

    // Members header
    NSTextField *membersHeader = makeLabel(@"Members", 11.0, secondaryText());
    membersHeader.frame = NSMakeRect(detailX + kPadding, contentY + contentH - 78.0, 80.0, 14.0);
    membersHeader.font = [NSFont boldSystemFontOfSize:11.0];
    [self addSubview:membersHeader];

    // Accept invitation button (visible when caller's status = pending)
    self.acceptButton = makePushButton(@"Accept Invitation", 12.0);
    self.acceptButton.frame = NSMakeRect(detailX + kPadding, contentY + contentH - 78.0, 130.0, kButtonHeight);
    self.acceptButton.target = self;
    self.acceptButton.action = @selector(handleAcceptInvitation:);
    self.acceptButton.hidden = YES;
    [self addSubview:self.acceptButton];

    // Members table
    CGFloat inviteAreaH = 36.0;
    CGFloat membersTableH = contentH - 92.0 - inviteAreaH;
    self.membersScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(detailX, contentY + inviteAreaH, detailW, membersTableH)];
    self.membersScrollView.hasVerticalScroller = YES;
    self.membersScrollView.autohidesScrollers = YES;
    self.membersScrollView.borderType = NSNoBorder;
    self.membersScrollView.backgroundColor = darkBackground();
    [self addSubview:self.membersScrollView];

    self.membersTable = [[NSTableView alloc] init];
    self.membersTable.backgroundColor = darkBackground();
    self.membersTable.headerView = nil;
    self.membersTable.rowHeight = 34.0;
    self.membersTable.intercellSpacing = NSMakeSize(0, 0);

    NSTableColumn *mc = [[NSTableColumn alloc] initWithIdentifier:@"member"];
    mc.width = detailW;
    [self.membersTable addTableColumn:mc];
    self.membersTable.delegate = self;
    self.membersTable.dataSource = self;
    self.membersScrollView.documentView = self.membersTable;

    // Invite row (at bottom of detail area)
    self.inviteField = makePlaceholderField(@"Invite by email (comma-separated)", 12.0);
    self.inviteField.frame = NSMakeRect(detailX + kPadding, contentY + 6.0, detailInnerW - 80.0, 22.0);
    [self addSubview:self.inviteField];

    self.inviteButton = makePushButton(@"Invite", 12.0);
    self.inviteButton.frame = NSMakeRect(detailX + detailW - kPadding - 70.0, contentY + 6.0, 70.0, kButtonHeight);
    self.inviteButton.target = self;
    self.inviteButton.action = @selector(handleInvite:);
    [self addSubview:self.inviteButton];

    [self refreshDetailVisibility];
}

#pragma mark - Public API

- (void)setTeams:(NSArray<NSDictionary<NSString *,id> *> *)teams {
    NSArray *snapshot = teams ?: @[];
    dispatch_async(dispatch_get_main_queue(), ^{
        _teams = snapshot;
        _selectedTeamRow = -1;
        _currentMembers = @[];
        _callerRole = @"";
        [self.teamsTable reloadData];
        [self refreshDetailVisibility];
    });
}

- (void)setCurrentTeamMembers:(NSArray<NSDictionary<NSString *,id> *> *)members
                   callerRole:(NSString *)callerRole {
    NSArray *membersSnapshot = members ?: @[];
    NSString *roleSnapshot = callerRole ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        _currentMembers = membersSnapshot;
        _callerRole = roleSnapshot;
        [self.membersTable reloadData];
        [self refreshDetailVisibility];
    });
}

- (void)setStatusText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = text ?: @"";
    });
}

- (void)setLoading:(BOOL)loading {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (loading) {
            [self.spinner startAnimation:nil];
            self.spinner.hidden = NO;
        } else {
            [self.spinner stopAnimation:nil];
            self.spinner.hidden = YES;
        }
    });
}

#pragma mark - Detail Visibility

- (void)refreshDetailVisibility {
    BOOL hasTeam = (_selectedTeamRow >= 0 && _selectedTeamRow < (NSInteger)_teams.count);
    NSDictionary *team = hasTeam ? _teams[(NSUInteger)_selectedTeamRow] : nil;

    if (hasTeam) {
        self.detailTitle.stringValue = team[@"name"] ?: @"";
        self.detailDescription.stringValue = team[@"description"] ?: @"";
    } else {
        self.detailTitle.stringValue = @"Select a team";
        self.detailDescription.stringValue = @"";
    }

    NSString *role = team[@"role"] ?: @"";
    NSString *status = team[@"status"] ?: @"";
    BOOL isPending = [status isEqualToString:@"pending"];
    BOOL isOwner   = [role isEqualToString:@"owner"];

    self.acceptButton.hidden     = !isPending;
    self.inviteField.hidden      = isPending || !hasTeam;
    self.inviteButton.hidden     = isPending || !hasTeam;
    self.deleteTeamButton.hidden = !isOwner;
}

#pragma mark - NSTableViewDataSource – teams

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.teamsTable) return (NSInteger)_teams.count;
    if (tableView == self.membersTable) return (NSInteger)_currentMembers.count;
    return 0;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    if (tableView == self.teamsTable) {
        return [self teamCellForRow:row];
    }
    if (tableView == self.membersTable) {
        return [self memberCellForRow:row];
    }
    return nil;
}

- (NSView *)teamCellForRow:(NSInteger)row {
    NSDictionary *team = _teams[(NSUInteger)row];
    NSString *name = team[@"name"] ?: @"";
    NSString *role = team[@"role"] ?: @"";
    NSString *status = team[@"status"] ?: @"";

    NSView *cell = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSidebarWidth, kRowHeight)];
    cell.wantsLayer = YES;

    NSTextField *nameLabel = makeLabel(name, 13.0, primaryText());
    nameLabel.frame = NSMakeRect(kPadding, 14.0, kSidebarWidth - 2.0 * kPadding, 16.0);
    [cell addSubview:nameLabel];

    NSString *badge = @"";
    if ([status isEqualToString:@"pending"]) badge = @"Invited";
    else if ([role isEqualToString:@"owner"]) badge = @"Owner";
    else if ([role isEqualToString:@"admin"]) badge = @"Admin";
    if (badge.length > 0) {
        NSTextField *badgeLabel = makeLabel(badge, 10.0, [status isEqualToString:@"pending"] ? accentColor() : secondaryText());
        badgeLabel.frame = NSMakeRect(kPadding, 2.0, kSidebarWidth - 2.0 * kPadding, 12.0);
        [cell addSubview:badgeLabel];
    }
    return cell;
}

- (NSView *)memberCellForRow:(NSInteger)row {
    NSDictionary *member = _currentMembers[(NSUInteger)row];
    NSString *displayName = member[@"displayName"] ?: member[@"email"] ?: @"";
    NSString *email = member[@"email"] ?: @"";
    NSString *role = member[@"role"] ?: @"";
    NSString *status = member[@"status"] ?: @"";

    CGFloat detailW = NSWidth(self.bounds) - kSidebarWidth - 1.0;
    NSView *cell = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, detailW, 34.0)];

    NSTextField *nameLabel = makeLabel(displayName, 12.0, primaryText());
    nameLabel.frame = NSMakeRect(kPadding, 12.0, detailW * 0.4, 16.0);
    [cell addSubview:nameLabel];

    NSTextField *emailLabel = makeLabel(email, 11.0, secondaryText());
    emailLabel.frame = NSMakeRect(kPadding, 1.0, detailW * 0.4, 12.0);
    [cell addSubview:emailLabel];

    NSString *roleText = [NSString stringWithFormat:@"%@ · %@", role, status];
    NSTextField *roleLabel = makeLabel(roleText, 11.0, secondaryText());
    roleLabel.frame = NSMakeRect(detailW * 0.45, 10.0, detailW * 0.3, 14.0);
    [cell addSubview:roleLabel];

    // Remove button (for owner/admin callers on non-owner members)
    BOOL callerCanRemove = ([_callerRole isEqualToString:@"owner"] || [_callerRole isEqualToString:@"admin"]);
    BOOL isOwnerMember   = [role isEqualToString:@"owner"];
    if (callerCanRemove && !isOwnerMember) {
        NSButton *removeBtn = makePushButton(@"Remove", 11.0);
        removeBtn.frame = NSMakeRect(detailW - kPadding - 60.0, 4.0, 60.0, 24.0);
        removeBtn.tag = row;
        removeBtn.target = self;
        removeBtn.action = @selector(handleRemoveMember:);
        [cell addSubview:removeBtn];
    }

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object != self.teamsTable) return;
    _selectedTeamRow = self.teamsTable.selectedRow;
    _currentMembers = @[];
    _callerRole = @"";
    [self.membersTable reloadData];
    [self refreshDetailVisibility];

    // Ask the delegate for data on the newly selected team
    if (_selectedTeamRow >= 0 && _selectedTeamRow < (NSInteger)_teams.count) {
        [self.delegate teamsPanelDidRequestRefresh:self];
    }
}

#pragma mark - Actions

- (void)handleTeamSelection:(id)sender {
#pragma unused(sender)
    // Selection changes handled by tableViewSelectionDidChange:
}

- (void)handleRefresh:(id)sender {
#pragma unused(sender)
    [self.delegate teamsPanelDidRequestRefresh:self];
}

- (void)handleCreate:(id)sender {
#pragma unused(sender)
    NSString *name = self.createNameField.stringValue;
    NSString *desc = self.createDescField.stringValue;
    if (name.length == 0) {
        [self setStatusText:@"Team name is required."];
        return;
    }
    self.createButton.enabled = NO;
    [self.delegate teamsPanel:self
         didRequestCreateTeamName:name
                       description:desc.length > 0 ? desc : nil];
    self.createNameField.stringValue = @"";
    self.createDescField.stringValue = @"";
}

- (void)handleInvite:(id)sender {
#pragma unused(sender)
    if (_selectedTeamRow < 0 || _selectedTeamRow >= (NSInteger)_teams.count) return;
    NSString *raw = self.inviteField.stringValue;
    if (raw.length == 0) {
        [self setStatusText:@"Enter at least one email address."];
        return;
    }

    NSArray<NSString *> *emails = [[raw componentsSeparatedByString:@","]
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *e, NSDictionary *b) {
            return [e stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length > 0;
        }]];
    NSMutableArray<NSString *> *trimmed = [NSMutableArray arrayWithCapacity:emails.count];
    for (NSString *e in emails) {
        [trimmed addObject:[e stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
    }

    if (trimmed.count == 0) {
        [self setStatusText:@"No valid emails found."];
        return;
    }

    NSString *teamId = _teams[(NSUInteger)_selectedTeamRow][@"id"] ?: @"";
    self.inviteButton.enabled = NO;
    [self.delegate teamsPanel:self didRequestInviteEmails:trimmed toTeamId:teamId];
    self.inviteField.stringValue = @"";
}

- (void)handleAcceptInvitation:(id)sender {
#pragma unused(sender)
    if (_selectedTeamRow < 0 || _selectedTeamRow >= (NSInteger)_teams.count) return;
    NSString *teamId = _teams[(NSUInteger)_selectedTeamRow][@"id"] ?: @"";
    self.acceptButton.enabled = NO;
    [self.delegate teamsPanel:self didRequestAcceptInvitationForTeamId:teamId];
}

- (void)handleRemoveMember:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_currentMembers.count) return;
    if (_selectedTeamRow < 0 || _selectedTeamRow >= (NSInteger)_teams.count) return;

    NSString *memberId = _currentMembers[(NSUInteger)row][@"id"] ?: @"";
    NSString *teamId   = _teams[(NSUInteger)_selectedTeamRow][@"id"] ?: @"";
    sender.enabled = NO;
    [self.delegate teamsPanel:self didRequestRemoveMemberId:memberId fromTeamId:teamId];
}

- (void)handleDeleteTeam:(id)sender {
#pragma unused(sender)
    if (_selectedTeamRow < 0 || _selectedTeamRow >= (NSInteger)_teams.count) return;
    NSString *teamId = _teams[(NSUInteger)_selectedTeamRow][@"id"] ?: @"";
    NSString *name   = _teams[(NSUInteger)_selectedTeamRow][@"name"] ?: @"this team";

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Delete \"%@\"?", name];
    alert.informativeText = @"This will permanently delete the team and remove all members. This cannot be undone.";
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;

    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertFirstButtonReturn) {
        self.deleteTeamButton.enabled = NO;
        [self.delegate teamsPanel:self didRequestDeleteTeamId:teamId];
    }
}

#pragma mark - Re-enable buttons (called by AppDelegate after network ops)

- (void)resetCreateButton  { self.createButton.enabled  = YES; }
- (void)resetInviteButton  { self.inviteButton.enabled  = YES; }
- (void)resetAcceptButton  { self.acceptButton.enabled  = YES; }
- (void)resetDeleteButton  { self.deleteTeamButton.enabled = YES; }

#pragma mark - Selected team ID

/// Returns the `id` string of the currently selected team, or nil.
- (nullable NSString *)selectedTeamId {
    if (_selectedTeamRow < 0 || _selectedTeamRow >= (NSInteger)_teams.count) return nil;
    return _teams[(NSUInteger)_selectedTeamRow][@"id"];
}

@end
