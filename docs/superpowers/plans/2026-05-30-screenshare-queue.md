# Screen Share Queue — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three runtime gaps in the existing screen-share permission system. The "Everyone / Ask Permission / No One" pre-meeting setting (`sharingPermissions` in the Redis room hash) is NOT changed. Only the runtime experience is fixed:
- **Gap 1 (Request Flooding):** Replace the one-at-a-time NSAlert popup with a persistent `InterScreenShareQueuePanel` that shows all pending requests at once (mirroring `InterSpeakerQueuePanel`).
- **Gap 2 (Mid-meeting Mode Toggle):** Let the host switch `sharingPermissions` mid-meeting via a segmented control in the moderation panel (new `POST /room/screen-share-mode` endpoint + `room:screenshare-mode-changed` Socket.IO event).
- **Gap 3 (Reconnect Queue Persistence):** Persist the pending request queue in Redis ZSET so that if the host reconnects, they see all outstanding requests.

**Architecture:**
- `InterScreenShareQueuePanel`: new ObjC class, mirrors `InterSpeakerQueuePanel`
- `InterScreenShareEntry`: new Swift class, mirrors `InterRaisedHandEntry`
- Existing `approveScreenShare(identity:)` / `denyScreenShare(identity:)` in `InterModerationController` remain unchanged
- New REST endpoints: `POST /room/request-screen-share` (persists to Redis ZSET), `POST /room/resolve-screen-share-request` (removes from ZSET), `POST /room/screen-share-mode` (changes mode)
- Participant calls `POST /room/request-screen-share` BEFORE sending the DataChannel signal (maintains idempotency)

---

## File Map

| File | Change |
|---|---|
| `inter/Networking/InterSpeakerQueue.swift` | ADD `InterScreenShareEntry` class + `InterScreenShareQueue` |
| `inter/UI/Views/InterScreenShareQueuePanel.h` | CREATE — mirrors `InterSpeakerQueuePanel.h` |
| `inter/UI/Views/InterScreenShareQueuePanel.m` | CREATE — mirrors `InterSpeakerQueuePanel.m` |
| `inter/App/AppDelegate.m` | REPLACE NSAlert with queue panel; ADD `room:screenshare-mode-changed` handler; ADD queue panel setup; ADD delegate methods |
| `inter/Networking/InterModerationController.swift` | ADD `requestScreenShareWithPersist` method; ADD 2 delegate callbacks for mode change |
| `token-server/index.js` | ADD `roomScreenShareQueueKey` + `roomScreenShareQueueNamesKey` helpers; ADD 3 REST endpoints; ADD `room:screenshare-mode-changed` Socket.IO broadcast; UPDATE `client:join-room` to send queue snapshot |

---

### Task 1: Add `InterScreenShareEntry` and `InterScreenShareQueue` data model

**Files:**
- Modify: `inter/Networking/InterSpeakerQueue.swift`

- [ ] **Step 1: Add classes at the end of the file**

Find the end of `InterSpeakerQueue.swift` and add the following:

```swift
// MARK: - Screen Share Request Queue

/// A single pending screen share request entry.
@objc public class InterScreenShareEntry: NSObject {
    /// LiveKit participant identity.
    @objc public let participantIdentity: String
    /// Human-readable display name.
    @objc public let displayName: String
    /// Timestamp when the request was made (seconds since epoch).
    @objc public let timestamp: TimeInterval

    @objc public init(participantIdentity: String,
                      displayName: String,
                      timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.participantIdentity = participantIdentity
        self.displayName = displayName
        self.timestamp = timestamp
        super.init()
    }
}

/// FIFO queue of pending screen share requests.
/// Mirrors InterSpeakerQueue for the raise-hand pattern.
@objc public class InterScreenShareQueue: NSObject {

    private var pendingRequests: [InterScreenShareEntry] = []

    /// All pending entries in FIFO order.
    @objc public var entries: [InterScreenShareEntry] { pendingRequests }

    /// Add a request. Idempotent — duplicate identity is ignored.
    @objc public func addRequest(identity: String, displayName: String, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        guard !pendingRequests.contains(where: { $0.participantIdentity == identity }) else { return }
        pendingRequests.append(InterScreenShareEntry(participantIdentity: identity, displayName: displayName, timestamp: timestamp))
    }

    /// Remove a resolved (approved or denied) request.
    @objc public func removeRequest(identity: String) {
        pendingRequests.removeAll { $0.participantIdentity == identity }
    }

    /// Remove all pending requests.
    @objc public func reset() {
        pendingRequests.removeAll()
    }

    /// Whether there is a pending request for this identity.
    @objc public func hasPendingRequest(for identity: String) -> Bool {
        pendingRequests.contains { $0.participantIdentity == identity }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add inter/Networking/InterSpeakerQueue.swift
git commit -m "feat(screenshare-queue): add InterScreenShareEntry and InterScreenShareQueue data model"
```

---

### Task 2: Create `InterScreenShareQueuePanel`

**Files:**
- Create: `inter/UI/Views/InterScreenShareQueuePanel.h`
- Create: `inter/UI/Views/InterScreenShareQueuePanel.m`

- [ ] **Step 1: Create the header file**

Create `inter/UI/Views/InterScreenShareQueuePanel.h`:

```objc
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterScreenShareEntry;
@class InterScreenShareQueuePanel;

/// Delegate for screen share queue host actions.
@protocol InterScreenShareQueuePanelDelegate <NSObject>
@optional
/// Host approved a specific screen share request.
- (void)screenShareQueuePanel:(InterScreenShareQueuePanel *)panel didApproveParticipant:(NSString *)identity;
/// Host denied a specific screen share request.
- (void)screenShareQueuePanel:(InterScreenShareQueuePanel *)panel didDenyParticipant:(NSString *)identity;
/// Host approved all pending requests at once.
- (void)screenShareQueuePanelDidApproveAll:(InterScreenShareQueuePanel *)panel;
/// Host denied all pending requests at once.
- (void)screenShareQueuePanelDidDenyAll:(InterScreenShareQueuePanel *)panel;
@end

/// Host-facing screen share request queue panel.
///
/// Shows an ordered list of participants waiting for screen share permission.
/// Each row: display name + "Approve" + "Deny" buttons.
/// Header has "Approve All" and "Deny All" buttons.
@interface InterScreenShareQueuePanel : NSView <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak, nullable) id<InterScreenShareQueuePanelDelegate> delegate;

/// Update the queue entries. Reloads the table.
- (void)setEntries:(NSArray<InterScreenShareEntry *> *)entries;

/// Whether the panel is currently visible.
@property (nonatomic, readonly) BOOL isVisible;

/// Show the panel.
- (void)showPanel;

/// Hide the panel.
- (void)hidePanel;

/// Toggle visibility.
- (void)togglePanel;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Create the implementation file**

Create `inter/UI/Views/InterScreenShareQueuePanel.m`:

```objc
#import "InterScreenShareQueuePanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

static const CGFloat InterShareQueuePanelWidth  = 280.0;
static const CGFloat InterShareQueueHeaderHeight = 36.0;
static const CGFloat InterShareQueueRowHeight    = 44.0;
static const CGFloat InterShareQueuePadding      =  8.0;

@interface InterScreenShareQueuePanel ()
@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) NSTextField *headerLabel;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSMutableArray<InterScreenShareEntry *> *queueEntries;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, strong) NSButton *denyAllButton;
@property (nonatomic, strong) NSButton *approveAllButton;
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

- (NSView *)hitTest:(NSPoint)point {
    if (!self.panelVisible) return nil;
    return [super hitTest:point];
}

- (BOOL)isVisible { return self.panelVisible; }

#pragma mark - Setup

- (void)setupViews {
    [self setWantsLayer:YES];
    self.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.95].CGColor;
    self.layer.cornerRadius = 8.0;
    self.layer.borderColor = [NSColor colorWithWhite:0.25 alpha:1.0].CGColor;
    self.layer.borderWidth = 1.0;
    self.hidden = YES;

    // Header bar
    NSView *headerBar = [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                                  self.bounds.size.height - InterShareQueueHeaderHeight,
                                                                  self.bounds.size.width,
                                                                  InterShareQueueHeaderHeight)];
    headerBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [headerBar setWantsLayer:YES];
    headerBar.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;
    [self addSubview:headerBar];

    // Header label
    self.headerLabel = [NSTextField labelWithString:@"📺 Share Requests"];
    self.headerLabel.frame = NSMakeRect(InterShareQueuePadding, 8,
                                        self.bounds.size.width - InterShareQueuePadding * 2 - 36,
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
    closeBtn.imageScaling = NSImageScaleProportionallyDown;
    closeBtn.bezelStyle = NSBezelStyleTexturedRounded;
    [closeBtn setButtonType:NSButtonTypeMomentaryLight];
    [closeBtn setTarget:self];
    [closeBtn setAction:@selector(handleClose:)];
    [headerBar addSubview:closeBtn];

    // Approve All / Deny All action bar below the header
    CGFloat actionBarY = self.bounds.size.height - InterShareQueueHeaderHeight - 32;
    NSView *actionBar = [[NSView alloc] initWithFrame:NSMakeRect(0, actionBarY, self.bounds.size.width, 32)];
    actionBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:actionBar];

    self.approveAllButton = [[NSButton alloc] initWithFrame:NSMakeRect(InterShareQueuePadding, 4, 120, 24)];
    self.approveAllButton.title = @"Approve All";
    self.approveAllButton.bezelStyle = NSBezelStyleTexturedRounded;
    [self.approveAllButton setTarget:self];
    [self.approveAllButton setAction:@selector(handleApproveAll:)];
    [actionBar addSubview:self.approveAllButton];

    self.denyAllButton = [[NSButton alloc] initWithFrame:NSMakeRect(self.bounds.size.width - 120 - InterShareQueuePadding, 4, 112, 24)];
    self.denyAllButton.title = @"Deny All";
    self.denyAllButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.denyAllButton.autoresizingMask = NSViewMinXMargin;
    [self.denyAllButton setTarget:self];
    [self.denyAllButton setAction:@selector(handleDenyAll:)];
    [actionBar addSubview:self.denyAllButton];

    // Empty label
    self.emptyLabel = [NSTextField labelWithString:@"No pending requests"];
    self.emptyLabel.frame = NSMakeRect(InterShareQueuePadding,
                                       self.bounds.size.height / 2 - 10,
                                       self.bounds.size.width - InterShareQueuePadding * 2, 20);
    self.emptyLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
    self.emptyLabel.alignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [NSColor colorWithWhite:0.5 alpha:1.0];
    self.emptyLabel.font = [NSFont systemFontOfSize:12];
    self.emptyLabel.hidden = YES;
    [self addSubview:self.emptyLabel];

    // Scroll view + table view
    CGFloat tableY = InterShareQueuePadding;
    CGFloat tableH = actionBarY - tableY - InterShareQueuePadding;
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, tableY, self.bounds.size.width, tableH)];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = NO;

    self.tableView = [[NSTableView alloc] initWithFrame:self.scrollView.bounds];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.headerView = nil;
    self.tableView.backgroundColor = [NSColor clearColor];
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    self.tableView.rowHeight = InterShareQueueRowHeight;
    self.tableView.intercellSpacing = NSMakeSize(0, 1);

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.width = self.bounds.size.width;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:col];

    self.scrollView.documentView = self.tableView;
    [self addSubview:self.scrollView];
}

#pragma mark - Public API

- (void)setEntries:(NSArray<InterScreenShareEntry *> *)entries {
    self.queueEntries = [entries mutableCopy];
    [self.tableView reloadData];
    self.emptyLabel.hidden = entries.count > 0;
    self.approveAllButton.enabled = entries.count > 0;
    self.denyAllButton.enabled = entries.count > 0;
}

- (void)showPanel {
    self.hidden = NO;
    self.panelVisible = YES;
}

- (void)hidePanel {
    self.hidden = YES;
    self.panelVisible = NO;
}

- (void)togglePanel {
    if (self.panelVisible) [self hidePanel]; else [self showPanel];
}

#pragma mark - Actions

- (void)handleClose:(id)sender {
    [self hidePanel];
}

- (void)handleApproveAll:(id)sender {
    [self.delegate screenShareQueuePanelDidApproveAll:self];
}

- (void)handleDenyAll:(id)sender {
    [self.delegate screenShareQueuePanelDidDenyAll:self];
}

- (void)handleApprove:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.queueEntries.count) return;
    NSString *identity = self.queueEntries[row].participantIdentity;
    [self.delegate screenShareQueuePanel:self didApproveParticipant:identity];
}

- (void)handleDeny:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.queueEntries.count) return;
    NSString *identity = self.queueEntries[row].participantIdentity;
    [self.delegate screenShareQueuePanel:self didDenyParticipant:identity];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.queueEntries.count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {

    InterScreenShareEntry *entry = self.queueEntries[row];

    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"ShareCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableView.bounds.size.width, InterShareQueueRowHeight)];
        cell.identifier = @"ShareCell";

        // Name label
        NSTextField *nameField = [NSTextField labelWithString:@""];
        nameField.frame = NSMakeRect(InterShareQueuePadding, 16,
                                     tableView.bounds.size.width - 180, 16);
        nameField.font = [NSFont boldSystemFontOfSize:12];
        nameField.textColor = [NSColor colorWithWhite:0.90 alpha:1.0];
        nameField.identifier = @"nameLabel";
        [cell addSubview:nameField];

        // Request label
        NSTextField *reqLabel = [NSTextField labelWithString:@"wants to share screen"];
        reqLabel.frame = NSMakeRect(InterShareQueuePadding, 2,
                                    tableView.bounds.size.width - 180, 12);
        reqLabel.font = [NSFont systemFontOfSize:10];
        reqLabel.textColor = [NSColor colorWithWhite:0.55 alpha:1.0];
        [cell addSubview:reqLabel];

        // Approve button
        NSButton *approveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(tableView.bounds.size.width - 170, 10, 75, 24)];
        approveBtn.title = @"Approve";
        approveBtn.bezelStyle = NSBezelStyleTexturedRounded;
        approveBtn.identifier = @"approveBtn";
        [approveBtn setTarget:self];
        [approveBtn setAction:@selector(handleApprove:)];
        [cell addSubview:approveBtn];

        // Deny button
        NSButton *denyBtn = [[NSButton alloc] initWithFrame:NSMakeRect(tableView.bounds.size.width - 90, 10, 82, 24)];
        denyBtn.title = @"Deny";
        denyBtn.bezelStyle = NSBezelStyleTexturedRounded;
        denyBtn.identifier = @"denyBtn";
        [denyBtn setTarget:self];
        [denyBtn setAction:@selector(handleDeny:)];
        [cell addSubview:denyBtn];
    }

    // Update content
    NSTextField *name = [cell viewWithTag:0];
    // Use identifier-based lookup instead of tag for nameLabel
    for (NSView *sub in cell.subviews) {
        if ([sub isKindOfClass:[NSTextField class]]) {
            NSTextField *tf = (NSTextField *)sub;
            if ([tf.identifier isEqualToString:@"nameLabel"]) {
                tf.stringValue = entry.displayName;
                break;
            }
        }
    }
    (void)name;

    // Set row index as tag so action handlers can look up the entry
    for (NSView *sub in cell.subviews) {
        if ([sub isKindOfClass:[NSButton class]]) {
            ((NSButton *)sub).tag = row;
        }
    }
    return cell;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return InterShareQueueRowHeight;
}

@end
```

- [ ] **Step 3: Add `InterScreenShareQueuePanel.m` to the Xcode project**

Add the new `.h` and `.m` files to the `inter` target in `inter.xcodeproj/project.pbxproj`. The easiest way is to open the project in Xcode and drag the files into the `UI/Views` group with "Add to target: inter" checked.

Alternatively, run:

```bash
cd /Users/aman_01/Documents/inter
# Check if the file is picked up automatically (workspace may auto-discover sources)
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | grep -i "screenShareQueue\|error"
```

If it errors with "file not found", add the files to `project.pbxproj` manually by referencing the pattern used for `InterSpeakerQueuePanel.m`.

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add inter/UI/Views/InterScreenShareQueuePanel.h inter/UI/Views/InterScreenShareQueuePanel.m
git commit -m "feat(screenshare-queue): create InterScreenShareQueuePanel"
```

---

### Task 3: Replace NSAlert with the queue panel in `AppDelegate.m` (Gap 1)

**Files:**
- Modify: `inter/App/AppDelegate.m`

- [ ] **Step 1: Add imports and new properties to the AppDelegate interface**

Find at the top of `AppDelegate.m`:

```objc
#import "InterSpeakerQueuePanel.h"
```

Add immediately after it:

```objc
#import "InterSpeakerQueuePanel.h"
#import "InterScreenShareQueuePanel.h"
```

Find the `@interface AppDelegate ()` extension and add the new properties near `normalSpeakerQueuePanel`:

```objc
@property (nonatomic, strong, nullable) InterScreenShareQueuePanel *normalScreenShareQueuePanel;
@property (nonatomic, strong, nullable) InterScreenShareQueue *screenShareQueue;
```

Also add `InterScreenShareQueuePanelDelegate` to the protocol conformance list in the `@interface AppDelegate ()` line:

```objc
<..., InterSpeakerQueuePanelDelegate, InterScreenShareQueuePanelDelegate, ...>
```

- [ ] **Step 2: Initialize the queue in `applicationDidFinishLaunching:` or meeting setup**

Find where `self.speakerQueue` is initialized:

```objc
    self.speakerQueue = [[InterSpeakerQueue alloc] init];
```

Add immediately after:

```objc
    self.speakerQueue = [[InterSpeakerQueue alloc] init];
    self.screenShareQueue = [[InterScreenShareQueue alloc] init];
```

- [ ] **Step 3: Set up the panel in the meeting window setup section**

Find where `self.normalSpeakerQueuePanel` is set up:

```objc
    self.normalSpeakerQueuePanel = [[InterSpeakerQueuePanel alloc] initWithFrame:NSMakeRect(queueX, 90.0, 260.0, 300.0)];
    self.normalSpeakerQueuePanel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.normalSpeakerQueuePanel.delegate = self;
    [view addSubview:self.normalSpeakerQueuePanel];
```

Add the screen share queue panel immediately after it:

```objc
    self.normalSpeakerQueuePanel = [[InterSpeakerQueuePanel alloc] initWithFrame:NSMakeRect(queueX, 90.0, 260.0, 300.0)];
    self.normalSpeakerQueuePanel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.normalSpeakerQueuePanel.delegate = self;
    [view addSubview:self.normalSpeakerQueuePanel];

    // Screen share request queue panel — positioned to the left of the speaker queue
    CGFloat ssQueueX = queueX - 290.0;
    self.normalScreenShareQueuePanel = [[InterScreenShareQueuePanel alloc] initWithFrame:NSMakeRect(ssQueueX, 90.0, 280.0, 280.0)];
    self.normalScreenShareQueuePanel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.normalScreenShareQueuePanel.delegate = self;
    [view addSubview:self.normalScreenShareQueuePanel];
```

- [ ] **Step 4: Replace the NSAlert-based `moderationController:receivedScreenShareRequest:` delegate method**

Find and replace the existing NSAlert implementation:

```objc
- (void)moderationController:(InterModerationController *)controller
  receivedScreenShareRequest:(NSString *)fromIdentity
                 displayName:(NSString *)displayName {
#pragma unused(controller)
    // Only the host handles incoming share requests.
    if (!self.roomController.isHost) return;

    self.normalPendingShareRequestIdentity = fromIdentity;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Screen Share Request";
    alert.informativeText = [NSString stringWithFormat:
        @"%@ is requesting to share their screen.", displayName];
    [alert addButtonWithTitle:@"Allow"];
    [alert addButtonWithTitle:@"Deny"];

    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.normalCallWindow completionHandler:^(NSModalResponse response) {
        NSString *identity = weakSelf.normalPendingShareRequestIdentity;
        weakSelf.normalPendingShareRequestIdentity = nil;
        if (!identity.length) return;
        if (response == NSAlertFirstButtonReturn) {
            [weakSelf.moderationController approveScreenShareWithIdentity:identity];
        } else {
            [weakSelf.moderationController denyScreenShareWithIdentity:identity];
        }
    }];
}
```

Replace it with:

```objc
- (void)moderationController:(InterModerationController *)controller
  receivedScreenShareRequest:(NSString *)fromIdentity
                 displayName:(NSString *)displayName {
#pragma unused(controller)
    // Non-hosts ignore this — only the host (or co-host with share privileges)
    // manages the request queue.
    if (!self.roomController.isHost) return;

    // Add to the FIFO queue
    [self.screenShareQueue addRequestWithIdentity:fromIdentity displayName:displayName];
    [self.normalScreenShareQueuePanel setEntries:self.screenShareQueue.entries];
    [self.normalScreenShareQueuePanel showPanel];
}
```

- [ ] **Step 5: Add `InterScreenShareQueuePanelDelegate` implementations**

Find the `speakerQueuePanel:didDismissParticipant:` method group and add the screen share queue delegate methods nearby:

```objc
// ---------------------------------------------------------------------------
// MARK: - InterScreenShareQueuePanelDelegate
// ---------------------------------------------------------------------------

- (void)screenShareQueuePanel:(InterScreenShareQueuePanel *)panel
        didApproveParticipant:(NSString *)identity {
    [self.screenShareQueue removeRequestWithIdentity:identity];
    [self.normalScreenShareQueuePanel setEntries:self.screenShareQueue.entries];
    if (self.screenShareQueue.entries.count == 0) {
        [self.normalScreenShareQueuePanel hidePanel];
    }
    [self.moderationController approveScreenShareWithIdentity:identity];
    // Also resolve the server-side queue entry
    [self resolveScreenShareRequest:identity approved:YES];
}

- (void)screenShareQueuePanel:(InterScreenShareQueuePanel *)panel
          didDenyParticipant:(NSString *)identity {
    [self.screenShareQueue removeRequestWithIdentity:identity];
    [self.normalScreenShareQueuePanel setEntries:self.screenShareQueue.entries];
    if (self.screenShareQueue.entries.count == 0) {
        [self.normalScreenShareQueuePanel hidePanel];
    }
    [self.moderationController denyScreenShareWithIdentity:identity];
    [self resolveScreenShareRequest:identity approved:NO];
}

- (void)screenShareQueuePanelDidApproveAll:(InterScreenShareQueuePanel *)panel {
    NSArray<InterScreenShareEntry *> *entries = [self.screenShareQueue.entries copy];
    for (InterScreenShareEntry *entry in entries) {
        [self.moderationController approveScreenShareWithIdentity:entry.participantIdentity];
        [self resolveScreenShareRequest:entry.participantIdentity approved:YES];
    }
    [self.screenShareQueue reset];
    [self.normalScreenShareQueuePanel setEntries:@[]];
    [self.normalScreenShareQueuePanel hidePanel];
}

- (void)screenShareQueuePanelDidDenyAll:(InterScreenShareQueuePanel *)panel {
    NSArray<InterScreenShareEntry *> *entries = [self.screenShareQueue.entries copy];
    for (InterScreenShareEntry *entry in entries) {
        [self.moderationController denyScreenShareWithIdentity:entry.participantIdentity];
        [self resolveScreenShareRequest:entry.participantIdentity approved:NO];
    }
    [self.screenShareQueue reset];
    [self.normalScreenShareQueuePanel setEntries:@[]];
    [self.normalScreenShareQueuePanel hidePanel];
}

/// Helper: call server to remove a resolved request from Redis ZSET (best-effort).
- (void)resolveScreenShareRequest:(NSString *)identity approved:(BOOL)approved {
    NSString *roomCode = self.roomController.roomCode;
    NSString *callerIdentity = self.roomController.localParticipantIdentity;
    if (!roomCode || !callerIdentity) return;

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/room/resolve-screen-share-request", self.serverBaseURL]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [self attachAuthHeaderToRequest:request];

    NSDictionary *body = @{
        @"roomCode": roomCode,
        @"callerIdentity": callerIdentity,
        @"targetIdentity": identity,
        @"resolution": approved ? @"approved" : @"denied",
    };
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) NSLog(@"[ShareQueue] resolveScreenShareRequest failed: %@", error.localizedDescription);
    }] resume];
}
```

- [ ] **Step 6: Reset screen share queue on room leave**

Find where `[self.speakerQueue reset]` is called on room leave:

```objc
    [self.speakerQueue reset];
```

Add immediately after:

```objc
    [self.speakerQueue reset];
    [self.screenShareQueue reset];
    [self.normalScreenShareQueuePanel setEntries:@[]];
    [self.normalScreenShareQueuePanel hidePanel];
```

- [ ] **Step 7: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "feat(screenshare-queue): replace NSAlert with queue panel (Gap 1)"
```

---

### Task 4: Add `requestScreenShare` persistence REST call (client side)

When a participant sends a screen share request, they should also call the server to persist the entry to the Redis ZSET (needed for Gap 3 reconnect).

**Files:**
- Modify: `inter/Networking/InterModerationController.swift`

- [ ] **Step 1: Add `requestScreenShareWithPersist` method**

Find the existing `requestScreenShare` method:

```swift
    @objc public func requestScreenShare() {
        sendControlSignal(type: .requestScreenShare)
        interLogInfo(InterLog.room, "ModerationController: sent requestScreenShare")
    }
```

Replace it with:

```swift
    /// Request permission to share screen. Persists the request to the server
    /// (Redis ZSET) for reconnect resilience, then broadcasts the DataChannel signal.
    @objc public func requestScreenShare() {
        let body: [String: Any] = [
            "roomCode": roomCode,
            "requesterIdentity": localIdentity,
        ]
        performPOST(endpoint: "/room/request-screen-share", body: body) { [weak self] _ in
            // Best-effort persistence — always send the DataChannel signal regardless
            self?.sendControlSignal(type: .requestScreenShare)
            interLogInfo(InterLog.room, "ModerationController: sent requestScreenShare (persisted)")
        }
    }
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add inter/Networking/InterModerationController.swift
git commit -m "feat(screenshare-queue): persist screen share requests to Redis on send"
```

---

### Task 5: Server — Redis helpers and new REST endpoints (Gaps 1 & 3)

**Files:**
- Modify: `token-server/index.js`

- [ ] **Step 1: Add Redis key helpers**

Find:

```javascript
function globalCameraLockKey(code) { return `room:${code}:global-camera-lock`; }
```

Add immediately after:

```javascript
function globalCameraLockKey(code) { return `room:${code}:global-camera-lock`; }

// Screen share request queue Redis key helpers
function roomScreenShareQueueKey(code) { return `room:${code}:screenshare-queue`; }
function roomScreenShareQueueNamesKey(code) { return `room:${code}:screenshare-queue:names`; }
```

- [ ] **Step 2: Add 2 new screen share queue REST endpoints**

Find the comment before `/room/mute-camera-one`:

```javascript
// ---------------------------------------------------------------------------
// POST /room/mute-camera-one — Host force-mutes a specific participant's camera.
```

Add the 2 new endpoints immediately BEFORE it:

```javascript
// ---------------------------------------------------------------------------
// POST /room/request-screen-share — Participant requests permission to share.
// Persists the request to Redis ZSET for reconnect resilience.
// Body: { roomCode, requesterIdentity }
// Returns: { success: true }
// ---------------------------------------------------------------------------
app.post('/room/request-screen-share', auth.requireAuth, async (req, res) => {
  const { roomCode, requesterIdentity } = req.body;
  if (!roomCode || !requesterIdentity) {
    return res.status(400).json({ error: 'roomCode and requesterIdentity are required' });
  }
  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  // Verify requester is a participant
  const isMember = await redis.sismember(roomParticipantsKey(code), requesterIdentity);
  if (!isMember) return res.status(403).json({ error: 'Not a participant in this room' });

  try {
    const now = Date.now();
    // ZADD NX: only add if not already in queue (idempotent)
    await redis.zadd(roomScreenShareQueueKey(code), 'NX', now, requesterIdentity);
    await redis.expire(roomScreenShareQueueKey(code), ROOM_CODE_EXPIRY_SECONDS);

    // Store display name for reconnect snapshot
    const displayName = await redis.hget(roomNamesKey(code), requesterIdentity);
    if (displayName) {
      await redis.hset(roomScreenShareQueueNamesKey(code), requesterIdentity, displayName);
      await redis.expire(roomScreenShareQueueNamesKey(code), ROOM_CODE_EXPIRY_SECONDS);
    }

    res.json({ success: true });
  } catch (err) {
    console.error('[error] request-screen-share failed:', err.message);
    res.status(500).json({ error: 'Failed to queue screen share request' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/resolve-screen-share-request — Host resolves (approves or denies)
// a screen share request. Removes entry from the Redis ZSET.
// Body: { roomCode, callerIdentity, targetIdentity, resolution }
// Returns: { success: true }
// ---------------------------------------------------------------------------
app.post('/room/resolve-screen-share-request', auth.requireAuth, async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity, resolution } = req.body;
  if (!roomCode || !callerIdentity || !targetIdentity) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and targetIdentity are required' });
  }
  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  try {
    await redis.zrem(roomScreenShareQueueKey(code), targetIdentity);
    await redis.hdel(roomScreenShareQueueNamesKey(code), targetIdentity);
    console.log(`[audit] Screen share request resolved: code=${code} target=${targetIdentity} resolution=${resolution || 'unknown'} by=${callerIdentity}`);
    res.json({ success: true });
  } catch (err) {
    console.error('[error] resolve-screen-share-request failed:', err.message);
    res.status(500).json({ error: 'Failed to resolve screen share request' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/mute-camera-one — Host force-mutes a specific participant's camera.
```

- [ ] **Step 3: Add `screenshare-queue-snapshot` to `client:join-room`**

Find in the `client:join-room` handler:

```javascript
    // Send camera state snapshot for reconnect reconciliation
    try {
```

Add the screen share queue snapshot AFTER the camera snapshot:

```javascript
    // Send screen share queue snapshot to the host on reconnect
    try {
      const callerRole = await getParticipantRole(code, identity);
      if (callerRole === 'host' || callerRole === 'coHost') {
        const queueEntries = await redis.zrangebyscore(roomScreenShareQueueKey(code), '-inf', '+inf', 'WITHSCORES');
        // zrangebyscore WITHSCORES returns [member, score, member, score, ...]
        const entries = [];
        for (let i = 0; i < queueEntries.length; i += 2) {
          const entryIdentity = queueEntries[i];
          const timestamp = parseFloat(queueEntries[i + 1]);
          const displayName = await redis.hget(roomScreenShareQueueNamesKey(code), entryIdentity) || entryIdentity;
          entries.push({ identity: entryIdentity, displayName, timestamp });
        }
        if (entries.length > 0) {
          socket.emit('room:screenshare-queue-snapshot', { entries });
        }
      }
    } catch (_) { /* best-effort */ }
```

- [ ] **Step 4: Verify server starts**

```bash
cd token-server && node -e "require('./index.js')" 2>&1 | head -5
```

- [ ] **Step 5: Test screen share request persistence**

```bash
# Request screen share
curl -s -X POST http://localhost:3000/room/request-screen-share \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <PARTICIPANT_TOKEN>" \
  -d '{"roomCode":"TESTAB","requesterIdentity":"user-2"}' | jq .
# Expected: { "success": true }

# Verify Redis ZSET
redis-cli ZRANGEBYSCORE "room:TESTAB:screenshare-queue" -inf +inf WITHSCORES
# Expected: 1) "user-2" 2) "<timestamp>"

# Resolve (approve)
curl -s -X POST http://localhost:3000/room/resolve-screen-share-request \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <HOST_TOKEN>" \
  -d '{"roomCode":"TESTAB","callerIdentity":"host-1","targetIdentity":"user-2","resolution":"approved"}' | jq .
# Expected: { "success": true }

# Verify removed from ZSET
redis-cli ZRANGEBYSCORE "room:TESTAB:screenshare-queue" -inf +inf
# Expected: (empty array)
```

- [ ] **Step 6: Commit**

```bash
git add token-server/index.js
git commit -m "feat(screenshare-queue): add Redis ZSET endpoints and reconnect snapshot (Gaps 1 & 3)"
```

---

### Task 6: Handle `room:screenshare-queue-snapshot` on client (Gap 3)

**Files:**
- Modify: `inter/App/AppDelegate.m`

- [ ] **Step 1: Register the `room:screenshare-queue-snapshot` Socket.IO handler**

Find where `room:camera-state-snapshot` is subscribed to. Add the screen share queue snapshot handler nearby:

```objc
// room:screenshare-queue-snapshot — sent by server to the host on reconnect.
// Repopulates the pending screen share request queue.
[self.socketManager on:@"room:screenshare-queue-snapshot" callback:^(NSArray *args, SocketAckEmitter *ack) {
    NSDictionary *payload = [args firstObject];
    if (![payload isKindOfClass:[NSDictionary class]]) return;

    NSArray<NSDictionary *> *entries = payload[@"entries"];
    if (![entries isKindOfClass:[NSArray class]]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSDictionary *entry in entries) {
            NSString *identity = entry[@"identity"];
            NSString *displayName = entry[@"displayName"] ?: identity;
            NSTimeInterval timestamp = [entry[@"timestamp"] doubleValue] / 1000.0; // ms → seconds
            if (identity.length > 0) {
                [self.screenShareQueue addRequestWithIdentity:identity
                                                 displayName:displayName
                                                   timestamp:timestamp];
            }
        }
        if (self.screenShareQueue.entries.count > 0) {
            [self.normalScreenShareQueuePanel setEntries:self.screenShareQueue.entries];
            [self.normalScreenShareQueuePanel showPanel];
        }
    });
}];
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "feat(screenshare-queue): handle screenshare-queue-snapshot for reconnect (Gap 3)"
```

---

### Task 7: Mid-meeting screen share mode toggle (Gap 2)

**Files:**
- Modify: `token-server/index.js`
- Modify: `inter/App/AppDelegate.m`

- [ ] **Step 1: Add `POST /room/screen-share-mode` endpoint to server**

Find the endpoint comment before `/room/mute-camera-one` and add the new endpoint BEFORE it:

```javascript
// ---------------------------------------------------------------------------
// POST /room/screen-share-mode — Host changes the screen share permission mid-meeting.
// Body: { roomCode, callerIdentity, mode }
// mode: "everyone" | "request" | "hostOnly"
// Returns: { success: true }
// ---------------------------------------------------------------------------
app.post('/room/screen-share-mode', auth.requireAuth, async (req, res) => {
  const { roomCode, callerIdentity, mode } = req.body;
  const VALID_MODES = ['everyone', 'request', 'hostOnly'];
  if (!roomCode || !callerIdentity || !VALID_MODES.includes(mode)) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and a valid mode are required' });
  }
  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });

  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  try {
    await redis.hset(roomKey(code), 'sharingPermissions', mode);

    // Clear the request queue if moving to "everyone" or "hostOnly"
    // (requests are no longer relevant)
    if (mode === 'everyone' || mode === 'hostOnly') {
      await redis.del(roomScreenShareQueueKey(code));
      await redis.del(roomScreenShareQueueNamesKey(code));
    }

    // Broadcast to all Socket.IO clients in the room
    io.to(code).emit('room:screenshare-mode-changed', { mode });
    console.log(`[audit] Screen share mode changed: code=${code} mode=${mode} by=${callerIdentity}`);
    res.json({ success: true });
  } catch (err) {
    console.error('[error] screen-share-mode failed:', err.message);
    res.status(500).json({ error: 'Failed to update screen share mode' });
  }
});
```

- [ ] **Step 2: Register `room:screenshare-mode-changed` Socket.IO handler in AppDelegate**

Find where `room:screenshare-queue-snapshot` is subscribed. Add the mode-changed handler nearby:

```objc
// room:screenshare-mode-changed — host updated the screen share mode mid-meeting.
[self.socketManager on:@"room:screenshare-mode-changed" callback:^(NSArray *args, SocketAckEmitter *ack) {
    NSDictionary *payload = [args firstObject];
    if (![payload isKindOfClass:[NSDictionary class]]) return;

    NSString *mode = payload[@"mode"];
    if (!mode.length) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Update the host's segmented control if visible
        [self.normalControlPanel setScreenSharePermissionMode:mode];

        // If mode switched away from "request", clear pending queue UI
        if ([mode isEqualToString:@"everyone"] || [mode isEqualToString:@"hostOnly"]) {
            [self.screenShareQueue reset];
            [self.normalScreenShareQueuePanel setEntries:@[]];
            [self.normalScreenShareQueuePanel hidePanel];
        }

        // If mode = "hostOnly" and local participant is not host/co-host and is sharing: stop
        if ([mode isEqualToString:@"hostOnly"] && !self.roomController.isHost) {
            if (self.normalSurfaceShareController.isSharingActive) {
                [self stopNormalScreenShare];
            }
        }
    });
}];
```

- [ ] **Step 3: Add `setScreenSharePermissionMode:` to `InterLocalCallControlPanel`**

Find in `InterLocalCallControlPanel.h`:

```objc
- (void)setCameraButtonTitle:(nullable NSString *)title;
```

Add the new method:

```objc
- (void)setCameraButtonTitle:(nullable NSString *)title;
/// Update the screen share permission segmented control.
/// mode: @"everyone" | @"request" | @"hostOnly"
/// Pass nil to hide the control (for non-host participants).
- (void)setScreenSharePermissionMode:(nullable NSString *)mode;
```

- [ ] **Step 4: Implement `setScreenSharePermissionMode:` in `InterLocalCallControlPanel.m`**

Find the `setCameraButtonTitle:` implementation and add after it:

```objc
- (void)setScreenSharePermissionMode:(nullable NSString *)mode {
    if (!mode) {
        self.screenShareModeControl.hidden = YES;
        return;
    }
    self.screenShareModeControl.hidden = NO;
    if ([mode isEqualToString:@"everyone"]) {
        self.screenShareModeControl.selectedSegment = 0;
    } else if ([mode isEqualToString:@"request"]) {
        self.screenShareModeControl.selectedSegment = 1;
    } else if ([mode isEqualToString:@"hostOnly"]) {
        self.screenShareModeControl.selectedSegment = 2;
    }
}
```

> **Note:** `screenShareModeControl` is a new `NSSegmentedControl` that needs to be added to `InterLocalCallControlPanel`. Add it to `setupViews` (or the host-controls section) with 3 segments: "Everyone", "Ask", "Host Only". Wire its action to a `screenShareModeChangedHandler` block (like `shareModeChangedHandler`). This control should only be visible when the local participant is the host.

For the NSSegmentedControl setup in `InterLocalCallControlPanel.m`:

```objc
// In setupViews or host setup section:
self.screenShareModeControl = [[NSSegmentedControl alloc] init];
[self.screenShareModeControl setSegmentCount:3];
[self.screenShareModeControl setLabel:@"Everyone" forSegment:0];
[self.screenShareModeControl setLabel:@"Ask" forSegment:1];
[self.screenShareModeControl setLabel:@"Host Only" forSegment:2];
self.screenShareModeControl.segmentStyle = NSSegmentStyleRounded;
self.screenShareModeControl.selectedSegment = 1; // "Ask" default
self.screenShareModeControl.hidden = YES; // shown only for hosts
[self.screenShareModeControl setTarget:self];
[self.screenShareModeControl setAction:@selector(handleScreenShareModeChanged:)];
// Add to appropriate container in the moderation controls area
[self.moderationControlsContainer addSubview:self.screenShareModeControl];
```

Wire the action:

```objc
- (void)handleScreenShareModeChanged:(NSSegmentedControl *)sender {
    NSDictionary *modes = @{ @0: @"everyone", @1: @"request", @2: @"hostOnly" };
    NSString *mode = modes[@(sender.selectedSegment)];
    if (mode && self.screenShareModeChangedHandler) {
        self.screenShareModeChangedHandler(mode);
    }
}
```

Declare `screenShareModeChangedHandler` in the header:

```objc
/// Called when the host changes the screen share permission segmented control.
@property (nonatomic, copy, nullable) void (^screenShareModeChangedHandler)(NSString *mode);
```

- [ ] **Step 5: Wire the handler in `AppDelegate.m`**

Find where `shareModeChangedHandler` is wired up. Add the new handler nearby:

```objc
    self.normalControlPanel.screenShareModeChangedHandler = ^(NSString *mode) {
        NSString *roomCode = weakSelf.roomController.roomCode;
        NSString *callerIdentity = weakSelf.roomController.localParticipantIdentity;
        if (!roomCode || !callerIdentity) return;

        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/room/screen-share-mode", weakSelf.serverBaseURL]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [weakSelf attachAuthHeaderToRequest:request];

        NSDictionary *body = @{ @"roomCode": roomCode, @"callerIdentity": callerIdentity, @"mode": mode };
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) NSLog(@"[ScreenShare] mode change failed: %@", error.localizedDescription);
        }] resume];
    };
```

- [ ] **Step 6: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add inter/App/AppDelegate.m inter/UI/Views/InterLocalCallControlPanel.h inter/UI/Views/InterLocalCallControlPanel.m token-server/index.js
git commit -m "feat(screenshare-queue): mid-meeting screen share mode toggle (Gap 2)"
```

---

### Task 8: End-to-end smoke test

- [ ] **Test A: Request flooding (Gap 1)**

1. `sharingPermissions` = `request` for the room.
2. Participant 2 clicks "Request to Share". Panel appears on host's screen showing "Participant 2 — wants to share screen" with Approve/Deny buttons. Request persists to Redis ZSET.
3. Participant 3 also clicks "Request to Share". Panel now shows BOTH participants.
4. Host clicks "Approve" on Participant 2 → Participant 2 gets `approveScreenShare` DataChannel signal → starts sharing. Entry removed from panel and Redis ZSET.
5. Host clicks "Deny" on Participant 3 → Participant 3 gets `denyScreenShare` signal. Panel closes.
6. Redis ZSET is now empty: `redis-cli ZCARD "room:{code}:screenshare-queue"` → `(integer) 0`.

- [ ] **Test B: Host reconnect (Gap 3)**

1. Participants 2 and 3 have pending requests in the queue.
2. Host disconnects and reconnects (network drop).
3. On reconnect, `client:join-room` fires → server sends `room:screenshare-queue-snapshot` with both entries.
4. Panel auto-shows with both requests. Host can approve/deny.

- [ ] **Test C: Mid-meeting mode toggle (Gap 2)**

1. Host switches "Ask" → "Everyone" via the segmented control.
2. Server broadcasts `room:screenshare-mode-changed { mode: "everyone" }`.
3. All participants see the Share button become available without a request.
4. Redis ZSET is cleared: `redis-cli ZCARD "room:{code}:screenshare-queue"` → `(integer) 0`.
5. Host switches to "Host Only" → non-host participants who are sharing get their screen share stopped automatically.
