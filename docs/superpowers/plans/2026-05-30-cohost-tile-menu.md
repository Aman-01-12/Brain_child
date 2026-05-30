# Co-Host Tile Menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the already-fully-implemented co-host backend as a tile menu item. A host or co-host can right-click (or click `···`) any participant tile and choose "Make Co-Host" or "Remove Co-Host". The backend (`/room/promote` + `roleChanged` DataChannel signal + `InterParticipantRole.coHost`) is already complete — this plan is purely UI plumbing.

**Scope:** ~4 files, ~60 lines net. No server changes required. No new DataChannel signals.

**Tech Stack:** ObjC (`AppDelegate`, `InterRemoteVideoLayoutManager`)

---

## File Map

| File | Change |
|---|---|
| `inter/UI/Views/InterRemoteVideoLayoutManager.h` | ADD `setIsCoHost:forParticipant:` declaration |
| `inter/UI/Views/InterRemoteVideoLayoutManager.m` | ADD `isCoHost` tile property + `coHostBadge`; ADD tile menu items; ADD `setIsCoHost:forParticipant:` |
| `inter/App/AppDelegate.m` | ADD `makeCoHost`/`removeCoHost` tile action cases; UPDATE `moderationController:participantRoleChanged:` to sync `isCoHost` |

---

### Task 1: Add `isCoHost` property and "Co-Host" badge to remote tiles

**Files:**
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.h`
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.m`

- [ ] **Step 1: Declare the public setter in the header**

Find in `InterRemoteVideoLayoutManager.h`:

```objc
- (void)setHostCameraLocked:(BOOL)locked forParticipant:(NSString *)identity;
```

Add immediately after it:

```objc
- (void)setHostCameraLocked:(BOOL)locked forParticipant:(NSString *)identity;
/// Update the co-host crown badge on a specific participant's tile.
- (void)setIsCoHost:(BOOL)isCoHost forParticipant:(NSString *)identity;
```

- [ ] **Step 2: Add `isCoHost` and `coHostBadge` to the tile view private interface**

Find in `InterRemoteVideoLayoutManager.m` the camera locked badge properties:

```objc
@property (nonatomic, strong) NSTextField *cameraLockedBadge;
@property (nonatomic, assign) BOOL isHostCameraLocked;
```

Add the co-host properties immediately after:

```objc
@property (nonatomic, strong) NSTextField *cameraLockedBadge;
@property (nonatomic, assign) BOOL isHostCameraLocked;
@property (nonatomic, strong) NSTextField *coHostBadge;
@property (nonatomic, assign) BOOL isCoHost;
```

- [ ] **Step 3: Initialize `coHostBadge` in `initWithVideoView:tileKey:displayName:`**

Find the `cameraLockedBadge` initialization block:

```objc
    self.cameraLockedBadge = [NSTextField labelWithString:@"📷"];
    self.cameraLockedBadge.font = [NSFont systemFontOfSize:14];
    self.cameraLockedBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.cameraLockedBadge setWantsLayer:YES];
    self.cameraLockedBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.cameraLockedBadge.layer.cornerRadius = 4.0;
    self.cameraLockedBadge.alignment = NSTextAlignmentCenter;
    self.cameraLockedBadge.hidden = YES;
    [self addSubview:self.cameraLockedBadge];
```

Add the co-host badge initialization immediately after it:

```objc
    self.cameraLockedBadge = [NSTextField labelWithString:@"📷"];
    self.cameraLockedBadge.font = [NSFont systemFontOfSize:14];
    self.cameraLockedBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.cameraLockedBadge setWantsLayer:YES];
    self.cameraLockedBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.cameraLockedBadge.layer.cornerRadius = 4.0;
    self.cameraLockedBadge.alignment = NSTextAlignmentCenter;
    self.cameraLockedBadge.hidden = YES;
    [self addSubview:self.cameraLockedBadge];

    self.coHostBadge = [NSTextField labelWithString:@"👑"];
    self.coHostBadge.font = [NSFont systemFontOfSize:14];
    self.coHostBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.coHostBadge setWantsLayer:YES];
    self.coHostBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.coHostBadge.layer.cornerRadius = 4.0;
    self.coHostBadge.alignment = NSTextAlignmentCenter;
    self.coHostBadge.hidden = YES;
    [self addSubview:self.coHostBadge];
```

- [ ] **Step 4: Position `coHostBadge` in `layout`**

Find the camera badge layout line:

```objc
    self.cameraLockedBadge.frame = NSMakeRect(b.size.width - 52, labelH + 2, 22, 22);
```

Add the co-host badge positioning immediately after:

```objc
    self.cameraLockedBadge.frame = NSMakeRect(b.size.width - 52, labelH + 2, 22, 22);
    // Co-host crown badge: top-right corner (near the ··· menu button)
    self.coHostBadge.frame = NSMakeRect(b.size.width - 26, b.size.height - 26, 22, 22);
```

- [ ] **Step 5: Add the `setIsCoHost:` custom setter**

Find the `setIsHostCameraLocked:` setter:

```objc
- (void)setIsHostCameraLocked:(BOOL)isHostCameraLocked {
    if (_isHostCameraLocked == isHostCameraLocked) return;
    _isHostCameraLocked = isHostCameraLocked;
    self.cameraLockedBadge.hidden = !isHostCameraLocked;
}
```

Add the co-host setter immediately after:

```objc
- (void)setIsHostCameraLocked:(BOOL)isHostCameraLocked {
    if (_isHostCameraLocked == isHostCameraLocked) return;
    _isHostCameraLocked = isHostCameraLocked;
    self.cameraLockedBadge.hidden = !isHostCameraLocked;
}

- (void)setIsCoHost:(BOOL)isCoHost {
    if (_isCoHost == isCoHost) return;
    _isCoHost = isCoHost;
    self.coHostBadge.hidden = !isCoHost;
}
```

- [ ] **Step 6: Add "Make Co-Host" / "Remove Co-Host" items to `showModerationMenu:`**

Find in `showModerationMenu:` the "Remove from Meeting" item:

```objc
    NSMenuItem *removeItem = [NSMenuItem new];
    removeItem.title = @"Remove from Meeting";
    removeItem.representedObject = @{ @"action": @"remove", @"identity": self.participantIdentity };
    removeItem.target = self;
    removeItem.action = @selector(handleMenuAction:);
    [menu addItem:removeItem];
```

Add the co-host items immediately BEFORE the remove item:

```objc
    [menu addItem:[NSMenuItem separatorItem]];
    // Co-host promotion (only shown to host/co-host — the layout manager caller
    // is responsible for not calling showModerationMenu: for non-moderators)
    if (self.isCoHost) {
        NSMenuItem *removeCoHostItem = [NSMenuItem new];
        removeCoHostItem.title = @"Remove Co-Host";
        removeCoHostItem.representedObject = @{ @"action": @"removeCoHost", @"identity": self.participantIdentity };
        removeCoHostItem.target = self;
        removeCoHostItem.action = @selector(handleMenuAction:);
        [menu addItem:removeCoHostItem];
    } else {
        NSMenuItem *makeCoHostItem = [NSMenuItem new];
        makeCoHostItem.title = @"Make Co-Host";
        makeCoHostItem.representedObject = @{ @"action": @"makeCoHost", @"identity": self.participantIdentity };
        makeCoHostItem.target = self;
        makeCoHostItem.action = @selector(handleMenuAction:);
        [menu addItem:makeCoHostItem];
    }

    NSMenuItem *removeItem = [NSMenuItem new];
    removeItem.title = @"Remove from Meeting";
    removeItem.representedObject = @{ @"action": @"remove", @"identity": self.participantIdentity };
    removeItem.target = self;
    removeItem.action = @selector(handleMenuAction:);
    [menu addItem:removeItem];
```

- [ ] **Step 7: Add `setIsCoHost:forParticipant:` to the layout manager**

Find `setHostCameraLocked:forParticipant:`:

```objc
- (void)setHostCameraLocked:(BOOL)locked forParticipant:(NSString *)identity {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoTileView *tile = self.tileViews[identity];
        if (tile) {
            tile.isHostCameraLocked = locked;
            tile.isCameraMuted = locked;
        }
    });
}
```

Add the co-host manager method immediately after it:

```objc
- (void)setHostCameraLocked:(BOOL)locked forParticipant:(NSString *)identity {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoTileView *tile = self.tileViews[identity];
        if (tile) {
            tile.isHostCameraLocked = locked;
            tile.isCameraMuted = locked;
        }
    });
}

- (void)setIsCoHost:(BOOL)isCoHost forParticipant:(NSString *)identity {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoTileView *tile = self.tileViews[identity];
        if (tile) {
            tile.isCoHost = isCoHost;
        }
    });
}
```

- [ ] **Step 8: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9: Commit**

```bash
git add inter/UI/Views/InterRemoteVideoLayoutManager.h inter/UI/Views/InterRemoteVideoLayoutManager.m
git commit -m "feat(cohost): add isCoHost tile badge and Make Co-Host tile menu items"
```

---

### Task 2: Wire `makeCoHost`/`removeCoHost` tile actions in `AppDelegate.m`

**Files:**
- Modify: `inter/App/AppDelegate.m`

- [ ] **Step 1: Add `makeCoHost` and `removeCoHost` cases**

Find in `handleTileModerationAction:` the `remove` action case:

```objc
    } else if ([actionType isEqualToString:@"remove"]) {
```

Add the two new cases immediately BEFORE it:

```objc
    } else if ([actionType isEqualToString:@"makeCoHost"]) {
        __weak typeof(self) weakSelf = self;
        [self.moderationController promoteParticipantWithIdentity:participantIdentity
                                                           toRole:InterParticipantRoleCoHost
                                                       completion:^(BOOL success, NSError *error) {
            if (success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.normalRemoteLayout setIsCoHost:YES forParticipant:participantIdentity];
                });
            } else {
                NSLog(@"[Moderation] makeCoHost failed for %@: %@", participantIdentity, error.localizedDescription);
            }
        }];

    } else if ([actionType isEqualToString:@"removeCoHost"]) {
        __weak typeof(self) weakSelf = self;
        [self.moderationController promoteParticipantWithIdentity:participantIdentity
                                                           toRole:InterParticipantRoleParticipant
                                                       completion:^(BOOL success, NSError *error) {
            if (success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.normalRemoteLayout setIsCoHost:NO forParticipant:participantIdentity];
                });
            } else {
                NSLog(@"[Moderation] removeCoHost failed for %@: %@", participantIdentity, error.localizedDescription);
            }
        }];

    } else if ([actionType isEqualToString:@"remove"]) {
```

- [ ] **Step 2: Update `moderationController:participantRoleChanged:` to sync tile badge**

Find:

```objc
- (void)moderationController:(InterModerationController *)controller
       participantRoleChanged:(NSString *)identity
                      newRole:(NSString *)roleString {
```

Inside this method, add co-host tile sync. After any existing role-change handling, add:

```objc
    // Sync the co-host crown badge on the remote tile
    BOOL nowCoHost = [roleString isEqualToString:@"coHost"];
    [self.normalRemoteLayout setIsCoHost:nowCoHost forParticipant:identity];
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "feat(cohost): wire makeCoHost/removeCoHost tile actions in AppDelegate"
```

---

### Task 3: End-to-end smoke test

- [ ] **Test A: Make Co-Host**

1. Host sees Participant 2's tile.
2. Host clicks `···` on the tile → menu shows "Make Co-Host".
3. Host clicks "Make Co-Host".
4. `/room/promote` is called with `newRole: "coHost"`.
5. All clients receive `roleChanged` DataChannel signal.
6. Participant 2's tile shows 👑 badge.
7. Next time host opens Participant 2's tile menu, it shows "Remove Co-Host" (not "Make Co-Host").

- [ ] **Test B: Remove Co-Host**

1. Host clicks `···` on Participant 2 (who is co-host) → menu shows "Remove Co-Host".
2. Host clicks "Remove Co-Host".
3. `/room/promote` is called with `newRole: "participant"`.
4. 👑 badge disappears from Participant 2's tile.
5. Tile menu reverts to "Make Co-Host".

- [ ] **Test C: Role change from another host**

1. Two hosts are in the meeting (Host A and Co-Host B).
2. Host A promotes Participant 3 to co-host via DataChannel signal.
3. Co-Host B's client receives `roleChanged` signal → `moderationController:participantRoleChanged:` fires → `setIsCoHost:YES` called → 👑 badge appears.
