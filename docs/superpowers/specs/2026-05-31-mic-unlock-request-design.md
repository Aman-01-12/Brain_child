# Mic Unlock Request Flow — Design Spec

**Date:** 2026-05-31  
**Project:** inter (macOS, Obj-C + Swift, LiveKit)  
**Feature:** Unified mic unlock request queue for per-tile mutes and Mute All  
**Status:** Approved for implementation planning

---

## 1. Summary

Replace the current "✋ Raise Hand to Speak" mic-unlock mechanism with a unified
"Ask to Unmute" request queue that mirrors the existing camera unlock flow exactly.
Both per-tile host mutes (`requestMuteOne`) and Mute All (`requestMuteAll`) funnel
to the same participant-side button and the same host-side queue panel.

Raise-hand stays in the product as a general intent signal ("I have a question")
but is completely decoupled from mic state. `allowToSpeak` now only lowers the
raise-hand badge — it no longer touches mic unlock.

Per-tile mic mutes are persisted to Redis so they survive host reconnects, matching
the existing camera-lock persistence model.

---

## 2. What Changes vs What Stays

### Changes

| Layer | Before | After |
|---|---|---|
| DataChannel signals | `requestMuteOne`, `requestMuteAll` | + `requestMicUnlock = 43`, `approveMicUnlock = 44` |
| Participant state flags | `hostMuted`, `globalMuteActive`, `speakPermissionGranted` (mic role) | + `micUnlockRequestPending`, `micUnlockApproved`, `micWasUnmutedWhileApproved`; `speakPermissionGranted` no longer drives mic button |
| `deriveMicButton` | 4-priority chain including raise-hand path | Rewritten — see §4 |
| `applyAllowToSpeak` | Sets `speakPermissionGranted=YES`, clears `hostMuted`, calls `deriveMicButton` | Lowers hand badge only — does NOT touch any mic flag or call `deriveMicButton` |
| Per-tile mic mute persistence | In-memory `hostMutedParticipants` NSMutableSet, lost on reconnect | Redis SET `room:${code}:mic-locked` |
| Host UI | `InterSpeakerQueuePanel` with "Allow" + "Dismiss" for raise-hand | + new `InterMicUnlockQueuePanel` with "Approve" + "Dismiss" |
| Token server | `/room/mute` — no Redis write | + writes identity to `room:${code}:mic-locked` SET |

### Stays Untouched

- `InterSpeakerQueuePanel` — raise-hand queue, "Allow" sends `allowToSpeak`, fully intact
- `requestMuteAll` / `applyRemoteMicMute` / `globalMuteActive` — set exactly as today
- `requestMuteOne` / `applyRemoteMicMuteOne` / `hostMuted` — set exactly as today
- Tile menu "Mute Mic" / "Unmute Mic" toggle — no change
- `stateSequenceNumber` guard on `InterMediaWiringController` — used for stale-approval discard
- `muteOnJoin` join-token mechanism — unchanged

---

## 3. New DataChannel Signals

Add to `InterControlSignalType` in `InterChatMessage.swift`:

```swift
case requestMicUnlock  = 43   // locked participant → host
case approveMicUnlock  = 44   // host → participant (temporary unlock)
```

Route in `InterChatController.swift` Phase 9 switch:
```swift
case .requestMicUnlock, .approveMicUnlock:
    guard signal.senderIdentity != localIdentity else { return }
    moderationController?.handleControlSignal(signal)
```

---

## 4. Participant Mic State Machine

### New flags on `InterMediaWiringController`

```objc
@property (nonatomic, assign, readwrite) BOOL micUnlockRequestPending;
@property (nonatomic, assign, readwrite) BOOL micUnlockApproved;
@property (nonatomic, assign) BOOL micWasUnmutedWhileApproved;
```

Public readonly declarations in `InterMediaWiringController.h`:
```objc
@property (nonatomic, assign, readonly) BOOL micUnlockRequestPending;
@property (nonatomic, assign, readonly) BOOL micUnlockApproved;
```

### New `deriveMicButton` (replaces the 4-priority chain)

```objc
- (void)deriveMicButton {
    BOOL restricted = self.hostMuted || self.globalMuteActive;

    if (restricted) {
        if (self.micUnlockApproved) {
            if (self.micWasUnmutedWhileApproved && self.isMicNetworkMuted) {
                // Revoke: user unmuted then re-muted while approved
                self.micUnlockApproved = NO;
                self.micWasUnmutedWhileApproved = NO;
                [self.controlPanel setMicrophoneEnabled:YES];
                [self.controlPanel setMicrophoneButtonTitle:@"Ask to Unmute"];
            } else {
                // Approved — allow normal toggle
                [self.controlPanel setMicrophoneEnabled:YES];
                [self.controlPanel setMicrophoneButtonTitle:
                    self.isMicNetworkMuted ? @"Turn Mic On" : @"Turn Mic Off"];
            }
        } else if (self.micUnlockRequestPending) {
            [self.controlPanel setMicrophoneEnabled:NO];
            [self.controlPanel setMicrophoneButtonTitle:@"Request Sent…"];
        } else {
            [self.controlPanel setMicrophoneEnabled:YES];
            [self.controlPanel setMicrophoneButtonTitle:@"Ask to Unmute"];
        }
    } else {
        // Lock lifted — clear all unlock-flow state
        self.micUnlockApproved = NO;
        self.micUnlockRequestPending = NO;
        self.micWasUnmutedWhileApproved = NO;
        [self.controlPanel setMicrophoneEnabled:!self.isMicNetworkMuted];
        // title: nil → button derives from enabled state
    }
}
```

### New public methods on `InterMediaWiringController`

```objc
- (void)applyMicUnlockRequestPending;      // sets pending=YES, calls deriveMicButton
- (void)applyMicUnlockApproved;            // sets approved=YES, pending=NO, wasUnmuted=NO, calls deriveMicButton
- (void)resetMicUnlockFlowState;           // clears all 3 flags, calls deriveMicButton — called on reconnect
```

### Updated `applyRemoteMicMuteOne`
At top: clear all 3 new flags before setting `hostMuted=YES`.

### Updated `applyRemoteMicMute` (Mute All)
At top: clear all 3 new flags before setting `globalMuteActive=YES`.

### Updated `applyUnmuteAll`
Clears `globalMuteActive`, `speakPermissionGranted` (existing). Does NOT clear `hostMuted` (§8.1 rule, unchanged). Does NOT clear the 3 new flags if `hostMuted` is still YES (tile mute persists).

### Updated `applyRemoteMicUnmute`
Clears `hostMuted` + all 3 new flags.

### `applyAllowToSpeak` — change
Remove: `self.speakPermissionGranted = YES`, `self.hostMuted = NO`, call to `deriveMicButton`.  
Keep: status text update, reconnect to `InterSpeakerQueuePanel` hand-lowering. This method now only lowers the visual hand indicator.

### `twoPhaseToggleMicrophone` guard (new)
```objc
if ((self.hostMuted || self.globalMuteActive) && !self.micUnlockApproved) {
    return; // AppDelegate button handler drives the request path
}
if (self.micUnlockApproved && !self.isMicNetworkMuted) {
    // About to mute while approved — track that user went mic-on at least once
    self.micWasUnmutedWhileApproved = YES;
}
```

---

## 5. AppDelegate Mic Button Handler

```objc
// Replaces the simple [wiring twoPhaseToggleMicrophone] call
if (wiring.hostMuted || wiring.globalMuteActive) {
    if (wiring.micUnlockApproved) {
        [wiring twoPhaseToggleMicrophone]; // guard bypassed — approved path
    } else if (!wiring.micUnlockRequestPending) {
        [wiring applyMicUnlockRequestPending];
        [self.moderationController requestMicUnlock];
    }
    return;
}
[wiring twoPhaseToggleMicrophone];
```

---

## 6. `InterModerationController` Changes

### New delegate protocol methods
```objc
@optional
- (void)moderationController:(InterModerationController *)controller
    receivedMicUnlockRequest:(NSString *)fromIdentity
                 displayName:(NSString *)displayName;
- (void)moderationControllerMicUnlockApproved:(InterModerationController *)controller;
```

### New send methods
```objc
@objc public func requestMicUnlock() {
    sendControlSignal(type: .requestMicUnlock)
}

@objc public func approveMicUnlock(identity: String) {
    guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else { return }
    sendControlSignal(type: .approveMicUnlock, targetIdentity: identity)
}
```

### New `_handleControlSignal` cases
```swift
case .requestMicUnlock:
    if !senderIsLocal {
        delegate?.moderationController?(self,
            receivedMicUnlockRequest: signal.senderIdentity ?? "",
            displayName: signal.senderName)
    }

case .approveMicUnlock:
    if targetIsLocal {
        let senderIdentity = signal.senderIdentity ?? ""
        let senderRole = roomController?.role(forParticipantIdentity: senderIdentity) ?? .participant
        guard InterPermissionMatrix.role(senderRole, hasPermission: .canMuteOthers) else {
            break // discard — unprivileged sender
        }
        delegate?.moderationControllerMicUnlockApproved?(self)
    }
```

---

## 7. Host UI — `InterMicUnlockQueuePanel`

Exact structural mirror of `InterCameraUnlockQueuePanel`.

### Files
- `inter/inter/UI/Views/InterMicUnlockQueuePanel.h`
- `inter/inter/UI/Views/InterMicUnlockQueuePanel.m`

### Delegate
```objc
@protocol InterMicUnlockQueuePanelDelegate <NSObject>
- (void)micUnlockQueuePanel:(InterMicUnlockQueuePanel *)panel
       didApproveForIdentity:(NSString *)identity;
- (void)micUnlockQueuePanel:(InterMicUnlockQueuePanel *)panel
        didDismissForIdentity:(NSString *)identity;
@end
```

### Queue model — `InterMicUnlockQueue` + `InterMicUnlockEntry`
Added to `InterSpeakerQueue.swift` alongside `InterCameraUnlockQueue`.

### AppDelegate wiring
- `normalMicUnlockQueuePanel` property
- `micUnlockQueue` (`InterMicUnlockQueue`) property
- Init: `self.micUnlockQueue = [[InterMicUnlockQueue alloc] init]`
- Reconnect reset: `[self.micUnlockQueue reset]` + `[self.normalMediaWiring resetMicUnlockFlowState]`
- `receivedMicUnlockRequest:displayName:` delegate:
  - Guard: `if (!self.roomController.isHost) return;`
  - Add to queue, update panel, show panel
- `micUnlockQueuePanel:didApproveForIdentity:`:
  - `[self.moderationController approveMicUnlockWithIdentity:identity]`
  - `[self.normalRemoteLayout setHostMuted:NO forParticipant:identity]`
  - `[self.hostMutedParticipants removeObject:identity]`
  - Remove from queue, update panel
- `micUnlockQueuePanel:didDismissForIdentity:`:
  - Remove from queue, update panel only
- Teardown: nil + removeFromSuperview for `normalMicUnlockQueuePanel`

---

## 8. Redis & Token Server

### New Redis key
```
room:${code}:mic-locked    SET of identity strings (mirrors camera-locked)
```

### New helper
```js
function roomMicLockedKey(code) { return `room:${code}:mic-locked`; }
```

### Updated `/room/mute` endpoint
After successful LiveKit server-mute, add:
```js
await redis.sadd(roomMicLockedKey(code), targetIdentity);
await redis.expire(roomMicLockedKey(code), 86400);
```

### New endpoints

**`POST /room/mic-lift-one`** — Host lifts per-tile mic lock
```js
await redis.srem(roomMicLockedKey(code), targetIdentity);
io.to(code).emit('room:mic-lock-changed', { identity: targetIdentity, locked: false });
```

**`GET /room/mic-locked`** — Reconnect snapshot
```js
const locked = await redis.smembers(roomMicLockedKey(code));
res.json({ locked });
```

### AppDelegate reconnect (new call, after camera-locked restore)
```objc
[self fetchMicLockedSnapshot]; // → GET /room/mic-locked
// For each identity in response:
[self.normalRemoteLayout setHostMuted:YES forParticipant:identity];
[self.hostMutedParticipants addObject:identity];
self.normalSpeakerQueuePanel.hostMutedIdentities = [self.hostMutedParticipants copy];
```

---

## 9. Edge Cases

| # | Scenario | Resolution |
|---|---|---|
| E1 | Tile mute first, Mute All arrives | Mute All clears all 3 flags + cancels pending queue entry. Participant re-requests. |
| E2 | Mute All active, host tile-mutes specific participant | `hostMuted=YES` added, all 3 flags cleared, any pending queue entry cancelled. |
| E3 | Approval arrives after superseding mute | Discarded: `hostMuted \|\| globalMuteActive` is true but `micUnlockApproved=NO` (was cleared by new mute). |
| E4 | Mute All lifted, tile mute still active | `applyUnmuteAll` does not clear `hostMuted`. Participant stays in "Ask to Unmute". |
| E5 | Co-host approves | Live metadata role lookup (`roomController?.role(forParticipantIdentity:)`). Any `canMuteOthers` role can approve. |
| E6 | Host reconnects mid-queue | Queue reset. Redis snapshot restores `hostMuted` tile state. Participants re-request. |
| E7 | Participant reconnects while tile-muted | `muteOnJoin` or snapshot → `applyRemoteMicMuteOne` → "Ask to Unmute". `resetMicUnlockFlowState` called on reconnect. |
| E8 | Approval but track never published | `twoPhaseToggleMicrophone` `[R7]` guard publishes from scratch. |
| E9 | `allowToSpeak` while `micUnlockApproved=YES` | `applyAllowToSpeak` no longer touches mic state. No conflict. |
| E10 | Host clicks tile "Unmute Mic" while unlock request pending | `requestUnmuteOne` path clears `isHostMuted` on tile and removes from `hostMutedParticipants`. Queue entry cancelled (same handler, same pattern as camera). |

---

## 10. Files Touched

| File | Change |
|---|---|
| `inter/Networking/InterChatMessage.swift` | 2 new signal cases |
| `inter/Networking/InterChatController.swift` | Route 2 new cases |
| `inter/Networking/InterModerationController.swift` | 2 delegate methods, 2 send methods, 2 handle cases |
| `inter/App/InterMediaWiringController.h` | 3 new public methods, 2 new readonly properties |
| `inter/App/InterMediaWiringController.m` | 3 new private flags, rewrite `deriveMicButton`, guard `twoPhaseToggleMicrophone`, update `applyRemoteMicMuteOne/All/Unmute/UnmuteAll/AllowToSpeak` |
| `inter/App/AppDelegate.m` | Mic button handler, new queue/panel wiring, reconnect snapshot, teardown |
| `inter/UI/Views/InterMicUnlockQueuePanel.h` | New file |
| `inter/UI/Views/InterMicUnlockQueuePanel.m` | New file |
| `inter/Networking/InterSpeakerQueue.swift` | `InterMicUnlockEntry` + `InterMicUnlockQueue` classes |
| `token-server/index.js` | Update `/room/mute`, add `/room/mic-lift-one`, add `GET /room/mic-locked` |

---

## 11. Out of Scope

- Mute All per-tile override (§8.1 rule) — already implemented, not changed
- Global camera lock — not touched
- Screen share queue — not touched
- Raise-hand queue panel UI — not touched
- iOS client — macOS only
