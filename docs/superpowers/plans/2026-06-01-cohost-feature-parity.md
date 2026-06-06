# Co-Host Feature Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give co-hosts full parity with the host for moderation, recording, chat export, and rename — while enforcing the host-only constraints (lobby toggle, local recording permission, cloud recording attribution).

**Architecture:** All new signals use the existing `InterControlSignal.extraData` dict to carry payloads; no struct changes needed. The server-side recording endpoint is extended to look up the host's `userId` via the existing room-user binding when the caller is a co-host. Client-side UI gating moves from `isHost` boolean checks to `InterPermissionMatrix` permission lookups so that mid-meeting role promotion automatically takes effect.

**Tech Stack:** macOS ObjC+Swift (Xcode scheme `inter`, destination `platform=macOS,arch=arm64`), Node.js/Express token server, Redis (ioredis), PostgreSQL.

---

## Build command (use after every task)

```bash
xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

---

## File Map

| File | Change |
|---|---|
| `inter/Networking/InterChatMessage.swift` | Add signal cases 45, 46 |
| `inter/Networking/InterChatController.swift` | Route 2 new signals to ModerationController |
| `inter/Networking/InterFeatureGate.h` | Add `InterFeatureChatExport` enum case |
| `inter/Networking/InterFeatureGate.m` | Tier/name/upsell entries for `InterFeatureChatExport` |
| `inter/Networking/InterModerationController.swift` | 2 new public methods, 2 new delegate methods, signal handlers, chat-disable moderator bypass |
| `inter/UI/Views/InterChatPanel.h` | Add `setExportButtonHidden:` declaration |
| `inter/UI/Views/InterChatPanel.m` | Implement `setExportButtonHidden:`; hide button by default |
| `inter/UI/Views/InterLobbyPanel.h` | Add `setLobbyToggleEnabled:` declaration |
| `inter/UI/Views/InterLobbyPanel.m` | Implement `setLobbyToggleEnabled:` |
| `inter/UI/Views/InterPreMeetingPanel.h` | Add `allowCoHostLocalRecording` to `InterPreMeetingSettings` |
| `inter/UI/Views/InterPreMeetingPanel.m` | UserDefaults key, toggle UI, collect/load/copy |
| `inter/UI/Views/InterRemoteVideoLayoutManager.m` | Add "Rename…" tile context menu item |
| `inter/App/AppDelegate.m` | 7 targeted changes (recording btn, buttons, role-change, chat export, chat-disable msg, rename handler, co-host local recording) |
| `token-server/index.js` | Co-host cloud recording attribution to host |

---

## Task 1 — Add signal enum cases

**Files:**
- Modify: `inter/Networking/InterChatMessage.swift`

- [ ] **Step 1: Open `InterChatMessage.swift` and find the last enum case**

The current last case is `approveMicUnlock = 44`. Append two new cases immediately after it (before any closing brace of the enum):

```swift
    /// Host/co-host renamed a participant's session display name.
    /// targetIdentity = the renamed participant. extraData["newDisplayName"] = new name.
    /// Session-only — not persisted.
    case renameParticipant = 45

    /// Host broadcast whether co-hosts may record locally to their own machine.
    /// extraData["allowed"] = "1" (permitted) or "0" (denied). Default: denied.
    case allowCoHostLocalRecording = 46
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add inter/Networking/InterChatMessage.swift
git commit -m "feat(signals): add renameParticipant(45) and allowCoHostLocalRecording(46)"
```

---

## Task 2 — Route new signals through InterChatController

**Files:**
- Modify: `inter/Networking/InterChatController.swift` (around line 591)

- [ ] **Step 1: Find and extend the moderation signal routing case block**

The existing block ends with `.requestMicUnlock, .approveMicUnlock:`. Add the two new types:

Old (exact text to replace):
```swift
             .requestMicUnlock, .approveMicUnlock:
```

New:
```swift
             .requestMicUnlock, .approveMicUnlock,
             .renameParticipant, .allowCoHostLocalRecording:
```

- [ ] **Step 2: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add inter/Networking/InterChatController.swift
git commit -m "feat(signals): route renameParticipant + allowCoHostLocalRecording to ModerationController"
```

---

## Task 3 — Add InterFeatureChatExport to the feature gate

**Files:**
- Modify: `inter/Networking/InterFeatureGate.h`
- Modify: `inter/Networking/InterFeatureGate.m`

- [ ] **Step 1: Add enum case to `InterFeatureGate.h`**

Find `// ── Add future features below this line ──────────────────────────────` and add before it:

```objc
    /// Chat transcript export — host/co-host can save the chat log.
    /// Minimum tier: pro
    InterFeatureChatExport,
```

- [ ] **Step 2: Add tier mapping to `InterFeatureGate.m`**

In the `tierRequirements` NSDictionary (where `InterFeatureCloudRecording: @1` is), add:

```objc
        @(InterFeatureChatExport):          @1,  // pro
```

- [ ] **Step 3: Add display name to `InterFeatureGate.m`**

In the `displayNames` NSDictionary, add:

```objc
        @(InterFeatureChatExport):          @"Chat Export",
```

- [ ] **Step 4: Add minimum tier string to `InterFeatureGate.m`**

In the `minimumTiers` NSDictionary, add:

```objc
        @(InterFeatureChatExport):          @"pro",
```

- [ ] **Step 5: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add inter/Networking/InterFeatureGate.h inter/Networking/InterFeatureGate.m
git commit -m "feat(gate): add InterFeatureChatExport at pro tier"
```

---

## Task 4 — InterChatPanel: add setExportButtonHidden: and hide by default

**Files:**
- Modify: `inter/UI/Views/InterChatPanel.h`
- Modify: `inter/UI/Views/InterChatPanel.m`

- [ ] **Step 1: Add public declaration to `InterChatPanel.h`**

After the `- (void)setChatInputEnabled:(BOOL)enabled;` declaration, add:

```objc
/// Show or hide the export/save-transcript button.
/// Hidden by default; revealed only for host/co-host on pro+ tier.
- (void)setExportButtonHidden:(BOOL)hidden;
```

- [ ] **Step 2: Hide the export button by default in `InterChatPanel.m` init**

Find (around line 131):
```objc
    [headerBar addSubview:self.exportButton];
```

Replace with:
```objc
    self.exportButton.hidden = YES;  // revealed by host/co-host on pro+ tier
    [headerBar addSubview:self.exportButton];
```

- [ ] **Step 3: Implement `setExportButtonHidden:` in `InterChatPanel.m`**

After the `setChatInputEnabled:` implementation, add:

```objc
- (void)setExportButtonHidden:(BOOL)hidden {
    self.exportButton.hidden = hidden;
}
```

- [ ] **Step 4: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add inter/UI/Views/InterChatPanel.h inter/UI/Views/InterChatPanel.m
git commit -m "feat(chat): add setExportButtonHidden: — hidden by default, shown only for pro host/co-host"
```

---

## Task 5 — InterLobbyPanel: add setLobbyToggleEnabled:

**Files:**
- Modify: `inter/UI/Views/InterLobbyPanel.h`
- Modify: `inter/UI/Views/InterLobbyPanel.m`

- [ ] **Step 1: Add public declaration to `InterLobbyPanel.h`**

After `@property (nonatomic, assign) BOOL lobbyEnabled;`, add:

```objc
/// Enable or disable the lobby on/off checkbox.
/// Pass NO for co-hosts: they can admit/deny participants but cannot toggle the waiting room.
- (void)setLobbyToggleEnabled:(BOOL)enabled;
```

- [ ] **Step 2: Implement in `InterLobbyPanel.m`**

After `- (void)setLobbyEnabled:(BOOL)lobbyEnabled { ... }`, add:

```objc
- (void)setLobbyToggleEnabled:(BOOL)enabled {
    _lobbyToggle.enabled = enabled;
}
```

- [ ] **Step 3: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add inter/UI/Views/InterLobbyPanel.h inter/UI/Views/InterLobbyPanel.m
git commit -m "feat(lobby): setLobbyToggleEnabled: — co-hosts admit/deny only, host controls lobby on/off"
```

---

## Task 6 — InterPreMeetingSettings: add allowCoHostLocalRecording

**Files:**
- Modify: `inter/UI/Views/InterPreMeetingPanel.h`
- Modify: `inter/UI/Views/InterPreMeetingPanel.m`

- [ ] **Step 1: Add property to `InterPreMeetingSettings` in `InterPreMeetingPanel.h`**

After `@property (nonatomic, assign) BOOL autoTranscript;`, add:

```objc
/// Allow co-hosts to record locally to their own machine (disabled by default; pro-gated; host controls).
@property (nonatomic, assign) BOOL allowCoHostLocalRecording;
```

- [ ] **Step 2: Add UserDefaults key constant in `InterPreMeetingPanel.m`**

Find where other `kUD*` constants are defined (e.g. `static NSString * const kUDAutoRecord = ...`) and add:

```objc
static NSString * const kUDAllowCoHostLocalRecording = @"allowCoHostLocalRecording";
```

- [ ] **Step 3: Load from UserDefaults in `settingsWithDefaults`**

After `s.autoTranscript = [ud boolForKey:kUDAutoTranscript];`, add:

```objc
    s.allowCoHostLocalRecording = [ud boolForKey:kUDAllowCoHostLocalRecording];
```

- [ ] **Step 4: Save to UserDefaults in `saveToUserDefaults`**

After `[ud setBool:self.autoTranscript forKey:kUDAutoTranscript];`, add:

```objc
    [ud setBool:self.allowCoHostLocalRecording forKey:kUDAllowCoHostLocalRecording];
```

- [ ] **Step 5: Copy in NSCopying**

After `c.autoTranscript = self.autoTranscript;`, add:

```objc
    c.allowCoHostLocalRecording = self.allowCoHostLocalRecording;
```

- [ ] **Step 6: Add ivar in class extension in `InterPreMeetingPanel.m`**

After `NSButton *_autoTranscriptToggle;`, add:

```objc
    NSButton *_allowCoHostLocalRecordingToggle;
```

- [ ] **Step 7: Build the toggle row in the UI**

Find in `InterPreMeetingPanel.m`:
```objc
    _autoRecordToggle = [self _addToggleRowWithLabel:@"Auto-Record to Cloud" y:y inView:_contentView];
```

After this line, decrement y and add the new toggle (follow the existing `y -= rowH;` pattern used throughout the method):

```objc
    y -= rowH;
    _allowCoHostLocalRecordingToggle = [self _addToggleRowWithLabel:@"Allow Co-Host Local Recording" y:y inView:_contentView];
```

- [ ] **Step 8: Enforce pro tier**

Find the block that sets `_autoRecordToggle.enabled = _isPro;` and add after it:

```objc
    _allowCoHostLocalRecordingToggle.enabled = _isPro;
    if (!_isPro) {
        _allowCoHostLocalRecordingToggle.state = NSControlStateValueOff;
    }
```

- [ ] **Step 9: Load saved value into UI in `_loadSettings:` or `_applySettings:`**

Find `_autoRecordToggle.state = s.autoRecord ? NSControlStateValueOn : NSControlStateValueOff;` and after it add:

```objc
    _allowCoHostLocalRecordingToggle.state = s.allowCoHostLocalRecording ? NSControlStateValueOn : NSControlStateValueOff;
```

- [ ] **Step 10: Collect in `_collectSettings:`**

Find `s.autoRecord = (_autoRecordToggle.state == NSControlStateValueOn) && _isPro;` and after it add:

```objc
    s.allowCoHostLocalRecording = (_allowCoHostLocalRecordingToggle.state == NSControlStateValueOn) && _isPro;
```

- [ ] **Step 11: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 12: Commit**

```bash
git add inter/UI/Views/InterPreMeetingPanel.h inter/UI/Views/InterPreMeetingPanel.m
git commit -m "feat(pre-meeting): add allowCoHostLocalRecording setting (pro-gated, off by default)"
```

---

## Task 7 — InterModerationController: new signals, methods, and moderator chat bypass

**Files:**
- Modify: `inter/Networking/InterModerationController.swift`

This task has four parts: (A) add 2 stored properties, (B) add 2 public methods, (C) add 2 optional delegate methods to `InterModerationDelegate`, (D) update `handleControlSignal`.

- [ ] **Step 1 (A): Add `coHostLocalRecordingAllowed` stored property**

In the `// MARK: - Public Properties` section, after `@objc public private(set) dynamic var isChatDisabled: Bool = false`, add:

```swift
    /// Whether the host has enabled local recording for co-hosts in this session.
    /// Defaults to false; updated via `.allowCoHostLocalRecording` DataChannel signal.
    @objc public private(set) dynamic var coHostLocalRecordingAllowed: Bool = false
```

- [ ] **Step 2 (A): Reset it in `detach()`**

Find `isChatDisabled = false` in `detach()` and add after it:

```swift
        coHostLocalRecordingAllowed = false
```

- [ ] **Step 3 (B): Add `renameParticipant(identity:newDisplayName:)` public method**

After the `enableChat()` method block, add:

```swift
    /// Renames a participant's display name for this session only (host/co-host only).
    /// Broadcasts `.renameParticipant` to all participants; no server persistence.
    @objc public func renameParticipant(identity: String, newDisplayName: String) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else { return }
        guard !identity.isEmpty, !newDisplayName.isEmpty else { return }
        sendControlSignal(type: .renameParticipant,
                          targetIdentity: identity,
                          extraData: ["newDisplayName": newDisplayName])
    }

    /// Broadcasts whether co-hosts may record locally (host only).
    @objc public func setCoHostLocalRecordingAllowed(_ allowed: Bool) {
        guard localRole == .host else { return }
        coHostLocalRecordingAllowed = allowed
        sendControlSignal(type: .allowCoHostLocalRecording,
                          extraData: ["allowed": allowed ? "1" : "0"])
        delegate?.moderationControllerAllowCoHostLocalRecordingChanged?(self, allowed: allowed)
    }
```

- [ ] **Step 4 (C): Add 2 optional delegate methods to `InterModerationDelegate` protocol**

After the `moderationController(_:receivedScreenShareModeChange:)` optional method, add:

```swift
    /// A participant's session display name was changed.
    /// Received by all participants including the renamed one.
    @objc optional func moderationController(_ controller: InterModerationController,
                                             participantRenamed identity: String,
                                             newDisplayName: String)

    /// Host changed the "allow co-host local recording" setting.
    @objc optional func moderationControllerAllowCoHostLocalRecordingChanged(
        _ controller: InterModerationController, allowed: Bool)
```

- [ ] **Step 5 (D): Fix `.disableChat` in `handleControlSignal` to bypass moderators**

Find in `handleControlSignal`:
```swift
        case .disableChat:
            isChatDisabled = true
            delegate?.moderationController(self, chatDisabledStateChanged: true)
```

Replace with:
```swift
        case .disableChat:
            isChatDisabled = true
            // Moderators keep their chat input — only participants are blocked.
            let isModerator = InterPermissionMatrix.role(localRole, hasPermission: .canDisableChat)
            delegate?.moderationController(self, chatDisabledStateChanged: !isModerator)
```

- [ ] **Step 6 (D): Handle `.renameParticipant` in `handleControlSignal`**

After the `.screenshareModeChanged` case (or any convenient adjacent case), add:

```swift
        case .renameParticipant:
            if let target = signal.targetIdentity,
               let newName = signal.extraData?["newDisplayName"],
               !newName.isEmpty {
                delegate?.moderationController?(self, participantRenamed: target, newDisplayName: newName)
            }

        case .allowCoHostLocalRecording:
            let allowed = signal.extraData?["allowed"] == "1"
            coHostLocalRecordingAllowed = allowed
            delegate?.moderationControllerAllowCoHostLocalRecordingChanged?(self, allowed: allowed)
```

- [ ] **Step 7: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 8: Commit**

```bash
git add inter/Networking/InterModerationController.swift
git commit -m "feat(moderation): moderator chat bypass; renameParticipant + allowCoHostLocalRecording signals"
```

---

## Task 8 — InterRemoteVideoLayoutManager: add "Rename…" tile menu item

**Files:**
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.m`

- [ ] **Step 1: Find the final separator + "Remove from Meeting" block**

The tile context menu ends with this block (around line 335):

```objc
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *removeItem = [[NSMenuItem alloc] initWithTitle:@"Remove from Meeting"
```

Insert "Rename…" before that separator:

```objc
    addItem(@"Rename…", @"rename");
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *removeItem = [[NSMenuItem alloc] initWithTitle:@"Remove from Meeting"
```

So the complete replacement: find:
```objc
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *removeItem = [[NSMenuItem alloc] initWithTitle:@"Remove from Meeting"
                                                        action:@selector(moderationMenuItemClicked:)
                                                 keyEquivalent:@""];
```

Replace with:
```objc
    addItem(@"Rename…", @"rename");
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *removeItem = [[NSMenuItem alloc] initWithTitle:@"Remove from Meeting"
                                                        action:@selector(moderationMenuItemClicked:)
                                                 keyEquivalent:@""];
```

- [ ] **Step 2: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add inter/UI/Views/InterRemoteVideoLayoutManager.m
git commit -m "feat(tile-menu): add Rename… context menu item for host/co-host tiles"
```

---

## Task 9 — AppDelegate: recording button + queue/lobby/moderation buttons use permission checks

**Files:**
- Modify: `inter/App/AppDelegate.m`

Three sub-changes, all in `setupNormalControlPanel` and the role-change delegate.

- [ ] **Step 9a: Recording button — use canStartRecording instead of isHost**

Find (around line 2318):
```objc
    // [Phase 10] Record toggle — visible to host/co-host only
    [self.normalControlPanel setRecordingButtonHidden:!self.roomController.isHost];
```

Replace with:
```objc
    // [Phase 10] Record toggle — visible to anyone with canStartRecording (host + co-host)
    BOOL canRecord = [InterPermissionMatrix
                      role:self.moderationController.localRole
                      hasPermission:(InterPermission)InterPermissionCanStartRecording];
    [self.normalControlPanel setRecordingButtonHidden:!canRecord];
```

- [ ] **Step 9b: Speaker queue button — canModerate instead of isHost**

Find (around line 2368):
```objc
    // Only show the speaker queue button to the host / co-host
    if (self.roomController.isHost) {
```

Replace with:
```objc
    // Show speaker queue button to host and co-host
    BOOL canModerateUI = [InterPermissionMatrix
                          role:self.moderationController.localRole
                          hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    if (canModerateUI) {
```

- [ ] **Step 9c: Poll X offset — use canModerateUI instead of isHost**

Find immediately after the queue button closing brace:
```objc
    CGFloat pollX = self.roomController.isHost ? 520.0 : 420.0;
```

Replace with:
```objc
    CGFloat pollX = canModerateUI ? 520.0 : 420.0;
```

- [ ] **Step 9d: Lobby + moderation buttons — canModerateUI instead of isHost**

Find (around line 2396):
```objc
    // [Phase 9] Lobby & moderation buttons (host/co-host only)
    if (self.roomController.isHost) {
```

Replace with:
```objc
    // [Phase 9] Lobby & moderation buttons (host/co-host only)
    if (canModerateUI) {
```

- [ ] **Step 9e: Role-change handler — update recording button on mid-meeting promotion**

In `moderationController:participantRoleChanged:newRole:`, find the block that ends with:
```objc
        if (nowCoHostOrHost && self.normalControlPanel) {
            NSString *activeMode = self.roomController.activeSharingPermissions ?: @"everyone";
            [self.normalControlPanel setScreenSharePermissionMode:activeMode];
        }
```

After this closing `}`, add:
```objc
        // Update recording button visibility when role changes mid-meeting.
        if (self.normalControlPanel) {
            BOOL canRecordNow = [InterPermissionMatrix
                                 role:controller.localRole
                                 hasPermission:(InterPermission)InterPermissionCanStartRecording];
            [self.normalControlPanel setRecordingButtonHidden:!canRecordNow];
        }
        // Create lobby + moderation buttons if co-host was promoted mid-meeting
        // (those buttons are created during setupNormalControlPanel which ran before promotion).
        if (nowCoHostOrHost && !self.normalModerationButton) {
            NSView *view = self.normalCallWindow.contentView;
            CGFloat modX = 610.0;
            self.normalLobbyToggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(modX, 40, 90, 42)];
            self.normalLobbyToggleButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
            [self.normalLobbyToggleButton setTitle:@"🚪 Lobby"];
            [self.normalLobbyToggleButton setTarget:self];
            [self.normalLobbyToggleButton setAction:@selector(toggleNormalLobbyPanel)];
            [view addSubview:self.normalLobbyToggleButton];

            self.normalModerationButton = [[NSButton alloc] initWithFrame:NSMakeRect(modX + 100, 40, 120, 42)];
            self.normalModerationButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
            [self.normalModerationButton setTitle:@"⚙️ Moderate"];
            [self.normalModerationButton setTarget:self];
            [self.normalModerationButton setAction:@selector(showModerationMenu:)];
            [view addSubview:self.normalModerationButton];
        }
```

- [ ] **Step 9f: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 9g: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "feat(cohost): recording btn + queue/lobby/moderation buttons gated on permissions not isHost"
```

---

## Task 10 — AppDelegate: chat export gating

**Files:**
- Modify: `inter/App/AppDelegate.m`

- [ ] **Step 1: Add `_updateChatExportVisibility` helper method**

Add this private method anywhere in the file (e.g. after `moderationDisableChat`):

```objc
- (void)_updateChatExportVisibility {
    if (!self.normalChatPanel) return;
    NSString *tier = self.roomController.tokenService.effectiveTier ?: @"free";
    BOOL tierOk = [InterFeatureGate isFeature:InterFeatureChatExport availableForTier:tier];
    BOOL canModerate = [InterPermissionMatrix
                        role:self.moderationController.localRole
                        hasPermission:(InterPermission)InterPermissionCanMuteOthers];
    [self.normalChatPanel setExportButtonHidden:!(tierOk && canModerate)];
}
```

- [ ] **Step 2: Call `_updateChatExportVisibility` at end of `applyMeetingSettingsAfterLaunch`**

Find `self.pendingMeetingSettings = nil;` at end of `applyMeetingSettingsAfterLaunch` and add before it:

```objc
    [self _updateChatExportVisibility];
```

- [ ] **Step 3: Call `_updateChatExportVisibility` in role-change handler**

In `moderationController:participantRoleChanged:newRole:`, inside the `if (localId.length > 0 && [identity isEqualToString:localId] ...)` block, after the moderation button creation code added in Task 9e, add:

```objc
        [self _updateChatExportVisibility];
```

- [ ] **Step 4: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "feat(chat-export): gate export button on pro tier + host/co-host role"
```

---

## Task 11 — AppDelegate: suppress chat-disabled system message for moderators

**Files:**
- Modify: `inter/App/AppDelegate.m`

The `moderationController:chatDisabledStateChanged:` delegate now receives `isDisabled=NO` for moderators (from Task 7), so their input is never disabled. However the old code still shows the "Chat has been disabled" banner for everyone. Fix that.

- [ ] **Step 1: Update the delegate method**

Find:
```objc
- (void)moderationController:(InterModerationController *)controller chatDisabledStateChanged:(BOOL)isDisabled {
#pragma unused(controller)
    if (self.normalChatPanel) {
        [self.normalChatPanel setChatInputEnabled:!isDisabled];
        if (isDisabled) {
            [self.normalChatPanel displaySystemMessage:@"Chat has been disabled by the host."];
        } else {
            [self.normalChatPanel displaySystemMessage:@"Chat has been re-enabled."];
        }
    }
}
```

Replace with:
```objc
- (void)moderationController:(InterModerationController *)controller chatDisabledStateChanged:(BOOL)isDisabled {
#pragma unused(controller)
    if (!self.normalChatPanel) return;
    [self.normalChatPanel setChatInputEnabled:!isDisabled];
    if (isDisabled) {
        // Moderators (host/co-host) keep their input — don't show the disable banner to them.
        BOOL isModerator = [InterPermissionMatrix
                            role:self.moderationController.localRole
                            hasPermission:(InterPermission)InterPermissionCanDisableChat];
        if (!isModerator) {
            [self.normalChatPanel displaySystemMessage:@"Chat has been disabled by the host."];
        }
    } else {
        [self.normalChatPanel displaySystemMessage:@"Chat has been re-enabled."];
    }
}
```

- [ ] **Step 2: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "feat(chat): suppress 'chat disabled' banner for host/co-host moderators"
```

---

## Task 12 — AppDelegate: lobby toggle restricted to host

**Files:**
- Modify: `inter/App/AppDelegate.m`

- [ ] **Step 1: In `toggleNormalLobbyPanel`, disable the toggle for co-hosts**

Find in `toggleNormalLobbyPanel`:
```objc
        self.normalLobbyPanel = [[InterLobbyPanel alloc] initWithFrame:NSMakeRect(0, 0, panelWidth, panelHeight)];
        self.normalLobbyPanel.delegate = self;
```

After `self.normalLobbyPanel.delegate = self;`, add:
```objc
        // Co-hosts can admit/deny but cannot toggle the waiting room on/off — host-only.
        [self.normalLobbyPanel setLobbyToggleEnabled:self.roomController.isHost];
```

- [ ] **Step 2: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "feat(lobby): co-hosts see lobby panel but cannot toggle waiting room on/off"
```

---

## Task 13 — AppDelegate: rename tile action + delegate

**Files:**
- Modify: `inter/App/AppDelegate.m`

- [ ] **Step 1: Add `"rename"` branch to the `moderationActionHandler` block**

Find the last branch in the tile action handler (the `removeCoHost` branch, around line 3958):
```objc
    } else if ([actionType isEqualToString:@"removeCoHost"]) {
        [self.moderationController promoteParticipantWithIdentity:participantIdentity
                                                           toRole:InterParticipantRoleParticipant
                                                       completion:^(BOOL success, NSError *error) {
            if (!success) { NSLog(@"[Moderation] removeCoHost failed for %@: %@", participantIdentity, error.localizedDescription); }
            // Badge update is handled by moderationController:participantRoleChanged: via DataChannel echo.
        }];
    }
```

Replace the closing `}` with:
```objc
    } else if ([actionType isEqualToString:@"removeCoHost"]) {
        [self.moderationController promoteParticipantWithIdentity:participantIdentity
                                                           toRole:InterParticipantRoleParticipant
                                                       completion:^(BOOL success, NSError *error) {
            if (!success) { NSLog(@"[Moderation] removeCoHost failed for %@: %@", participantIdentity, error.localizedDescription); }
            // Badge update is handled by moderationController:participantRoleChanged: via DataChannel echo.
        }];
    } else if ([actionType isEqualToString:@"rename"]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Rename Participant";
        alert.informativeText = @"Enter a new display name for this session:";
        NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 22)];
        nameField.placeholderString = @"New display name";
        alert.accessoryView = nameField;
        [alert addButtonWithTitle:@"Rename"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSString *newName = nameField.stringValue;
            if (newName.length > 0) {
                [self.moderationController renameParticipant:participantIdentity
                                            newDisplayName:newName];
            }
        }
    }
```

- [ ] **Step 2: Implement the rename delegate method**

After the `moderationController:participantRoleChanged:newRole:` implementation, add:

```objc
- (void)moderationController:(InterModerationController *)controller
           participantRenamed:(NSString *)identity
              newDisplayName:(NSString *)newDisplayName {
#pragma unused(controller)
    // Update the tile label for everyone's view.
    if (self.normalRemoteLayout) {
        [self.normalRemoteLayout registerDisplayName:newDisplayName forParticipant:identity];
    }
    // If the local user was renamed, show a banner so they know.
    NSString *localId = self.roomController.localParticipantIdentity;
    if (self.normalChatPanel && [identity isEqualToString:localId]) {
        [self.normalChatPanel displaySystemMessage:
            [NSString stringWithFormat:@"Your display name was changed to \"%@\".", newDisplayName]];
    }
}
```

- [ ] **Step 3: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "feat(rename): tile 'Rename…' broadcasts session-only name change to all participants"
```

---

## Task 14 — AppDelegate: co-host local recording flag

**Files:**
- Modify: `inter/App/AppDelegate.m`

- [ ] **Step 1: Add `coHostLocalRecordingAllowed` property**

In the `@interface AppDelegate ()` private extension, add:

```objc
@property (nonatomic, assign) BOOL coHostLocalRecordingAllowed;
```

- [ ] **Step 2: Broadcast the setting at call start**

In `applyMeetingSettingsAfterLaunch`, find `self.pendingMeetingSettings = nil;`. Just before that line, add:

```objc
    // Broadcast co-host local recording permission to all participants.
    if (isHost && self.pendingMeetingSettings) {
        BOOL allow = self.pendingMeetingSettings.allowCoHostLocalRecording;
        self.coHostLocalRecordingAllowed = allow;
        [self.moderationController setCoHostLocalRecordingAllowed:allow];
    }
```

- [ ] **Step 3: Receive flag change via delegate**

After the `moderationController:participantRenamed:newDisplayName:` method added in Task 13, add:

```objc
- (void)moderationControllerAllowCoHostLocalRecordingChanged:(InterModerationController *)controller
                                                       allowed:(BOOL)allowed {
#pragma unused(controller)
    self.coHostLocalRecordingAllowed = allowed;
}
```

- [ ] **Step 4: Gate local recording in `handleRecordToggle` for co-hosts**

In `handleRecordToggle`, find the free-tier local recording path:
```objc
        // Free/ungated tiers: local recording only (no cloud option)
        if (![InterFeatureGate isFeature:InterFeatureCloudRecording availableForTier:tier]) {
            [coordinator startLocalRecordingWithScreenShareSource:self.normalSurfaceShareController
                                                       subscriber:self.roomController.subscriber
                                              localMediaController:self.normalMediaController
                                                         userTier:tier];
            return;
        }
```

Replace with:
```objc
        // Free/ungated tiers: local recording only (no cloud option)
        if (![InterFeatureGate isFeature:InterFeatureCloudRecording availableForTier:tier]) {
            // Co-hosts require explicit host permission for local recording.
            if (self.moderationController.localRole == InterParticipantRoleCoHost
                && !self.coHostLocalRecordingAllowed) {
                NSAlert *blocked = [[NSAlert alloc] init];
                blocked.messageText = @"Local Recording Not Permitted";
                blocked.informativeText = @"The meeting host has not enabled local recording for co-hosts.";
                [blocked addButtonWithTitle:@"OK"];
                [blocked runModal];
                return;
            }
            [coordinator startLocalRecordingWithScreenShareSource:self.normalSurfaceShareController
                                                       subscriber:self.roomController.subscriber
                                              localMediaController:self.normalMediaController
                                                         userTier:tier];
            return;
        }
```

Also gate the "Record Locally" button in the pro-tier mode-selection alert. Find:
```objc
        if (response == NSAlertFirstButtonReturn) {
            // Local recording
            [coordinator startLocalRecordingWithScreenShareSource:self.normalSurfaceShareController
```

Replace with:
```objc
        if (response == NSAlertFirstButtonReturn) {
            // Local recording — check co-host permission
            if (self.moderationController.localRole == InterParticipantRoleCoHost
                && !self.coHostLocalRecordingAllowed) {
                NSAlert *blocked = [[NSAlert alloc] init];
                blocked.messageText = @"Local Recording Not Permitted";
                blocked.informativeText = @"The meeting host has not enabled local recording for co-hosts.";
                [blocked addButtonWithTitle:@"OK"];
                [blocked runModal];
                return;
            }
            [coordinator startLocalRecordingWithScreenShareSource:self.normalSurfaceShareController
```

- [ ] **Step 5: Add "Allow Co-Host Local Recording" toggle in moderation menu**

In `showModerationMenu:`, after the "Disable/Enable Chat" section (find `[menu addItem:[NSMenuItem separatorItem]];` before "Lock/Unlock Meeting"), add before that separator:

```objc
    // Co-host local recording toggle (host-only)
    if (self.roomController.isHost) {
        NSString *coHostRecordTitle = self.coHostLocalRecordingAllowed
            ? @"🎥 Disallow Co-Host Local Recording"
            : @"🎥 Allow Co-Host Local Recording";
        [menu addItemWithTitle:coHostRecordTitle
                        action:@selector(moderationToggleCoHostLocalRecording)
                 keyEquivalent:@""];
    }
```

- [ ] **Step 6: Add the toggle action method**

After `moderationEnableChat`:

```objc
- (void)moderationToggleCoHostLocalRecording {
    BOOL newValue = !self.coHostLocalRecordingAllowed;
    self.coHostLocalRecordingAllowed = newValue;
    [self.moderationController setCoHostLocalRecordingAllowed:newValue];
}
```

- [ ] **Step 7: Build**

Expected: `BUILD SUCCEEDED`

- [ ] **Step 8: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "feat(recording): co-host local recording gated on host's allowCoHostLocalRecording setting"
```

---

## Task 15 — Token server: attribute co-host cloud recordings to the host

**Files:**
- Modify: `token-server/index.js`

When a co-host calls `POST /room/record/start`, the `recording_sessions` row must be attributed to the **host's** `user_id` so that it appears in the host's library and counts against the host's quota.

- [ ] **Step 1: Replace the quota-check block with an attribution + quota block**

Find this exact block in `app.post('/room/record/start', ...)`:
```js
  // Check quota using the room's creation-time tier (same grace period logic)
  const quotaCheck = await checkRecordingQuota(req.user.userId, roomTier);
  if (!quotaCheck.allowed) {
    return res.status(403).json({ error: quotaCheck.reason, quota: quotaCheck });
  }
  if (quotaCheck.remainingMinutes < estimatedMinutes) {
    return res.status(403).json({
      error: `Estimated duration (${estimatedMinutes}m) exceeds remaining quota (${quotaCheck.remainingMinutes}m)`,
      quota: quotaCheck,
    });
  }
```

Replace with:
```js
  // Attribute the recording to the host's account.
  // If a co-host initiated the recording, resolve the host's userId and run
  // quota checks against the host — so recordings land in the host's library.
  let recordingUserId = req.user.userId;
  const isCallerHost = roomData.hostIdentity === callerIdentity;
  if (!isCallerHost) {
    // validateModerator above allows 'host', 'co-host', and 'interviewer'.
    // Only co-hosts may attribute recordings to the host's account.
    // Interviewers and any future moderator-tier roles must not reach this path.
    if (validation.role !== 'co-host') {
      return res.status(403).json({ error: 'Only a co-host may start a recording attributed to the host account.' });
    }
    const hostBoundId = await redis.hget(roomUserBindingKey(code), roomData.hostIdentity);
    if (!hostBoundId) {
      return res.status(403).json({ error: 'Host has not joined this room yet; recording cannot be started.' });
    }
    const hostNumericId = parseInt(hostBoundId, 10);
    if (!Number.isFinite(hostNumericId) || hostNumericId <= 0) {
      return res.status(500).json({ error: 'Corrupt host binding in room data.' });
    }
    const { rows: hostRows } = await db.query('SELECT tier FROM users WHERE id = $1', [hostNumericId]);
    if (!hostRows.length) return res.status(403).json({ error: 'Host account not found.' });
    const hostTier = hostRows[0].tier || 'free';
    const TIER_LEVELS_CHECK = { free: 0, pro: 1, hiring: 2 };
    if ((TIER_LEVELS_CHECK[hostTier] ?? 0) < (TIER_LEVELS_CHECK['pro'] ?? 0)) {
      return res.status(403).json({ error: "Host's account does not support cloud recording.", requiredTier: 'pro' });
    }
    recordingUserId = hostNumericId;
    const hostQuotaCheck = await checkRecordingQuota(recordingUserId, hostTier);
    if (!hostQuotaCheck.allowed) {
      return res.status(403).json({ error: hostQuotaCheck.reason, quota: hostQuotaCheck });
    }
    if (hostQuotaCheck.remainingMinutes < estimatedMinutes) {
      return res.status(403).json({
        error: `Estimated duration (${estimatedMinutes}m) exceeds host's remaining quota (${hostQuotaCheck.remainingMinutes}m)`,
        quota: hostQuotaCheck,
      });
    }
  } else {
    // Caller is the host — use normal quota check
    const quotaCheck = await checkRecordingQuota(req.user.userId, roomTier);
    if (!quotaCheck.allowed) {
      return res.status(403).json({ error: quotaCheck.reason, quota: quotaCheck });
    }
    if (quotaCheck.remainingMinutes < estimatedMinutes) {
      return res.status(403).json({
        error: `Estimated duration (${estimatedMinutes}m) exceeds remaining quota (${quotaCheck.remainingMinutes}m)`,
        quota: quotaCheck,
      });
    }
  }
```

- [ ] **Step 2: Update the `recording_sessions` INSERT to use `recordingUserId`**

Find:
```js
        [req.user.userId, roomData.roomName, code, egressInfo.egressId, recordingMode, validatedTier === 'free']
```

Replace with:
```js
        [recordingUserId, roomData.roomName, code, egressInfo.egressId, recordingMode, validatedTier === 'free']
```

- [ ] **Step 3: Syntax check**

```bash
cd /Users/aman_01/Documents/inter/token-server && node --check index.js && echo "SYNTAX OK"
```

Expected: `SYNTAX OK`

- [ ] **Step 4: Commit**

```bash
git add token-server/index.js
git commit -m "feat(recording): co-host cloud recordings attributed to host's account + quota"
```

---

## Task 16 — Final verification

- [ ] **Full client build**

```bash
xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Token server syntax**

```bash
cd /Users/aman_01/Documents/inter/token-server && node --check index.js && echo "SYNTAX OK"
```

Expected: `SYNTAX OK`

- [ ] **Smoke-test checklist** (manual)

| Scenario | Expected |
|---|---|
| Host joins → recording button visible | ✅ |
| Co-host joins → recording button visible | ✅ |
| Participant joins → recording button hidden | ✅ |
| Co-host joins → Lobby + Moderate buttons visible | ✅ |
| Co-host opens Lobby panel → "Enable Waiting Room" checkbox disabled | ✅ |
| Host disables chat → co-host input still active, no banner | ✅ |
| Host disables chat → participant input disabled, banner shown | ✅ |
| Host (pro) → export button visible in chat panel | ✅ |
| Co-host (pro room) → export button visible | ✅ |
| Participant → export button hidden | ✅ |
| Host renames participant via tile menu → all tiles update | ✅ |
| Renamed participant → sees "Your display name was changed to…" banner | ✅ |
| Host toggles "Allow Co-Host Local Recording" in moderation menu → co-host can now start local recording | ✅ |
| Co-host tries local recording without permission → blocked alert | ✅ |
| Co-host starts cloud recording → session attributed to host in DB | ✅ |
| Mid-meeting: participant promoted to co-host → recording + lobby + moderate buttons appear | ✅ |

- [ ] **Tag the release**

```bash
git tag cohost-feature-parity-v1
```
