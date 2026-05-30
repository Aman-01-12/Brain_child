# Unified Mic State Architecture — macOS / Obj-C / Swift / LiveKit / Node.js

> Production-grade implementation of the enterprise mic permission model for your meeting app.
> Translated from the original TypeScript/JavaScript plan to your stack:
> **Obj-C + Swift macOS client** · **LiveKit (WebRTC transport)** · **Node.js token/signalling server**
> Everything unchanged in intent. Only language, platform, and WebRTC layer idioms changed.

---

## Table of Contents

1. [Core Data Model](#1-core-data-model)
2. [Server-Side Architecture (Node.js)](#2-server-side-architecture-nodejs)
3. [Socket Event Taxonomy](#3-socket-event-taxonomy)
4. [MicStateManager — The Single Source of Truth](#4-micstatemanager)
5. [Host-Side Logic](#5-host-side-logic)
6. [Participant-Side Logic](#6-participant-side-logic)
7. [UI State Derivation Rules](#7-ui-state-derivation-rules)
8. [Edge Case Handling](#8-edge-case-handling)
9. [WebRTC Track Layer Integration](#9-webrtc-track-layer-integration)
10. [State Reconciliation on Reconnect](#10-state-reconciliation-on-reconnect)
11. [Permission Notification Flow](#11-permission-notification-flow)
12. [Race Condition Guards](#12-race-condition-guards)
13. [Test Suite](#13-test-suite)
14. [Migration Guide](#14-migration-guide)

---

## Stack Map

| Layer | Original | Your Stack |
|---|---|---|
| Client platform | Browser / web | **macOS desktop app** (AppKit / SwiftUI for macOS) |
| Client language | TypeScript | Swift (preferred) / Obj-C |
| Client UI state | Framework-agnostic TS | AppKit (`NSViewController`, KVO, delegate) or SwiftUI for macOS via `@Published` |
| Client socket | Socket.IO JS client | Socket.IO Swift client (`socket.io-client-swift`) or Obj-C wrapper |
| Server | Node.js + Socket.IO | **Node.js + Socket.IO — unchanged** |
| WebRTC transport | Browser `MediaStreamTrack` | **LiveKit Swift SDK** (`LKLocalAudioTrack`, `LKRoom`) |
| Audio track mute | `track.enabled = false` | `track.mute()` / `track.unmute()` via LiveKit SDK |
| Hard audio lock | `track.stop()` | Unpublish track from LiveKit room (`room.localParticipant.unpublish(track:)`) |
| Reconnect | Socket.IO auto-reconnect | LiveKit handles WebRTC reconnect; Socket.IO handles signalling reconnect separately |
| Serialisation | TypeScript interfaces | `Codable` structs (Swift) / `NSDictionary` (Obj-C) |

---

## 1. Core Data Model

### 1.1 MicState — Swift

Replace every `participant.muted` boolean with this struct. This is the canonical
shape stored on the server (as plain JSON) and decoded on every client.

```swift
// MicState.swift

/// The action that caused the last state change.
/// Used for debugging, audit, and conflict resolution logging.
enum MicStateAction: String, Codable {
    case hostMute            = "host-mute"
    case hostUnmuteDirect    = "host-unmute-direct"
    case hostGrantPermission = "host-grant-permission"
    case hostRevokePermission = "host-revoke-permission"
    case hostDisableAudio    = "host-disable-audio"
    case globalMuteAll       = "global-mute-all"
    case globalUnmuteAll     = "global-unmute-all"
    case selfMute            = "self-mute"
    case selfUnmute          = "self-unmute"
    case raiseHand           = "raise-hand"
    case lowerHand           = "lower-hand"
    case rejoinSync          = "rejoin-sync"
}

struct MicState: Codable, Equatable {

    // ── Layer 1: Host Permission ────────────────────────────────────────
    /// Written ONLY by host tile actions. Never by participant. Never by muteAll.
    var hostMuted: Bool

    /// True when host explicitly grants this participant permission to speak.
    /// Only meaningful when globalMuteActive is true.
    /// Reset when globalMute is lifted or when participant is re-muted.
    var speakPermissionGranted: Bool

    /// Hard lock. When true, mic is disabled at the LiveKit track level —
    /// the local audio track is unpublished from the room entirely.
    /// Set via meeting settings. Overrides everything.
    var audioDisabled: Bool

    // ── Layer 2: Global Mute (Mute All) ────────────────────────────────
    /// Written ONLY by muteAll / unmuteAll from the moderation panel.
    /// Never by individual tile actions.
    var globalMuteActive: Bool

    /// True when participant has raised their hand.
    /// Only relevant when globalMuteActive is true.
    var handRaised: Bool

    // ── Layer 3: Participant Self-Mute ──────────────────────────────────
    /// Written ONLY by the participant's own mic toggle.
    /// Host never writes this field. Server never writes it directly.
    var selfMuted: Bool

    // ── Metadata ────────────────────────────────────────────────────────
    /// Monotonically increasing. Used for conflict resolution.
    /// Increment on every state write. Never reuse or decrement.
    var sequenceNumber: Int

    /// ISO 8601 timestamp of last write. Used as tiebreaker.
    var lastUpdatedAt: String

    /// Which action caused the last change. For debugging and audit.
    var lastAction: MicStateAction
}

extension MicState {
    /// Default state for a participant who just joined.
    /// globalMuteActive will be overwritten from room state immediately after creation.
    static func makeDefault() -> MicState {
        MicState(
            hostMuted: false,
            speakPermissionGranted: false,
            audioDisabled: false,
            globalMuteActive: false,
            handRaised: false,
            selfMuted: false,
            sequenceNumber: 0,
            lastUpdatedAt: ISO8601DateFormatter().string(from: Date()),
            lastAction: .rejoinSync
        )
    }
}
```

### 1.1 MicState — Obj-C

If you are still using Obj-C for the participant model, use a plain class with
an `NSDictionary` initialiser from the JSON payload. The logic is identical —
only the syntax differs.

```objc
// MicState.h

typedef NS_ENUM(NSInteger, MicStateAction) {
    MicStateActionHostMute,
    MicStateActionHostUnmuteDirect,
    MicStateActionHostGrantPermission,
    MicStateActionHostRevokePermission,
    MicStateActionHostDisableAudio,
    MicStateActionGlobalMuteAll,
    MicStateActionGlobalUnmuteAll,
    MicStateActionSelfMute,
    MicStateActionSelfUnmute,
    MicStateActionRaiseHand,
    MicStateActionLowerHand,
    MicStateActionRejoinSync
};

@interface MicState : NSObject <NSCopying>

// Layer 1 — Host
@property (nonatomic, assign) BOOL hostMuted;
@property (nonatomic, assign) BOOL speakPermissionGranted;
@property (nonatomic, assign) BOOL audioDisabled;

// Layer 2 — Global Mute
@property (nonatomic, assign) BOOL globalMuteActive;
@property (nonatomic, assign) BOOL handRaised;

// Layer 3 — Self
@property (nonatomic, assign) BOOL selfMuted;

// Metadata
@property (nonatomic, assign) NSInteger sequenceNumber;
@property (nonatomic, copy)   NSString *lastUpdatedAt;
@property (nonatomic, assign) MicStateAction lastAction;

+ (instancetype)defaultState;
- (instancetype)initWithDictionary:(NSDictionary *)dict;

@end
```

```objc
// MicState.m

@implementation MicState

+ (instancetype)defaultState {
    MicState *s = [[MicState alloc] init];
    s.hostMuted             = NO;
    s.speakPermissionGranted = NO;
    s.audioDisabled         = NO;
    s.globalMuteActive      = NO;
    s.handRaised            = NO;
    s.selfMuted             = NO;
    s.sequenceNumber        = 0;
    s.lastUpdatedAt         = [[ISO8601DateFormatter new] stringFromDate:[NSDate date]];
    s.lastAction            = MicStateActionRejoinSync;
    return s;
}

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        _hostMuted              = [dict[@"hostMuted"] boolValue];
        _speakPermissionGranted = [dict[@"speakPermissionGranted"] boolValue];
        _audioDisabled          = [dict[@"audioDisabled"] boolValue];
        _globalMuteActive       = [dict[@"globalMuteActive"] boolValue];
        _handRaised             = [dict[@"handRaised"] boolValue];
        _selfMuted              = [dict[@"selfMuted"] boolValue];
        _sequenceNumber         = [dict[@"sequenceNumber"] integerValue];
        _lastUpdatedAt          = dict[@"lastUpdatedAt"] ?: @"";
        // map string → enum as needed
    }
    return self;
}

@end
```

### 1.2 Participant Model — Swift

```swift
// Participant.swift
// Works on macOS 12+ (AppKit or SwiftUI for macOS)

enum ParticipantRole: String, Codable {
    case host, coHost = "co-host", participant
}

struct Participant: Codable, Identifiable {
    let id: String
    var socketId: String
    var displayName: String
    var role: ParticipantRole
    var micState: MicState
    var isConnected: Bool
    var joinedAt: String
}
```

### 1.3 Room Model

The Room lives on the **Node.js server** — see Section 2.
On the iOS client, you hold a lightweight `RoomSnapshot` decoded from the
server's `ROOM_STATE_SNAPSHOT` event.

```swift
// RoomSnapshot.swift — client-side view of room state

struct RoomSnapshot: Codable {
    let roomId: String
    var globalMuteActive: Bool
    var roomSequence: Int
    var participants: [ParticipantSnapshot]
}

struct ParticipantSnapshot: Codable {
    let id: String
    let displayName: String
    var micState: MicState
}
```

---

## 2. Server-Side Architecture (Node.js)

**Nothing changes here from the original plan.** The Node.js server code,
directory structure, and `MicStateManager` are identical. Your token server
already runs Node.js + Socket.IO; this architecture slots straight in.

Reproduce the original directory layout verbatim:

```
server/
├── rooms/
│   ├── RoomManager.js / .ts
│   └── Room.js / .ts
├── mic/
│   ├── MicStateManager.js / .ts      ← ALL mic state writes go through here
│   ├── MicStateValidator.js / .ts
│   └── MicStateBroadcaster.js / .ts
├── socket/
│   ├── handlers/
│   │   ├── hostModerationHandlers.js / .ts
│   │   ├── participantHandlers.js / .ts
│   │   └── reconnectHandlers.js / .ts
│   └── eventNames.js / .ts
└── index.js / .ts
```

The complete Node.js implementation for every file is defined in the original
plan Sections 2–5 and 10. Implement them exactly as written. The macOS client
is a consumer of these events — it never changes the server contract.

---

## 3. Socket Event Taxonomy

### 3.1 Event Name Constants — Swift

Define every socket event name in one place. Never use string literals in handlers.
This mirrors the original `EVENTS` constant object exactly.

```swift
// SocketEventNames.swift

enum SocketEvent {

    // ── Host → Server ──────────────────────────────────────────────────
    static let hostMuteAll           = "host:mute-all"
    static let hostUnmuteAll         = "host:unmute-all"
    static let hostMuteParticipant   = "host:mute-participant"
    static let hostUnmuteParticipant = "host:unmute-participant"
    static let hostGrantPermission   = "host:grant-speak-permission"
    static let hostRevokePermission  = "host:revoke-speak-permission"
    static let hostDisableAudio      = "host:disable-audio"
    static let hostEnableAudio       = "host:enable-audio"

    // ── Participant → Server ────────────────────────────────────────────
    static let participantSelfMute   = "participant:self-mute"
    static let participantSelfUnmute = "participant:self-unmute"
    static let participantRaiseHand  = "participant:raise-hand"
    static let participantLowerHand  = "participant:lower-hand"

    // ── Server → All Clients ───────────────────────────────────────────
    /// Single unified event for any mic state change.
    /// Payload always contains the full MicState of the affected participant.
    static let micStateUpdate        = "room:mic-state-update"
    static let roomGlobalMuteChanged = "room:global-mute-changed"

    // ── Server → Target Participant Only ───────────────────────────────
    static let permissionGranted     = "you:permission-granted"
    static let permissionRevoked     = "you:permission-revoked"
    static let hostRequestsUnmute    = "you:host-requests-unmute"
    static let youWereMuted          = "you:were-muted"

    // ── Server → Host Only ─────────────────────────────────────────────
    static let handRaisedNotify      = "host:hand-raised-notification"

    // ── Reconnect ──────────────────────────────────────────────────────
    static let rejoinRoom            = "client:rejoin"
    static let roomStateSnapshot     = "server:room-snapshot"
}
```

### 3.2 Event Table

Identical to the original. The server contract does not change.

| Event | Sender | Receivers | Writes to |
|---|---|---|---|
| `host:mute-all` | host | server | `room.globalMuteActive = true`, all `participant.micState.globalMuteActive = true` |
| `host:unmute-all` | host | server | `room.globalMuteActive = false`, all `globalMuteActive = false`, all `speakPermissionGranted = false` |
| `host:mute-participant` | host | server | `participant.micState.hostMuted = true` |
| `host:unmute-participant` | host | server | context-aware — see Section 5.2 |
| `host:grant-speak-permission` | host | server | `speakPermissionGranted = true`, `handRaised = false` |
| `host:revoke-speak-permission` | host | server | `speakPermissionGranted = false` |
| `host:disable-audio` | host | server | `audioDisabled = true` |
| `host:enable-audio` | host | server | `audioDisabled = false` |
| `participant:self-mute` | participant | server | `selfMuted = true` |
| `participant:self-unmute` | participant | server | `selfMuted = false` (validated server-side) |
| `participant:raise-hand` | participant | server | `handRaised = true` |
| `participant:lower-hand` | participant | server | `handRaised = false` |
| `room:mic-state-update` | server | all in room | read-only on client — re-renders tile |
| `room:global-mute-changed` | server | all in room | read-only on client |
| `you:permission-granted` | server | target only | triggers UI notification |
| `you:were-muted` | server | target only | triggers UI notification |
| `host:hand-raised-notification` | server | host(s) only | renders hand-raised badge on tile |

---

## 4. MicStateManager

**On the server:** The Node.js `MicStateManager` is the single source of truth for
all writes. Implement it exactly as in the original plan (Section 4). Nothing changes.

**On the macOS client:** You do not have a `MicStateManager` that writes — the client
is read-only with respect to MicState. It receives `room:mic-state-update` events
and applies them to its local store. The equivalent on the client side is a
`MicStateStore` (or ViewModel) that:

- Holds the local copy of every participant's `MicState`
- Accepts incoming `MicState` payloads from the socket
- Applies sequence-number conflict resolution before updating
- Notifies the UI layer (via `@Published` for SwiftUI-for-macOS, or KVO/delegate for AppKit)

```swift
// MicStateStore.swift
// macOS client — read/apply path. The server owns all writes.

import Foundation
import Combine

final class MicStateStore: ObservableObject {

    // Key: participantId
    @Published private(set) var participantStates: [String: MicState] = [:]
    @Published private(set) var globalMuteActive: Bool = false
    @Published private(set) var roomSequence: Int = 0

    let localParticipantId: String

    init(localParticipantId: String) {
        self.localParticipantId = localParticipantId
    }

    // MARK: - Called by SocketListener on every room:mic-state-update

    func applyMicStateUpdate(participantId: String, incoming: MicState) {
        guard let current = participantStates[participantId] else {
            // First time seeing this participant
            participantStates[participantId] = incoming
            return
        }

        // Sequence-number conflict resolution — identical logic to original plan
        guard incoming.sequenceNumber > current.sequenceNumber else {
            print("[MicStateStore] Discarding stale update for \(participantId): " +
                  "current=\(current.sequenceNumber) incoming=\(incoming.sequenceNumber)")
            return
        }

        participantStates[participantId] = incoming

        // If it is the local user, sync LiveKit audio track immediately
        if participantId == localParticipantId {
            LiveKitTrackSync.shared.syncTrack(with: incoming)
        }
    }

    func applyRoomSnapshot(_ snapshot: RoomSnapshot) {
        globalMuteActive = snapshot.globalMuteActive
        roomSequence     = snapshot.roomSequence
        for p in snapshot.participants {
            participantStates[p.id] = p.micState
        }
        // Sync own LiveKit audio track after full snapshot
        if let ownState = participantStates[localParticipantId] {
            LiveKitTrackSync.shared.syncTrack(with: ownState)
        }
    }

    func applyGlobalMuteChanged(globalMuteActive: Bool, roomSequence: Int) {
        // Only apply if sequence is newer
        guard roomSequence > self.roomSequence else { return }
        self.globalMuteActive = globalMuteActive
        self.roomSequence     = roomSequence
    }

    // MARK: - Convenience accessors

    func micState(for participantId: String) -> MicState? {
        participantStates[participantId]
    }

    var localMicState: MicState? {
        participantStates[localParticipantId]
    }
}
```

---

## 5. Host-Side Logic

### 5.1 Socket Emit Calls — Swift (Host)

The socket handlers on the **server** are identical to the original plan (Section 5.1).
On the **iOS host client**, you emit the right event when the host taps a tile control.

```swift
// HostModerationSocket.swift

final class HostModerationSocket {

    private let socket: SocketIOClient  // your Socket.IO-Swift client
    private let roomId: String

    init(socket: SocketIOClient, roomId: String) {
        self.socket = socket
        self.roomId = roomId
    }

    func muteAll() {
        socket.emit(SocketEvent.hostMuteAll, ["roomId": roomId])
    }

    func unmuteAll() {
        socket.emit(SocketEvent.hostUnmuteAll, ["roomId": roomId])
    }

    func muteParticipant(targetId: String) {
        socket.emit(SocketEvent.hostMuteParticipant,
                    ["roomId": roomId, "targetId": targetId])
    }

    /// Context-aware: server decides whether this is a direct unmute
    /// or a permission grant, based on globalMuteActive.
    func unmuteTileAction(targetId: String) {
        socket.emit(SocketEvent.hostUnmuteParticipant,
                    ["roomId": roomId, "targetId": targetId])
    }

    func grantSpeakPermission(targetId: String) {
        socket.emit(SocketEvent.hostGrantPermission,
                    ["roomId": roomId, "targetId": targetId])
    }

    func revokeSpeakPermission(targetId: String) {
        socket.emit(SocketEvent.hostRevokePermission,
                    ["roomId": roomId, "targetId": targetId])
    }

    func disableAudio(targetId: String) {
        socket.emit(SocketEvent.hostDisableAudio,
                    ["roomId": roomId, "targetId": targetId])
    }
}
```

### 5.2 Host Tile UI State — Swift

The host tile for each participant shows exactly one primary action button.
Its label is derived **exclusively** from `micState.hostMuted`.
`selfMuted` is **never** consulted for the primary control — it may only appear
as a secondary informational indicator. This is the fix for Bug 3.

```swift
// HostTileViewModel.swift

struct HostTileControls {
    enum PrimaryAction { case mute, unmute }

    let primaryLabel: String
    let primaryAction: PrimaryAction
    let showHandRaisedBadge: Bool
    let showPermissionGranted: Bool
    let isAudioDisabled: Bool
    /// Secondary informational indicator only — does NOT affect primaryAction
    let participantSelfMutedIndicator: Bool
}

func deriveHostTileControls(state: MicState) -> HostTileControls {
    HostTileControls(
        // THIS is the fix for Bug 3.
        // The tile reads ONLY hostMuted. selfMuted is NOT consulted here.
        primaryLabel:  state.hostMuted ? "Unmute mic" : "Mute mic",
        primaryAction: state.hostMuted ? .unmute : .mute,
        showHandRaisedBadge:          state.handRaised,
        showPermissionGranted:        state.speakPermissionGranted,
        isAudioDisabled:              state.audioDisabled,
        participantSelfMutedIndicator: state.selfMuted
    )
}
```

**In UIKit** (Obj-C or Swift):

```objc
// Obj-C — in your tile cell's configure method
- (void)configureTileWithMicState:(MicState *)state {
    // Read ONLY hostMuted for the primary button label
    if (state.hostMuted) {
        [self.primaryMicButton setTitle:@"Unmute mic" forState:UIControlStateNormal];
        self.primaryMicButton.tag = MicActionUnmute;
    } else {
        [self.primaryMicButton setTitle:@"Mute mic" forState:UIControlStateNormal];
        self.primaryMicButton.tag = MicActionMute;
    }

    // Hand raised badge — shown on top of tile
    self.handRaisedBadge.hidden = !state.handRaised;

    // Secondary indicator — small icon, does not change primary button
    self.selfMutedIndicator.hidden = !state.selfMuted;
}
```

---

## 6. Participant-Side Logic

### 6.1 Socket Emit Calls — Swift (Participant)

```swift
// ParticipantMicSocket.swift

final class ParticipantMicSocket {

    private let socket: SocketIOClient
    private let roomId: String

    init(socket: SocketIOClient, roomId: String) {
        self.socket = socket
        self.roomId = roomId
    }

    func selfMute() {
        socket.emit(SocketEvent.participantSelfMute, ["roomId": roomId])
    }

    func selfUnmute() {
        socket.emit(SocketEvent.participantSelfUnmute, ["roomId": roomId])
    }

    func raiseHand() {
        socket.emit(SocketEvent.participantRaiseHand, ["roomId": roomId])
    }

    func lowerHand() {
        socket.emit(SocketEvent.participantLowerHand, ["roomId": roomId])
    }
}
```

### 6.2 Participant Mic Button State Derivation — Swift

The participant's mic button state is derived from ALL layers combined,
in priority order: highest override first.

```swift
// ParticipantMicButtonState.swift

enum MicButtonState {
    case active             // mic is on, participant can mute
    case selfMuted          // participant muted themselves, can unmute freely
    case hostMuted          // host muted them, cannot unmute
    case globalMuted        // Mute All is active, must raise hand
    case handRaised         // hand raised, waiting for approval
    case permissionGranted  // host approved, participant can now unmute
    case audioDisabled      // hard lock, no interaction possible
}

struct MicButtonProps {
    let state: MicButtonState
    let label: String
    let iconName: String    // map to your asset catalogue names
    let isClickable: Bool
    let tapAction: MicTapAction?
}

enum MicTapAction {
    case selfMute, selfUnmute, raiseHand, lowerHand
}

func deriveParticipantMicButton(micState: MicState) -> MicButtonProps {

    // Priority: highest override first
    if micState.audioDisabled {
        return MicButtonProps(state: .audioDisabled,
                              label: "Mic disabled",
                              iconName: "mic_off_lock",
                              isClickable: false,
                              tapAction: nil)
    }

    if micState.hostMuted && !micState.speakPermissionGranted {
        return MicButtonProps(state: .hostMuted,
                              label: "Muted by host",
                              iconName: "mic_off_host",
                              isClickable: false,
                              tapAction: nil)
    }

    if micState.globalMuteActive && !micState.speakPermissionGranted {
        if micState.handRaised {
            return MicButtonProps(state: .handRaised,
                                  label: "Waiting for host…",
                                  iconName: "hand_raised",
                                  isClickable: true,
                                  tapAction: .lowerHand)
        }
        return MicButtonProps(state: .globalMuted,
                              label: "Raise hand to speak",
                              iconName: "hand_raise",
                              isClickable: true,
                              tapAction: .raiseHand)
    }

    if micState.speakPermissionGranted && micState.selfMuted {
        // Has permission but still self-muted — show prompt
        return MicButtonProps(state: .permissionGranted,
                              label: "Tap to unmute — you may speak",
                              iconName: "mic_permission",
                              isClickable: true,
                              tapAction: .selfUnmute)
    }

    if micState.selfMuted {
        return MicButtonProps(state: .selfMuted,
                              label: "Unmute",
                              iconName: "mic_off_self",
                              isClickable: true,
                              tapAction: .selfUnmute)
    }

    return MicButtonProps(state: .active,
                          label: "Mute",
                          iconName: "mic_on",
                          isClickable: true,
                          tapAction: .selfMute)
}
```

### 6.3 Incoming Socket Event Handlers — Swift

Implement these in your `SocketListener` / `SessionManager` class, whichever
owns the socket connection.

```swift
// SocketListener+MicEvents.swift

extension SocketListener {

    func registerMicEventHandlers() {

        // ── Broadcast to all clients ──────────────────────────────────────

        socket.on(SocketEvent.micStateUpdate) { [weak self] data, _ in
            guard let self,
                  let payload = data.first as? [String: Any],
                  let participantId = payload["participantId"] as? String,
                  let micStateDict = payload["micState"] as? [String: Any],
                  let micState = try? MicState(from: micStateDict) else { return }

            self.micStateStore.applyMicStateUpdate(participantId: participantId,
                                                    incoming: micState)
            // UI layer observes micStateStore — no manual refresh needed
        }

        socket.on(SocketEvent.roomGlobalMuteChanged) { [weak self] data, _ in
            guard let self,
                  let payload = data.first as? [String: Any],
                  let globalMuteActive = payload["globalMuteActive"] as? Bool,
                  let roomSequence = payload["roomSequence"] as? Int else { return }

            self.micStateStore.applyGlobalMuteChanged(
                globalMuteActive: globalMuteActive,
                roomSequence: roomSequence
            )
        }

        // ── Targeted to this participant only ─────────────────────────────

        socket.on(SocketEvent.permissionGranted) { [weak self] data, _ in
            guard let self,
                  let payload = data.first as? [String: Any],
                  let micStateDict = payload["micState"] as? [String: Any],
                  let micState = try? MicState(from: micStateDict) else { return }

            self.micStateStore.applyMicStateUpdate(
                participantId: self.localParticipantId, incoming: micState
            )

            // Show non-blocking banner notification — NOT a modal
            NotificationBannerPresenter.show(
                type: .permissionGranted,
                message: "The host has allowed you to speak. Tap the mic to unmute.",
                autoDismissAfter: 8.0,
                primaryAction: .init(title: "Unmute now") {
                    self.participantSocket.selfUnmute()
                }
            )
        }

        socket.on(SocketEvent.permissionRevoked) { [weak self] data, _ in
            guard let self,
                  let payload = data.first as? [String: Any],
                  let micStateDict = payload["micState"] as? [String: Any],
                  let micState = try? MicState(from: micStateDict) else { return }

            self.micStateStore.applyMicStateUpdate(
                participantId: self.localParticipantId, incoming: micState
            )
            // WebRTC sync happens automatically inside applyMicStateUpdate

            NotificationBannerPresenter.show(
                type: .permissionRevoked,
                message: "The host has muted your microphone.",
                autoDismissAfter: 4.0
            )
        }

        socket.on(SocketEvent.youWereMuted) { [weak self] data, _ in
            guard let self,
                  let payload = data.first as? [String: Any],
                  let micStateDict = payload["micState"] as? [String: Any],
                  let micState = try? MicState(from: micStateDict) else { return }

            self.micStateStore.applyMicStateUpdate(
                participantId: self.localParticipantId, incoming: micState
            )

            NotificationBannerPresenter.show(
                type: .mutedByHost,
                message: "Your microphone has been muted by the host.",
                autoDismissAfter: 4.0
            )
        }

        // ── Server rejected a self-unmute ─────────────────────────────────

        socket.on("self-unmute-rejected") { [weak self] data, _ in
            guard let self,
                  let payload = data.first as? [String: Any],
                  let micStateDict = payload["micState"] as? [String: Any],
                  let micState = try? MicState(from: micStateDict) else { return }

            // Server is authoritative — sync local state from server response
            self.micStateStore.applyMicStateUpdate(
                participantId: self.localParticipantId, incoming: micState
            )
        }
    }
}
```

#### Decoding MicState from a dictionary (Swift helper)

Since Socket.IO delivers data as `[Any]`, you need a convenience init:

```swift
extension MicState {
    init(from dict: [String: Any]) throws {
        let decoder = JSONDecoder()
        let data = try JSONSerialization.data(withJSONObject: dict)
        self = try decoder.decode(MicState.self, from: data)
    }
}
```

---

## 7. UI State Derivation Rules

### 7.1 The Computed `isMicOff` Function — Swift

```swift
// MicStateComputed.swift

/// Determines whether the mic should be off at the RTCMediaStreamTrack level.
/// This is the ONLY function consulted before enabling or disabling the track.
func isMicOff(_ state: MicState) -> Bool {
    return state.audioDisabled
        || state.selfMuted
        || state.hostMuted
        || (state.globalMuteActive && !state.speakPermissionGranted)
}
```

**In Obj-C:**
```objc
BOOL isMicOff(MicState *state) {
    return state.audioDisabled
        || state.selfMuted
        || state.hostMuted
        || (state.globalMuteActive && !state.speakPermissionGranted);
}
```

### 7.2 Host Tile Render Matrix

Identical logic to original. `selfMuted` NEVER changes what the primary button
shows. It may only appear as a secondary informational indicator.

| `hostMuted` | `selfMuted` | `globalMuteActive` | `speakPermission` | `handRaised` | Host sees on tile |
|---|---|---|---|---|---|
| false | false | false | false | false | "Mute mic" button |
| false | true | false | false | false | "Mute mic" button + self-muted indicator |
| true | any | any | any | false | "Unmute mic" button |
| true | any | true | any | true | "Unmute mic" button + raised hand badge |
| any | any | any | true | false | "Revoke permission" in dropdown |
| any | any | any | any | — | `audioDisabled` lock icon |

### 7.3 Participant Mic Button Render Matrix

Identical logic to original. Priority order is enforced in `deriveParticipantMicButton`.

| `audioDisabled` | `hostMuted` | `globalMuteActive` | `speakPermission` | `handRaised` | `selfMuted` | Participant sees |
|---|---|---|---|---|---|---|
| true | any | any | any | any | any | Locked mic — no interaction |
| false | true | any | false | any | any | "Muted by host" — no interaction |
| false | false | true | false | false | any | "Raise hand to speak" |
| false | false | true | false | true | any | "Waiting for host…" (tap = lower hand) |
| false | any | true | true | any | true | "Tap to unmute — you may speak" (pulsing) |
| false | false | false | any | any | true | "Unmute" |
| false | false | false | any | any | false | "Mute" |

---

## 8. Edge Case Handling

All edge case logic lives on the **Node.js server** (unchanged from original plan,
Section 8). The iOS client handles the consequences — the right responses on
receiving those server-emitted events. Notes below clarify client-side impact.

### 8.1 Individual tile mute stacks with Mute All

Server logic: `unmuteAll` clears `globalMuteActive` but never touches `hostMuted`.
Participants with individual host-mutes stay muted after Unmute All.

**Client impact:** After receiving `room:mic-state-update` from an `unmuteAll`,
`isMicOff` may still return `true` for a participant because `hostMuted` is still
set. The tile shows "Unmute mic" — the host must explicitly tap the tile.

### 8.2 Participant self-mutes while holding speak permission

`speakPermissionGranted` is preserved when participant calls `selfMute`.
They can unmute again without re-raising their hand.

**Client impact:** When `speakPermissionGranted = true` AND `selfMuted = true`,
`deriveParticipantMicButton` returns the `.permissionGranted` state —
the pulsing "Tap to unmute" button. This correctly guides the participant.

### 8.3 Participant joins mid-session during Mute All

Server seeds their `MicState` with `globalMuteActive = true` on join.
Sends a `ROOM_STATE_SNAPSHOT` to their socket.

**Client impact:** Call `applyRoomSnapshot` on receiving `server:room-snapshot`.
This sets the participant's `globalMuteActive` correctly from the start.
Do not show a "Raise hand" UI until the snapshot has been applied.

### 8.4 Two hosts click conflicting controls simultaneously

Server wins. Sequence number conflict resolution on the client:
`applyMicStateUpdate` discards any update whose `sequenceNumber` is not
strictly greater than the current stored one.

### 8.5 Participant disconnects and reconnects

```swift
// In your SocketListener / SessionManager reconnect handler

socket.on(clientEvent: .reconnect) { [weak self] _, _ in
    guard let self else { return }
    self.socket.emit(SocketEvent.rejoinRoom, [
        "roomId":        self.currentRoomId,
        "participantId": self.localParticipantId
    ])
}

socket.on(SocketEvent.roomStateSnapshot) { [weak self] data, _ in
    guard let self,
          let payload = data.first as? [String: Any],
          let snapshot = try? RoomSnapshot(from: payload) else { return }

    self.micStateStore.applyRoomSnapshot(snapshot)
}
```

### 8.6 Raise-hand gate not triggered by per-tile mute

This is guaranteed architecturally — the server's `muteParticipant()` writes
ONLY to `hostMuted`. It never sets `globalMuteActive`. The raise-hand button
on the participant side appears ONLY when `globalMuteActive = true`.
Since per-tile mute never touches `globalMuteActive`, the raise-hand button
will never appear from a per-tile mute. No special client code needed.

### 8.7 Rapid Mute All → Unmute All → Mute All

`roomSequence` guards against out-of-order `room:global-mute-changed` events.
`applyGlobalMuteChanged` discards events with non-increasing `roomSequence`.

---

## 9. WebRTC Track Layer Integration

Use Google's WebRTC iOS SDK (`RTCMediaStreamTrack`, `RTCAudioTrack`).
The philosophy is identical to the original: never toggle the track in response
to individual state fields — always run through `isMicOff`.

```swift
// WebRTCTrackSync.swift

import WebRTC  // Google WebRTC iOS SDK

final class WebRTCTrackSync {

    static let shared = WebRTCTrackSync()
    private init() {}

    private weak var localAudioTrack: RTCAudioTrack?

    func setLocalAudioTrack(_ track: RTCAudioTrack) {
        localAudioTrack = track
    }

    /// Call this every time the local user's MicState changes.
    /// This is the ONLY place that sets track.isEnabled.
    func syncTrack(with micState: MicState) {
        guard let track = localAudioTrack else { return }

        let shouldBeMuted = isMicOff(micState)
        track.isEnabled = !shouldBeMuted
    }

    /// Hard lock — audioDisabled = true.
    /// Stop the track entirely so the OS does not show the mic-in-use indicator.
    /// You must re-acquire the track when audioDisabled is lifted.
    func handleAudioDisabled(micState: MicState, peerConnection: RTCPeerConnection) {
        guard let track = localAudioTrack else { return }

        if micState.audioDisabled {
            // Stop the track and release reference.
            // Remove the sender from the peer connection so the remote side
            // no longer receives any audio from this participant.
            track.isEnabled = false
            if let sender = peerConnection.senders.first(where: { $0.track == track }) {
                peerConnection.removeTrack(sender)
            }
            localAudioTrack = nil
        } else {
            syncTrack(with: micState)
        }
    }
}
```

**In Obj-C:**
```objc
// WebRTCTrackSync.m

- (void)syncTrackWithMicState:(MicState *)state {
    if (!self.localAudioTrack) return;
    self.localAudioTrack.isEnabled = !isMicOff(state);
}
```

---

## 10. State Reconciliation on Reconnect

**Server logic** is unchanged from original plan Section 10.

**iOS client reconnect flow:**

```
Socket reconnects
    │
    ├── client emits "client:rejoin" { roomId, participantId }
    │
    ├── server calls syncStateOnRejoin()
    │   ├── reconciles globalMuteActive from current room state
    │   └── emits "server:room-snapshot" to rejoining socket
    │
    └── client receives "server:room-snapshot"
        ├── calls micStateStore.applyRoomSnapshot(snapshot)
        ├── re-syncs WebRTC track for local user
        └── UI re-renders from updated store
```

Key rule: the client does **not** assume its last-known state is still valid
after a reconnect. It always waits for and applies the server snapshot
before re-enabling any mic controls.

---

## 11. Permission Notification Flow

### 11.1 Complete Raise-Hand → Approval Flow

Identical sequence of events to original plan Section 11.1.
Only the client-side implementation changes language.

```
Participant (iOS)              Server (Node.js)              Host (iOS)
    │                              │                              │
    │── participant:raise-hand ───>│                              │
    │                              │── host:hand-raised-notify ──>│
    │   handRaised = true          │                              │
    │<── room:mic-state-update ────│                              │
    │                              │<── host:grant-permission ────│
    │                              │  Writes:                     │
    │                              │  speakPermissionGranted=true │
    │                              │  handRaised=false            │
    │                              │  hostMuted=false             │
    │<── you:permission-granted ───│                              │
    │   (shows banner)             │                              │
    │── participant:self-unmute ──>│                              │
    │                              │  Validates & writes          │
    │                              │  selfMuted=false             │
    │<── room:mic-state-update ────│                              │
    │ [RTCAudioTrack enabled]      │── room:mic-state-update ────>│
```

### 11.2 Notification Banner Spec

The `you:permission-granted` notification must:

- Appear as a **non-blocking banner** — not a `UIAlertController` modal.
  The participant must be able to see the meeting video tiles.
- Include a direct **"Unmute now" button** that calls `participantSocket.selfUnmute()`.
- Auto-dismiss after **8 seconds** if not tapped.
- If dismissed without acting, the mic button still shows "Tap to unmute — you may speak."
- **Never auto-unmute.** The participant must always take the action themselves.

Implement as a custom `UIView` overlaid on the meeting surface, animated in from
the bottom or top. Avoid `UNUserNotificationCenter` — this is in-app UI, not a
system notification.

---

## 12. Race Condition Guards

### 12.1 Sequence Number Validation

Already implemented inside `MicStateStore.applyMicStateUpdate` — discards
any update where `incoming.sequenceNumber <= current.sequenceNumber`.

### 12.2 Debounce for Rapid Mute All / Unmute All (Server)

Implement on the **Node.js server** — identical to original plan Section 12.2.
No client change needed; the server guarantees at most one mute-all event
per 300 ms per socket.

### 12.3 Optimistic Update for Self-Mute/Unmute — Swift

Only self-mute and self-unmute use optimistic updates.
**All host actions wait for the server response** before updating UI.

```swift
// In ParticipantMicViewController or ViewModel

func handleMicButtonTap() {
    guard let state = micStateStore.localMicState else { return }
    let props = deriveParticipantMicButton(micState: state)
    guard props.isClickable, let action = props.tapAction else { return }

    switch action {
    case .selfMute:
        // Optimistic update — immediate UI feedback
        var optimistic = state
        optimistic.selfMuted = true
        micStateStore.applyMicStateUpdate(
            participantId: localParticipantId,
            incoming: optimistic
        )
        WebRTCTrackSync.shared.syncTrack(with: optimistic)
        participantSocket.selfMute()
        // Server will emit room:mic-state-update; sequence-number check corrects
        // any mismatch.

    case .selfUnmute:
        var optimistic = state
        optimistic.selfMuted = false
        micStateStore.applyMicStateUpdate(
            participantId: localParticipantId,
            incoming: optimistic
        )
        WebRTCTrackSync.shared.syncTrack(with: optimistic)
        participantSocket.selfUnmute()

    case .raiseHand:
        participantSocket.raiseHand()
        // No optimistic update — wait for server echo

    case .lowerHand:
        participantSocket.lowerHand()
    }
}
```

---

## 13. Test Suite

### Philosophy

The **Node.js server** is where all the logic lives — test it with Jest or Mocha
exactly as described in original plan Section 13. The iOS client has almost
no logic to unit-test in isolation; its job is to receive state and render it.

What to test on the iOS client:

- `isMicOff` pure function
- `deriveParticipantMicButton` pure function
- `deriveHostTileControls` pure function
- `MicStateStore.applyMicStateUpdate` sequence-number conflict resolution
- `MicStateStore.applyRoomSnapshot` full state replacement

Use **XCTest**. All of these are pure functions or simple value-type transformations —
no mocking required.

```swift
// MicStateTests.swift

import XCTest
@testable import YourMeetingApp

final class MicStateTests: XCTestCase {

    // MARK: - isMicOff

    func test_isMicOff_selfMuted_returnsTrue() {
        var state = MicState.makeDefault()
        state.selfMuted = true
        XCTAssertTrue(isMicOff(state))
    }

    func test_isMicOff_hostMuted_returnsTrue() {
        var state = MicState.makeDefault()
        state.hostMuted = true
        XCTAssertTrue(isMicOff(state))
    }

    func test_isMicOff_audioDisabled_returnsTrue() {
        var state = MicState.makeDefault()
        state.audioDisabled = true
        XCTAssertTrue(isMicOff(state))
    }

    func test_isMicOff_globalMuteWithNoPermission_returnsTrue() {
        var state = MicState.makeDefault()
        state.globalMuteActive = true
        state.speakPermissionGranted = false
        XCTAssertTrue(isMicOff(state))
    }

    func test_isMicOff_globalMuteWithPermission_returnsFalse() {
        var state = MicState.makeDefault()
        state.globalMuteActive = true
        state.speakPermissionGranted = true
        XCTAssertFalse(isMicOff(state))
    }

    func test_isMicOff_allFalse_returnsFalse() {
        XCTAssertFalse(isMicOff(MicState.makeDefault()))
    }

    // MARK: - deriveHostTileControls (Bug 3 regression)

    func test_hostTile_selfMutedParticipant_primaryLabelIsStillMute() {
        // selfMuted = true must NOT change the host tile's primary button to "Unmute"
        var state = MicState.makeDefault()
        state.hostMuted = false
        state.selfMuted = true
        let controls = deriveHostTileControls(state: state)
        XCTAssertEqual(controls.primaryLabel, "Mute mic")
        XCTAssertEqual(controls.primaryAction, .mute)
    }

    func test_hostTile_hostMuted_primaryLabelIsUnmute() {
        var state = MicState.makeDefault()
        state.hostMuted = true
        state.selfMuted = false
        let controls = deriveHostTileControls(state: state)
        XCTAssertEqual(controls.primaryLabel, "Unmute mic")
        XCTAssertEqual(controls.primaryAction, .unmute)
    }

    func test_hostTile_handRaisedBadge_visibleWhenHandRaised() {
        var state = MicState.makeDefault()
        state.handRaised = true
        let controls = deriveHostTileControls(state: state)
        XCTAssertTrue(controls.showHandRaisedBadge)
    }

    // MARK: - deriveParticipantMicButton

    func test_micButton_audioDisabled_isNotClickable() {
        var state = MicState.makeDefault()
        state.audioDisabled = true
        let props = deriveParticipantMicButton(micState: state)
        XCTAssertEqual(props.state, .audioDisabled)
        XCTAssertFalse(props.isClickable)
    }

    func test_micButton_hostMuted_isNotClickable() {
        var state = MicState.makeDefault()
        state.hostMuted = true
        let props = deriveParticipantMicButton(micState: state)
        XCTAssertEqual(props.state, .hostMuted)
        XCTAssertFalse(props.isClickable)
    }

    func test_micButton_globalMute_showsRaiseHand() {
        var state = MicState.makeDefault()
        state.globalMuteActive = true
        let props = deriveParticipantMicButton(micState: state)
        XCTAssertEqual(props.state, .globalMuted)
        XCTAssertEqual(props.tapAction, .raiseHand)
    }

    func test_micButton_handRaised_showsWaiting() {
        var state = MicState.makeDefault()
        state.globalMuteActive = true
        state.handRaised = true
        let props = deriveParticipantMicButton(micState: state)
        XCTAssertEqual(props.state, .handRaised)
        XCTAssertEqual(props.tapAction, .lowerHand)
    }

    func test_micButton_permissionGrantedAndSelfMuted_showsUnmutePrompt() {
        var state = MicState.makeDefault()
        state.globalMuteActive = true
        state.speakPermissionGranted = true
        state.selfMuted = true
        let props = deriveParticipantMicButton(micState: state)
        XCTAssertEqual(props.state, .permissionGranted)
        XCTAssertEqual(props.tapAction, .selfUnmute)
    }

    // MARK: - MicStateStore conflict resolution

    func test_storeDiscardsStaleUpdate() {
        let store = MicStateStore(localParticipantId: "p1")
        var fresh = MicState.makeDefault()
        fresh.sequenceNumber = 5
        fresh.selfMuted = true
        store.applyMicStateUpdate(participantId: "p1", incoming: fresh)

        var stale = MicState.makeDefault()
        stale.sequenceNumber = 3
        stale.selfMuted = false
        store.applyMicStateUpdate(participantId: "p1", incoming: stale)

        // Stale update discarded — selfMuted must still be true
        XCTAssertTrue(store.micState(for: "p1")?.selfMuted == true)
    }

    func test_storeAppliesNewerUpdate() {
        let store = MicStateStore(localParticipantId: "p1")
        var old = MicState.makeDefault()
        old.sequenceNumber = 2
        old.selfMuted = true
        store.applyMicStateUpdate(participantId: "p1", incoming: old)

        var newer = MicState.makeDefault()
        newer.sequenceNumber = 7
        newer.selfMuted = false
        store.applyMicStateUpdate(participantId: "p1", incoming: newer)

        XCTAssertTrue(store.micState(for: "p1")?.selfMuted == false)
    }
}
```

**Server-side tests (Node.js/Jest)** — run exactly as described in original
plan Section 13.1 and 13.2. The iOS client does not replicate server tests.

---

## 14. Migration Guide

Steps are identical in intent to the original plan. Language notes added below.

### Step 1 — Add MicState struct alongside old field

Do not remove your existing `participant.muted` / `isMuted` property yet.
Add the new `MicState` struct. Derive the old bool from `isMicOff(participant.micState)`
so existing rendering code does not break.

In Obj-C: add `MicState *micState` property to your participant model and
keep the existing `BOOL muted` computed as `isMicOff(self.micState)`.

### Step 2 — Replace muteAll/unmuteAll handlers on the server

Highest-impact fix (Bug 1 — tiles not updating after Unmute All).
Deploy and verify that all participant tiles update correctly.

### Step 3 — Replace per-tile mute handler on the server

Verify that per-tile mute no longer triggers the raise-hand gate on the participant.
This is Bug 2.

### Step 4 — Replace per-tile unmute handler on the server

Fixes the direct unmute bypass when globalMuteActive is true.

### Step 5 — Fix host tile rendering on iOS

Replace the tile's label derivation with `deriveHostTileControls`.
This fixes Bug 3 — tile showing wrong state when participant is self-muted.

### Step 6 — Fix participant mic button derivation on iOS

Replace participant mic button state with `deriveParticipantMicButton`.
Test every state in the render matrix.

### Step 7 — Add reconnect reconciliation

Implement the `client:rejoin` emit on reconnect and handle `server:room-snapshot`
with `applyRoomSnapshot` in `MicStateStore`.

### Step 8 — Remove old muted field

Once all handlers and UI components are migrated and all tests pass,
delete `participant.muted` / `isMuted` entirely.

### Step 9 — Run test suites

- **iOS:** All XCTest cases in Section 13 must pass.
- **Server (Node.js/Jest):** All test cases from original plan Section 13 must pass.
- End-to-end: Test the full raise-hand flow on device against the updated server.

---

*This document is the complete implementation contract for your Obj-C / Swift / Node.js stack.
The server (Node.js) is implemented exactly as in the original plan.
The iOS client implements the derivation functions, the socket event handlers,
the MicStateStore, and the WebRTC track sync — all translated to Swift / Obj-C.
Implement each section in the order listed. Each section has clear inputs,
outputs, and tests — making it safe to implement and verify incrementally.*
