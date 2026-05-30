# INTER MEETING MODERATION TOOLS

**iOS / macOS · Obj-C / Swift / LiveKit · Node.js**

*Enterprise Moderation Tools · Complete Implementation Plan*

- ▸ Camera Mute (Global / Per-Participant)
- ▸ Kick / Remove
- ▸ Presenter Delegation
- ▸ Role Assignment (Co-Host, Presenter, Speaker)

**Tech Stack:** WebRTC · Socket.IO · Signalling Controller
**Architecture:** Source / Publish / Room / MicState · iOS ObjC.md

*(same server contract, conflict resolution, event taxonomy pattern)*

---

## Table of Contents

1. Architecture Foundations
2. Camera Mute — Global
3. Camera Mute — Per Participant
4. Kick / Remove
5. Screen Share
6. Role Assignment (Co-Host)
   - 6.3 Co-Host Full Implementation
7. Permissions Matrix & Conflict Resolution
8. Reconnect Reconciliation
9. Edge Cases & Race Guards
10. Test Suite
11. Migration Guide

---

## 1. Architecture Foundations

Every moderation action in this document is built on the same five-layer architecture. Understanding these layers once means all five features become predictable.

### 1.1 The Three-Tier Ownership Model

Each media attribute (camera, mic, screen-share, role) has exactly one ownership tier, each with a single writer authority:

| Owner Field | Commission |
|---|---|
| roomId / hostId | Set only via Dispatch; kicked / initiated |
| Room-Wide (muteAll / offFromLock / selfVideoEnabled) | Server-authoritative |
| Per-Participant (localMuteState / videoEnabled) | Set by self only; valid within that participant's session |

### 1.2 Your Existing File Map

The plan slots directly into your current structure. No top-level refactoring needed.

| Primary Actor | ALL features (AT, i.e. single authority) |
|---|---|
| Role & permissions | Extending methods per section. Call synchronised local state when granted or revoked |
| Signalling streams | Surface started / stopped handler.h / .m |
| Room controller | Manages MicState, triggers mic + hardware; talks to RoomSnapshot |
| Snapshot / gate | Holds room snapshot — lives here alongside gate |
| Co-authority checks | Gate, role-driven flags. Used by e.g. can-use annotations? |
| Queue / message | Network payload products — Node.js need not relay; notify |
| Rule | RULE — carries lastUpdatedAt (ISO 8601). ALWAYS discard incoming events whose stored timestamp is older. Do not skip it. |

> **📌 NAMING:** Use canonical event names:
> - `"mute-off-all"` // lift all mutes
> - `"you-were-muted-off"`
> - `"you-were-kicked"` // → reject

---

## 2. Camera Mute — Global

### 2.1 What It Is & What Apps Do

Host mutes all cameras simultaneously. Zoom calls it "Stop Video for All". Google Meet: "Turn off everyone's camera". Microsoft Teams: all attendees are platform-visible.

What happens: host taps button in panel → sends it out → receives it → confirm → becomes completely "off". LED turns off. Camera re-enable is blocked until host (or individual participant override in 2.2) lifts it.

### 2.2 Data Model

| Field | Details |
|---|---|
| Mirror enum | MirrorCameraState: case on, off, lockedOff |
| on / off | Participant choice — rejoin state equal, hardware toggle |
| lockedOff | Host-set — entirely disables toggle. Metadata default → DateFormatter UTC |

### 2.3 Server-Side Handler (Node.js)

```javascript
socket.on('mute-camera-all', ({ roomId }) => {
  if (!isHostOrCoHost(socket.userId, roomId)) return;
  let count = 0;
  Object.values(participants).forEach(p => {
    p.cameraState = 'lockedOff';
    count += 1;
  });
  // Broadcast full snapshot to room
  io.to(roomId).emit('camera-state-changed', {
    roomId, participants: snapshot,
    affectedCount: count, reason: 'host-mute-all',
    initiatorId: socket.userId
  });
});
```

> **NOTE:** NOT touched by server — keeps participant's own choice intact. Only cameraState is changed, not video track preference.

### 2.4 iOS Obj-C Implementation

```swift
// Swift — final class CameraStateManager: ObservableObject {
  @Published var states: [String: CameraState] = [:]
  func apply(_ snapshot: [[String: Any]]) { ... }
  // syncLocal() — called when granted or revoked
  func syncLocal(userId: String, newState: CameraState) {
    if states[userId] == .lockedOff { return } // guard
    states[userId] = newState
  }
}
```

---

## 3. Camera Mute — Per Participant

Host or co-host mutes one specific participant's camera. Analogous to per-participant mic mute.

> **KEY DISTINCTION:**
> - Participants cannot mute themselves in this flow — only a moderator triggers it.
> - Overrides self-mute preference. Override is not persistent — re-join resets to their own choice.

### 3.1 Flow

| Step | Actor | Action |
|---|---|---|
| 1 | Host | Taps participant tile → 'Turn off camera' in menu |
| 2 | Target | Receives 'camera-muted-by-host' event |
| 3 | Also | Show 'Your camera was turned off by the host' toast |
| 4 | Target | Camera LED turns off, track paused |

### 3.2 Mutation Logic

```javascript
// Server
socket.on('mute-camera-participant', ({ roomId, targetId }) => {
  if (!isHostOrCoHost(socket.userId, roomId)) return;
  const p = getParticipantById(roomId, targetId);
  if (!p) return;
  p.cameraState = 'off';
  p.lastUpdatedAt = new Date().toISOString();
  io.to(roomId).emit('camera-state-changed', { targetId, cameraState: 'off' });
});
```

### 3.3 iOS Obj-C — Camera Track Pause

```objc
// MARK: - CameraTrackManager
- (void)pauseCameraTrack:(NSString *)participantId {
  LiveKitParticipant *p = [self.room participantWithIdentity:participantId];
  if (!p) return;
  [p.videoTracks enumerateObjectsUsingBlock:^(LKVideoTrack *track, ...) {
    track.isEnabled = NO;
  }];
}
```

---

## 4. Kick / Remove

### 4.1 Behavior

Kicked participant is removed and cannot rejoin unless explicitly re-invited. What enterprise apps do differently: Zoom, Teams, Webex — they have 'Admit Denied' so the participant cannot re-enter (a re-join attempt is silently rejected).

| Platform | Re-join behaviour |
|---|---|
| Zoom | Cannot rejoin unless host re-invites |
| Google Meet | Rejoin dialog appears but host must re-admit |
| Microsoft Teams | Blocked for the meeting duration |
| Your App (target) | Same: banned Set, reject on reconnect |

### 4.2 Banned-Set Implementation (Node.js)

```javascript
const bannedUsers = new Map(); // roomId → Set<userId>

async function kickParticipant(roomId, targetId, requesterId) {
  // 1. Validate — only host/co-host
  if (!canKick(requesterId, roomId)) {
    return { error: 'insufficient_permissions' };
  }
  // 2. Add to banned set
  if (!bannedUsers.has(roomId)) bannedUsers.set(roomId, new Set());
  bannedUsers.get(roomId).add(targetId);
  // 3. Display — emit to target first
  io.to(targetId).emit('you-were-kicked', { roomId, reason: 'removed_by_host' });
  // 4. Delete from participants
  delete participants[roomId][targetId];
  // 5. Broadcast updated room snapshot
  io.to(roomId).emit('participant-left', { userId: targetId, reason: 'kicked' });
  // 6. 500ms delay then disconnect socket
  setTimeout(() => {
    const sock = getSocketByUserId(targetId);
    if (sock) sock.disconnect(true);
  }, 500);
}

// Guard on reconnect — reject banned users
socket.on('join-room', ({ roomId, userId }) => {
  if (bannedUsers.get(roomId)?.has(userId)) {
    socket.emit('join-rejected', { reason: 'banned_by_host' });
    socket.disconnect();
    return;
  }
  // ... normal join flow
});
```

### 4.3 iOS Obj-C — Kick Response

```swift
// MARK: - Handle kick event
socket.on('you-were-kicked') { [weak self] data, _ in
  guard let payload = data.first as? [String: Any] else { return }
  DispatchQueue.main.async {
    self?.localParticipant.willLeave()
    self?.showToast("You were removed from the meeting", icon: .warning)
    self?.navigateToHome()
  }
}
```

---

## 5. Screen Share

### 5.1 Capability Map

Screen share ability maps to role and host-level settings:

| Role | Default Can Share? | Advanced Share Control |
|---|---|---|
| Host | Yes — always | Full control |
| Co-Host | Yes | Full control |
| Presenter | Yes (if granted) | Organizer-granted at a time |
| Participant | No (by default) | Host can grant |
| Attendee/View | No | Webinar-only role |

### 5.2 Presenter Awareness

When a participant starts sharing, a visual treatment distinguishes them from regular participants. The presenter tile is elevated in the grid, confirming the screen share is integrated with the role/priority system.

| State | Grid Behaviour |
|---|---|
| No sharer | All tiles equal size |
| Sharer active | Sharer tile promoted to primary; others to secondary bar |
| Multiple sharers | Only one at a time — new sharer request prompts existing |
| Confirmed / Insert | s.insert(shareId); didUpdate array { $0.id contains... } |

### 5.3 Mic during Screen Share

```javascript
socket.on('screen-share-started', ({ roomId, userId }) => {
  const p = participants[roomId][userId];
  if (!p) return;
  p.isScreenSharing = true;
  p.screenShareStartedAt = new Date().toISOString();
  p.lastUpdatedAt = new Date().toISOString();
  p.sequenceNumber += 1;
  io.to(roomId).emit('screen-share-update', { userId, isSharing: true });
});
```

---

## 6. Role Assignment System

### 6.1 Roles & Why They Matter

The platform uses an 8-tier hierarchy:

| Role | Platform context |
|---|---|
| host | Primary moderator — full authority |
| co-host | Delegated moderator (Zoom, Webex, Teams support multiple) |
| presenter | Screen-share + speak; webinar-oriented (Zoom Webinar, Webex) |
| speaker | Elevated participant — unmuted by default |
| participant | Standard attendee |
| attendee | View-only (webinar mode — Zoom, Webex) |
| panelist | Webinar panelist with limited moderation |
| interpreter | Language channel role (Zoom, Teams) |

```swift
enum ParticipantRole: String, Codable, CaseIterable {
  case host         = "host"
  case coHost       = "co-host"
  case presenter    = "presenter"
  case speaker      = "speaker"
  case participant  = "participant"
  case attendee     = "attendee"
}
```

### 6.2 Permissions Extension

```swift
// Permissions.swift
extension ParticipantRole {
  /// Can this role mute / unmute others?
  var canModerateOthers: Bool { self == .host || self == .coHost }
  /// Share screen (requires grant OR host-level permission)
  var canShareScreen: Bool { self != .attendee }
  /// Kick participant
  var canKick: Bool { self == .host || self == .coHost }
  /// Assign / promote roles
  var canAssignRoles: Bool { self == .host }
  /// Self unmute (only if host allows)
  var canSelfUnmute: Bool { self != .attendee }
  /// Promote to presenter globally
  var canPromotePresenter: Bool { self == .host || self == .coHost }
}
```

---

## 6.3 Co-Host — Full Implementation

### 6.3.1 What Co-Host Is Intended To Do

Co-host is a trusted delegate of the host's moderation authority to another participant, not to be everywhere at once. In a 200-person meeting, co-hosts handle different breakout areas, chat moderation, and disruptive participant management — a powerful non-host role.

> **CO-HOST CAN:**
> - Mute / unmute any participant's microphone
> - Turn on / off camera / remove from meeting
> - Start / stop recording (if enabled)
> - Control screen share / someone else's share
> - Transfer Co-Host, End meeting for all

### 6.3.2 Co-Host Flow Walkthrough

| Step | Actor | Event / Action |
|---|---|---|
| 1 | Host | Taps participant tile → emit { roomId, targetId: 'mv-cohost' } |
| 2 | Server | Validates → sets role. Broadcasts full snapshot. |
| 3 | Recipient | Receives 'role-changed' event — UI updates |
| 4 | All clients | Participant badge/icon changes in participant list |
| 5 | Future actions | Now passes canModerateOthers checks |

```javascript
// Server — role assignment handler
socket.on('assign-role', ({ roomId, targetId, role }) => {
  if (!canAssignRoles(socket.userId, roomId)) {
    socket.emit('error', { reason: 'insufficient_permissions' });
    return;
  }
  const p = participants[roomId]?.[targetId];
  if (!p) { socket.emit('error', { reason: 'participant_not_found' }); return; }
  const previousRole = p.role;
  p.role = role;
  p.lastUpdatedAt = new Date().toISOString();
  io.to(roomId).emit('role-changed', {
    userId: targetId, previousRole, newRole: role,
    assignedBy: socket.userId
  });
});
```

```swift
// iOS — receive role change
socket.on('role-changed') { [weak self] data, _ in
  guard let payload = data.first as? [String: Any],
        let userId = payload["userId"] as? String,
        let roleStr = payload["newRole"] as? String,
        let role = ParticipantRole(rawValue: roleStr) else { return }
  DispatchQueue.main.async {
    self?.localParticipant.updateRole(userId: userId, role: role)
    self?.participantList.reloadBadges()
    if userId == self?.localParticipant.userId {
      self?.showToast("You are now a \(role.rawValue)", icon: .star)
    }
  }
}
```

---

## 7. Permissions Matrix & Conflict Resolution

### 7.1 Who Can Do What

| Action | Host | Co-Host | Presenter | Speaker | Participant | Attendee |
|---|---|---|---|---|---|---|
| Mute all cameras | ✓ | ✓ | — | — | — | — |
| Mute one camera | ✓ | ✓ | — | — | — | — |
| Kick participant | ✓ | ✓ | — | — | — | — |
| Assign co-host | ✓ | — | — | — | — | — |
| Assign presenter | ✓ | ✓ | — | — | — | — |
| Share screen | ✓ | ✓ | ✓ | — | ✓* | — |
| Self unmute | ✓ | ✓ | ✓ | ✓ | ✓* | — |
| Raise hand | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

*\* Subject to host's "Allow participants to unmute themselves" toggle.*

### 7.2 Conflict Resolution Rules

1. **Host action always wins** — host-set locks cannot be overridden by co-host.
2. **Last-writer-wins** within the same tier (co-host vs co-host) using `lastUpdatedAt` ISO timestamp.
3. **Downgrade must leave server** — if no host remains, a co-host becomes acting host or the entire meeting is evaluated and terminated immediately.
4. **RECONNECT:** if a participant reconnects after being kicked, the banned-set is checked and re-join is rejected regardless of role upgrade attempts.

---

## 8. Reconnect Reconciliation

When a participant reconnects (network blip, app restart), the server must reconcile current moderation state. Includes RoomSnapshot (already used in your existing architecture).

### 8.1 Server Snapshot Send

```javascript
socket.on('request-snapshot', ({ roomId, userId }) => {
  const snap = buildRoomSnapshot(roomId);
  // Apply any pending banned check
  if (bannedUsers.get(roomId)?.has(userId)) {
    socket.emit('join-rejected', { reason: 'banned_by_host' });
    socket.disconnect();
    return;
  }
  // Send full moderation state
  socket.emit('room-snapshot', {
    participants: snap.participants,
    roomCameraLocked: snap.roomCameraLocked,
    displayName: snap.displayName,
  });
});
```

### 8.2 iOS — Apply Snapshot on Reconnect

```swift
// On socket reconnect:
func applySnapshot(_ snapshot: RoomSnapshot) {
  for participant in snapshot.participants {
    store.upsert(participant)
    if participant.cameraState == .lockedOff {
      cameraManager.pauseCameraTrack(participant.id)
    }
  }
  if snapshot.roomCameraLocked {
    uiState.showCameraLockedBanner = true
  }
}
```

---

## 9. Edge Cases & Race Guards

### 9.1 Network Blip During Mute-All

If the host triggers mute-all and a participant's snapshot arrives before the mute-all event (due to reorder), the snapshot's timestamp ensures the mute-all is not silently dropped:

> **RULE:**
> - ALWAYS discard incoming events whose stored `lastUpdatedAt` is older.
> - Do NOT skip this check.
> - Both sides (iOS + server) enforce the rule independently.

### 9.2 Race: Two Co-Hosts Mute Simultaneously

```javascript
// Both fire at same ms:
// co-host-A: mutes p2
// co-host-B: mutes p2
// → Both arrive at server. last-writer-wins by timestamp.
// → Silent no-op for older event. No conflict exception thrown.
```

### 9.3 Participant Leaves Mid-Kick

If target disconnects before the kick socket event is delivered, the server marks them banned regardless — re-join will be rejected. The kick initiated event is idempotent.

### 9.4 Host Leaves — Leadership Transfer

When host disconnects mid-meeting: if a co-host exists, first co-host in the list auto-promotes to host. If no co-host, the meeting is terminated after a 60-second grace window (configurable). Atomic: no two participants can both be promoted simultaneously.

---

## 10. Test Suite

### 10.1 iOS (XCTest)

```swift
// Swift — CameraStateTests.swift
func test_MuteAll_SetsLockedOff() {
  let mgr = CameraStateManager()
  mgr.makeDefault()
  mgr.applyMuteAll()
  XCTAssertTrue(mgr.states.values.allSatisfy { $0 == .lockedOff })
}

func test_LiftMuteAll_LeavesChoiceIntact() {
  let mgr = CameraStateManager()
  mgr.states["p1"] = .off // was off before mute-all
  mgr.applyLiftMuteAll()
  XCTAssertFalse(mgr.states.values.allSatisfy { $0 == .lockedOff })
  // p1's choice (.off) is NOT touched — main thread
}

func test_Stale_Snapshot_NotApplied() {
  let mgr = CameraStateManager()
  mgr.states["p1"] = .lockedOff // fresh state
  let staleSnap = buildStaleSnapshot(userId: "p1", state: .on)
  mgr.applyIfFresh(staleSnap)
  XCTAssertEqual(mgr.states["p1"], .lockedOff) // unchanged
}
```

### 10.2 Node.js / Jest

```javascript
// kickParticipant.test.js
describe('kickParticipant', () => {
  it('COBALT setup — p2 kicked, p3 attempted re-join', async () => {
    const room = setupTestRoom(['p1-host', 'p2', 'p3']);
    await kickParticipant(room.id, 'p2', 'p1-host');
    expect(room.participants['p2']).toBeUndefined();
    expect(bannedUsers.get(room.id).has('p2')).toBe(true);
    // p3 attempts rejoin — not banned
    const result = await attemptRejoin(room.id, 'p3');
    expect(result.error).toBeUndefined();
    // p2 banned_by_host
    const p2result = await attemptRejoin(room.id, 'p2');
    expect(p2result.reason).toBe('banned_by_host');
  });
});
```

---

## 11. Migration Guide

Each step must be verified before proceeding to the next. Rollback logs maintained throughout.

### 11.1 Order of Operations

1. Add the banned-set Map to your Node.js room controller — verify with existing tests.
2. Deploy `ParticipantRole` enum + Permissions extension to iOS — run full test suite.
3. Add `CameraStateManager` — sync state on granted/revoked. Run full test.
4. Server: add `assign-role`, `mute-camera-all`, `mute-camera-participant`, `kick` handlers.
5. iOS: subscribe to all new socket events; wire to existing UI surfaces.
6. Run full integration test (Jest + XCTest) against staging environment.
7. Migrate to LiveKit Publisher/Track pattern (replace existing track controller).
8. Extend `.h`/`.m` method set; call synchronise local when granted/revoked.

> **⚠️ CRITICAL REMINDER:**
> - Single source of truth — server is always authoritative.
> - Read-ahead race protection pattern is universal.
> - Applies to Obj-C / Swift stack too.

---

*Inter Meeting Moderation Tools · Complete Implementation Plan · iOS Obj-C / Swift / LiveKit · Node.js*
