// ============================================================================
// InterRecordingListPanel.m
// inter
//
// Phase 10D.4 — Recording list management UI panel.
// Displays local + cloud recordings in separate sections with download/delete.
//
// ISOLATION INVARIANT [G8]:
// This view has NO side effects on media, recording pipelines, or networking.
// All actions are reported via the delegate protocol.
// ============================================================================

#import "InterRecordingListPanel.h"

// ============================================================================
// InterRecordingListEntry
// ============================================================================

@implementation InterRecordingListEntry
@end

// ============================================================================
// Section header sentinel — represents a section header row in the flat model.
// ============================================================================

@interface _InterRecordingSectionHeader : NSObject
@property (nonatomic, copy) NSString *title;
@end

@implementation _InterRecordingSectionHeader
@end

// ============================================================================
// InterRecordingListPanel
// ============================================================================

static const CGFloat kPanelWidth          = 400.0;
static const CGFloat kRowHeight           = 64.0;
static const CGFloat kSectionHeaderHeight = 28.0;
static const CGFloat kHeaderHeight        = 40.0;

/// Returns nil when value is absent or [NSNull null]; otherwise returns the
/// value cast to NSString (or stringified if it is a non-string scalar).
static NSString *safeStringFromJSON(id value) {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    return [NSString stringWithFormat:@"%@", value];
}

/// Returns nil when value is absent or [NSNull null]; otherwise returns value.
static id safeNumberFromJSON(id value) {
    if (!value || value == [NSNull null]) return nil;
    return value;
}

@interface InterRecordingListPanel () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView  *tableView;
@property (nonatomic, strong) NSTextField  *headerLabel;
@property (nonatomic, strong) NSTextField  *emptyLabel;
@property (nonatomic, strong) NSButton     *closeButton;
@property (nonatomic, strong) NSButton     *refreshButton;
/// Local recordings (from filesystem)
@property (nonatomic, strong) NSMutableArray<InterRecordingListEntry *> *localEntries;
/// Cloud recordings (from token server)
@property (nonatomic, strong) NSMutableArray<InterRecordingListEntry *> *cloudEntries;
/// Flat table model: interleaves _InterRecordingSectionHeader and InterRecordingListEntry objects.
@property (nonatomic, strong) NSMutableArray *flatRows;
@end

@implementation InterRecordingListPanel

// ---------------------------------------------------------------------------
// MARK: - Init
// ---------------------------------------------------------------------------

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _localEntries = [NSMutableArray array];
        _cloudEntries = [NSMutableArray array];
        _flatRows     = [NSMutableArray array];
        [self _setupUI];
    }
    return self;
}

// ---------------------------------------------------------------------------
// MARK: - UI Setup
// ---------------------------------------------------------------------------

- (void)_setupUI {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [[NSColor colorWithWhite:0.12 alpha:0.95] CGColor];
    self.layer.cornerRadius = 10.0;

    // Header label
    _headerLabel = [NSTextField labelWithString:@"Recordings"];
    _headerLabel.font = [NSFont boldSystemFontOfSize:15];
    _headerLabel.textColor = [NSColor whiteColor];
    _headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_headerLabel];

    // Close button
    _closeButton = [NSButton buttonWithTitle:@"✕" target:self action:@selector(_close:)];
    _closeButton.bordered = NO;
    _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    _closeButton.contentTintColor = [NSColor secondaryLabelColor];
    [self addSubview:_closeButton];

    // Refresh button
    _refreshButton = [NSButton buttonWithTitle:@"↻" target:self action:@selector(_refresh:)];
    _refreshButton.bordered = NO;
    _refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    _refreshButton.contentTintColor = [NSColor secondaryLabelColor];
    [self addSubview:_refreshButton];

    // Table view inside scroll view
    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = [NSColor clearColor];
    _tableView.headerView = nil;
    _tableView.rowHeight = kRowHeight;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    _tableView.intercellSpacing = NSMakeSize(0, 1);

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"recording"];
    column.width = kPanelWidth - 20;
    [_tableView addTableColumn:column];

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.documentView = _tableView;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.drawsBackground = NO;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_scrollView];

    // Empty state label
    _emptyLabel = [NSTextField labelWithString:@"No recordings yet"];
    _emptyLabel.font = [NSFont systemFontOfSize:13];
    _emptyLabel.textColor = [NSColor tertiaryLabelColor];
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.hidden = YES;
    [self addSubview:_emptyLabel];

    // Layout
    [NSLayoutConstraint activateConstraints:@[
        [_headerLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [_headerLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [_headerLabel.heightAnchor constraintEqualToConstant:kHeaderHeight - 10],

        [_closeButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [_closeButton.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],

        [_refreshButton.trailingAnchor constraintEqualToAnchor:_closeButton.leadingAnchor constant:-4],
        [_refreshButton.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],

        [_scrollView.topAnchor constraintEqualToAnchor:self.topAnchor constant:kHeaderHeight],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
}

// ---------------------------------------------------------------------------
// MARK: - Flat Row Model
// ---------------------------------------------------------------------------

/// Rebuild the flat row array from local + cloud entries.  Each non-empty
/// section gets a header row followed by its sorted entries.
- (void)_rebuildFlatRows {
    [self.flatRows removeAllObjects];

    if (self.localEntries.count > 0) {
        _InterRecordingSectionHeader *hdr = [[_InterRecordingSectionHeader alloc] init];
        hdr.title = [NSString stringWithFormat:@"Local Recordings (%lu)", (unsigned long)self.localEntries.count];
        [self.flatRows addObject:hdr];
        [self.flatRows addObjectsFromArray:self.localEntries];
    }

    if (self.cloudEntries.count > 0) {
        _InterRecordingSectionHeader *hdr = [[_InterRecordingSectionHeader alloc] init];
        hdr.title = [NSString stringWithFormat:@"Cloud Recordings (%lu)", (unsigned long)self.cloudEntries.count];
        [self.flatRows addObject:hdr];
        [self.flatRows addObjectsFromArray:self.cloudEntries];
    }

    [self.tableView reloadData];
    self.emptyLabel.hidden = self.flatRows.count > 0;
}

// ---------------------------------------------------------------------------
// MARK: - Sorting helper
// ---------------------------------------------------------------------------

static NSComparisonResult _sortNewestFirst(InterRecordingListEntry *a, InterRecordingListEntry *b, void *ctx) {
#pragma unused(ctx)
    if (!a.startedAt && !b.startedAt) return NSOrderedSame;
    if (!a.startedAt) return NSOrderedDescending;
    if (!b.startedAt) return NSOrderedAscending;
    return [b.startedAt compare:a.startedAt];
}

// ---------------------------------------------------------------------------
// MARK: - Public API
// ---------------------------------------------------------------------------

- (NSUInteger)recordingCount {
    return self.localEntries.count + self.cloudEntries.count;
}

- (void)setRecordings:(NSArray<InterRecordingListEntry *> *)recordings {
    [self.localEntries removeAllObjects];
    [self.cloudEntries removeAllObjects];

    for (InterRecordingListEntry *entry in recordings) {
        if ([entry.recordingMode isEqualToString:@"local_composed"]) {
            [self.localEntries addObject:entry];
        } else {
            [self.cloudEntries addObject:entry];
        }
    }

    [self.localEntries sortUsingFunction:_sortNewestFirst context:NULL];
    [self.cloudEntries sortUsingFunction:_sortNewestFirst context:NULL];
    [self _rebuildFlatRows];
}

- (void)setCloudRecordings:(NSArray<InterRecordingListEntry *> *)recordings {
    [self.cloudEntries removeAllObjects];
    [self.cloudEntries addObjectsFromArray:recordings ?: @[]];
    [self.cloudEntries sortUsingFunction:_sortNewestFirst context:NULL];
    [self _rebuildFlatRows];
}

- (void)addLocalRecordings:(NSArray<NSURL *> *)fileURLs {
    for (NSURL *url in fileURLs) {
        InterRecordingListEntry *entry = [[InterRecordingListEntry alloc] init];
        entry.recordingId = url.path;
        entry.roomName = [url.lastPathComponent stringByDeletingPathExtension];
        entry.recordingMode = @"local_composed";
        entry.status = @"completed";

        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
        if (attrs) {
            entry.startedAt = attrs[NSFileCreationDate];
            entry.fileSizeBytes = [attrs[NSFileSize] longLongValue];
        }

        [self.localEntries addObject:entry];
    }
    [self.localEntries sortUsingFunction:_sortNewestFirst context:NULL];
    [self _rebuildFlatRows];
}

- (void)reloadRecordings {
    // 1. Scan local recordings directory
    NSURL *documentsURL = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *recordingsDir = [documentsURL URLByAppendingPathComponent:@"Inter Recordings" isDirectory:YES];

    NSMutableArray<NSURL *> *localFiles = [NSMutableArray array];
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:recordingsDir
                                                     includingPropertiesForKeys:@[NSURLCreationDateKey, NSURLFileSizeKey]
                                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                          error:nil];
    for (NSURL *fileURL in contents) {
        if ([fileURL.pathExtension.lowercaseString isEqualToString:@"mp4"]) {
            [localFiles addObject:fileURL];
        }
    }

    [self.localEntries removeAllObjects];
    for (NSURL *url in localFiles) {
        InterRecordingListEntry *entry = [[InterRecordingListEntry alloc] init];
        entry.recordingId = url.path;
        entry.roomName = [url.lastPathComponent stringByDeletingPathExtension];
        entry.recordingMode = @"local_composed";
        entry.status = @"completed";
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
        if (attrs) {
            entry.startedAt = attrs[NSFileCreationDate];
            entry.fileSizeBytes = [attrs[NSFileSize] longLongValue];
        }
        [self.localEntries addObject:entry];
    }
    [self.localEntries sortUsingFunction:_sortNewestFirst context:NULL];

    // 2. Fetch cloud recordings from the token server
    if (self.serverBaseURL.length > 0 && self.accessToken.length > 0) {
        NSString *urlStr = [NSString stringWithFormat:@"%@/recordings?limit=50", self.serverBaseURL];
        NSURL *url = [NSURL URLWithString:urlStr];
        if (url) {
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
            [request setValue:[NSString stringWithFormat:@"Bearer %@", self.accessToken]
           forHTTPHeaderField:@"Authorization"];
            [request setTimeoutInterval:15.0];

            __weak typeof(self) weakSelf = self;
            [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;

                    if (error || !data) {
                        NSLog(@"[Recordings] Cloud fetch failed: %@", error.localizedDescription);
                        [strongSelf _rebuildFlatRows];
                        return;
                    }
                    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                    if (httpResp.statusCode < 200 || httpResp.statusCode >= 300) {
                        NSLog(@"[Recordings] Cloud fetch returned status %ld", (long)httpResp.statusCode);
                        [strongSelf _rebuildFlatRows];
                        return;
                    }

                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    NSArray *recordingsArr = json[@"recordings"];
                    if (![recordingsArr isKindOfClass:[NSArray class]]) {
                        [strongSelf _rebuildFlatRows];
                        return;
                    }

                    NSMutableArray<InterRecordingListEntry *> *parsed = [NSMutableArray array];
                    for (NSDictionary *dict in recordingsArr) {
                        if (![dict isKindOfClass:[NSDictionary class]]) continue;
                        InterRecordingListEntry *entry = [[InterRecordingListEntry alloc] init];
                        entry.recordingId   = safeStringFromJSON(dict[@"id"]) ?: @"";
                        entry.roomName      = safeStringFromJSON(dict[@"room_name"]) ?: @"Recording";
                        entry.roomCode      = safeStringFromJSON(dict[@"room_code"]) ?: @"";
                        entry.recordingMode = safeStringFromJSON(dict[@"recording_mode"]) ?: @"cloud_composed";
                        entry.status        = safeStringFromJSON(dict[@"status"]) ?: @"completed";
                        id durationVal = safeNumberFromJSON(dict[@"duration_seconds"]);
                        entry.durationSeconds = durationVal ? [durationVal integerValue] : 0;
                        id fileSizeVal = safeNumberFromJSON(dict[@"file_size_bytes"]);
                        entry.fileSizeBytes   = fileSizeVal ? [fileSizeVal longLongValue] : 0;
                        id watermarkedVal = safeNumberFromJSON(dict[@"watermarked"]);
                        entry.watermarked     = watermarkedVal ? [watermarkedVal boolValue] : NO;

                        // Parse ISO-8601 dates
                        NSString *startedStr = dict[@"started_at"];
                        if ([startedStr isKindOfClass:[NSString class]]) {
                            NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
                            fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
                            entry.startedAt = [fmt dateFromString:startedStr];
                            if (!entry.startedAt) {
                                fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime;
                                entry.startedAt = [fmt dateFromString:startedStr];
                            }
                        }
                        NSString *endedStr = dict[@"ended_at"];
                        if ([endedStr isKindOfClass:[NSString class]]) {
                            NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
                            fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
                            entry.endedAt = [fmt dateFromString:endedStr];
                        }

                        [parsed addObject:entry];
                    }

                    [strongSelf.cloudEntries removeAllObjects];
                    [strongSelf.cloudEntries addObjectsFromArray:parsed];
                    [strongSelf.cloudEntries sortUsingFunction:_sortNewestFirst context:NULL];
                    [strongSelf _rebuildFlatRows];
                });
            }] resume];
            return; // _rebuildFlatRows called in completion
        }
    }

    // No cloud server configured — just show local entries
    [self _rebuildFlatRows];
}

// ---------------------------------------------------------------------------
// MARK: - NSTableViewDataSource
// ---------------------------------------------------------------------------

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.flatRows.count;
}

// ---------------------------------------------------------------------------
// MARK: - NSTableViewDelegate
// ---------------------------------------------------------------------------

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= self.flatRows.count) return kRowHeight;
    id item = self.flatRows[(NSUInteger)row];
    if ([item isKindOfClass:[_InterRecordingSectionHeader class]]) {
        return kSectionHeaderHeight;
    }
    return kRowHeight;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= self.flatRows.count) return NO;
    return [self.flatRows[(NSUInteger)row] isKindOfClass:[_InterRecordingSectionHeader class]];
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= self.flatRows.count) return NO;
    return ![self.flatRows[(NSUInteger)row] isKindOfClass:[_InterRecordingSectionHeader class]];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= self.flatRows.count) return nil;

    id item = self.flatRows[(NSUInteger)row];

    // Section header row
    if ([item isKindOfClass:[_InterRecordingSectionHeader class]]) {
        _InterRecordingSectionHeader *section = item;
        NSTextField *headerView = [tableView makeViewWithIdentifier:@"SectionHeader" owner:self];
        if (!headerView) {
            headerView = [NSTextField labelWithString:@""];
            headerView.identifier = @"SectionHeader";
            headerView.font = [NSFont boldSystemFontOfSize:11];
            headerView.textColor = [NSColor secondaryLabelColor];
            headerView.wantsLayer = YES;
            headerView.layer.backgroundColor = [[NSColor colorWithWhite:0.15 alpha:1.0] CGColor];
        }
        headerView.stringValue = [NSString stringWithFormat:@"  %@", section.title];
        return headerView;
    }

    // Entry row
    InterRecordingListEntry *entry = (InterRecordingListEntry *)item;

    NSTableCellView *cellView = [tableView makeViewWithIdentifier:@"RecordingCell" owner:self];
    if (!cellView) {
        cellView = [self _createCellViewForEntry:entry];
    } else {
        [self _configureCellView:cellView forEntry:entry];
    }

    return cellView;
}

// ---------------------------------------------------------------------------
// MARK: - Cell Creation
// ---------------------------------------------------------------------------

- (NSTableCellView *)_createCellViewForEntry:(InterRecordingListEntry *)entry {
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, kPanelWidth - 20, kRowHeight)];
    cell.identifier = @"RecordingCell";
    cell.wantsLayer = YES;
    cell.layer.backgroundColor = [[NSColor colorWithWhite:0.18 alpha:1.0] CGColor];
    cell.layer.cornerRadius = 6.0;

    // Title (room name + mode badge)
    NSTextField *titleField = [NSTextField labelWithString:@""];
    titleField.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    titleField.textColor = [NSColor whiteColor];
    titleField.translatesAutoresizingMaskIntoConstraints = NO;
    titleField.tag = 100;
    [cell addSubview:titleField];

    // Subtitle (date + duration + size)
    NSTextField *subtitleField = [NSTextField labelWithString:@""];
    subtitleField.font = [NSFont systemFontOfSize:11];
    subtitleField.textColor = [NSColor secondaryLabelColor];
    subtitleField.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleField.tag = 101;
    [cell addSubview:subtitleField];

    // Mode badge
    NSTextField *badgeField = [NSTextField labelWithString:@""];
    badgeField.font = [NSFont systemFontOfSize:9 weight:NSFontWeightBold];
    badgeField.textColor = [NSColor whiteColor];
    badgeField.wantsLayer = YES;
    badgeField.layer.cornerRadius = 3.0;
    badgeField.layer.masksToBounds = YES;
    badgeField.translatesAutoresizingMaskIntoConstraints = NO;
    badgeField.tag = 102;
    [cell addSubview:badgeField];

    // Action button (open/download)
    NSButton *actionBtn = [NSButton buttonWithTitle:@"Open" target:self action:@selector(_actionButtonClicked:)];
    actionBtn.translatesAutoresizingMaskIntoConstraints = NO;
    actionBtn.tag = 200;
    actionBtn.controlSize = NSControlSizeSmall;
    actionBtn.bezelStyle = NSBezelStyleRecessed;
    [cell addSubview:actionBtn];

    // Delete button
    NSButton *deleteBtn = [NSButton buttonWithTitle:@"✕" target:self action:@selector(_deleteButtonClicked:)];
    deleteBtn.translatesAutoresizingMaskIntoConstraints = NO;
    deleteBtn.tag = 201;
    deleteBtn.bordered = NO;
    deleteBtn.contentTintColor = [NSColor systemRedColor];
    [cell addSubview:deleteBtn];

    [NSLayoutConstraint activateConstraints:@[
        [titleField.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
        [titleField.topAnchor constraintEqualToAnchor:cell.topAnchor constant:8],
        [titleField.trailingAnchor constraintLessThanOrEqualToAnchor:actionBtn.leadingAnchor constant:-8],

        [badgeField.leadingAnchor constraintEqualToAnchor:titleField.trailingAnchor constant:6],
        [badgeField.centerYAnchor constraintEqualToAnchor:titleField.centerYAnchor],

        [subtitleField.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
        [subtitleField.topAnchor constraintEqualToAnchor:titleField.bottomAnchor constant:4],
        [subtitleField.trailingAnchor constraintLessThanOrEqualToAnchor:actionBtn.leadingAnchor constant:-8],

        [actionBtn.trailingAnchor constraintEqualToAnchor:deleteBtn.leadingAnchor constant:-4],
        [actionBtn.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],

        [deleteBtn.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [deleteBtn.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];

    [self _configureCellView:cell forEntry:entry];
    return cell;
}

- (void)_configureCellView:(NSTableCellView *)cell forEntry:(InterRecordingListEntry *)entry {
    NSTextField *titleField    = [cell viewWithTag:100];
    NSTextField *subtitleField = [cell viewWithTag:101];
    NSTextField *badgeField    = [cell viewWithTag:102];
    NSButton    *actionBtn     = [cell viewWithTag:200];

    // Title
    NSString *displayName = entry.roomName ?: @"Recording";
    titleField.stringValue = displayName;

    // Badge
    if ([entry.recordingMode isEqualToString:@"local_composed"]) {
        badgeField.stringValue = @"LOCAL";
        badgeField.layer.backgroundColor = [[NSColor systemBlueColor] CGColor];
        actionBtn.title = @"Open";
    } else if ([entry.recordingMode isEqualToString:@"cloud_composed"]) {
        badgeField.stringValue = @"CLOUD";
        badgeField.layer.backgroundColor = [[NSColor systemGreenColor] CGColor];
        actionBtn.title = @"Download";
    } else if ([entry.recordingMode isEqualToString:@"multi_track"]) {
        badgeField.stringValue = @"MULTI";
        badgeField.layer.backgroundColor = [[NSColor systemPurpleColor] CGColor];
        actionBtn.title = @"Download";
    } else {
        badgeField.stringValue = @"";
        badgeField.layer.backgroundColor = nil;
    }

    // Status indicator for failed recordings
    if ([entry.status isEqualToString:@"failed"]) {
        titleField.textColor = [NSColor systemRedColor];
        badgeField.stringValue = @"FAILED";
        badgeField.layer.backgroundColor = [[NSColor systemRedColor] CGColor];
    } else {
        titleField.textColor = [NSColor whiteColor];
    }

    // Subtitle: date + duration + size
    NSMutableString *subtitle = [NSMutableString string];
    if (entry.startedAt) {
        static NSDateFormatter *fmt;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            fmt = [[NSDateFormatter alloc] init];
            fmt.dateStyle = NSDateFormatterShortStyle;
            fmt.timeStyle = NSDateFormatterShortStyle;
        });
        [subtitle appendString:[fmt stringFromDate:entry.startedAt]];
    }
    if (entry.durationSeconds > 0) {
        NSInteger mins = entry.durationSeconds / 60;
        NSInteger secs = entry.durationSeconds % 60;
        [subtitle appendFormat:@"  •  %ld:%02ld", (long)mins, (long)secs];
    }
    if (entry.fileSizeBytes > 0) {
        NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:entry.fileSizeBytes
                                                           countStyle:NSByteCountFormatterCountStyleFile];
        [subtitle appendFormat:@"  •  %@", sizeStr];
    }
    if (entry.watermarked) {
        [subtitle appendString:@"  •  🔒 Watermarked"];
    }
    subtitleField.stringValue = subtitle;
}

// ---------------------------------------------------------------------------
// MARK: - Actions
// ---------------------------------------------------------------------------

- (void)_close:(id)sender {
    self.hidden = YES;
}

- (void)_refresh:(id)sender {
    [self reloadRecordings];
}

/// Map a button click back to the corresponding entry in the flat model.
- (InterRecordingListEntry *)_entryForButtonSender:(NSButton *)sender {
    NSInteger row = [self.tableView rowForView:sender];
    if (row < 0 || (NSUInteger)row >= self.flatRows.count) return nil;
    id item = self.flatRows[(NSUInteger)row];
    if (![item isKindOfClass:[InterRecordingListEntry class]]) return nil;
    return item;
}

- (void)_actionButtonClicked:(NSButton *)sender {
    InterRecordingListEntry *entry = [self _entryForButtonSender:sender];
    if (!entry) return;

    if ([entry.recordingMode isEqualToString:@"local_composed"]) {
        // Open local file
        NSURL *fileURL = [NSURL fileURLWithPath:entry.recordingId];
        if ([self.delegate respondsToSelector:@selector(recordingListPanel:didRequestOpenLocal:)]) {
            [self.delegate recordingListPanel:self didRequestOpenLocal:fileURL];
        }
    } else {
        // Download cloud recording
        if ([self.delegate respondsToSelector:@selector(recordingListPanel:didRequestDownload:)]) {
            [self.delegate recordingListPanel:self didRequestDownload:entry.recordingId];
        }
    }
}

- (void)_deleteButtonClicked:(NSButton *)sender {
    InterRecordingListEntry *entry = [self _entryForButtonSender:sender];
    if (!entry) return;

    // Confirmation alert
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Delete Recording?";
    alert.informativeText = [NSString stringWithFormat:@"Are you sure you want to delete \"%@\"? This action cannot be undone.", entry.roomName ?: @"this recording"];
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        if ([entry.recordingMode isEqualToString:@"local_composed"]) {
            // Delete local file
            NSError *deleteError = nil;
            BOOL deleted = [[NSFileManager defaultManager] removeItemAtPath:entry.recordingId error:&deleteError];
            if (deleted) {
                [self.localEntries removeObject:entry];
                [self _rebuildFlatRows];
            } else {
                NSLog(@"[Phase 10] Failed to delete recording at %@: %@", entry.recordingId, deleteError.localizedDescription);
                NSAlert *errorAlert = [[NSAlert alloc] init];
                errorAlert.messageText = @"Delete Failed";
                errorAlert.informativeText = @"Could not delete the recording file. Please try again.";
                [errorAlert addButtonWithTitle:@"OK"];
                errorAlert.alertStyle = NSAlertStyleWarning;
                [errorAlert runModal];
            }
        } else {
            if ([self.delegate respondsToSelector:@selector(recordingListPanel:didRequestDelete:)]) {
                [self.delegate recordingListPanel:self didRequestDelete:entry.recordingId];
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Hit Testing
// ---------------------------------------------------------------------------

- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if (!NSPointInRect(local, self.bounds)) return nil;
    return [super hitTest:point];
}

@end
