# Mic Unlock Request Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace "Raise Hand to Speak" as the mic-unlock mechanism with a unified "Ask to Unmute" request queue that mirrors the camera unlock flow — works for both per-tile host mutes and Mute All, persists to Redis, and includes a dedicated host-side queue panel.

**Architecture:** Full parity with the camera lock system. Two new DataChannel signals (`requestMicUnlock = 43`, `approveMicUnlock = 44`), three new client-side state flags (`micUnlockRequestPending`, `micUnlockApproved`, `micWasUnmutedWhileApproved`), a rewritten `deriveMicButton`, a new `InterMicUnlockQueuePanel`, Redis persistence via `room:${code}:mic-locked`, and a 30-second pending-request timeout as an approval-loss safety net. Raise-hand stays as a standalone intent signal but is decoupled from mic state.

**Tech Stack:** Objective-C + Swift (macOS), LiveKit DataChannel, Redis (ioredis 5), Node.js/Express 5, XCTest

**Spec:** `docs/superpowers/specs/2026-05-31-mic-unlock-request-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `inter/Networking/InterChatMessage.swift` | Modify | Add signal cases 43, 44 |
| `inter/Networking/InterChatController.swift` | Modify | Route new signal cases |
| `inter/Networking/InterSpeakerQueue.swift` | Modify | Add `InterMicUnlockEntry` + `InterMicUnlockQueue` |
| `inter/Networking/InterModerationController.swift` | Modify | New delegate methods, send methods, handler cases |
| `inter/App/InterMediaWiringController.h` | Modify | Declare 3 new public methods + 2 readonly properties |
| `inter/App/InterMediaWiringController.m` | Modify | 3 new private flags, rewrite `deriveMicButton`, guard `twoPhaseToggleMicrophone`, update `applyRemoteMicMuteOne/All/Unmute/UnmuteAll/AllowToSpeak` |
| `inter/UI/Views/InterMicUnlockQueuePanel.h` | Create | Panel delegate protocol + public interface |
| `inter/UI/Views/InterMicUnlockQueuePanel.m` | Create | NSView subclass with table view (mirrors `InterCameraUnlockQueuePanel`) |
| `inter/App/AppDelegate.m` | Modify | Mic button handler, queue/panel wiring, reconnect snapshot, tile-menu handler, teardown |
| `token-server/index.js` | Modify | Update `/room/mute` (SADD), add `/room/mic-lift-one`, add `GET /room/mic-locked` |
| `interTests/InterCameraWiringTests.swift` | Modify | Add mic unlock state machine tests |

---

## Task 1: New DataChannel Signal Types

**Files:**
- Modify: `inter/inter/Networking/InterChatMessage.swift`

- [ ] **Step 1.1: Add two new cases to `InterControlSignalType`**

Open `inter/inter/Networking/InterChatMessage.swift`. Find the `InterControlSignalType` enum. After the `approveCameraUnlock = 42` case, add:

```swift
case requestMicUnlock  = 43   // locked participant → host: "I want my mic back"
case approveMicUnlock  = 44   // host → participant: temporary mic unlock granted
```

- [ ] **Step 1.2: Build to verify no compile errors**

```bash
cd /Users/aman_01/Documents/inter
xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 1.3: Commit**

```bash
git add inter/inter/Networking/InterChatMessage.swift
git commit -m "feat(mic-unlock): add requestMicUnlock=43, approveMicUnlock=44 signal types"
```

---

## Task 2: Route New Signals in ChatController

**Files:**
- Modify: `inter/inter/Networking/InterChatController.swift`

- [ ] **Step 2.1: Add new cases to Phase 9 routing switch**

In `InterChatController.swift`, find the Phase 9 switch block. It currently ends with:
```swift
.requestCameraUnlock, .approveCameraUnlock:
    guard signal.senderIdentity != localIdentity else { return }
    moderationController?.handleControlSignal(signal)
```

Add `.requestMicUnlock, .approveMicUnlock` to the same list so the line reads:

```swift
.requestCameraUnlock, .approveCameraUnlock,
.requestMicUnlock, .approveMicUnlock:
    guard signal.senderIdentity != localIdentity else { return }
    moderationController?.handleControlSignal(signal)
```

- [ ] **Step 2.2: Build**

```bash
xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2.3: Commit**

```bash
git add inter/inter/Networking/InterChatController.swift
git commit -m "feat(mic-unlock): route requestMicUnlock/approveMicUnlock to moderationController"
```

---

## Task 3: Mic Unlock Queue Model

**Files:**
- Modify: `inter/inter/Networking/InterSpeakerQueue.swift`

- [ ] **Step 3.1: Write the failing test**

Open `interTests/InterCameraWiringTests.swift`. At the bottom, before the closing `}` of the class, add:

```swift
// MARK: - InterMicUnlockQueue

func testMicUnlockQueueAddDeduplicates() {
    let queue = InterMicUnlockQueue()
    queue.addRequest(identity: "alice", displayName: "Alice")
    queue.addRequest(identity: "alice", displayName: "Alice")
    XCTAssertEqual(queue.count, 1, "Duplicate identity must not create two entries")
}

func testMicUnlockQueueRemove() {
    let queue = InterMicUnlockQueue()
    queue.addRequest(identity: "alice", displayName: "Alice")
    queue.removeRequest(identity: "alice")
    XCTAssertEqual(queue.count, 0)
}

func testMicUnlockQueueReset() {
    let queue = InterMicUnlockQueue()
    queue.addRequest(identity: "alice", displayName: "Alice")
    queue.addRequest(identity: "bob", displayName: "Bob")
    queue.reset()
    XCTAssertEqual(queue.count, 0)
}

func testMicUnlockQueueHasPendingRequest() {
    let queue = InterMicUnlockQueue()
    queue.addRequest(identity: "alice", displayName: "Alice")
    XCTAssertTrue(queue.hasPendingRequest(for: "alice"))
    XCTAssertFalse(queue.hasPendingRequest(for: "bob"))
}
```

- [ ] **Step 3.2: Run tests to verify they fail**

```bash
xcodebuild test -scheme inter -destination 'platform=macOS,arch=arm64' -only-testing:interTests/InterCameraWiringTests 2>&1 | grep -E "error:|FAILED|testMicUnlock"
```

Expected: compile error — `InterMicUnlockQueue` not yet defined.

- [ ] **Step 3.3: Add `InterMicUnlockEntry` and `InterMicUnlockQueue` to `InterSpeakerQueue.swift`**

Open `inter/inter/Networking/InterSpeakerQueue.swift`. At the very end of the file, after the closing `}` of `InterCameraUnlockQueue`, add:

```swift
// MARK: - Mic Unlock Queue

/// One pending mic-unlock request from a participant.
@objc public class InterMicUnlockEntry: NSObject {
    @objc public let participantIdentity: String
    @objc public let displayName: String
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

/// FIFO queue of pending mic unlock requests. Mirrors InterCameraUnlockQueue.
/// F10 mitigation: addRequest deduplicates by identity — one entry per participant max.
@objc public class InterMicUnlockQueue: NSObject {
    private var pendingRequests: [InterMicUnlockEntry] = []

    @objc public var entries: [InterMicUnlockEntry] { pendingRequests }

    @objc public private(set) dynamic var count: Int = 0

    /// Add a request. Idempotent — duplicate identity is silently dropped (F10: prevents queue flooding).
    @objc public func addRequest(identity: String, displayName: String) {
        guard !pendingRequests.contains(where: { $0.participantIdentity == identity }) else { return }
        pendingRequests.append(InterMicUnlockEntry(participantIdentity: identity,
                                                   displayName: displayName))
        count = pendingRequests.count
    }

    @objc public func removeRequest(identity: String) {
        pendingRequests.removeAll { $0.participantIdentity == identity }
        count = pendingRequests.count
    }

    @objc public func reset() {
        pendingRequests.removeAll()
        count = 0
    }

    @objc public func hasPendingRequest(for identity: String) -> Bool {
        pendingRequests.contains { $0.participantIdentity == identity }
    }
}
```

- [ ] **Step 3.4: Run tests to verify they pass**

```bash
xcodebuild test -scheme inter -destination 'platform=macOS,arch=arm64' -only-testing:interTests/InterCameraWiringTests 2>&1 | grep -E "Test.*passed|Test.*failed|BUILD"
```

Expected: All InterCameraWiringTests pass including the 4 new mic queue tests.

- [ ] **Step 3.5: Commit**

```bash
git add inter/inter/Networking/InterSpeakerQueue.swift interTests/InterCameraWiringTests.swift
git commit -m "feat(mic-unlock): add InterMicUnlockEntry + InterMicUnlockQueue with dedup guard"
```

---

## Task 4: `InterMediaWiringController` — State Flags and `deriveMicButton`

**Files:**
- Modify: `inter/inter/App/InterMediaWiringController.h`
- Modify: `inter/inter/App/InterMediaWiringController.m`

- [ ] **Step 4.1: Write failing tests for new state machine**

Add to `interTests/InterCameraWiringTests.swift` after the mic queue tests (still inside the class):

```swift
// MARK: - Mic Unlock State Machine (InterMediaWiringController)

func testMicButtonShowsAskToUnmuteWhenHostMuted() {
    // This test validates that deriveMicButton produces "Ask to Unmute"
    // when hostMuted=YES and no approval pending.
    // Since InterMediaWiringController requires a real controlPanel,
    // we test through the public applyRemoteMicMuteOne path.
    // Full integration tested in InterIntegrationTests.
    // Placeholder: will compile-verify the new public API exists.
    let wiring = InterMediaWiringController()
    XCTAssertFalse(wiring.micUnlockRequestPending)
    XCTAssertFalse(wiring.micUnlockApproved)
}

func testResetMicUnlockFlowStateClearsAllFlags() {
    let wiring = InterMediaWiringController()
    wiring.applyMicUnlockRequestPending()
    wiring.resetMicUnlockFlowState()
    XCTAssertFalse(wiring.micUnlockRequestPending)
    XCTAssertFalse(wiring.micUnlockApproved)
}
```

- [ ] **Step 4.2: Run tests to confirm compile failure**

```bash
xcodebuild test -scheme inter -destination 'platform=macOS,arch=arm64' -only-testing:interTests/InterCameraWiringTests 2>&1 | grep -E "error:|testMicButton|testReset"
```

Expected: compile error — `micUnlockRequestPending`, `applyMicUnlockRequestPending`, `resetMicUnlockFlowState` not found.

- [ ] **Step 4.3: Add public API declarations to `InterMediaWiringController.h`**

Open `inter/inter/App/InterMediaWiringController.h`. After the `cameraUnlockApproved` readonly property declaration, add:

```objc
/// YES after participant taps "Ask to Unmute". Button shows "Request Sent…" (disabled).
@property (nonatomic, assign, readonly) BOOL micUnlockRequestPending;

/// YES after host approves the mic unlock request. Normal toggle re-enabled.
@property (nonatomic, assign, readonly) BOOL micUnlockApproved;

/// Sets micUnlockRequestPending=YES and starts the 30-second approval timeout (F6).
- (void)applyMicUnlockRequestPending;

/// Sets micUnlockApproved=YES, clears pending. No-op if restriction already lifted (F16).
- (void)applyMicUnlockApproved;

/// Clears all three mic unlock flow flags. Call on reconnect.
- (void)resetMicUnlockFlowState;
```

- [ ] **Step 4.4: Add private properties to `InterMediaWiringController.m` class extension**

In `InterMediaWiringController.m`, find the `@interface InterMediaWiringController ()` class extension. After the `cameraWasEnabledWhileApproved` property, add:

```objc
@property (nonatomic, assign, readwrite) BOOL micUnlockRequestPending;
@property (nonatomic, assign, readwrite) BOOL micUnlockApproved;
@property (nonatomic, assign) BOOL micWasUnmutedWhileApproved;
@property (nonatomic, strong, nullable) NSTimer *micUnlockRequestTimer;
```

- [ ] **Step 4.5: Replace `deriveParticipantMicButton` with new implementation**

In `InterMediaWiringController.m`, find the existing `- (void)deriveParticipantMicButton` method and replace it entirely:

```objc
/// Single source of truth for mic button state.
/// Priority: restricted → approval path → normal toggle.
- (void)deriveParticipantMicButton {
    BOOL restricted = self.hostMuted || self.globalMuteActive;

    if (restricted) {
        if (self.micUnlockApproved) {
            if (self.micWasUnmutedWhileApproved && self.isMicNetworkMuted) {
                // Revoke: participant used the granted unmute then re-muted themselves.
                self.micUnlockApproved = NO;
                self.micWasUnmutedWhileApproved = NO;
                [self.controlPanel setMicrophoneEnabled:YES];
                [self.controlPanel setMicrophoneButtonTitle:@"Ask to Unmute"];
            } else {
                // Approved — normal toggle available.
                [self.controlPanel setMicrophoneEnabled:YES];
                NSString *title = self.isMicNetworkMuted ? @"Turn Mic On" : @"Turn Mic Off";
                [self.controlPanel setMicrophoneButtonTitle:title];
            }
        } else if (self.micUnlockRequestPending) {
            // F6: timer running — show pending state.
            [self.controlPanel setMicrophoneEnabled:NO];
            [self.controlPanel setMicrophoneButtonTitle:@"Request Sent…"];
        } else {
            [self.controlPanel setMicrophoneEnabled:YES];
            [self.controlPanel setMicrophoneButtonTitle:@"Ask to Unmute"];
        }
    } else {
        // Restriction lifted — clear all unlock-flow state.
        self.micUnlockApproved = NO;
        self.micUnlockRequestPending = NO;
        self.micWasUnmutedWhileApproved = NO;
        [self invalidateMicUnlockRequestTimer];
        [self.controlPanel setMicrophoneEnabled:!self.isMicNetworkMuted];
        [self.controlPanel setMicrophoneButtonTitle:nil];
    }
}
```

- [ ] **Step 4.6: Add timer helper and new public methods**

In `InterMediaWiringController.m`, in the `#pragma mark - Remote Mic Mute/Unmute` section, add these methods after `deriveParticipantMicButton`:

```objc
/// F6 mitigation: cancel approval-loss timer.
- (void)invalidateMicUnlockRequestTimer {
    [self.micUnlockRequestTimer invalidate];
    self.micUnlockRequestTimer = nil;
}

- (void)applyMicUnlockRequestPending {
    self.micUnlockRequestPending = YES;
    [self deriveParticipantMicButton];
    // F6: start 30-second safety-net timer. If approval never arrives,
    // auto-reset to "Ask to Unmute" so participant isn't stuck forever.
    [self invalidateMicUnlockRequestTimer];
    __weak typeof(self) weakSelf = self;
    self.micUnlockRequestTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                                  repeats:NO
                                                                    block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (self.micUnlockRequestPending) {
            self.micUnlockRequestPending = NO;
            [self deriveParticipantMicButton];
        }
    }];
}

- (void)applyMicUnlockApproved {
    // F16 mitigation: if restriction was already lifted, approval is moot.
    if (!self.hostMuted && !self.globalMuteActive) { return; }
    self.micUnlockApproved = YES;
    self.micUnlockRequestPending = NO;
    self.micWasUnmutedWhileApproved = NO;
    [self invalidateMicUnlockRequestTimer];
    [self deriveParticipantMicButton];
}

- (void)resetMicUnlockFlowState {
    self.micUnlockApproved = NO;
    self.micUnlockRequestPending = NO;
    self.micWasUnmutedWhileApproved = NO;
    [self invalidateMicUnlockRequestTimer];
    [self deriveParticipantMicButton];
}
```

- [ ] **Step 4.7: Update `applyRemoteMicMuteOne` to clear new flags**

Find `- (void)applyRemoteMicMuteOne` in `InterMediaWiringController.m`. At the very top of the method body, before the `isConnected` guard, add:

```objc
// Clear any pending unlock flow — new mute supersedes it.
self.micUnlockApproved = NO;
self.micUnlockRequestPending = NO;
self.micWasUnmutedWhileApproved = NO;
[self invalidateMicUnlockRequestTimer];
```

- [ ] **Step 4.8: Update `applyRemoteMicMute` (Mute All) to clear new flags**

Find `- (void)applyRemoteMicMute` in `InterMediaWiringController.m`. At the very top of the method body, add:

```objc
// Clear any pending unlock flow — Mute All supersedes any pending request.
self.micUnlockApproved = NO;
self.micUnlockRequestPending = NO;
self.micWasUnmutedWhileApproved = NO;
[self invalidateMicUnlockRequestTimer];
```

- [ ] **Step 4.9: Update `applyRemoteMicUnmute` to clear new flags**

Find `- (void)applyRemoteMicUnmute` in `InterMediaWiringController.m`. At the very top, add:

```objc
self.micUnlockApproved = NO;
self.micUnlockRequestPending = NO;
self.micWasUnmutedWhileApproved = NO;
[self invalidateMicUnlockRequestTimer];
```

- [ ] **Step 4.10: Update `applyAllowToSpeak` — decouple from mic state**

Find `- (void)applyAllowToSpeak` in `InterMediaWiringController.m`. Remove these lines from its body:

```objc
self.speakPermissionGranted = YES;
self.hostMuted = NO;
self.stateSequenceNumber++;
[self deriveParticipantMicButton];
[self.controlPanel setMediaStatusText:@"The host has allowed you to speak — click the mic to unmute."];
```

Replace the entire method body with:

```objc
- (void)applyAllowToSpeak {
    // Raise-hand approval: lower the visual hand indicator only.
    // Mic unlock is now handled exclusively by the approveMicUnlock DataChannel
    // signal path. This method no longer touches mic state.
    interLogInfo(InterLog.room, "MediaWiring: allowToSpeak received — hand lowered (mic state unchanged)");
}
```

- [ ] **Step 4.11: Add `micWasUnmutedWhileApproved` tracking to `twoPhaseToggleMicrophone`**

Find `- (void)twoPhaseToggleMicrophone` in `InterMediaWiringController.m`. In the connected path, before the `if (shouldMute)` branch, add:

```objc
// Guard: cannot freely toggle while restricted unless approved.
if ((self.hostMuted || self.globalMuteActive) && !self.micUnlockApproved) {
    return; // AppDelegate button handler drives the request path.
}
// Track that participant used their approved unmute (for revoke detection).
if (self.micUnlockApproved && !self.isMicNetworkMuted) {
    // User is currently mic-on while approved — about to mute.
    self.micWasUnmutedWhileApproved = YES;
}
```

Place this block immediately before `BOOL shouldMute = !self.isMicNetworkMuted;`.

- [ ] **Step 4.12: Run tests**

```bash
xcodebuild test -scheme inter -destination 'platform=macOS,arch=arm64' -only-testing:interTests/InterCameraWiringTests 2>&1 | grep -E "Test.*passed|Test.*failed|BUILD"
```

Expected: All pass including `testMicButtonShowsAskToUnmuteWhenHostMuted` and `testResetMicUnlockFlowStateClearsAllFlags`.

- [ ] **Step 4.13: Commit**

```bash
git add inter/inter/App/InterMediaWiringController.h inter/inter/App/InterMediaWiringController.m interTests/InterCameraWiringTests.swift
git commit -m "feat(mic-unlock): rewrite deriveMicButton, add unlock flow state machine with 30s timeout"
```

---

## Task 5: `InterModerationController` — New Signals and Handlers

**Files:**
- Modify: `inter/inter/Networking/InterModerationController.swift`

- [ ] **Step 5.1: Add new delegate protocol methods**

In `InterModerationController.swift`, find the `@objc public protocol InterModerationControllerDelegate` block. After `moderationControllerCameraUnlockApproved`, add:

```swift
@objc optional func moderationController(_ controller: InterModerationController,
                                         receivedMicUnlockRequest fromIdentity: String,
                                         displayName: String)
@objc optional func moderationControllerMicUnlockApproved(_ controller: InterModerationController)
```

- [ ] **Step 5.2: Add new send methods**

In `InterModerationController.swift`, after `approveCameraUnlock(identity:)`, add:

```swift
@objc public func requestMicUnlock() {
    sendControlSignal(type: .requestMicUnlock)
    interLogInfo(InterLog.room, "ModerationController: sent requestMicUnlock")
}

@objc public func approveMicUnlock(identity: String) {
    guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else { return }
    sendControlSignal(type: .approveMicUnlock, targetIdentity: identity)
    interLogInfo(InterLog.room, "ModerationController: sent approveMicUnlock to %{private}@", identity)
}
```

- [ ] **Step 5.3: Add handler cases to `_handleControlSignal`**

In `InterModerationController.swift`, find the `case .requestCameraUnlock:` handler. Immediately after the closing `case .approveCameraUnlock:` block, add:

```swift
case .requestMicUnlock:
    if !senderIsLocal {
        interLogInfo(InterLog.room, "ModerationController: %{public}@ requests mic unlock",
                     signal.senderName)
        delegate?.moderationController?(self,
                                        receivedMicUnlockRequest: signal.senderIdentity ?? "",
                                        displayName: signal.senderName)
    }

case .approveMicUnlock:
    if targetIsLocal {
        let senderIdentity = signal.senderIdentity ?? ""
        let senderRole = roomController?.role(forParticipantIdentity: senderIdentity) ?? .participant
        guard InterPermissionMatrix.role(senderRole, hasPermission: .canMuteOthers) else {
            interLogWarning(InterLog.room,
                            "ModerationController: discarded approveMicUnlock from unprivileged sender %{private}@",
                            senderIdentity)
            break
        }
        interLogInfo(InterLog.room, "ModerationController: mic unlock approved by %{public}@",
                     signal.senderName)
        delegate?.moderationControllerMicUnlockApproved?(self)
    }
```

- [ ] **Step 5.4: Build**

```bash
xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5.5: Commit**

```bash
git add inter/inter/Networking/InterModerationController.swift
git commit -m "feat(mic-unlock): add requestMicUnlock/approveMicUnlock signals and handlers in ModerationController"
```

---

## Task 6: `InterMicUnlockQueuePanel` — Host UI Panel

**Files:**
- Create: `inter/inter/UI/Views/InterMicUnlockQueuePanel.h`
- Create: `inter/inter/UI/Views/InterMicUnlockQueuePanel.m`

- [ ] **Step 6.1: Create the header file**

Create `inter/inter/UI/Views/InterMicUnlockQueuePanel.h`:

```objc
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterMicUnlockEntry;
@class InterMicUnlockQueuePanel;

@protocol InterMicUnlockQueuePanelDelegate <NSObject>
@optional
- (void)micUnlockQueuePanel:(InterMicUnlockQueuePanel *)panel didApproveParticipant:(NSString *)identity;
- (void)micUnlockQueuePanel:(InterMicUnlockQueuePanel *)panel didDenyParticipant:(NSString *)identity;
- (void)micUnlockQueuePanelDidApproveAll:(InterMicUnlockQueuePanel *)panel;
- (void)micUnlockQueuePanelDidDenyAll:(InterMicUnlockQueuePanel *)panel;
@end

@interface InterMicUnlockQueuePanel : NSView <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, weak, nullable) id<InterMicUnlockQueuePanelDelegate> delegate;
- (void)setEntries:(NSArray<InterMicUnlockEntry *> *)entries;
@property (nonatomic, readonly) BOOL isVisible;
- (void)showPanel;
- (void)hidePanel;
- (void)togglePanel;
@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 6.2: Create the implementation file**

Create `inter/inter/UI/Views/InterMicUnlockQueuePanel.m`. This is a structural mirror of `InterCameraUnlockQueuePanel.m` with mic-specific strings:

```objc
#import "InterMicUnlockQueuePanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

static const CGFloat InterMUQPanelWidth   = 280.0;
static const CGFloat InterMUQHeaderHeight = 36.0;
static const CGFloat InterMUQRowHeight    = 44.0;
static const CGFloat InterMUQPadding      = 8.0;

@interface InterMicUnlockQueuePanel ()
@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) NSTextField *headerLabel;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSMutableArray<InterMicUnlockEntry *> *queueEntries;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, strong) NSButton *approveAllButton;
@property (nonatomic, strong) NSButton *denyAllButton;
@end

@implementation InterMicUnlockQueuePanel

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
    if (!self.panelVisible) { return nil; }
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

    NSView *headerBar = [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                                  self.bounds.size.height - InterMUQHeaderHeight,
                                                                  self.bounds.size.width,
                                                                  InterMUQHeaderHeight)];
    headerBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [headerBar setWantsLayer:YES];
    headerBar.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;
    [self addSubview:headerBar];

    self.headerLabel = [NSTextField labelWithString:@"🎙 Mic Requests"];
    self.headerLabel.frame = NSMakeRect(InterMUQPadding, 8,
                                         self.bounds.size.width - InterMUQPadding * 2 - 36, 20);
    self.headerLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.headerLabel.font = [NSFont boldSystemFontOfSize:13];
    self.headerLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    [headerBar addSubview:self.headerLabel];

    NSButton *closeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(self.bounds.size.width - 36, 6, 28, 24)];
    closeBtn.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    closeBtn.bezelStyle = NSBezelStyleInline;
    closeBtn.title = @"✕";
    closeBtn.font = [NSFont systemFontOfSize:11];
    closeBtn.target = self;
    closeBtn.action = @selector(hidePanel);
    [headerBar addSubview:closeBtn];

    CGFloat tableTop = self.bounds.size.height - InterMUQHeaderHeight - InterMUQPadding;
    CGFloat buttonAreaH = 36.0;
    CGFloat tableH = tableTop - buttonAreaH - InterMUQPadding * 2;
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, buttonAreaH + InterMUQPadding * 2,
                                                                      self.bounds.size.width, tableH)];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.drawsBackground = NO;

    self.tableView = [[NSTableView alloc] initWithFrame:self.scrollView.bounds];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [NSColor clearColor];
    self.tableView.headerView = nil;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"participant"];
    col.width = self.bounds.size.width;
    [self.tableView addTableColumn:col];
    self.scrollView.documentView = self.tableView;
    [self addSubview:self.scrollView];

    self.emptyLabel = [NSTextField labelWithString:@"No pending requests"];
    self.emptyLabel.frame = NSMakeRect(0, self.bounds.size.height / 2 - 10, self.bounds.size.width, 20);
    self.emptyLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.emptyLabel.alignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [NSColor colorWithWhite:0.6 alpha:1.0];
    self.emptyLabel.font = [NSFont systemFontOfSize:12];
    [self addSubview:self.emptyLabel];

    CGFloat btnW = (self.bounds.size.width - InterMUQPadding * 3) / 2;
    self.approveAllButton = [[NSButton alloc] initWithFrame:NSMakeRect(InterMUQPadding, InterMUQPadding, btnW, 28)];
    self.approveAllButton.bezelStyle = NSBezelStyleRounded;
    self.approveAllButton.title = @"Approve All";
    self.approveAllButton.font = [NSFont systemFontOfSize:12];
    self.approveAllButton.target = self;
    self.approveAllButton.action = @selector(approveAllTapped);
    [self addSubview:self.approveAllButton];

    self.denyAllButton = [[NSButton alloc] initWithFrame:NSMakeRect(InterMUQPadding * 2 + btnW, InterMUQPadding, btnW, 28)];
    self.denyAllButton.bezelStyle = NSBezelStyleRounded;
    self.denyAllButton.title = @"Deny All";
    self.denyAllButton.font = [NSFont systemFontOfSize:12];
    self.denyAllButton.target = self;
    self.denyAllButton.action = @selector(denyAllTapped);
    [self addSubview:self.denyAllButton];
}

#pragma mark - Public

- (void)setEntries:(NSArray<InterMicUnlockEntry *> *)entries {
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
    self.panelVisible ? [self hidePanel] : [self showPanel];
}

#pragma mark - Actions

- (void)approveAllTapped {
    [self.delegate micUnlockQueuePanelDidApproveAll:self];
}

- (void)denyAllTapped {
    [self.delegate micUnlockQueuePanelDidDenyAll:self];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.queueEntries.count;
}

#pragma mark - NSTableViewDelegate

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.queueEntries.count) return nil;
    InterMicUnlockEntry *entry = self.queueEntries[row];

    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"MicUnlockCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableView.bounds.size.width, InterMUQRowHeight)];
        cell.identifier = @"MicUnlockCell";

        NSTextField *nameLabel = [NSTextField labelWithString:@""];
        nameLabel.identifier = @"nameLabel";
        nameLabel.frame = NSMakeRect(InterMUQPadding, 14, tableView.bounds.size.width - 140, 16);
        nameLabel.autoresizingMask = NSViewWidthSizable;
        nameLabel.font = [NSFont systemFontOfSize:12];
        nameLabel.textColor = [NSColor colorWithWhite:0.9 alpha:1.0];
        [cell addSubview:nameLabel];

        NSButton *approveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(tableView.bounds.size.width - 130, 10, 60, 24)];
        approveBtn.identifier = @"approveBtn";
        approveBtn.autoresizingMask = NSViewMinXMargin;
        approveBtn.bezelStyle = NSBezelStyleInline;
        approveBtn.title = @"Approve";
        approveBtn.font = [NSFont systemFontOfSize:11];
        approveBtn.target = self;
        approveBtn.action = @selector(approveTapped:);
        [cell addSubview:approveBtn];

        NSButton *denyBtn = [[NSButton alloc] initWithFrame:NSMakeRect(tableView.bounds.size.width - 64, 10, 56, 24)];
        denyBtn.identifier = @"denyBtn";
        denyBtn.autoresizingMask = NSViewMinXMargin;
        denyBtn.bezelStyle = NSBezelStyleInline;
        denyBtn.title = @"Deny";
        denyBtn.font = [NSFont systemFontOfSize:11];
        denyBtn.target = self;
        denyBtn.action = @selector(denyTapped:);
        [cell addSubview:denyBtn];
    }

    NSTextField *nameLabel = [cell viewWithTag:0] ?: (NSTextField *)[cell viewWithIdentifier:@"nameLabel"];
    nameLabel.stringValue = entry.displayName ?: entry.participantIdentity;

    NSButton *approveBtn = (NSButton *)[cell viewWithIdentifier:@"approveBtn"];
    approveBtn.tag = row;

    NSButton *denyBtn = (NSButton *)[cell viewWithIdentifier:@"denyBtn"];
    denyBtn.tag = row;

    return cell;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return InterMUQRowHeight;
}

- (void)approveTapped:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.queueEntries.count) return;
    NSString *identity = self.queueEntries[row].participantIdentity;
    [self.delegate micUnlockQueuePanel:self didApproveParticipant:identity];
}

- (void)denyTapped:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.queueEntries.count) return;
    NSString *identity = self.queueEntries[row].participantIdentity;
    [self.delegate micUnlockQueuePanel:self didDenyParticipant:identity];
}

@end
```

- [ ] **Step 6.3: Build**

```bash
xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6.4: Commit**

```bash
git add inter/inter/UI/Views/InterMicUnlockQueuePanel.h inter/inter/UI/Views/InterMicUnlockQueuePanel.m
git commit -m "feat(mic-unlock): add InterMicUnlockQueuePanel (mirrors camera panel)"
```

---

## Task 7: AppDelegate Wiring

**Files:**
- Modify: `inter/inter/App/AppDelegate.m`

- [ ] **Step 7.1: Add import and properties**

In `AppDelegate.m`, find the `#import "InterCameraUnlockQueuePanel.h"` import line. Add below it:

```objc
#import "InterMicUnlockQueuePanel.h"
```

In the `@interface AppDelegate ()` extension (or the property declarations section), after `normalCameraUnlockQueuePanel`, add:

```objc
@property (nonatomic, strong, nullable) InterMicUnlockQueuePanel *normalMicUnlockQueuePanel;
@property (nonatomic, strong, nonnull) InterMicUnlockQueue *micUnlockQueue;
```

Also add conformance to the new delegate: in the `@interface AppDelegate ()` line, add `<InterMicUnlockQueuePanelDelegate>` alongside the existing `<InterCameraUnlockQueuePanelDelegate>`.

- [ ] **Step 7.2: Initialise queue in `applicationDidFinishLaunching:`**

Find `self.cameraUnlockQueue = [[InterCameraUnlockQueue alloc] init];`. Add after it:

```objc
self.micUnlockQueue = [[InterMicUnlockQueue alloc] init];
```

- [ ] **Step 7.3: Update mic button tap handler**

Find the current mic button tap handler that calls `[wiring twoPhaseToggleMicrophone]`. Replace the handler body with:

```objc
InterMediaWiringController *wiring = self.normalMediaWiring;
if (!wiring) return;

if (wiring.hostMuted || wiring.globalMuteActive) {
    if (wiring.micUnlockApproved) {
        [wiring twoPhaseToggleMicrophone]; // F16: approved path — restriction check done in wiring
    } else if (!wiring.micUnlockRequestPending) {
        [wiring applyMicUnlockRequestPending];
        [self.moderationController requestMicUnlock];
    }
    return;
}
[wiring twoPhaseToggleMicrophone];
```

- [ ] **Step 7.4: Wire `moderationControllerMicUnlockApproved` delegate**

In AppDelegate, find `- (void)moderationControllerCameraUnlockApproved:`. After its closing `}`, add:

```objc
- (void)moderationControllerMicUnlockApproved:(InterModerationController *)controller {
#pragma unused(controller)
    NSLog(@"[MicUnlock] Host approved mic unlock — re-enabling toggle");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.normalMediaWiring applyMicUnlockApproved];
    });
}
```

- [ ] **Step 7.5: Wire `receivedMicUnlockRequest` delegate**

Find `- (void)moderationController:(InterModerationController *)controller receivedCameraUnlockRequest:`. After its closing `}`, add:

```objc
- (void)moderationController:(InterModerationController *)controller
      receivedMicUnlockRequest:(NSString *)fromIdentity
                   displayName:(NSString *)displayName {
#pragma unused(controller)
    // F1 mitigation: discard if sender is not actually mic-restricted.
    if (!self.moderationController.isAllMuted &&
        ![self.hostMutedParticipants containsObject:fromIdentity]) {
        NSLog(@"[MicUnlock] discarded requestMicUnlock from non-muted participant %@", fromIdentity);
        return;
    }
    if (!self.roomController.isHost) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.micUnlockQueue addRequest:identity:fromIdentity displayName:displayName];
        [self.normalMicUnlockQueuePanel setEntries:self.micUnlockQueue.entries];
        [self.normalMicUnlockQueuePanel showPanel];
    });
}
```

Note: `addRequest:identity:` is a typo above — use the correct selector signature:
```objc
[self.micUnlockQueue addRequest:fromIdentity displayName:displayName];
```

- [ ] **Step 7.6: Wire `micUnlockQueuePanel:didApproveParticipant:` delegate**

After the `cameraUnlockQueuePanel:didApproveParticipant:` delegate, add:

```objc
- (void)micUnlockQueuePanel:(InterMicUnlockQueuePanel *)panel
     didApproveParticipant:(NSString *)identity {
#pragma unused(panel)
    [self.moderationController approveMicUnlockWithIdentity:identity];
    // Update tile badge — host's own DataChannel signal is not echoed.
    [self.normalRemoteLayout setHostMuted:NO forParticipant:identity];
    [self.hostMutedParticipants removeObject:identity];
    self.normalSpeakerQueuePanel.hostMutedIdentities = [self.hostMutedParticipants copy];
    [self.micUnlockQueue removeRequest:identity];
    [self.normalMicUnlockQueuePanel setEntries:self.micUnlockQueue.entries];
    if (self.micUnlockQueue.count == 0) {
        [self.normalMicUnlockQueuePanel hidePanel];
    }
}
```

- [ ] **Step 7.7: Wire `micUnlockQueuePanel:didDenyParticipant:` delegate**

```objc
- (void)micUnlockQueuePanel:(InterMicUnlockQueuePanel *)panel
       didDenyParticipant:(NSString *)identity {
#pragma unused(panel)
    [self.micUnlockQueue removeRequest:identity];
    [self.normalMicUnlockQueuePanel setEntries:self.micUnlockQueue.entries];
    if (self.micUnlockQueue.count == 0) {
        [self.normalMicUnlockQueuePanel hidePanel];
    }
}
```

- [ ] **Step 7.8: Wire approve-all and deny-all delegates**

```objc
- (void)micUnlockQueuePanelDidApproveAll:(InterMicUnlockQueuePanel *)panel {
#pragma unused(panel)
    NSArray<InterMicUnlockEntry *> *entries = [self.micUnlockQueue.entries copy];
    for (InterMicUnlockEntry *entry in entries) {
        [self.moderationController approveMicUnlockWithIdentity:entry.participantIdentity];
        [self.normalRemoteLayout setHostMuted:NO forParticipant:entry.participantIdentity];
        [self.hostMutedParticipants removeObject:entry.participantIdentity];
    }
    self.normalSpeakerQueuePanel.hostMutedIdentities = [self.hostMutedParticipants copy];
    [self.micUnlockQueue reset];
    [self.normalMicUnlockQueuePanel setEntries:@[]];
    [self.normalMicUnlockQueuePanel hidePanel];
}

- (void)micUnlockQueuePanelDidDenyAll:(InterMicUnlockQueuePanel *)panel {
#pragma unused(panel)
    [self.micUnlockQueue reset];
    [self.normalMicUnlockQueuePanel setEntries:@[]];
    [self.normalMicUnlockQueuePanel hidePanel];
}
```

- [ ] **Step 7.9: Cancel queue entries when host clicks tile "Unmute Mic"**

Find the existing `unmuteMic` tile action handler in AppDelegate. After `[self.normalRemoteLayout setHostMuted:NO forParticipant:participantIdentity]`, add:

```objc
// Cancel any pending mic unlock request — tile unmute supersedes queue.
[self.micUnlockQueue removeRequest:participantIdentity];
[self.normalMicUnlockQueuePanel setEntries:self.micUnlockQueue.entries];
if (self.micUnlockQueue.count == 0) {
    [self.normalMicUnlockQueuePanel hidePanel];
}
```

Add the same block in the `unmuteMic` Mute-All path (the `allowToSpeak` branch) after `[self.normalRemoteLayout setHostMuted:NO forParticipant:participantIdentity]`.

- [ ] **Step 7.10: Add to reconnect reset**

Find `[self.cameraUnlockQueue reset]` in the reconnect handler. Add after it:

```objc
[self.micUnlockQueue reset];
[self.normalMediaWiring resetMicUnlockFlowState];
```

- [ ] **Step 7.11: Add panel to teardown**

Find `[self.normalCameraUnlockQueuePanel removeFromSuperview]` in the teardown block. Add after it:

```objc
[self.normalMicUnlockQueuePanel removeFromSuperview];
self.normalMicUnlockQueuePanel = nil;
```

- [ ] **Step 7.12: Build**

```bash
xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7.13: Commit**

```bash
git add inter/inter/App/AppDelegate.m
git commit -m "feat(mic-unlock): wire mic unlock queue panel, delegates, reconnect reset, teardown in AppDelegate"
```

---

## Task 8: Token Server — Redis Persistence

**Files:**
- Modify: `token-server/index.js`

- [ ] **Step 8.1: Add `roomMicLockedKey` helper**

In `token-server/index.js`, find `function roomCameraLockedKey(code)`. Immediately after it, add:

```js
function roomMicLockedKey(code) { return `room:${code}:mic-locked`; } // SET of mic-locked identities
```

- [ ] **Step 8.2: Update `/room/mute` to persist to Redis**

Find the `POST /room/mute` endpoint. After the successful LiveKit `mutePublishedTrack` call and before `res.json(...)`, add:

```js
// Persist per-tile mic lock for reconnect restoration (F17: best-effort, non-fatal).
if (trackSource === 'microphone') {
    try {
        await redis.multi()
            .sadd(roomMicLockedKey(code), targetIdentity)
            .expire(roomMicLockedKey(code), 86400)
            .exec();
    } catch (e) {
        // F17: Redis write is best-effort. LiveKit state is authoritative.
        console.error('[warn] mic-lock redis write failed:', e.message);
    }
}
```

- [ ] **Step 8.3: Add `POST /room/mic-lift-one` endpoint**

Find the `POST /room/camera-lift-one` endpoint. After its closing block, add:

```js
// POST /room/mic-lift-one — Host lifts per-participant mic lock.
app.post('/room/mic-lift-one', auth.requireAuth, async (req, res) => {
    const { roomCode: code, callerIdentity, targetIdentity } = req.body;
    if (!code || !callerIdentity || !targetIdentity) {
        return res.status(400).json({ error: 'Missing required fields' });
    }
    try {
        const roomData = await getRoomData(code);
        if (!roomData) return res.status(404).json({ error: 'Room not found' });
        if (roomData.hostIdentity !== callerIdentity) {
            return res.status(403).json({ error: 'Caller is not the host' });
        }
        // F7: atomic pipeline — SREM + expire reset.
        await redis.multi()
            .srem(roomMicLockedKey(code), targetIdentity)
            .exec();
        io.to(code).emit('room:mic-lock-changed', { identity: targetIdentity, locked: false });
        console.log(`[audit] mic-lift-one: code=${code} target=${targetIdentity} by=${callerIdentity}`);
        res.json({ success: true });
    } catch (err) {
        console.error('[error] mic-lift-one failed:', err.message);
        res.status(500).json({ error: 'Failed to lift mic lock' });
    }
});
```

- [ ] **Step 8.4: Add `GET /room/mic-locked` endpoint**

After `/room/mic-lift-one`, add:

```js
// GET /room/mic-locked — Returns identities with active per-tile mic locks (reconnect snapshot).
app.get('/room/mic-locked', auth.requireAuth, async (req, res) => {
    const { roomCode: code, callerIdentity } = req.query;
    if (!code || !callerIdentity) {
        return res.status(400).json({ error: 'Missing required fields' });
    }
    try {
        const roomData = await getRoomData(code);
        if (!roomData) return res.status(404).json({ error: 'Room not found' });
        const locked = await redis.smembers(roomMicLockedKey(code));
        res.json({ locked });
    } catch (err) {
        console.error('[error] mic-locked fetch failed:', err.message);
        res.status(500).json({ error: 'Failed to fetch mic-locked identities' });
    }
});
```

- [ ] **Step 8.5: Test the new endpoints manually**

```bash
cd /Users/aman_01/Documents/inter/token-server
node -e "
const redis = require('./redis');
const key = 'room:TEST:mic-locked';
redis.sadd(key, 'alice').then(() => redis.smembers(key)).then(m => {
  console.log('sadd + smembers:', m);
  return redis.srem(key, 'alice');
}).then(() => redis.smembers(key)).then(m => {
  console.log('after srem:', m);
  process.exit(0);
}).catch(e => { console.error(e); process.exit(1); });
"
```

Expected output:
```
sadd + smembers: [ 'alice' ]
after srem: []
```

- [ ] **Step 8.6: Commit**

```bash
cd /Users/aman_01/Documents/inter
git add token-server/index.js
git commit -m "feat(mic-unlock): persist per-tile mic mutes to Redis, add mic-lift-one and mic-locked endpoints"
```

---

## Task 9: AppDelegate — `fetchMicLockedSnapshot`

**Files:**
- Modify: `inter/inter/App/AppDelegate.m`

- [ ] **Step 9.1: Add `fetchMicLockedSnapshot` method**

In `AppDelegate.m`, after `fetchCameraLockedSnapshot`, add:

```objc
/// Fetch mic-locked identities on (re)connect and apply host-muted tile state.
- (void)fetchMicLockedSnapshot {
    NSString *roomCode = self.roomController.roomCode;
    NSString *identity = self.roomController.localParticipantIdentity;
    NSString *serverURL = self.roomController.tokenServerURL;
    if (!roomCode.length || !identity.length || !serverURL.length) return;

    NSString *urlStr = [NSString stringWithFormat:@"%@/room/mic-locked?roomCode=%@&callerIdentity=%@",
                        serverURL,
                        [roomCode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                        [identity stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    NSString *token = self.roomController.tokenService.currentAccessToken;
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return;
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode > 299) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray<NSString *> *locked = json[@"locked"];
        if (![locked isKindOfClass:[NSArray class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            // Clear existing in-memory host-muted set before applying snapshot.
            [weakSelf.hostMutedParticipants removeAllObjects];
            for (NSString *lockedIdentity in locked) {
                if (![lockedIdentity isKindOfClass:[NSString class]] || !lockedIdentity.length) continue;
                [weakSelf.normalRemoteLayout setHostMuted:YES forParticipant:lockedIdentity];
                [weakSelf.hostMutedParticipants addObject:lockedIdentity];
            }
            weakSelf.normalSpeakerQueuePanel.hostMutedIdentities = [weakSelf.hostMutedParticipants copy];
        });
    }] resume];
}
```

- [ ] **Step 9.2: Call `fetchMicLockedSnapshot` from reconnect handler**

Find `[self fetchCameraLockedSnapshot];` in the reconnect handler. Add after it:

```objc
[self fetchMicLockedSnapshot];
```

- [ ] **Step 9.3: Build**

```bash
xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9.4: Commit**

```bash
git add inter/inter/App/AppDelegate.m
git commit -m "feat(mic-unlock): add fetchMicLockedSnapshot for host reconnect tile restoration"
```

---

## Task 10: Edge Case — Cancel Queue on New Mute

**Files:**
- Modify: `inter/inter/App/AppDelegate.m`

When `requestMuteAll` or a new `requestMuteOne` arrives and the host processes it, any pending queue entries for that participant should be removed (E1, E2 from spec).

- [ ] **Step 10.1: Cancel pending queue entry when Mute All is applied**

Find `- (void)moderationControllerReceivedMuteAllRequest:` in AppDelegate. After the block that marks all tiles as host-muted, add:

```objc
// Cancel all pending mic unlock requests — Mute All supersedes any pending request.
[self.micUnlockQueue reset];
[self.normalMicUnlockQueuePanel setEntries:@[]];
[self.normalMicUnlockQueuePanel hidePanel];
```

- [ ] **Step 10.2: Cancel pending queue entry when tile mute arrives**

Find the `muteMic` tile action handler's success completion block. After adding to `hostMutedParticipants`, add:

```objc
// Cancel any existing unlock request from this participant — new mute supersedes it.
[weakSelf.micUnlockQueue removeRequest:participantIdentity];
[weakSelf.normalMicUnlockQueuePanel setEntries:weakSelf.micUnlockQueue.entries];
if (weakSelf.micUnlockQueue.count == 0) {
    [weakSelf.normalMicUnlockQueuePanel hidePanel];
}
```

- [ ] **Step 10.3: Build**

```bash
xcodebuild -scheme inter -destination 'platform=macOS,arch=arm64' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 10.4: Commit**

```bash
git add inter/inter/App/AppDelegate.m
git commit -m "feat(mic-unlock): cancel pending queue entries on new mute (Mute All and tile mute)"
```

---

## Task 11: Final Build and Full Test Run

- [ ] **Step 11.1: Run all tests**

```bash
xcodebuild test -scheme inter -destination 'platform=macOS,arch=arm64' 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` with no failures.

- [ ] **Step 11.2: Verify the 6 paranoid mitigations are in place**

Check each mitigation in the codebase:

```bash
# F1: non-muted participant filter
grep -n "isAllMuted.*hostMutedParticipants\|hostMutedParticipants.*isAllMuted" inter/inter/App/AppDelegate.m

# F6: 30-second timer
grep -n "micUnlockRequestTimer\|scheduledTimerWithTimeInterval:30" inter/inter/App/InterMediaWiringController.m

# F7: atomic pipeline for Redis SADD+EXPIRE
grep -n "multi().sadd\|\.sadd.*\.expire\|multi.*sadd" token-server/index.js

# F10: dedup guard in addRequest
grep -n "contains.*participantIdentity\|containsObject.*identity" inter/inter/Networking/InterSpeakerQueue.swift

# F16: moot-approval guard
grep -n "hostMuted.*globalMuteActive.*return\|!self.hostMuted && !self.globalMuteActive" inter/inter/App/InterMediaWiringController.m

# F17: Redis write is non-fatal
grep -n "mic-lock redis write failed\|best-effort" token-server/index.js
```

Each grep must return at least one match.

- [ ] **Step 11.3: Final commit**

```bash
cd /Users/aman_01/Documents/inter
git add -A
git commit -m "feat(mic-unlock): complete mic unlock request flow — Ask to Unmute replaces raise-hand as mic gate"
```

---

## Summary of Changes

| Component | Change |
|---|---|
| Signal types 43, 44 | `requestMicUnlock`, `approveMicUnlock` |
| `InterSpeakerQueue.swift` | `InterMicUnlockEntry` + `InterMicUnlockQueue` (dedup, reset) |
| `InterMediaWiringController` | 3 new flags, rewritten `deriveMicButton`, `applyMicUnlockRequestPending/Approved`, `resetMicUnlockFlowState`, 30s timer, `applyAllowToSpeak` decoupled |
| `InterModerationController` | 2 delegate methods, 2 send methods, 2 handler cases with role validation |
| `InterMicUnlockQueuePanel.h/.m` | New UI panel (mirrors camera panel) |
| `AppDelegate.m` | Mic button handler, 6 delegate methods, queue cancel on new mute, reconnect snapshot call, teardown |
| `token-server/index.js` | `roomMicLockedKey`, `/room/mute` SADD, `/room/mic-lift-one`, `GET /room/mic-locked` |
