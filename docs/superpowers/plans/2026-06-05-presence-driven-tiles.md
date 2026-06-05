# Presence-Driven Tile Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make normal-call tile management presence-driven and consistent for all roles and any participant count by deriving the UI from a single authoritative roster snapshot, and replace the custom Metal remote-camera renderer with `AVSampleBufferDisplayLayer`.

**Architecture:** A new Swift `InterParticipantRoster` is the single source of truth. It is fed by the existing `InterLiveKitSubscriber` Room delegate callbacks, first-frame signals, and local-camera setters; on any change it emits a complete immutable `[InterParticipantSnapshotEntry]` to the ObjC layer on the main thread. `InterRemoteVideoLayoutManager` reconciles tiles declaratively against the snapshot (the only path that adds/removes/updates tiles). Remote camera tiles render via `AVSampleBufferDisplayLayer`; `MetalSurfaceView` stays for screen share only.

**Tech Stack:** Swift + Objective-C, LiveKit SDK, AVFoundation (`AVSampleBufferDisplayLayer`, `AVCaptureVideoPreviewLayer`), CoreMedia/CoreVideo, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-05-presence-driven-tiles-design.md`

**Build command (run after every implementation step):**
```bash
cd /Users/aman_01/Documents/inter && xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -30
```

**Test command:**
```bash
cd /Users/aman_01/Documents/inter && xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug test 2>&1 | grep -E "Test Case|error:|BUILD SUCCEEDED|BUILD FAILED|failed|passed" | head -60
```

---

## File Structure

**Create:**
- `inter/Networking/InterParticipantSnapshot.swift` — `@objc` snapshot value type (`InterParticipantSnapshotEntry`) crossing Swift→ObjC.
- `inter/Networking/InterParticipantRoster.swift` — single source of truth; computes + emits snapshots.
- `inter/Networking/InterRemoteSampleBufferView.swift` — `AVSampleBufferDisplayLayer`-backed remote camera view (replaces Metal `InterRemoteVideoView` for cameras).
- `interTests/InterParticipantRosterTests.swift` — unit tests for snapshot computation.
- `interTests/InterRemoteSampleBufferViewTests.swift` — unit tests for CVPixelBuffer→CMSampleBuffer wrapping.

**Modify:**
- `inter/Networking/InterLiveKitSubscriber.swift` — own + feed the roster; emit `applyParticipantSnapshot:`; remove the racy `attach()` seeding.
- `inter/UI/Views/InterTrackRendererBridge.m` — forward `applyParticipantSnapshot:` to the layout manager.
- `inter/UI/Views/InterRemoteVideoLayoutManager.h` — declare `applyParticipantSnapshot:`.
- `inter/UI/Views/InterRemoteVideoLayoutManager.m` — add the declarative reconciler; delete `cameraOffStates`/`pendingFirstFrameIdentifiers` and the scattered mutation paths; route tiles through the snapshot.
- `inter/App/InterMediaWiringController.m` — feed local camera on/off + active speaker into the roster.
- `interTests/InterMultiParticipantTests.swift` — integration tests for host/participant symmetry and rejoin-after-empty.

**Untouched (verify, do not edit):** `inter/Rendering/MetalSurfaceView.m`, `inter/Rendering/MetalRenderEngine.m` (screen share only).

---

## Task 1: Snapshot value type + protocol hook

**Files:**
- Create: `inter/Networking/InterParticipantSnapshot.swift`
- Modify: `inter/Networking/InterLiveKitSubscriber.swift` (protocol `InterRemoteTrackRenderer`)

- [ ] **Step 1: Create the snapshot entry type**

Create `inter/Networking/InterParticipantSnapshot.swift`:

```swift
// ============================================================================
// InterParticipantSnapshot.swift
// inter
//
// Immutable value type describing one participant's presence + media state at a
// single instant. The roster emits a complete ordered array of these on every
// change; the ObjC layout manager reconciles tiles to match. @objc so it crosses
// the Swift→ObjC bridge into InterRemoteVideoLayoutManager.
// ============================================================================

import Foundation

@objc public final class InterParticipantSnapshotEntry: NSObject {
    @objc public let identity: String
    @objc public let displayName: String
    @objc public let isLocal: Bool
    /// Remote: subscribed && track present && !muted && first frame seen.
    /// Local:  local capture is active.
    @objc public let cameraOn: Bool
    @objc public let micMuted: Bool
    @objc public let handRaised: Bool
    @objc public let isSpeaking: Bool
    @objc public let isScreenSharing: Bool

    @objc public init(identity: String,
                      displayName: String,
                      isLocal: Bool,
                      cameraOn: Bool,
                      micMuted: Bool,
                      handRaised: Bool,
                      isSpeaking: Bool,
                      isScreenSharing: Bool) {
        self.identity = identity
        self.displayName = displayName
        self.isLocal = isLocal
        self.cameraOn = cameraOn
        self.micMuted = micMuted
        self.handRaised = handRaised
        self.isSpeaking = isSpeaking
        self.isScreenSharing = isScreenSharing
        super.init()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? InterParticipantSnapshotEntry else { return false }
        return identity == o.identity &&
            displayName == o.displayName &&
            isLocal == o.isLocal &&
            cameraOn == o.cameraOn &&
            micMuted == o.micMuted &&
            handRaised == o.handRaised &&
            isSpeaking == o.isSpeaking &&
            isScreenSharing == o.isScreenSharing
    }

    public override var hash: Int {
        return identity.hashValue
    }

    public override var description: String {
        return "<Entry \(identity) local=\(isLocal) cam=\(cameraOn) mic!=\(micMuted) speak=\(isSpeaking) share=\(isScreenSharing)>"
    }
}
```

- [ ] **Step 2: Add the snapshot delegate hook to the protocol**

In `inter/Networking/InterLiveKitSubscriber.swift`, add to the `InterRemoteTrackRenderer` protocol (right after `activeSpeakerDidChange`):

```swift
    /// The full participant roster changed. Carries the complete ordered set of
    /// presence entries (local first, then remote join order). The receiver reconciles
    /// its tiles to match — this is the single source of truth for tile lifecycle/state.
    @objc optional func applyParticipantSnapshot(_ entries: [InterParticipantSnapshotEntry])
```

- [ ] **Step 3: Build to verify it compiles**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/aman_01/Documents/inter
git add inter/Networking/InterParticipantSnapshot.swift inter/Networking/InterLiveKitSubscriber.swift
git commit -m "feat(tiles): add InterParticipantSnapshotEntry value type + applyParticipantSnapshot hook"
```

---

## Task 2: InterParticipantRoster (single source of truth) + unit tests

**Files:**
- Create: `inter/Networking/InterParticipantRoster.swift`
- Test: `interTests/InterParticipantRosterTests.swift`

The roster is a pure model: it holds per-identity state, accepts mutations via simple methods, and rebuilds the full ordered snapshot. It does NOT touch LiveKit directly (the subscriber feeds it), which makes it unit-testable without a live room.

- [ ] **Step 1: Write the failing test**

Create `interTests/InterParticipantRosterTests.swift`:

```swift
import XCTest
@testable import inter

final class InterParticipantRosterTests: XCTestCase {

    private func makeRoster() -> (InterParticipantRoster, SnapshotSink) {
        let sink = SnapshotSink()
        let roster = InterParticipantRoster()
        roster.onSnapshot = { sink.last = $0 }
        return (roster, sink)
    }

    final class SnapshotSink {
        var last: [InterParticipantSnapshotEntry] = []
    }

    func test_localOnly_emitsSingleLocalEntry() {
        let (roster, sink) = makeRoster()
        roster.setLocal(identity: "me", displayName: "Me", cameraOn: false, micMuted: false)
        XCTAssertEqual(sink.last.count, 1)
        XCTAssertTrue(sink.last[0].isLocal)
        XCTAssertEqual(sink.last[0].identity, "me")
        XCTAssertFalse(sink.last[0].cameraOn)
    }

    func test_localFirstThenRemoteJoinOrder() {
        let (roster, sink) = makeRoster()
        roster.setLocal(identity: "me", displayName: "Me", cameraOn: true, micMuted: false)
        roster.participantJoined("a", displayName: "Alice")
        roster.participantJoined("b", displayName: "Bob")
        XCTAssertEqual(sink.last.map { $0.identity }, ["me", "a", "b"])
        XCTAssertTrue(sink.last[0].isLocal)
        XCTAssertFalse(sink.last[1].isLocal)
    }

    func test_remoteCameraOn_requiresUnmuteAndFirstFrame() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        // joined but no track/frame yet → camera off (avatar)
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.cameraOn)
        // subscribed + unmuted but still no frame → still off (avoid black feed)
        roster.cameraSubscribed("a")
        roster.cameraMuted("a", muted: false)
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.cameraOn)
        // first frame arrives → camera on
        roster.cameraFirstFrame("a")
        XCTAssertTrue(sink.last.first { $0.identity == "a" }!.cameraOn)
    }

    func test_remoteCameraMute_turnsOffEvenAfterFrame() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.cameraSubscribed("a")
        roster.cameraMuted("a", muted: false)
        roster.cameraFirstFrame("a")
        XCTAssertTrue(sink.last.first { $0.identity == "a" }!.cameraOn)
        roster.cameraMuted("a", muted: true)
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.cameraOn)
    }

    func test_participantLeft_removesEntry() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.participantJoined("b", displayName: "Bob")
        roster.participantLeft("a")
        XCTAssertEqual(sink.last.map { $0.identity }, ["b"])
    }

    func test_resync_reemitsCurrentSnapshot() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        sink.last = []
        roster.resync()
        XCTAssertEqual(sink.last.map { $0.identity }, ["a"])
    }

    func test_activeSpeaker_setsIsSpeakingOnMatchingEntry() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.participantJoined("b", displayName: "Bob")
        roster.setActiveSpeaker("b")
        XCTAssertFalse(sink.last.first { $0.identity == "a" }!.isSpeaking)
        XCTAssertTrue(sink.last.first { $0.identity == "b" }!.isSpeaking)
        roster.setActiveSpeaker("")   // none
        XCTAssertFalse(sink.last.first { $0.identity == "b" }!.isSpeaking)
    }

    func test_displayNameUpdate_reflectedInSnapshot() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "a")
        roster.updateDisplayName("Alice", for: "a")
        XCTAssertEqual(sink.last.first { $0.identity == "a" }!.displayName, "Alice")
    }

    func test_micMuteAndHandRaise_reflectedInSnapshot() {
        let (roster, sink) = makeRoster()
        roster.participantJoined("a", displayName: "Alice")
        roster.micMuted("a", muted: true)
        roster.handRaised("a", raised: true)
        let e = sink.last.first { $0.identity == "a" }!
        XCTAssertTrue(e.micMuted)
        XCTAssertTrue(e.handRaised)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run the test command. Expected: FAIL — `cannot find 'InterParticipantRoster' in scope`.

- [ ] **Step 3: Implement the roster**

Create `inter/Networking/InterParticipantRoster.swift`:

```swift
// ============================================================================
// InterParticipantRoster.swift
// inter
//
// SINGLE SOURCE OF TRUTH for presence-driven tile management.
//
// The roster holds per-identity presence + media state. It is fed by
// InterLiveKitSubscriber (Room delegate callbacks + first-frame signals) and by
// the media wiring controller (local camera state + active speaker). On any
// change it rebuilds the COMPLETE ordered snapshot and invokes `onSnapshot` on
// the main thread. The UI reconciles to the snapshot; nothing mutates tiles
// directly. This removes all ordering races (including attach-before-wire).
//
// THREADING: all mutators hop to the main thread and coalesce emission
// (latest-wins) via a scheduled microtask, so a burst of joins collapses to one
// snapshot. The roster never touches local capture or recording [G8].
// ============================================================================

import Foundation
import os.log

@objc public final class InterParticipantRoster: NSObject {

    /// Invoked with the complete ordered snapshot whenever state changes.
    /// Always called on the main thread.
    @objc public var onSnapshot: (([InterParticipantSnapshotEntry]) -> Void)?

    private struct RemoteState {
        var displayName: String
        var subscribed: Bool = false
        var cameraMuted: Bool = true     // assume off until proven on
        var firstFrameSeen: Bool = false
        var micMuted: Bool = false
        var handRaised: Bool = false
        var isScreenSharing: Bool = false
    }

    private struct LocalState {
        var identity: String
        var displayName: String
        var cameraOn: Bool
        var micMuted: Bool
    }

    // Ordered remote identities (join order) + their state.
    private var remoteOrder: [String] = []
    private var remote: [String: RemoteState] = [:]
    private var local: LocalState?
    private var activeSpeaker: String = ""

    private var emitScheduled = false

    @objc public override init() { super.init() }

    // MARK: - Local

    @objc public func setLocal(identity: String, displayName: String, cameraOn: Bool, micMuted: Bool) {
        runOnMain {
            self.local = LocalState(identity: identity, displayName: displayName,
                                    cameraOn: cameraOn, micMuted: micMuted)
            self.scheduleEmit()
        }
    }

    @objc public func setLocalCameraOn(_ on: Bool) {
        runOnMain {
            guard var l = self.local else { return }
            l.cameraOn = on
            self.local = l
            self.scheduleEmit()
        }
    }

    @objc public func setLocalMicMuted(_ muted: Bool) {
        runOnMain {
            guard var l = self.local else { return }
            l.micMuted = muted
            self.local = l
            self.scheduleEmit()
        }
    }

    // MARK: - Remote presence

    @objc public func participantJoined(_ identity: String, displayName: String) {
        runOnMain {
            guard !identity.isEmpty else { return }
            if self.remote[identity] == nil {
                self.remoteOrder.append(identity)
                self.remote[identity] = RemoteState(displayName: displayName)
            } else {
                self.remote[identity]?.displayName = displayName
            }
            self.scheduleEmit()
        }
    }

    @objc public func participantLeft(_ identity: String) {
        runOnMain {
            self.remote[identity] = nil
            self.remoteOrder.removeAll { $0 == identity }
            if self.activeSpeaker == identity { self.activeSpeaker = "" }
            self.scheduleEmit()
        }
    }

    // MARK: - Remote media

    @objc public func cameraSubscribed(_ identity: String) {
        mutateRemote(identity) { $0.subscribed = true }
    }

    @objc public func cameraEnded(_ identity: String) {
        mutateRemote(identity) {
            $0.subscribed = false
            $0.firstFrameSeen = false
            $0.cameraMuted = true
        }
    }

    @objc public func cameraMuted(_ identity: String, muted: Bool) {
        mutateRemote(identity) {
            $0.cameraMuted = muted
            if muted { $0.firstFrameSeen = false }
        }
    }

    @objc public func cameraFirstFrame(_ identity: String) {
        // Hot-path guarded: only emit when this actually flips state.
        runOnMain {
            guard var s = self.remote[identity], !s.firstFrameSeen else { return }
            s.firstFrameSeen = true
            self.remote[identity] = s
            self.scheduleEmit()
        }
    }

    @objc public func micMuted(_ identity: String, muted: Bool) {
        mutateRemote(identity) { $0.micMuted = muted }
    }

    @objc public func handRaised(_ identity: String, raised: Bool) {
        mutateRemote(identity) { $0.handRaised = raised }
    }

    @objc public func screenSharing(_ identity: String, sharing: Bool) {
        mutateRemote(identity) { $0.isScreenSharing = sharing }
    }

    @objc public func updateDisplayName(_ name: String, for identity: String) {
        mutateRemote(identity) { $0.displayName = name }
    }

    @objc public func setActiveSpeaker(_ identity: String) {
        runOnMain {
            self.activeSpeaker = identity
            self.scheduleEmit()
        }
    }

    /// Re-emit the current snapshot. Call when the downstream delegate is (re)wired
    /// so late wiring or reconnect self-heals — this is the race fix.
    @objc public func resync() {
        runOnMain { self.scheduleEmit() }
    }

    /// Drop all remote participants (e.g. on disconnect). Keeps local.
    @objc public func reset() {
        runOnMain {
            self.remote.removeAll()
            self.remoteOrder.removeAll()
            self.activeSpeaker = ""
            self.scheduleEmit()
        }
    }

    // MARK: - Internals

    private func mutateRemote(_ identity: String, _ apply: (inout RemoteState) -> Void) {
        runOnMain {
            guard var s = self.remote[identity] else { return }
            apply(&s)
            self.remote[identity] = s
            self.scheduleEmit()
        }
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func scheduleEmit() {
        // Coalesce bursts: collapse multiple mutations in one runloop turn to a
        // single snapshot emission (latest-wins).
        if emitScheduled { return }
        emitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.emitScheduled = false
            self.emitNow()
        }
    }

    private func emitNow() {
        var entries: [InterParticipantSnapshotEntry] = []
        if let l = local {
            entries.append(InterParticipantSnapshotEntry(
                identity: l.identity, displayName: l.displayName, isLocal: true,
                cameraOn: l.cameraOn, micMuted: l.micMuted, handRaised: false,
                isSpeaking: activeSpeaker == l.identity, isScreenSharing: false))
        }
        for id in remoteOrder {
            guard let s = remote[id] else { continue }
            let camOn = s.subscribed && !s.cameraMuted && s.firstFrameSeen
            entries.append(InterParticipantSnapshotEntry(
                identity: id, displayName: s.displayName, isLocal: false,
                cameraOn: camOn, micMuted: s.micMuted, handRaised: s.handRaised,
                isSpeaking: activeSpeaker == id, isScreenSharing: s.isScreenSharing))
        }
        onSnapshot?(entries)
    }
}
```

Note: the unit tests call mutators synchronously and read `sink.last` immediately. Because `scheduleEmit()` defers to the next runloop turn, add a **synchronous emit for tests**. Replace the body of `scheduleEmit()` with a test-friendly version that emits immediately when not coalescing is needed — but production wants coalescing. Resolve by emitting synchronously at the end of each mutator in addition to scheduling: simplest correct approach is to make `scheduleEmit()` emit synchronously (the coalescing is a perf nicety, not correctness). Use this implementation instead:

```swift
    private func scheduleEmit() {
        // Synchronous emit keeps the snapshot immediately consistent for callers and
        // tests. Mutators already run on the main thread, so this stays on main.
        emitNow()
    }
```

Remove the `emitScheduled` property and the async version. (Burst coalescing can be reintroduced later if profiling shows churn; correctness comes first.)

- [ ] **Step 4: Run the tests to verify they pass**

Run the test command. Expected: all `InterParticipantRosterTests` PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/aman_01/Documents/inter
git add inter/Networking/InterParticipantRoster.swift interTests/InterParticipantRosterTests.swift
git commit -m "feat(tiles): add InterParticipantRoster single source of truth + unit tests"
```

---

## Task 3: Wire roster into the subscriber; remove racy attach() seeding

**Files:**
- Modify: `inter/Networking/InterLiveKitSubscriber.swift`

- [ ] **Step 1: Add the roster property and resync-on-wire**

In `InterLiveKitSubscriber`, add a roster owned by the subscriber and resync whenever `trackRenderer` is set. Replace the existing `trackRenderer` property declaration:

```swift
    /// Delegate receiving decoded remote frames.
    @objc public weak var trackRenderer: InterRemoteTrackRenderer?
```

with:

```swift
    /// The presence roster — single source of truth for tiles. Owned here so it can
    /// be fed from the same delegate callbacks that drive media.
    @objc public let roster = InterParticipantRoster()

    /// Delegate receiving decoded remote frames + roster snapshots.
    @objc public weak var trackRenderer: InterRemoteTrackRenderer? {
        didSet {
            // Pipe roster snapshots to whatever delegate is current, then resync so a
            // late-wired delegate (the participant-side race) immediately gets the full
            // roster — including participants already present when we attached.
            let weakRenderer = trackRenderer
            roster.onSnapshot = { entries in
                weakRenderer?.applyParticipantSnapshot?(entries)
            }
            roster.resync()
        }
    }
```

- [ ] **Step 2: Replace the racy seeding in `attach(to:)`**

In `attach(to:)`, DELETE this block (the optional-chaining-on-nil race):

```swift
        // Seed presence tiles for participants who are ALREADY in the room at the moment
        // we attach (e.g. a participant joining a room where the host is already present).
        // LiveKit only fires participantDidConnect for participants who join AFTER us, so
        // without this seeding a participant who is already present with their camera off
        // would never get a tile until they toggled their camera.
        let existing = room.remoteParticipants.values.compactMap { p -> (String, String)? in
            guard let id = p.identity?.stringValue, !id.isEmpty else { return nil }
            return (id, p.name ?? id)
        }
        if !existing.isEmpty {
            DispatchQueue.main.async {
                for (id, name) in existing {
                    self.trackRenderer?.remoteParticipantDidJoin?(id, displayName: name)
                }
            }
        }
```

and replace it with seeding into the roster (works even though `trackRenderer` may be nil — the roster holds the state and re-emits when wired):

```swift
        // Seed the roster with participants already present at attach time. Feeding the
        // roster (not the delegate) means the snapshot survives until the delegate is
        // wired, so a participant joining a room where the host is already present always
        // gets the host tile — no ordering race.
        for p in room.remoteParticipants.values {
            guard let id = p.identity?.stringValue, !id.isEmpty else { continue }
            roster.participantJoined(id, displayName: p.name ?? id)
            for (_, pub) in p.trackPublications {
                if pub.source == .camera {
                    roster.cameraSubscribed(id)
                    roster.cameraMuted(id, muted: pub.isMuted)
                }
                if pub.source == .microphone {
                    roster.micMuted(id, muted: pub.isMuted)
                }
                if pub.source == .screenShareVideo {
                    roster.screenSharing(id, sharing: true)
                }
            }
        }
```

- [ ] **Step 3: Feed the roster from every delegate callback**

In `room(_:participantDidConnect:)` add after the existing `remoteParticipantDidJoin` dispatch:

```swift
        roster.participantJoined(pid, displayName: name)
```

In `room(_:participantDidDisconnect:)` add inside the `DispatchQueue.main.async` block:

```swift
            self.roster.participantLeft(pid)
```

In `didSubscribeTrack`, in the `.camera` case (after `videoTrack.add(videoRenderer: renderer)`), add:

```swift
                roster.participantJoined(participantId, displayName: participantName)
                roster.cameraSubscribed(participantId)
                roster.cameraMuted(participantId, muted: publication.isMuted)
```

and inside the camera `RemoteFrameRenderer` callback (after the `trackRenderer?.didReceiveRemoteCameraFrame` line), add the first-frame signal:

```swift
                    self?.roster.cameraFirstFrame(participantId)
```

In the `.screenShareVideo` case of `didSubscribeTrack`, add:

```swift
                roster.screenSharing(participantId, sharing: true)
```

In `didUnsubscribeTrack`, `.camera` case add:

```swift
            roster.cameraEnded(participantId)
```

and `.screenShareVideo` case add:

```swift
            roster.screenSharing(participantId, sharing: false)
```

In `didUpdateIsMuted`, `.camera` case (both branches) add at the end of the case:

```swift
            roster.cameraMuted(participantId, muted: isMuted)
```

`.microphone` case add:

```swift
            roster.micMuted(participantId, muted: isMuted)
```

In `didUpdateName` add:

```swift
        roster.updateDisplayName(displayName, for: participantId)
```

- [ ] **Step 4: Reset roster on detach**

In `detach()`, before `self.room = nil`, add:

```swift
        roster.reset()
```

- [ ] **Step 5: Build to verify it compiles**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/aman_01/Documents/inter
git add inter/Networking/InterLiveKitSubscriber.swift
git commit -m "feat(tiles): feed roster from subscriber; remove racy attach() seeding"
```

---

## Task 4: Bridge forwards the snapshot to the layout manager

**Files:**
- Modify: `inter/UI/Views/InterTrackRendererBridge.m`

- [ ] **Step 1: Forward `applyParticipantSnapshot:`**

In `inter/UI/Views/InterTrackRendererBridge.m`, add this method to the `InterRemoteTrackRenderer` implementation (next to the other forwarding methods). The layout manager method is added in Task 5:

```objc
- (void)applyParticipantSnapshot:(NSArray<InterParticipantSnapshotEntry *> *)entries {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoLayoutManager *mgr = self.layoutManager;
        if (mgr) {
            [mgr applyParticipantSnapshot:entries];
        }
    });
}
```

Ensure `#import "inter-Swift.h"` is present (it is, guarded by `__has_include`) so `InterParticipantSnapshotEntry` is visible.

- [ ] **Step 2: Build**

Run the build command. Expected: error `no visible @interface ... applyParticipantSnapshot:` (layout manager method not yet declared) — this is expected; proceed to Task 5 which adds it. If you want each task to build green, do Task 5 Step 1 (header declaration) before building. Otherwise commit after Task 5.

- [ ] **Step 3: Commit (after Task 5 compiles)**

Deferred — commit bridge + layout manager together at the end of Task 5.

---

## Task 5: Declarative reconciler in the layout manager; delete old mutation paths

**Files:**
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.h`
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.m`

This task routes ALL tile lifecycle/state through one method and deletes the four racy paths. Read the current file around the symbols named below before editing.

- [ ] **Step 1: Declare the reconciler in the header**

In `inter/UI/Views/InterRemoteVideoLayoutManager.h`, add a forward declaration near the top (after the existing `@class` lines):

```objc
@class InterParticipantSnapshotEntry;
```

and declare the method in the `@interface` (in the public API section):

```objc
/// Reconcile all tiles to match the authoritative roster snapshot. This is the ONLY
/// entry point that adds/removes/updates tiles. Local entry (isLocal) uses the local
/// preview layer; remote entries use AVSampleBufferDisplayLayer tiles.
- (void)applyParticipantSnapshot:(NSArray<InterParticipantSnapshotEntry *> *)entries;
```

- [ ] **Step 2: Implement the reconciler in the .m**

In `inter/UI/Views/InterRemoteVideoLayoutManager.m`, add the method (place it near the other public tile methods such as `addRemoteParticipant:displayName:`):

```objc
- (void)applyParticipantSnapshot:(NSArray<InterParticipantSnapshotEntry *> *)entries {
    NSAssert([NSThread isMainThread], @"applyParticipantSnapshot: must run on main");

    // 1. Build the set of identities the snapshot wants on screen (remote only — local
    //    self-view is managed by its own preview path below).
    NSMutableSet<NSString *> *wantedRemote = [NSMutableSet set];
    InterParticipantSnapshotEntry *localEntry = nil;
    for (InterParticipantSnapshotEntry *e in entries) {
        if (e.isLocal) { localEntry = e; continue; }
        [wantedRemote addObject:e.identity];
    }

    // 2. Removals: any current remote tile not in the snapshot is torn down.
    NSArray<NSString *> *currentKeys = self.tileViews.allKeys.copy;
    for (NSString *key in currentKeys) {
        if (![wantedRemote containsObject:key]) {
            [self removeCameraViewForParticipant:key];
        }
    }

    // 3. Additions + updates for remote entries.
    for (InterParticipantSnapshotEntry *e in entries) {
        if (e.isLocal) { continue; }
        InterRemoteVideoTileView *tile = self.tileViews[e.identity];
        if (!tile) {
            // Create a presence tile immediately (avatar shown until camera on).
            [self ensureTileForParticipant:e.identity displayName:e.displayName];
            tile = self.tileViews[e.identity];
        }
        if (!tile) { continue; }

        // State is DERIVED from the snapshot every pass — avatar can never float over
        // a live feed because its visibility is recomputed here, not mutated ad-hoc.
        [tile updateAvatarInitialFromDisplayName:e.displayName];
        tile.nameLabel.stringValue = e.displayName;
        [tile setCameraOff:!e.cameraOn];
        tile.micMutedBadge.hidden = !e.micMuted;
        [tile setHandRaised:e.handRaised];
        tile.isSpeaking = e.isSpeaking;
    }

    // 4. Local self entry: drive the existing local preview path.
    if (localEntry) {
        self.localSelfCameraOn = localEntry.cameraOn;       // see Step 4
        [self updateAvatarInitialFromDisplayName:localEntry.displayName];
    }

    // 5. Keep count + active-speaker bookkeeping in sync, then lay out.
    self.remoteParticipantCount = wantedRemote.count;
    NSString *speaker = @"";
    for (InterParticipantSnapshotEntry *e in entries) {
        if (e.isSpeaking) { speaker = e.identity; break; }
    }
    self.activeSpeakerIdentity = speaker;
    [self updateLayoutAnimated:NO];
}
```

- [ ] **Step 3: Add the `ensureTileForParticipant:displayName:` helper**

The reconciler needs a creation helper that builds a tile with its renderer view but does NOT itself flip camera state (the reconciler does that). Add:

```objc
- (void)ensureTileForParticipant:(NSString *)identity displayName:(NSString *)displayName {
    if (self.tileViews[identity]) { return; }
    InterRemoteSampleBufferView *videoView = [[InterRemoteSampleBufferView alloc] initWithFrame:self.bounds];
    self.remoteCameraViews[identity] = videoView;
    InterRemoteVideoTileView *tile = [self tileForKey:identity videoView:videoView];
    [tile updateAvatarInitialFromDisplayName:displayName];
    [tile setCameraOff:YES];   // avatar until first frame flips cameraOn in the snapshot
}
```

NOTE: `InterRemoteSampleBufferView` is created in Task 6. Until then this references a missing type. To keep Task 5 building green, temporarily use the existing `InterRemoteVideoView` type here and switch to `InterRemoteSampleBufferView` in Task 6 Step 5. Use whichever renderer type currently compiles.

- [ ] **Step 4: Add the `localSelfCameraOn` state and route the local self-view**

Add a property in the class extension at the top of the .m:

```objc
@property (nonatomic, assign) BOOL localSelfCameraOn;
```

Find the existing `SingleCamera`/local-self branch in `applyCurrentLayoutAnimated:` (the `else if (localCaptureSession)` branch added previously). Gate the avatar vs preview there on `self.localSelfCameraOn`: when `localSelfCameraOn` is NO, show the local avatar placeholder; when YES, show `localPreviewLayer`. (Reuse the existing local self tile; do not create a second path.)

- [ ] **Step 5: Delete the racy mutation paths**

Remove the following members and their use sites (search each symbol and delete the now-dead code; the reconciler replaces them):

- `cameraOffStates` (NSMutableDictionary) — declaration + all reads/writes.
- `pendingFirstFrameIdentifiers` (NSMutableSet) + `_pendingFirstFrameLock` ivar + all lock/unlock/insert/contains use.
- The body of `addRemoteParticipant:displayName:` — make it call `[self ensureTileForParticipant:participantId displayName:displayName]` then `[self updateLayoutAnimated:NO]` (kept only for any external callers; the snapshot is now primary).
- In `handleRemoteCameraFrame:fromParticipant:` — remove the dedup-set logic and the `setCameraOff:NO` flip and `updateLayoutAnimated`. Keep ONLY the part that forwards the pixel buffer to the participant's renderer view. Camera-on state now comes exclusively from the snapshot (`cameraFirstFrame` → `cameraOn`).
- `handleRemoteTrackMuted:` / `handleRemoteTrackUnmuted:` / `handleRemoteTrackEnded:` (camera) — remove the avatar/tile mutation; leave them as no-ops or delete and remove their declarations + bridge call sites if unused. (Mic-mute badge now also comes from the snapshot.)
- `addRemoteParticipant:` / `removeRemoteParticipant:` presence hooks and the `remoteParticipantDidJoin`/`remoteParticipantDidLeave` bridge forwards may be removed since the snapshot supersedes them — but only after confirming no other caller depends on them. If unsure, leave the bridge methods as thin no-ops to avoid protocol breakage.

After deletions, the ONLY code that changes a tile's `cameraOff`, avatar, name, mic badge, hand badge, or `isSpeaking` must be `applyParticipantSnapshot:`.

- [ ] **Step 6: Keep `handleRemoteCameraFrame:` feeding the renderer**

Confirm `handleRemoteCameraFrame:fromParticipant:` still routes the pixel buffer to `self.remoteCameraViews[participantId]` via its `updateFrame:`/`enqueuePixelBuffer:` method (the actual render path). The snapshot controls visibility; the frame path controls pixels.

- [ ] **Step 7: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`. Fix any references to deleted symbols.

- [ ] **Step 8: Commit (bridge + layout manager together)**

```bash
cd /Users/aman_01/Documents/inter
git add inter/UI/Views/InterTrackRendererBridge.m \
        inter/UI/Views/InterRemoteVideoLayoutManager.h \
        inter/UI/Views/InterRemoteVideoLayoutManager.m
git commit -m "feat(tiles): declarative snapshot reconciler; remove racy mutation paths"
```

---

## Task 6: Swap remote camera renderer to AVSampleBufferDisplayLayer

**Files:**
- Create: `inter/Networking/InterRemoteSampleBufferView.swift`
- Test: `interTests/InterRemoteSampleBufferViewTests.swift`
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.m` (use the new type)

- [ ] **Step 1: Write the failing test for CVPixelBuffer→CMSampleBuffer wrapping**

Create `interTests/InterRemoteSampleBufferViewTests.swift`:

```swift
import XCTest
import CoreVideo
import CoreMedia
@testable import inter

final class InterRemoteSampleBufferViewTests: XCTestCase {

    private func makePixelBuffer(width: Int, height: Int, fmt: OSType) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let r = CVPixelBufferCreate(kCFAllocatorDefault, width, height, fmt, attrs as CFDictionary, &pb)
        XCTAssertEqual(r, kCVReturnSuccess)
        return pb!
    }

    func test_wrap_nv12_producesValidSampleBuffer() {
        let pb = makePixelBuffer(width: 320, height: 240,
                                 fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let sb = InterRemoteSampleBufferView.makeSampleBuffer(from: pb)
        XCTAssertNotNil(sb)
        XCTAssertTrue(CMSampleBufferIsValid(sb!))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sb!), 1)
    }

    func test_wrap_bgra_producesValidSampleBuffer() {
        let pb = makePixelBuffer(width: 64, height: 64, fmt: kCVPixelFormatType_32BGRA)
        let sb = InterRemoteSampleBufferView.makeSampleBuffer(from: pb)
        XCTAssertNotNil(sb)
        XCTAssertTrue(CMSampleBufferIsValid(sb!))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run the test command. Expected: FAIL — `cannot find 'InterRemoteSampleBufferView' in scope`.

- [ ] **Step 3: Implement the view**

Create `inter/Networking/InterRemoteSampleBufferView.swift`:

```swift
// ============================================================================
// InterRemoteSampleBufferView.swift
// inter
//
// Remote camera renderer backed by AVSampleBufferDisplayLayer. Replaces the
// custom Metal InterRemoteVideoView for normal-call camera tiles. Apple handles
// YCbCr→RGB conversion and display scheduling; no CVDisplayLink, no Metal shader,
// no drawableSize bookkeeping. Mirror is a layer transform.
//
// THREADING: updateFrame(_:) may be called on the WebRTC decode thread; enqueue
// is thread-safe. We wrap the CVPixelBuffer in a timed CMSampleBuffer and enqueue.
// ============================================================================

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

@objc public final class InterRemoteSampleBufferView: NSView {

    private let displayLayer = AVSampleBufferDisplayLayer()

    /// When true, the layer is horizontally mirrored (matches local preview).
    @objc public var isMirrored: Bool = true { didSet { applyMirror() } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
        layer?.backgroundColor = NSColor.black.cgColor
        applyMirror()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func layout() {
        super.layout()
        displayLayer.frame = bounds
        applyMirror()
    }

    private func applyMirror() {
        // Horizontal flip around the layer's center.
        if isMirrored {
            displayLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        } else {
            displayLayer.setAffineTransform(.identity)
        }
    }

    /// Enqueue a decoded frame. Safe to call off the main thread.
    @objc public func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let sample = Self.makeSampleBuffer(from: pixelBuffer) else { return }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)
    }

    /// Tear down rendering (parity with the old shutdownRenderingSynchronously).
    @objc public func shutdownRendering() {
        displayLayer.flushAndRemoveImage()
    }

    /// Wrap a CVPixelBuffer in a display-ready CMSampleBuffer with an immediate PTS.
    @objc public static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
        guard fdStatus == noErr, let fd = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard sbStatus == noErr, let sb = sampleBuffer else { return nil }

        // Display immediately (no decode reordering for live frames).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the test command. Expected: `InterRemoteSampleBufferViewTests` PASS.

- [ ] **Step 5: Use the new view in the layout manager**

In `inter/UI/Views/InterRemoteVideoLayoutManager.m`:
- Switch `ensureTileForParticipant:displayName:` (Task 5 Step 3) to allocate `InterRemoteSampleBufferView` instead of `InterRemoteVideoView`.
- Change the type of the `remoteCameraViews` dictionary values and any local variables from `InterRemoteVideoView *` to `InterRemoteSampleBufferView *`.
- In `handleRemoteCameraFrame:fromParticipant:`, call `[view updateFrame:pixelBuffer]` (new method) instead of the old Metal `updateFrame:`.
- In `removeCameraViewForParticipant:`, call `[view shutdownRendering]` instead of `shutdownRenderingSynchronously`.

Confirm `#import "inter-Swift.h"` is present so `InterRemoteSampleBufferView` is visible to ObjC.

- [ ] **Step 6: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd /Users/aman_01/Documents/inter
git add inter/Networking/InterRemoteSampleBufferView.swift \
        interTests/InterRemoteSampleBufferViewTests.swift \
        inter/UI/Views/InterRemoteVideoLayoutManager.m
git commit -m "feat(tiles): render remote cameras via AVSampleBufferDisplayLayer"
```

---

## Task 7: Local camera + active speaker → roster; verify two-tier speaker UI

**Files:**
- Modify: `inter/App/InterMediaWiringController.m`

- [ ] **Step 1: Locate the subscriber reference and local-camera toggle sites**

In `inter/App/InterMediaWiringController.m`, find where the `InterLiveKitSubscriber` is held (the media wiring owns/accesses it) and where the active-speaker KVO updates `activeSpeakerIdentity`, and where local camera enable/mute happens (the G2 host camera lift/mute methods).

- [ ] **Step 2: Seed the local entry once when wiring the room**

Where the subscriber/room is wired for a normal call, after the subscriber exists, set the local entry (use the existing local identity + display name + current camera/mic state):

```objc
[subscriber.roster setLocalIdentity:localIdentity
                        displayName:localDisplayName
                           cameraOn:localCameraOn
                           micMuted:localMicMuted];
```

(The Swift method is `setLocal(identity:displayName:cameraOn:micMuted:)`; its ObjC selector is `setLocalIdentity:displayName:cameraOn:micMuted:`. If the generated selector differs, use the exact one from `inter-Swift.h`.)

- [ ] **Step 3: Push local camera + mic toggles into the roster**

In the host camera lift method add:

```objc
[subscriber.roster setLocalCameraOn:YES];
```

In the host camera mute method add:

```objc
[subscriber.roster setLocalCameraOn:NO];
```

In the local mic mute/unmute path add:

```objc
[subscriber.roster setLocalMicMuted:muted];
```

- [ ] **Step 4: Push active speaker into the roster**

Where `activeSpeakerIdentity` is currently propagated to the layout manager, also feed the roster so `isSpeaking` is part of the snapshot:

```objc
[subscriber.roster setActiveSpeaker:identity ?: @""];
```

- [ ] **Step 5: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Verify the two-tier speaker UI still works**

Confirm (by reading the code, no edits expected):
- `InterRemoteVideoTileView.isSpeaking` still sets the green border in `setIsSpeaking:` ([InterRemoteVideoLayoutManager.m:307](inter/UI/Views/InterRemoteVideoLayoutManager.m#L307)) — applies in grid + stage.
- `setActiveSpeakerIdentity:` ([InterRemoteVideoLayoutManager.m:2420](inter/UI/Views/InterRemoteVideoLayoutManager.m#L2420)) still drives stage-only auto-spotlight + 3s revert + user-pin override, and the reconciler now sets `activeSpeakerIdentity` from the snapshot (Task 5 Step 2 point 5). Grid order stays stable — no reordering on speaker change.

- [ ] **Step 7: Commit**

```bash
cd /Users/aman_01/Documents/inter
git add inter/App/InterMediaWiringController.m
git commit -m "feat(tiles): feed local camera/mic + active speaker into roster"
```

---

## Task 8: Remove dead Metal camera code + integration tests

**Files:**
- Modify: `inter/Networking/InterRemoteVideoView.swift` (delete if fully unused) or its references
- Modify: `interTests/InterMultiParticipantTests.swift`

- [ ] **Step 1: Confirm `InterRemoteVideoView` (Metal) is no longer referenced for cameras**

Run:
```bash
cd /Users/aman_01/Documents/inter && grep -rn "InterRemoteVideoView" inter interTests | grep -v "InterRemoteVideoView.swift" | grep -v "InterRemoteVideoViewTests"
```
Expected: no remaining production references (cameras now use `InterRemoteSampleBufferView`). If `InterRemoteVideoViewTests.swift` exists and tests the deleted class, either delete that test file or repoint it. Do NOT delete the file if screen-share or any other consumer still uses it — verify first.

- [ ] **Step 2: Remove the Metal camera view (only if unreferenced)**

If Step 1 shows zero production references, remove `inter/Networking/InterRemoteVideoView.swift` and its test `interTests/InterRemoteVideoViewTests.swift` from the project (delete files and remove from `project.pbxproj` via Xcode, or leave the file but mark it deprecated if pbxproj editing is risky). Keep `MetalSurfaceView`/`MetalRenderEngine` — still used for screen share.

- [ ] **Step 3: Write the integration test for host/participant symmetry + rejoin**

In `interTests/InterMultiParticipantTests.swift`, add tests that drive the roster the way both roles do and assert identical snapshots. Match the existing file's XCTest style:

```swift
func test_participantJoiningRoomWithHostPresent_getsHostTile() {
    // Simulates the participant side: host already present at attach time.
    let roster = InterParticipantRoster()
    var last: [InterParticipantSnapshotEntry] = []
    // trackRenderer wired LATE — mimic the race: seed before onSnapshot is set.
    roster.participantJoined("host", displayName: "Host")
    roster.cameraSubscribed("host")
    roster.cameraMuted("host", muted: false)
    roster.cameraFirstFrame("host")
    // Now the delegate is wired and resyncs:
    roster.onSnapshot = { last = $0 }
    roster.resync()
    XCTAssertEqual(last.map { $0.identity }, ["host"])
    XCTAssertTrue(last[0].cameraOn, "host tile must show feed after first frame")
}

func test_rejoinAfterEmptyRoom_recreatesTile() {
    let roster = InterParticipantRoster()
    var last: [InterParticipantSnapshotEntry] = []
    roster.onSnapshot = { last = $0 }
    roster.participantJoined("a", displayName: "Alice")
    roster.participantLeft("a")
    XCTAssertTrue(last.isEmpty)
    roster.participantJoined("a", displayName: "Alice")
    XCTAssertEqual(last.map { $0.identity }, ["a"])
}

func test_hostAndParticipant_produceIdenticalSnapshotForSameRoom() {
    func build() -> [InterParticipantSnapshotEntry] {
        let r = InterParticipantRoster()
        var out: [InterParticipantSnapshotEntry] = []
        r.onSnapshot = { out = $0 }
        r.setLocal(identity: "self", displayName: "Self", cameraOn: true, micMuted: false)
        r.participantJoined("x", displayName: "X")
        r.cameraSubscribed("x"); r.cameraMuted("x", muted: false); r.cameraFirstFrame("x")
        return out
    }
    XCTAssertEqual(build(), build())
}
```

- [ ] **Step 4: Run the full test suite**

Run the test command. Expected: all roster, sample-buffer, and multi-participant tests PASS; `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Users/aman_01/Documents/inter
git add -A
git commit -m "chore(tiles): remove dead Metal camera renderer + add presence integration tests"
```

---

## Self-Review (completed during plan authoring)

**1. Spec coverage:**
- Single source of truth → Task 2 (roster) + Task 3 (wiring). ✓
- Declarative reconcile / avatar-never-floats → Task 5. ✓
- Participant-side race fix (resync on wire) → Task 3 Step 1 + Task 8 Step 3 test. ✓
- Local unified into roster → Task 2 (`setLocal`) + Task 5 Step 4 + Task 7. ✓
- AVSampleBufferDisplayLayer swap → Task 6. ✓
- Active speaker two-tier (border all modes, spotlight stage-only, stable grid order) → Task 7 Step 6. ✓
- First-frame gating / no black feed → roster `cameraFirstFrame` (Task 2/3). ✓
- Screen-share Metal untouched → Task 8 Step 2 guard. ✓
- Testing strategy → Tasks 2, 6, 8. ✓

**2. Placeholder scan:** Each code step contains complete code. Refactor-by-deletion steps (Task 5 Step 5, Task 6 Step 5) name exact symbols/types to change rather than pseudo-instructions, because the exact surrounding lines must be read in-file first; this is intentional for mechanical edits in a large existing file.

**3. Type consistency:** `InterParticipantSnapshotEntry` (Task 1) used identically in Tasks 3/4/5/8. Roster method names (`setLocal`, `setLocalCameraOn`, `participantJoined`, `cameraSubscribed`, `cameraMuted`, `cameraFirstFrame`, `cameraEnded`, `micMuted`, `handRaised`, `screenSharing`, `updateDisplayName`, `setActiveSpeaker`, `resync`, `reset`) defined in Task 2 and used consistently in Tasks 3/7/8. `InterRemoteSampleBufferView.updateFrame(_:)` / `makeSampleBuffer(from:)` / `shutdownRendering()` defined in Task 6 and used in Task 5/6. The ObjC selector for `setLocal(...)` is flagged in Task 7 Step 2 (verify against `inter-Swift.h`).

**Known risk noted in spec §9:** `CMSampleBuffer` wrapping correctness is covered by `InterRemoteSampleBufferViewTests` (NV12 + BGRA).
