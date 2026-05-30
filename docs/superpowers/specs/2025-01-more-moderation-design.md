# More Moderation Tools — Design Document

**Date:** 2025-01  
**Scope:** Camera Mute (Global + Per-Participant), Kick/Remove + Ban, Screen Share Gaps, Co-Host UI Wiring  
**Stack:** macOS ObjC/Swift + LiveKit 2.12.1 + Node.js/Express/Redis/Socket.IO

---

## 0. Document Status

| Status | Notes |
|---|---|
| ✅ Context explored | Full codebase audit done |
| ✅ Clarifying questions answered | See §0.1 |
| 🔴 Not yet implemented | All four features |

### 0.1 Decisions from Clarifying Questions

| Question | Decision |
|---|---|
| Camera mute transport | DataChannel-only (like mic mute). No LiveKit `mutePublishedTrack`. Client enforces flags. Server stores state in Redis + rejects self-unmute-camera when `hostCameraMuted=true`. |
| Global lock lift behavior | Lock lifts; cameras stay off until each participant manually re-enables. No auto-resume. |
| Ban set storage | Redis-backed (`room:{code}:banned` SET with TTL = room TTL). NOT in-memory. |
| Screen share permissions | NOT changing the permission model. Keep existing "Everyone / Ask Permission / No One" pre-meeting setting. Fix three specific gaps (request flooding, mid-meeting toggle, reconnect queue persistence). |
| Co-Host implementation | The backend and signal handling are already done. Only the tile menu "Make Co-Host" item is missing — add it. |

---

## 1. Compatibility Analysis of `more_moderation.md`

### What the doc proposes vs. what already exists

| Feature | Doc says | Current reality |
|---|---|---|
| Camera Mute Global | New Socket.IO event | Nothing exists — no server-side or DataChannel camera lock |
| Camera Mute Per-Participant | New Socket.IO event | **Partial.** `askToUnmuteCamera` (polite ask) + `/room/mute?trackSource=camera` (LiveKit server mute) exist, but no DataChannel-enforced client-side camera mute with host-flag model |
| Kick + Ban | In-memory `bannedUsers` Map | **Partial.** `/room/remove` + `participantRemoved` DataChannel signal work. No ban set, no rejoin guard. |
| Screen Share control | Role-based capability table | The "Everyone / Ask Permission / No One" setting exists pre-meeting. Three runtime gaps described below. |
| Role Assignment Co-Host | New `assign-role` socket handler | **Fully implemented.** `/room/promote` + `roleChanged` DataChannel signal + client role update all work. Tile menu "Make Co-Host" item is missing. |
| CameraStateManager (new class) | Proposed | **Rejected.** Use the existing `InterMediaWiringController` + `InterModerationController` pattern. |
| 8-tier role hierarchy | attendee, speaker, interpreter added | **Partially relevant.** Our 5-tier system (host/co-host/panelist/presenter/participant) covers all real use cases. Adding `speaker`, `attendee`, `interpreter` is deferred — not needed for this release. |
| Socket.IO as primary transport | All events use `socket.on(...)` | **Architectural mismatch.** Our architecture uses REST for server-authoritative actions + LiveKit DataChannel for participant-to-participant signals. Socket.IO is used only for state sync (just added for mic state). We follow the existing pattern throughout. |
| `lastUpdatedAt` timestamp conflict | ISO 8601 timestamp on every event | **Replaced by `sequenceNumber`.** We already use a sequence number model from the mic state refactor. Camera state will use the same. |

---

## 2. Feature A — Camera Mute (Per-Participant + Global)

### 2.1 Architecture

Follows the **exact same 3-flag model** as mic mute. The "4th flag" (`speakPermissionGranted` equivalent for camera) is not needed — cameras have no "raise hand to re-enable" flow.

```
isCameraOff          — participant's own camera toggle (self-controlled)
hostCameraMuted      — host has force-muted this participant's camera (per-participant)
globalCameraLockActive — host has locked all cameras (global)
```

**Priority logic (`deriveCameraButton`):**

```
Priority 1: globalCameraLockActive = YES
  → button shows "Camera Locked", is disabled
  → if camera track is currently on: pause it

Priority 2: hostCameraMuted = YES
  → button shows "Camera Off (Host)", is disabled
  → if camera track is currently on: pause it

Priority 3 (normal — participant controls freely):
  → isCameraOff = NO → button title "Turn Camera Off"
  → isCameraOff = YES → button title "Turn Camera On"
```

When **global lock is lifted**: clear `globalCameraLockActive`. Fall to Priority 3. Since `isCameraOff` is still `YES` (camera hasn't auto-resumed), button shows "Turn Camera On". Participant must manually re-enable. **No auto-resume.**

When **per-participant lock is lifted**: clear `hostCameraMuted`. Same: falls to Priority 3, camera stays off until participant acts.

### 2.2 New DataChannel Signal Types

Add to `InterControlSignalType` in `inter/Networking/InterChatMessage.swift`:

```swift
case requestMuteCameraOne  = 36  // host → force-mute one participant's camera
case requestMuteCameraAll  = 37  // host → global camera lock (all cameras off)
case liftCameraLockOne     = 38  // host → lift per-participant camera mute
case liftCameraLockAll     = 39  // host → lift global camera lock
```

### 2.3 Client-Side Changes

#### `inter/App/InterMediaWiringController.h`

New readonly properties:
```objc
@property (nonatomic, readonly) BOOL isCameraOff;
@property (nonatomic, readonly) BOOL hostCameraMuted;
@property (nonatomic, readonly) BOOL globalCameraLockActive;
@property (nonatomic, readonly) NSInteger cameraStateSequenceNumber;
```

New public methods:
```objc
- (void)applyCameraHostMute;        // sets hostCameraMuted=YES → deriveCameraButton
- (void)applyCameraGlobalLock;      // sets globalCameraLockActive=YES → deriveCameraButton
- (void)applyCameraHostUnmute;      // clears hostCameraMuted → deriveCameraButton
- (void)applyCameraGlobalLockLift;  // clears globalCameraLockActive → deriveCameraButton
- (void)twoPhaseToggleCamera;       // participant-initiated toggle (blocked when locked)
```

#### `inter/App/InterMediaWiringController.m`

- Add readwrite class-extension properties for the three flags + `cameraStateSequenceNumber`
- Implement `applyCameraHostMute`, `applyCameraGlobalLock`, `applyCameraHostUnmute`, `applyCameraGlobalLockLift` (each increments `cameraStateSequenceNumber`)
- Implement `deriveCameraButton` following the priority logic above
- Implement `twoPhaseToggleCamera`: if `hostCameraMuted || globalCameraLockActive` → early return (blocked); otherwise toggle camera track + update `isCameraOff` + call `deriveCameraButton`
- Wire camera track pause/unpause through existing `InterLiveKitPublisher` (same as mic: `publisher.muteCameraTrackWithCompletion:` / `publisher.unmuteCameraTrackWithCompletion:`)

#### `inter/Networking/InterModerationController.swift`

New host-side methods:
```swift
@objc public func muteCameraOne(identity: String, completion: @escaping (Bool, NSError?) -> Void)
// → POST /room/mute-camera-one → then sendControlSignal(.requestMuteCameraOne, targetIdentity: identity)

@objc public func muteCameraAll(completion: @escaping (Bool, Int, NSError?) -> Void)
// → POST /room/mute-camera-all → then sendControlSignal(.requestMuteCameraAll)

@objc public func liftCameraLockOne(identity: String, completion: @escaping (Bool, NSError?) -> Void)
// → POST /room/lift-camera-lock-one → then sendControlSignal(.liftCameraLockOne, targetIdentity: identity)

@objc public func liftCameraLockAll(completion: @escaping (Bool, Int, NSError?) -> Void)
// → POST /room/lift-camera-lock-all → then sendControlSignal(.liftCameraLockAll)
```

New incoming signal handlers (in the existing `switch signal.type` block):
```swift
case .requestMuteCameraOne:
    if targetIsLocal {
        delegate?.moderationControllerCameraHostMuted(self)
    }

case .requestMuteCameraAll:
    if targetIsLocal {
        delegate?.moderationControllerCameraGlobalLockActivated(self)
    }
    // If host/co-host receives it: update tile states
    delegate?.moderationControllerReceivedCameraLockAll(self)

case .liftCameraLockOne:
    if targetIsLocal {
        delegate?.moderationControllerCameraHostUnmuted(self)
    }

case .liftCameraLockAll:
    if targetIsLocal {
        delegate?.moderationControllerCameraGlobalLockLifted(self)
    }
    delegate?.moderationControllerReceivedCameraLockLiftAll(self)
```

New delegate methods (add to `InterModerationControllerDelegate`):
```objc
- (void)moderationControllerCameraHostMuted:(InterModerationController *)controller;
- (void)moderationControllerCameraHostUnmuted:(InterModerationController *)controller;
- (void)moderationControllerCameraGlobalLockActivated:(InterModerationController *)controller;
- (void)moderationControllerCameraGlobalLockLifted:(InterModerationController *)controller;
- (void)moderationControllerReceivedCameraLockAll:(InterModerationController *)controller;
- (void)moderationControllerReceivedCameraLockLiftAll:(InterModerationController *)controller;
```

#### `inter/App/AppDelegate.m`

Delegate implementations:
```objc
- (void)moderationControllerCameraHostMuted:(InterModerationController *)controller {
    // Self was camera-muted by host
    [self.normalMediaWiring applyCameraHostMute];
    // Show toast: "Your camera was turned off by the host"
    [self showToast:@"Your camera was turned off by the host"];
}

- (void)moderationControllerCameraGlobalLockActivated:(InterModerationController *)controller {
    [self.normalMediaWiring applyCameraGlobalLock];
    [self showToast:@"Host turned off cameras for everyone"];
}

- (void)moderationControllerCameraHostUnmuted:(InterModerationController *)controller {
    [self.normalMediaWiring applyCameraHostUnmute];
}

- (void)moderationControllerCameraGlobalLockLifted:(InterModerationController *)controller {
    [self.normalMediaWiring applyCameraGlobalLockLift];
    [self showToast:@"Camera lock lifted — tap to re-enable your camera"];
}

- (void)moderationControllerReceivedCameraLockAll:(InterModerationController *)controller {
    // HOST/CO-HOST path: update all remote tiles
    NSArray *participants = [self.roomController remoteParticipantList];
    for (NSDictionary *p in participants) {
        NSString *identity = p[@"identity"];
        if (identity.length > 0) {
            [self.normalRemoteLayout setCameraLocked:YES forParticipant:identity];
        }
    }
}
```

Update `handleTileModerationAction:` for `muteCamera`:
```objc
// BEFORE (calls LiveKit server-side mute — NOT what we want):
[self.moderationController muteParticipant:identity trackSource:@"camera" completion:...];

// AFTER (DataChannel-only, following mic mute pattern):
[self.moderationController muteCameraOneWithIdentity:participantIdentity
                                          completion:^(BOOL success, NSError *error) {
    if (success) {
        [weakSelf.normalRemoteLayout setCameraLocked:YES forParticipant:participantIdentity];
    }
}];
```

Update `handleTileModerationAction:` for `unmuteCamera`:
```objc
// BEFORE (only sends polite ask):
[self.moderationController askToUnmuteCameraWithIdentity:participantIdentity];

// AFTER (lifts host mute, then asks politely):
[self.moderationController liftCameraLockOneWithIdentity:participantIdentity
                                              completion:^(BOOL success, NSError *error) {
    if (success) {
        [weakSelf.normalRemoteLayout setCameraLocked:NO forParticipant:participantIdentity];
        // Then send the polite ask:
        [weakSelf.moderationController askToUnmuteCameraWithIdentity:participantIdentity];
    }
}];
```

New panel button: "Lock All Cameras" / "Lift Camera Lock" (in the same section as "Mute All"). When `moderationController.isCameraAllLocked`:
- Button title: "Lift Camera Lock"
- Action: `moderationLiftCameraLockAll`
- Else title: "Lock All Cameras"
- Action: `moderationLockCameraAll`

#### `inter/UI/Views/InterRemoteVideoLayoutManager.m` (tile)

Add tile properties and methods:
```objc
// New properties on InterRemoteVideoTileView:
@property (nonatomic, assign) BOOL isCameraLocked; // host-muted camera (per-participant or global)

// New camera lock badge (🎥 with slash, or just dimmed overlay)
@property (nonatomic, strong) NSTextField *cameraLockedBadge;
```

New public methods on `InterRemoteVideoLayoutManager`:
```objc
- (void)setCameraLocked:(BOOL)locked forParticipant:(NSString *)identity;
```

### 2.4 Server-Side Changes

#### Redis Key Helpers

```javascript
function cameraStateKey(code, identity) { return `room:${code}:camerastate:${identity}`; }
function globalCameraLockKey(code) { return `room:${code}:global-camera-lock`; }
```

#### New REST Endpoints

```javascript
// POST /room/mute-camera-one — Host force-mutes one participant's camera
// Body: { roomCode, callerIdentity, targetIdentity }
// → Validates role, sets Redis cameraStateKey { hostCameraMuted: 1 }
// → Returns { success: true }
// NOTE: DataChannel signal to participant is sent by caller (client-side, after success)

// POST /room/lift-camera-lock-one
// Body: { roomCode, callerIdentity, targetIdentity }
// → Clears cameraStateKey.hostCameraMuted

// POST /room/mute-camera-all
// Body: { roomCode, callerIdentity }
// → Sets globalCameraLockKey = 1, sets cameraStateKey.globalCameraLockActive = 1 for all known participants
// → Returns { success: true, lockedCount: N }

// POST /room/lift-camera-lock-all
// Body: { roomCode, callerIdentity }
// → Clears globalCameraLockKey, clears cameraStateKey.globalCameraLockActive for all participants
```

#### Socket.IO: Camera-On Request Guard

```javascript
socket.on('participant:camera-on', async ({ roomCode, identity }) => {
  const code = roomCode.toUpperCase();
  const camState = await redis.hgetall(cameraStateKey(code, identity));
  if (camState?.hostCameraMuted === '1') {
    // Reject: host has muted this participant's camera
    socket.emit('camera-on-rejected', { reason: 'host_muted' });
    return;
  }
  const globalLock = await redis.get(globalCameraLockKey(code));
  if (globalLock === '1') {
    socket.emit('camera-on-rejected', { reason: 'global_lock' });
    return;
  }
  // Allow — broadcast to room that this participant's camera is on
  io.to(roomCode).emit('participant:camera-state-changed', { identity, cameraOn: true });
});
```

#### Reconnect State Recovery

In the existing `client:join-room` Socket.IO handler, after loading mic state, also load camera state:
```javascript
const camState = await redis.hgetall(cameraStateKey(code, socket.identity));
const globalLock = await redis.get(globalCameraLockKey(code));
socket.emit('camera-state-snapshot', {
  hostCameraMuted: camState?.hostCameraMuted === '1',
  globalCameraLockActive: globalLock === '1',
});
```

Client handles `camera-state-snapshot` → calls `applyCameraHostMute` / `applyCameraGlobalLock` as needed (analogous to mic state reconnect reconciliation).

---

## 3. Feature B — Kick / Remove + Ban Set

### 3.1 What Already Works

- **Client → Host**: Tile menu "Remove from Meeting" → `handleTileModerationAction:@"remove"` → `[moderationController removeParticipantWithIdentity:]`
- **Server**: `POST /room/remove` → validates role hierarchy → `roomService.removeParticipant` (LiveKit) → `redis.srem` → `redis.hdel`
- **Signal**: After REST success → `sendControlSignal(.participantRemoved, targetIdentity: identity)`
- **Target client**: `moderationControllerLocalParticipantWasRemoved:` → shows alert "Removed from meeting" → `requestExitCurrentMode()`

### 3.2 What Needs to Change

#### Server (`token-server/index.js`)

**1. Add Redis ban key helper:**
```javascript
function roomBannedKey(code) { return `room:${code}:banned`; }
```

**2. Update `/room/remove` to add to banned set:**
```javascript
// After successful removeParticipant:
await redis.sadd(roomBannedKey(code), targetIdentity);
await redis.expire(roomBannedKey(code), ROOM_CODE_EXPIRY_SECONDS);
```

**3. Add ban check to `/room/join` (early guard, before lobby check):**
```javascript
// After getRoomData validation, before lobby check:
const isBanned = await redis.sismember(roomBannedKey(code), identity);
if (isBanned) {
  console.log(`[audit] Join blocked (banned): code=${code} identity=${identity}`);
  return res.status(403).json({ error: 'You have been removed from this meeting.' });
}
```

**4. Add ban check to Socket.IO `client:join-room`:**
```javascript
const isBanned = await redis.sismember(roomBannedKey(code), identity);
if (isBanned) {
  socket.emit('join-rejected', { reason: 'banned_by_host' });
  socket.disconnect(true);
  return;
}
```

#### Client (`AppDelegate.m`)

Update the alert text in `moderationControllerLocalParticipantWasRemoved:`:
```objc
alert.messageText = @"Removed from Meeting";
alert.informativeText = @"You have been removed from this meeting by the host. You may not rejoin.";
```

The rest of the kick flow (exits to home, LiveKit disconnects) already works correctly. The ban enforcement is purely server-side — the client simply gets a 403 from `/room/join` if they try to rejoin.

### 3.3 Edge Cases

| Case | Behavior |
|---|---|
| Target disconnects before `participantRemoved` signal arrives | Signal is lost. But ban set is already written to Redis. Rejoin attempt is blocked. ✅ |
| Host removes self accidentally | Server rejects (can't remove self — role hierarchy check: `targetRole >= callerRole` blocks same-tier). |
| Co-host tries to remove host | Server rejects (host role > co-host role). |
| Server restarts during meeting | Ban set persists in Redis. Rejoins blocked. ✅ |
| Room expires | Redis TTL expires entire `room:{code}:*` keyspace including ban set. ✅ |

---

## 4. Feature C — Screen Share Gaps (3 Fixes)

### 4.1 Current State

The existing "Everyone / Ask Permission / No One" setting is configured at room creation and stored in Redis as `room:{code}:screenShareMode`. The `requestScreenShare` / `approveScreenShare` / `denyScreenShare` DataChannel signals (types 32/33/34) already exist. 

**Current bug**: When in "Ask Permission" mode, each `requestScreenShare` signal fires an individual `NSAlert` popup on the host. 50 simultaneous requests = 50 popups.

### 4.2 Gap 1 — Request Flooding → Request Queue Panel

**Design:**

- Requests are stacked into a **new `InterScreenShareQueuePanel`** (modeled on the existing `InterSpeakerQueuePanel` pattern)
- Host sees a badge/count ("Screen Share Requests (N)") on the moderation panel button
- Panel shows a FIFO list of requestors. Each row: display name + "Approve" + "Deny" buttons
- Top of panel: "Approve All" / "Deny All" buttons
- Panel is ordered by request time (already true since DataChannel signals arrive in order)
- After requesting: participant sees "Waiting for host approval..." status in the control area. NOT a popup. NOT re-requestable until denied or approved.
- If host denies: participant sees a dismissible inline notification "Host denied your screen share request"

**No new DataChannel signal needed:**
`denyScreenShare = 34` already means "host denied your screen share request" (it is targeted at a specific participant via `targetIdentity`). It is NOT used to end an active share — it fires only when the host denies a pending request. We reuse it.

**State tracking on host side:**

```objc
// In AppDelegate.m:
@property (nonatomic, strong) NSMutableArray *screenShareRequestQueue; // ordered by arrival
@property (nonatomic, strong) NSMutableSet *pendingScreenShareRequesters; // identity set

// New delegate method replaces NSAlert:
- (void)moderationController:(InterModerationController *)controller
      screenShareRequested:(NSString *)identity
               displayName:(NSString *)displayName {
    if ([self.pendingScreenShareRequesters containsObject:identity]) {
        return; // Duplicate — ignore
    }
    [self.pendingScreenShareRequesters addObject:identity];
    [self.screenShareRequestQueue addObject:@{@"identity": identity, @"displayName": displayName}];
    [self.screenShareQueuePanel setRequests:self.screenShareRequestQueue];
    // Update badge count on moderation panel
    self.normalModerationPanel.screenShareRequestCount = self.screenShareRequestQueue.count;
}
```

**Redis persistence for Gap 3 (see §4.4):**

The `pendingScreenShareRequesters` set is mirrored to Redis as a sorted set:
```
room:{code}:screenshare-queue → ZADD with Unix timestamp score, member = identity
```

**`InterScreenShareQueuePanel`:**
- Based on `InterSpeakerQueuePanel` architecture
- Each entry: display name label + "Approve" button + "Deny" button
- Header: "Screen Share Requests (N)" + "Approve All" + "Deny All"
- Approve action: `[moderationController approveScreenShareWithIdentity:identity]` → sends `approveScreenShare` signal → removes from queue panel + Redis sorted set
- Deny action: `[moderationController denyScreenShareWithIdentity:identity]` → sends existing `denyScreenShare` (type 34) signal → removes from queue

### 4.3 Gap 2 — Mid-Meeting Screen Share Mode Toggle

**Design:**

Add a segmented control to the moderation panel (same row as "Mute All / Unmute All"):
```
Screen Share: [Everyone | Ask Permission | No One]
```

**Server: New REST endpoint**
```javascript
// POST /room/screen-share-mode
// Body: { roomCode, callerIdentity, mode: 'everyone' | 'ask' | 'none' }
// → Validates host/co-host
// → Sets redis.hset(roomKey(code), 'screenShareMode', mode)
// → Broadcasts socket event 'room:screenshare-mode-changed' to all in room
// → If mode = 'none': sends denyScreenShare DataChannel to all active non-host sharers
// → If mode = 'everyone': clears screenshare-queue, approves implicitly
```

**Server: Mode-change side effects:**

```javascript
if (mode === 'none') {
  // Clear the request queue
  await redis.del(screenShareQueueKey(code));
  // Broadcast 'screenshare-mode-changed' — clients will disable the screen share button
  io.to(roomCode).emit('room:screenshare-mode-changed', { mode: 'none' });
}
if (mode === 'everyone') {
  // Clear the request queue (everyone implicitly approved)
  await redis.del(screenShareQueueKey(code));
  io.to(roomCode).emit('room:screenshare-mode-changed', { mode: 'everyone' });
}
if (mode === 'ask') {
  io.to(roomCode).emit('room:screenshare-mode-changed', { mode: 'ask' });
}
```

**Client: `InterModerationController` addition:**
```swift
@objc public private(set) dynamic var screenShareMode: String = "ask" // "everyone" | "ask" | "none"
```

**Client: Screen share button state:**
- `screenShareMode = "none"` → screen share button disabled (except host/co-host)
- `screenShareMode = "ask"` → button triggers request flow (existing)
- `screenShareMode = "everyone"` → button starts sharing immediately (existing)

**Host receives `room:screenshare-mode-changed`:**
- Updates `moderationController.screenShareMode`
- Clears `screenShareRequestQueue` if mode → "everyone" or "none"
- Updates the queue panel badge

**Stopping active shares on "No One":**
- Server does NOT automatically stop active screen shares (would be disruptive)
- Instead: server broadcasts the mode change; clients check `screenShareMode` and if currently sharing + mode is "none" + not host/co-host → stop sharing automatically
- `InterSurfaceShareController` checks `moderationController.screenShareMode` before allowing new shares

### 4.4 Gap 3 — Queue Persistence on Reconnect

**Redis state:**
```javascript
function screenShareQueueKey(code) { return `room:${code}:screenshare-queue`; }
// Stored as Redis ZSET: score = Unix timestamp (request time), member = identity

function screenShareQueueNamesKey(code) { return `room:${code}:screenshare-queue:names`; }
// Stored as Redis HASH: identity → displayName
```

**On host reconnect (`client:join-room`):**
```javascript
// Load screen share queue:
const queueEntries = await redis.zrangebyscore(screenShareQueueKey(code), '-inf', '+inf', 'WITHSCORES');
const queueNames = await redis.hgetall(screenShareQueueNamesKey(code)) || {};
// Build ordered list: [{identity, displayName, requestedAt}]
socket.emit('screenshare-queue-snapshot', { queue: buildQueueSnapshot(queueEntries, queueNames) });
```

**On request arrival, write to Redis:**
```javascript
socket.on('participant:request-screen-share', async ({ roomCode, identity, displayName }) => {
  const code = roomCode.toUpperCase();
  const mode = await redis.hget(roomKey(code), 'screenShareMode');
  if (mode === 'none') { /* reject immediately */ return; }
  if (mode === 'everyone') { /* approve immediately */ return; }
  // mode === 'ask': add to Redis queue
  await redis.zadd(screenShareQueueKey(code), Date.now(), identity);
  await redis.hset(screenShareQueueNamesKey(code), identity, displayName);
  await redis.expire(screenShareQueueKey(code), ROOM_CODE_EXPIRY_SECONDS);
  await redis.expire(screenShareQueueNamesKey(code), ROOM_CODE_EXPIRY_SECONDS);
  // Forward DataChannel requestScreenShare signal to host (already done by existing flow)
});
```

---

## 5. Feature D — Co-Host Role Assignment (UI Wiring Only)

### 5.1 Current Status

The following are **fully implemented and verified**:
- Server: `POST /room/promote` endpoint validates role + updates Redis + issues new JWT
- DataChannel signal: `roleChanged = 20` with `extraData["newRole"]`
- `InterModerationController.promoteParticipant(identity:toRole:completion:)` — exists
- `AppDelegate.moderationController(_:participantRoleChanged:)` — updates `isHostMode` flag on remote layout

### 5.2 What Is Missing

The tile moderation menu (`showModerationMenu:`) has no "Make Co-Host" item. Only "Allow Sharing" (which promotes to Presenter).

### 5.3 Change

**`inter/UI/Views/InterRemoteVideoLayoutManager.m`**

Add a new `isCoHost` property to `InterRemoteVideoTileView` to know whether the current participant is already a co-host (so we can offer "Remove Co-Host" instead of "Make Co-Host"):

```objc
// Add to showModerationMenu: (after "Allow Sharing" separator):
[menu addItem:[NSMenuItem separatorItem]];
if (self.isCoHost) {
    addItem(@"Remove Co-Host", @"removeCoHost");
} else {
    addItem(@"Make Co-Host", @"makeCoHost");
}
```

**`inter/App/AppDelegate.m`**

In `handleTileModerationAction:`:
```objc
} else if ([actionType isEqualToString:@"makeCoHost"]) {
    [self.moderationController promoteParticipantWithIdentity:participantIdentity
                                                       toRole:InterParticipantRoleCoHost
                                                   completion:^(BOOL success, NSError *error) {
        if (success) {
            [weakSelf.normalRemoteLayout setIsCoHost:YES forParticipant:participantIdentity];
        } else {
            NSLog(@"[Moderation] makeCoHost failed for %@: %@", participantIdentity, error.localizedDescription);
        }
    }];

} else if ([actionType isEqualToString:@"removeCoHost"]) {
    [self.moderationController promoteParticipantWithIdentity:participantIdentity
                                                       toRole:InterParticipantRoleParticipant
                                                   completion:^(BOOL success, NSError *error) {
        if (success) {
            [weakSelf.normalRemoteLayout setIsCoHost:NO forParticipant:participantIdentity];
        } else {
            NSLog(@"[Moderation] removeCoHost failed for %@: %@", participantIdentity, error.localizedDescription);
        }
    }];
}
```

**Receiving role-changed signal (already implemented):**

`moderationController(_:participantRoleChanged:newRole:)` in `AppDelegate.m` already refreshes `normalRemoteLayout.isHostMode`. We just need to also call `setIsCoHost:` when the new role is "co-host" and the target is a remote participant.

---

## 6. Conflict Resolution Rules

| Rule | Applies to |
|---|---|
| **Host action always wins.** A host camera lock cannot be overridden by a co-host lift. Server checks `callerRole >= targetLockerRole`. | Camera lock |
| **Per-participant wins over global for lift.** Host can lift one participant's camera mute without lifting the global lock. | Camera mute |
| **Last-writer-wins within same tier.** If two co-hosts mute the same camera simultaneously, last REST call to arrive wins (Redis SET is atomic). | Camera, mic |
| **Ban is irrevocable within session.** Once banned, no role change or promote can unban. Ban clears only when room TTL expires. | Kick/ban |
| **Reconnect gets server state.** Server is single source of truth. Client always reconciles from server snapshot on reconnect. | All features |

---

## 7. Edge Cases

| Scenario | Resolution |
|---|---|
| Host camera-mutes participant who is actively sharing screen | Camera mute applies to camera track only. Screen share track is unaffected. |
| Participant's camera track fails to pause locally | `applyCameraHostMute` still sets the flag. `deriveCameraButton` disables the button. The track may still broadcast briefly but will be re-attempted. |
| Host lifts global camera lock but `hostCameraMuted` also set for participant | Priority 2 (`hostCameraMuted`) still applies. Participant's camera stays locked. |
| Co-host kicks participant, host undoes it | No undo mechanism — ban is permanent for session. Design decision: host should not kick carelessly. |
| `requestScreenShare` signal arrives while host is offline/reconnecting | Redis queue preserves it. Host sees it on reconnect via `screenshare-queue-snapshot`. |
| Host changes screen share mode to "everyone" while 20 requests are pending | Server clears the queue, broadcasts mode-changed. All 20 requestors see their "Waiting..." state clear automatically. |
| Participant with `isCameraOff=YES` (self-muted) receives global camera lock | Flags set: `globalCameraLockActive=YES`. Button shows "Camera Locked". On lock lift: button shows "Turn Camera On" (not "Turn Camera Off") because `isCameraOff` was already `YES`. Correct behavior. |

---

## 8. Test Plan

### 8.1 Unit Tests (XCTest — new file `InterCameraWiringTests.swift`)

```swift
// test_GlobalLock_BlocksParticipantToggle
// test_HostMute_BlocksParticipantToggle
// test_GlobalLockLift_CameraStaysOff
// test_HostMuteLifted_CameraStaysOff
// test_Priority1_GlobalLockOverridesHostMute (both set → "Camera Locked" shown)
// test_DeriveButton_NormalState_MirrorsSelfMute
```

### 8.2 Unit Tests (XCTest — new file `InterBanSetTests.swift`)

```swift
// test_KickedParticipant_CannotRejoin (server returns 403)
// test_NonKickedParticipant_CanRejoin
// test_BanPersistsAcrossServerReconnect (Redis-backed)
```

### 8.3 Integration Tests (token-server Jest or manual)

```
1. Camera mute per-participant: host mutes participant → participant camera off, button disabled → host lifts → participant manually re-enables ✅
2. Camera global lock: host locks all → all cameras off → host lifts → cameras stay off → participants re-enable one by one ✅
3. Screen share queue: 5 participants request simultaneously → host sees queue panel → approves 2, denies 2, approves all remaining ✅
4. Screen share mode toggle: host switches "Ask Permission → Everyone" → queue cleared → participants can share immediately ✅
5. Screen share mode toggle: host switches "Ask Permission → No One" → button disabled for participants ✅
6. Kick + ban: host kicks participant → participant sees alert → tries to rejoin → blocked by 403 ✅
7. Co-host promotion: host promotes → co-host sees moderation menus → can mute participants ✅
```

---

## 9. Implementation Order

This is the recommended sequence for the writing-plans phase:

1. **Feature B (Ban Set)** — smallest change, highest security value. Server-only (3 lines in `/room/remove`, 4 lines in `/room/join`). Zero client changes except alert text.
2. **Feature A part 1 (Camera Mute Per-Participant)** — analogous to mic mute, well-understood pattern. Unblocks tile menu for camera.
3. **Feature A part 2 (Camera Mute Global)** — builds on part 1.
4. **Feature D (Co-Host tile menu)** — trivial, 20 lines of ObjC.
5. **Feature C Gap 1 (Screen Share request queue)** — most complex new UI.
6. **Feature C Gap 2 (Mid-meeting mode toggle)** — new REST endpoint + Socket.IO event.
7. **Feature C Gap 3 (Queue persistence)** — Redis sorted set for queue.

---

## 10. Files Changed Summary

| File | Change Type |
|---|---|
| `inter/Networking/InterChatMessage.swift` | ADD 4 new signal types (36–39) |
| `inter/App/InterMediaWiringController.h` | ADD 4 properties + 5 methods |
| `inter/App/InterMediaWiringController.m` | ADD flag logic, `deriveCameraButton`, `twoPhaseToggleCamera` |
| `inter/Networking/InterModerationController.swift` | ADD 4 host camera methods, 4 signal handlers, `screenShareMode` property |
| `inter/App/AppDelegate.m` | ADD 6 delegate methods, update 2 tile action cases, add Co-Host tile actions, fix alert text |
| `inter/UI/Views/InterRemoteVideoLayoutManager.m` | ADD `cameraLockedBadge`, `isCameraLocked`, `isCoHost`, tile menu items "Make Co-Host"/"Remove Co-Host" |
| `inter/UI/Views/InterScreenShareQueuePanel.h/.m` | CREATE new view (based on InterSpeakerQueuePanel) |
| `token-server/index.js` | ADD 4 camera REST endpoints, ban guard in `/room/join` + `/room/remove`, Socket.IO camera-on guard, screen share queue handlers |
| `interTests/InterCameraWiringTests.swift` | CREATE new test file |

---

*Generated by brainstorming + context exploration. Approved design — ready for `writing-plans` phase.*
