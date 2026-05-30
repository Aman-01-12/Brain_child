# Camera Mute (Per-Participant + Global) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let hosts force-mute any participant's camera (or all cameras) via a DataChannel-enforced flag model that mirrors the existing mic mute system — three flags (`hostCameraMuted`, `globalCameraLockActive`, self-state from `media.isCameraEnabled`) drive a single `deriveCameraButton` method, and the server stores camera state in Redis for reconnect reconciliation.

**Architecture:** DataChannel-only (no LiveKit server-side `mutePublishedTrack` for camera). The host's client sends a REST call to update Redis state, then broadcasts a DataChannel signal. The target participant's client receives the signal, calls `applyCameraHostMute` / `applyCameraGlobalLock` on `InterMediaWiringController`, which physically turns off the camera track (G2 pattern: mute LiveKit track → stop capture) and updates the button via `deriveCameraButton`. When the lock is lifted, cameras stay off until participants manually re-enable — no auto-resume.

**Tech Stack:** ObjC (`InterMediaWiringController`, `AppDelegate`, `InterLocalCallControlPanel`), Swift (`InterChatMessage`, `InterModerationController`), Node.js/Redis

---

## File Map

| File | Change |
|---|---|
| `inter/Networking/InterChatMessage.swift` | ADD 4 signal types (36–39) |
| `inter/UI/Views/InterLocalCallControlPanel.h` | ADD `setCameraButtonTitle:` declaration |
| `inter/UI/Views/InterLocalCallControlPanel.m` | ADD `setCameraButtonTitle:` implementation |
| `inter/App/InterMediaWiringController.h` | ADD 3 readonly properties + 4 `apply*` methods |
| `inter/App/InterMediaWiringController.m` | ADD 3 readwrite properties in class extension; ADD `deriveCameraButton`; ADD 4 `apply*` methods; ADD guard to `twoPhaseToggleCamera` |
| `inter/Networking/InterModerationController.swift` | ADD 4 host-side methods; ADD 4 signal handlers; ADD 6 `@objc optional` delegate callbacks |
| `inter/App/AppDelegate.m` | ADD 6 delegate method implementations; UPDATE `muteCamera`/`unmuteCamera` tile action cases |
| `inter/UI/Views/InterRemoteVideoLayoutManager.m` | ADD `isHostCameraLocked` tile property + `cameraLockedBadge` NSTextField; ADD public `setHostCameraLocked:forParticipant:` |
| `inter/UI/Views/InterRemoteVideoLayoutManager.h` | ADD `setHostCameraLocked:forParticipant:` declaration |
| `token-server/index.js` | ADD `roomCameraStateKey` + `globalCameraLockKey` helpers; ADD 4 REST endpoints; ADD Socket.IO `participant:camera-on` guard; UPDATE `client:join-room` to send camera snapshot |
| `interTests/InterCameraWiringTests.swift` | CREATE — unit tests for flag priority logic |

---

### Task 1: Add camera DataChannel signal types

**Files:**
- Modify: `inter/Networking/InterChatMessage.swift`

- [ ] **Step 1: Add 4 new signal types**

Find this block in `InterChatMessage.swift`:

```swift
    case askToUnmuteCamera = 35
```

Add 4 new cases immediately after it:

```swift
    case askToUnmuteCamera = 35

    /// Host has force-muted a specific participant's camera (DataChannel, targeted).
    case requestMuteCameraOne  = 36
    /// Host has locked all cameras in the room (DataChannel, broadcast).
    case requestMuteCameraAll  = 37
    /// Host has lifted the per-participant camera mute (DataChannel, targeted).
    case liftCameraLockOne     = 38
    /// Host has lifted the global camera lock (DataChannel, broadcast).
    case liftCameraLockAll     = 39
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add inter/Networking/InterChatMessage.swift
git commit -m "feat(camera-mute): add DataChannel signal types 36-39"
```

---

### Task 2: Add `setCameraButtonTitle:` to the control panel

`deriveCameraButton` needs to set custom locked titles on the camera button. The control panel already has `setCameraEnabled:` (sets "Turn Camera On" / "Turn Camera Off") and `setMicrophoneButtonTitle:` (sets a custom title). Add the camera equivalent.

**Files:**
- Modify: `inter/UI/Views/InterLocalCallControlPanel.h`
- Modify: `inter/UI/Views/InterLocalCallControlPanel.m`

- [ ] **Step 1: Declare the method in the header**

Find in `InterLocalCallControlPanel.h`:

```objc
- (void)setCameraEnabled:(BOOL)enabled;
```

Add the new declaration immediately after it:

```objc
- (void)setCameraEnabled:(BOOL)enabled;
/// Set a custom title on the camera button, or pass nil to reset to
/// the default title based on the current camera-on/off state.
- (void)setCameraButtonTitle:(nullable NSString *)title;
```

- [ ] **Step 2: Implement the method**

Find in `InterLocalCallControlPanel.m`:

```objc
- (void)setCameraEnabled:(BOOL)enabled {
    self.cameraButton.title = enabled ? @"Turn Camera Off" : @"Turn Camera On";
}
```

Add the implementation immediately after it:

```objc
- (void)setCameraEnabled:(BOOL)enabled {
    self.cameraButton.title = enabled ? @"Turn Camera Off" : @"Turn Camera On";
}

- (void)setCameraButtonTitle:(nullable NSString *)title {
    if (title) {
        self.cameraButton.title = title;
    } else {
        // Reset to default: infer from current button title
        BOOL cameraOn = [self.cameraButton.title isEqualToString:@"Turn Camera Off"];
        self.cameraButton.title = cameraOn ? @"Turn Camera Off" : @"Turn Camera On";
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add inter/UI/Views/InterLocalCallControlPanel.h inter/UI/Views/InterLocalCallControlPanel.m
git commit -m "feat(camera-mute): add setCameraButtonTitle: to control panel"
```

---

### Task 3: Extend `InterMediaWiringController` header with camera flag API

**Files:**
- Modify: `inter/App/InterMediaWiringController.h`

- [ ] **Step 1: Add camera properties and methods**

Find this section in `InterMediaWiringController.h`:

```objc
// -- G2 Two-Phase Toggles --------------------------------------------------

/// Two-phase camera toggle: [G2] mute track FIRST → stop device (disable);
/// start device FIRST → wait for frame → unmute track (enable).
- (void)twoPhaseToggleCamera;
```

Replace it with:

```objc
// -- G2 Two-Phase Toggles --------------------------------------------------

/// Two-phase camera toggle: [G2] mute track FIRST → stop device (disable);
/// start device FIRST → wait for frame → unmute track (enable).
/// Blocked when hostCameraMuted or globalCameraLockActive — call is silently
/// ignored (button is disabled by deriveCameraButton so this guard is a safety
/// net only).
- (void)twoPhaseToggleCamera;

// -- Camera Host-Mute State (mirrors mic mute 3-flag model) ----------------

/// Per-participant camera mute by host. Set ONLY by applyCameraHostMute.
/// When YES, participant sees "Camera Off (Host)" and button is disabled.
@property (nonatomic, readonly) BOOL hostCameraMuted;

/// Global camera lock set by host for the entire room. Set ONLY by
/// applyCameraGlobalLock. When YES, participant sees "Camera Locked" (disabled).
@property (nonatomic, readonly) BOOL globalCameraLockActive;

/// Monotonically increasing counter incremented on every authoritative camera
/// state change. Mirrors stateSequenceNumber for mic.
@property (nonatomic, readonly) NSInteger cameraStateSequenceNumber;

/// Received requestMuteCameraOne DataChannel signal.
/// Sets hostCameraMuted=YES, physically turns off camera via G2 sequence.
- (void)applyCameraHostMute;

/// Received requestMuteCameraAll DataChannel signal.
/// Sets globalCameraLockActive=YES, physically turns off camera via G2 sequence.
- (void)applyCameraGlobalLock;

/// Received liftCameraLockOne DataChannel signal.
/// Clears hostCameraMuted. Camera stays off until participant re-enables.
- (void)applyCameraHostUnmute;

/// Received liftCameraLockAll DataChannel signal.
/// Clears globalCameraLockActive. Camera stays off until participant re-enables.
- (void)applyCameraGlobalLockLift;
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add inter/App/InterMediaWiringController.h
git commit -m "feat(camera-mute): add camera flag API to InterMediaWiringController header"
```

---

### Task 4: Implement camera flags and `deriveCameraButton` in `InterMediaWiringController.m`

**Files:**
- Modify: `inter/App/InterMediaWiringController.m`

- [ ] **Step 1: Add readwrite flags to the class extension**

Find this block in the `@interface InterMediaWiringController ()` class extension:

```objc
/// Monotonically increasing counter incremented on every authoritative state
/// change. Async completion blocks capture this before their async call and
/// discard their update if the value has advanced (Bug 2 stale-update guard).
@property (nonatomic, assign, readwrite) NSInteger stateSequenceNumber;
@end
```

Replace it with:

```objc
/// Monotonically increasing counter incremented on every authoritative state
/// change. Async completion blocks capture this before their async call and
/// discard their update if the value has advanced (Bug 2 stale-update guard).
@property (nonatomic, assign, readwrite) NSInteger stateSequenceNumber;
// Camera host-mute flags (mirrors mic 3-flag model)
@property (nonatomic, assign, readwrite) BOOL hostCameraMuted;
@property (nonatomic, assign, readwrite) BOOL globalCameraLockActive;
@property (nonatomic, assign, readwrite) NSInteger cameraStateSequenceNumber;
@end
```

- [ ] **Step 2: Add `deriveCameraButton` and the 4 `apply*` methods**

Find this block (the end of `applyRemoteMicUnmute` / just before `wireNetworkPublish`):

```objc
#pragma mark - Network Wiring

- (void)wireNetworkPublish {
```

Insert the new camera methods immediately before this `#pragma mark`:

```objc
#pragma mark - Camera Host-Mute State

/// Priority-ordered derivation of the camera button title and enabled state
/// from the three camera state flags. Called after every authoritative camera
/// state transition.
- (void)deriveCameraButton {
    // Priority 1: global camera lock — entirely disabled.
    if (self.globalCameraLockActive) {
        [self.controlPanel setCameraButtonTitle:@"Camera Locked"];
        self.controlPanel.cameraButton.enabled = NO;
        return;
    }
    // Priority 2: per-participant host mute — button disabled.
    if (self.hostCameraMuted) {
        [self.controlPanel setCameraButtonTitle:@"Camera Off (Host)"];
        self.controlPanel.cameraButton.enabled = NO;
        return;
    }
    // Priority 3: normal — participant controls camera freely.
    self.controlPanel.cameraButton.enabled = YES;
    [self.controlPanel setCameraEnabled:self.mediaController.isCameraEnabled];
}

/// Received requestMuteCameraOne. Physically turns off camera via G2 sequence,
/// sets hostCameraMuted, and updates the button via deriveCameraButton.
- (void)applyCameraHostMute {
    InterRoomController *rc = self.roomController;
    InterLocalMediaController *media = self.mediaController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;

    self.hostCameraMuted = YES;
    self.cameraStateSequenceNumber++;
    [self deriveCameraButton];

    // Physically turn off the camera if it is currently on.
    if (media.isCameraEnabled) {
        __weak typeof(self) weakSelf = self;
        if (isConnected && rc.publisher.cameraSource != nil) {
            [rc.publisher muteCameraTrackWithCompletion:^{
                [weakSelf toggleCamera]; // stops capture device
            }];
        } else {
            [self toggleCamera];
        }
    }
}

/// Received requestMuteCameraAll. Physically turns off camera via G2 sequence,
/// sets globalCameraLockActive, and updates the button.
- (void)applyCameraGlobalLock {
    InterRoomController *rc = self.roomController;
    InterLocalMediaController *media = self.mediaController;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;

    self.globalCameraLockActive = YES;
    self.cameraStateSequenceNumber++;
    [self deriveCameraButton];

    if (media.isCameraEnabled) {
        __weak typeof(self) weakSelf = self;
        if (isConnected && rc.publisher.cameraSource != nil) {
            [rc.publisher muteCameraTrackWithCompletion:^{
                [weakSelf toggleCamera];
            }];
        } else {
            [self toggleCamera];
        }
    }
}

/// Received liftCameraLockOne. Clears hostCameraMuted. Camera stays off until
/// participant manually re-enables — no auto-resume (design decision).
- (void)applyCameraHostUnmute {
    self.hostCameraMuted = NO;
    self.cameraStateSequenceNumber++;
    [self deriveCameraButton];
}

/// Received liftCameraLockAll. Clears globalCameraLockActive. Camera stays off.
- (void)applyCameraGlobalLockLift {
    self.globalCameraLockActive = NO;
    self.cameraStateSequenceNumber++;
    [self deriveCameraButton];
}

#pragma mark - Network Wiring

- (void)wireNetworkPublish {
```

- [ ] **Step 3: Add the guard to `twoPhaseToggleCamera`**

Find the start of `twoPhaseToggleCamera`:

```objc
- (void)twoPhaseToggleCamera {
    InterLocalMediaController *media = self.mediaController;
    InterRoomController *rc = self.roomController;
    BOOL shouldEnable = !media.isCameraEnabled;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
```

Replace it with:

```objc
- (void)twoPhaseToggleCamera {
    // Blocked when camera is locked by host — button should already be disabled
    // by deriveCameraButton, so this is a safety net for programmatic callers.
    if (self.hostCameraMuted || self.globalCameraLockActive) { return; }

    InterLocalMediaController *media = self.mediaController;
    InterRoomController *rc = self.roomController;
    BOOL shouldEnable = !media.isCameraEnabled;
    BOOL isConnected = rc && rc.connectionState == InterRoomConnectionStateConnected;
```

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add inter/App/InterMediaWiringController.m
git commit -m "feat(camera-mute): implement camera flag state machine in InterMediaWiringController"
```

---

### Task 5: Add delegate callbacks and host-side methods to `InterModerationController`

**Files:**
- Modify: `inter/Networking/InterModerationController.swift`

- [ ] **Step 1: Add 6 `@objc optional` delegate callbacks to `InterModerationDelegate`**

Find this block at the end of the `InterModerationDelegate` protocol:

```swift
    /// Host has denied our screen share request.
    @objc optional func moderationControllerScreenShareRequestDenied(_ controller: InterModerationController)
}
```

Replace it with:

```swift
    /// Host has denied our screen share request.
    @objc optional func moderationControllerScreenShareRequestDenied(_ controller: InterModerationController)

    // MARK: Camera Mute Callbacks

    /// Host force-muted our camera (requestMuteCameraOne received, targeted at us).
    @objc optional func moderationControllerLocalCameraHostMuted(_ controller: InterModerationController)

    /// Host lifted our per-participant camera mute (liftCameraLockOne received).
    @objc optional func moderationControllerLocalCameraHostUnmuted(_ controller: InterModerationController)

    /// Host locked all cameras (requestMuteCameraAll received).
    @objc optional func moderationControllerCameraGlobalLockActivated(_ controller: InterModerationController)

    /// Host lifted the global camera lock (liftCameraLockAll received).
    @objc optional func moderationControllerCameraGlobalLockLifted(_ controller: InterModerationController)

    /// Host locked all cameras and we are a host/co-host — update remote tile badges.
    @objc optional func moderationControllerReceivedCameraLockAllBroadcast(_ controller: InterModerationController)

    /// Host lifted the global camera lock and we are a host/co-host — update remote tile badges.
    @objc optional func moderationControllerReceivedCameraLockLiftAllBroadcast(_ controller: InterModerationController)
}
```

- [ ] **Step 2: Add 4 host-side camera mute methods**

Find the `// MARK: - Ask to Unmute (9.2.4)` section near `askToUnmuteCamera`:

```swift
    /// Ask a specific participant to turn their camera back on (DataChannel request).
    @objc public func askToUnmuteCamera(identity: String) {
```

Add 4 new methods immediately BEFORE `askToUnmuteCamera`:

```swift
    // MARK: - Camera Mute (Host Actions)

    /// Force-mute a specific participant's camera. Updates Redis state then
    /// sends a targeted DataChannel signal so the participant's client turns
    /// off the camera. DataChannel-only: no LiveKit mutePublishedTrack.
    @objc public func muteCameraOne(identity: String,
                                    completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }
        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "targetIdentity": identity,
        ]
        performPOST(endpoint: "/room/mute-camera-one", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.sendControlSignal(type: .requestMuteCameraOne, targetIdentity: identity)
                interLogInfo(InterLog.room, "ModerationController: camera-muted %{private}@", identity)
                self.completeOnMain { completion(true, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    /// Lock all cameras in the room. Updates Redis then broadcasts DataChannel signal.
    @objc public func muteCameraAll(completion: @escaping (Bool, Int, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else {
            completion(false, 0, makeError("Insufficient permissions"))
            return
        }
        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
        ]
        performPOST(endpoint: "/room/mute-camera-all", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                let json = self.parseJSON(data)
                let count = json?["lockedCount"] as? Int ?? 0
                self.sendControlSignal(type: .requestMuteCameraAll)
                interLogInfo(InterLog.room, "ModerationController: camera-locked-all (%d)", count)
                self.completeOnMain { completion(true, count, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, 0, error) }
            }
        }
    }

    /// Lift the camera mute on a specific participant.
    @objc public func liftCameraLockOne(identity: String,
                                        completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }
        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
            "targetIdentity": identity,
        ]
        performPOST(endpoint: "/room/lift-camera-lock-one", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.sendControlSignal(type: .liftCameraLockOne, targetIdentity: identity)
                interLogInfo(InterLog.room, "ModerationController: lift camera-lock-one %{private}@", identity)
                self.completeOnMain { completion(true, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    /// Lift the global camera lock for the entire room.
    @objc public func liftCameraLockAll(completion: @escaping (Bool, NSError?) -> Void) {
        guard InterPermissionMatrix.role(localRole, hasPermission: .canMuteOthers) else {
            completion(false, makeError("Insufficient permissions"))
            return
        }
        let body: [String: Any] = [
            "roomCode": roomCode,
            "callerIdentity": localIdentity,
        ]
        performPOST(endpoint: "/room/lift-camera-lock-all", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.sendControlSignal(type: .liftCameraLockAll)
                interLogInfo(InterLog.room, "ModerationController: lift camera-lock-all")
                self.completeOnMain { completion(true, nil) }
            case .failure(let error):
                self.completeOnMain { completion(false, error) }
            }
        }
    }

    /// Ask a specific participant to turn their camera back on (DataChannel request).
    @objc public func askToUnmuteCamera(identity: String) {
```

- [ ] **Step 3: Add signal handlers for the 4 new signal types**

Find the `case .askToUnmuteCamera:` block in the signal dispatch switch (around line 992):

```swift
        case .askToUnmuteCamera:
```

Find the next `case .participantRemoved:` and add the 4 new cases between them. Look for this pattern:

```swift
        case .askToUnmuteCamera:
            if let target = signal.targetIdentity, let name = signal.senderName {
```

After the end of the `.askToUnmuteCamera` case handling and before `.participantRemoved`, add:

```swift
        case .requestMuteCameraOne:
            // Participant receives: host has force-muted their camera.
            if targetIsLocal {
                delegate?.moderationControllerLocalCameraHostMuted?(self)
            }
            // Host/co-host receives their own broadcast (targetIsLocal=false for them):
            // Nothing to do — tile badge update handled by tile-level tracking.

        case .requestMuteCameraAll:
            // Everyone receives this (no targetIdentity).
            delegate?.moderationControllerCameraGlobalLockActivated?(self)
            delegate?.moderationControllerReceivedCameraLockAllBroadcast?(self)

        case .liftCameraLockOne:
            if targetIsLocal {
                delegate?.moderationControllerLocalCameraHostUnmuted?(self)
            }

        case .liftCameraLockAll:
            delegate?.moderationControllerCameraGlobalLockLifted?(self)
            delegate?.moderationControllerReceivedCameraLockLiftAllBroadcast?(self)
```

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add inter/Networking/InterModerationController.swift
git commit -m "feat(camera-mute): add camera mute host methods and signal handlers to InterModerationController"
```

---

### Task 6: Wire camera mute delegate methods in `AppDelegate.m`

**Files:**
- Modify: `inter/App/AppDelegate.m`

- [ ] **Step 1: Add 6 delegate implementations**

Find the `moderationControllerLocalParticipantWasRemoved:` method (around line 3920):

```objc
- (void)moderationControllerLocalParticipantWasRemoved:(InterModerationController *)controller {
```

Add the 6 new camera delegate methods BEFORE this method:

```objc
// ---------------------------------------------------------------------------
// MARK: - Camera Mute Delegate Callbacks
// ---------------------------------------------------------------------------

- (void)moderationControllerLocalCameraHostMuted:(InterModerationController *)controller {
#pragma unused(controller)
    // Our camera was force-muted by the host. InterMediaWiringController handles
    // the actual camera-off sequence and button update.
    [self.normalMediaWiring applyCameraHostMute];
}

- (void)moderationControllerLocalCameraHostUnmuted:(InterModerationController *)controller {
#pragma unused(controller)
    [self.normalMediaWiring applyCameraHostUnmute];
}

- (void)moderationControllerCameraGlobalLockActivated:(InterModerationController *)controller {
#pragma unused(controller)
    // Our camera is locked globally. Apply to local media wiring.
    [self.normalMediaWiring applyCameraGlobalLock];
}

- (void)moderationControllerCameraGlobalLockLifted:(InterModerationController *)controller {
#pragma unused(controller)
    [self.normalMediaWiring applyCameraGlobalLockLift];
}

- (void)moderationControllerReceivedCameraLockAllBroadcast:(InterModerationController *)controller {
#pragma unused(controller)
    // We are a host/co-host receiving the broadcast. Update all remote tile badges.
    NSArray<NSDictionary<NSString *, NSString *> *> *participants =
        [self.roomController remoteParticipantList];
    for (NSDictionary *p in participants) {
        NSString *identity = p[@"identity"];
        if (identity.length > 0) {
            [self.normalRemoteLayout setHostCameraLocked:YES forParticipant:identity];
        }
    }
}

- (void)moderationControllerReceivedCameraLockLiftAllBroadcast:(InterModerationController *)controller {
#pragma unused(controller)
    NSArray<NSDictionary<NSString *, NSString *> *> *participants =
        [self.roomController remoteParticipantList];
    for (NSDictionary *p in participants) {
        NSString *identity = p[@"identity"];
        if (identity.length > 0) {
            [self.normalRemoteLayout setHostCameraLocked:NO forParticipant:identity];
        }
    }
}

- (void)moderationControllerLocalParticipantWasRemoved:(InterModerationController *)controller {
```

- [ ] **Step 2: Update `handleTileModerationAction:` camera cases**

Find in `handleTileModerationAction:`:

```objc
    } else if ([actionType isEqualToString:@"muteCamera"]) {
        [self.moderationController muteParticipantWithIdentity:participantIdentity
                                                   trackSource:@"camera"
                                                    completion:^(BOOL success, NSError *error) {
            if (!success) NSLog(@"[Moderation] muteCamera failed for %@: %@", participantIdentity, error.localizedDescription);
        }];

    } else if ([actionType isEqualToString:@"unmuteCamera"]) {
        // No server-side camera unmute; ask the participant to turn their camera on
        [self.moderationController askToUnmuteCameraWithIdentity:participantIdentity];
```

Replace both cases with:

```objc
    } else if ([actionType isEqualToString:@"muteCamera"]) {
        // DataChannel-only camera mute: update Redis state via REST, then signal
        // the target participant. No LiveKit mutePublishedTrack.
        __weak typeof(self) weakSelf = self;
        [self.moderationController muteCameraOneWithIdentity:participantIdentity
                                                 completion:^(BOOL success, NSError *error) {
            if (success) {
                [weakSelf.normalRemoteLayout setHostCameraLocked:YES forParticipant:participantIdentity];
            } else {
                NSLog(@"[Moderation] muteCamera failed for %@: %@", participantIdentity, error.localizedDescription);
            }
        }];

    } else if ([actionType isEqualToString:@"unmuteCamera"]) {
        // Lift the host camera mute, then send a polite ask to turn camera on.
        __weak typeof(self) weakSelf = self;
        [self.moderationController liftCameraLockOneWithIdentity:participantIdentity
                                                     completion:^(BOOL success, NSError *error) {
            if (success) {
                [weakSelf.normalRemoteLayout setHostCameraLocked:NO forParticipant:participantIdentity];
                // Polite ask: participant is notified they can turn camera back on.
                [weakSelf.moderationController askToUnmuteCameraWithIdentity:participantIdentity];
            } else {
                NSLog(@"[Moderation] unmuteCamera failed for %@: %@", participantIdentity, error.localizedDescription);
            }
        }];
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add inter/App/AppDelegate.m
git commit -m "feat(camera-mute): wire camera mute delegates and tile actions in AppDelegate"
```

---

### Task 7: Add camera locked badge on remote tiles

**Files:**
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.h`
- Modify: `inter/UI/Views/InterRemoteVideoLayoutManager.m`

- [ ] **Step 1: Add public method declaration to header**

Find in `InterRemoteVideoLayoutManager.h` the `setHostMuted:forParticipant:` declaration and add the new one alongside it:

```objc
/// Update the host-muted camera lock badge on a specific participant's tile.
/// YES shows a 🚫 camera indicator; NO hides it.
- (void)setHostCameraLocked:(BOOL)locked forParticipant:(NSString *)identity;
```

- [ ] **Step 2: Add `isHostCameraLocked` property and `cameraLockedBadge` to `InterRemoteVideoTileView`**

Find the existing tile properties in `InterRemoteVideoLayoutManager.m`:

```objc
@property (nonatomic, strong) NSTextField *micMutedBadge;
```

Add after it:

```objc
@property (nonatomic, strong) NSTextField *micMutedBadge;
@property (nonatomic, strong) NSTextField *cameraLockedBadge;
@property (nonatomic, assign) BOOL isHostCameraLocked;
```

- [ ] **Step 3: Initialize the `cameraLockedBadge` in `initWithVideoView:tileKey:displayName:`**

Find the `micMutedBadge` initialization block:

```objc
    self.micMutedBadge = [NSTextField labelWithString:@"🔇"];
    self.micMutedBadge.font = [NSFont systemFontOfSize:14];
    self.micMutedBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.micMutedBadge setWantsLayer:YES];
    self.micMutedBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.micMutedBadge.layer.cornerRadius = 4.0;
    self.micMutedBadge.alignment = NSTextAlignmentCenter;
    self.micMutedBadge.hidden = YES;
    [self addSubview:self.micMutedBadge];
```

Add the camera badge initialization immediately after it:

```objc
    self.micMutedBadge = [NSTextField labelWithString:@"🔇"];
    self.micMutedBadge.font = [NSFont systemFontOfSize:14];
    self.micMutedBadge.frame = NSMakeRect(0, 0, 22, 22);
    [self.micMutedBadge setWantsLayer:YES];
    self.micMutedBadge.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    self.micMutedBadge.layer.cornerRadius = 4.0;
    self.micMutedBadge.alignment = NSTextAlignmentCenter;
    self.micMutedBadge.hidden = YES;
    [self addSubview:self.micMutedBadge];

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

- [ ] **Step 4: Position `cameraLockedBadge` in `layout`**

Find the `micMutedBadge` layout line:

```objc
    self.micMutedBadge.frame = NSMakeRect(b.size.width - 26, labelH + 2, 22, 22);
```

Add the camera badge positioning immediately after it (place it to the left of the mic badge):

```objc
    self.micMutedBadge.frame = NSMakeRect(b.size.width - 26, labelH + 2, 22, 22);
    self.cameraLockedBadge.frame = NSMakeRect(b.size.width - 52, labelH + 2, 22, 22);
```

- [ ] **Step 5: Add custom setter for `isHostCameraLocked`**

Find the existing `setIsMicMuted:` custom setter:

```objc
- (void)setIsMicMuted:(BOOL)isMicMuted {
    if (_isMicMuted == isMicMuted) return;
    _isMicMuted = isMicMuted;
    self.micMutedBadge.hidden = !isMicMuted;
}
```

Add the camera locked setter immediately after it:

```objc
- (void)setIsMicMuted:(BOOL)isMicMuted {
    if (_isMicMuted == isMicMuted) return;
    _isMicMuted = isMicMuted;
    self.micMutedBadge.hidden = !isMicMuted;
}

- (void)setIsHostCameraLocked:(BOOL)isHostCameraLocked {
    if (_isHostCameraLocked == isHostCameraLocked) return;
    _isHostCameraLocked = isHostCameraLocked;
    self.cameraLockedBadge.hidden = !isHostCameraLocked;
}
```

- [ ] **Step 6: Add `setHostCameraLocked:forParticipant:` to the layout manager**

Find `setHostMuted:forParticipant:` and add the new method alongside it. Look for this pattern near the bottom of the layout manager implementation:

```objc
- (void)setHostMuted:(BOOL)hostMuted forParticipant:(NSString *)identity {
```

Add immediately after the `setHostMuted:` implementation:

```objc
- (void)setHostCameraLocked:(BOOL)locked forParticipant:(NSString *)identity {
    dispatch_async(dispatch_get_main_queue(), ^{
        InterRemoteVideoTileView *tile = self.tileViews[identity];
        if (tile) {
            tile.isHostCameraLocked = locked;
            // Also update the tile menu label for the host's own view
            tile.isCameraMuted = locked;
        }
    });
}
```

- [ ] **Step 7: Build**

```bash
xcodebuild -scheme inter -destination "platform=macOS" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add inter/UI/Views/InterRemoteVideoLayoutManager.h inter/UI/Views/InterRemoteVideoLayoutManager.m
git commit -m "feat(camera-mute): add camera locked badge and isHostCameraLocked to remote tiles"
```

---

### Task 8: Add server-side camera state Redis helpers and REST endpoints

**Files:**
- Modify: `token-server/index.js`

- [ ] **Step 1: Add Redis key helpers**

Find:

```javascript
function roomBannedKey(code) { return `room:${code}:banned`; }
```

Add immediately after it:

```javascript
function roomBannedKey(code) { return `room:${code}:banned`; }

// Camera-mute Redis key helpers
function roomCameraStateKey(code, identity) { return `room:${code}:camerastate:${identity}`; }
function globalCameraLockKey(code) { return `room:${code}:global-camera-lock`; }
```

- [ ] **Step 2: Add 4 camera REST endpoints**

Find the comment before `/room/remove`:

```javascript
// ---------------------------------------------------------------------------
// POST /room/remove — Remove a participant from the room
```

Add all 4 camera endpoints immediately BEFORE this comment block:

```javascript
// ---------------------------------------------------------------------------
// POST /room/mute-camera-one — Host force-mutes a specific participant's camera.
// DataChannel-only: no LiveKit mutePublishedTrack. Just stores Redis state so
// reconnecting participants get the correct camera lock applied.
// Body: { roomCode, callerIdentity, targetIdentity }
// Returns: { success: true }
// ---------------------------------------------------------------------------
app.post('/room/mute-camera-one', auth.requireAuth, async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity } = req.body;
  if (!roomCode || !callerIdentity || !targetIdentity) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and targetIdentity are required' });
  }
  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });
  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  try {
    await redis.hset(roomCameraStateKey(code, targetIdentity), 'hostCameraMuted', '1');
    await redis.expire(roomCameraStateKey(code, targetIdentity), ROOM_CODE_EXPIRY_SECONDS);
    console.log(`[audit] Camera mute-one: code=${code} target=${targetIdentity} by=${callerIdentity}`);
    res.json({ success: true });
  } catch (err) {
    console.error('[error] mute-camera-one failed:', err.message);
    res.status(500).json({ error: 'Failed to mute camera' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/lift-camera-lock-one — Lift the per-participant camera mute.
// Body: { roomCode, callerIdentity, targetIdentity }
// Returns: { success: true }
// ---------------------------------------------------------------------------
app.post('/room/lift-camera-lock-one', auth.requireAuth, async (req, res) => {
  const { roomCode, callerIdentity, targetIdentity } = req.body;
  if (!roomCode || !callerIdentity || !targetIdentity) {
    return res.status(400).json({ error: 'roomCode, callerIdentity, and targetIdentity are required' });
  }
  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });
  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  try {
    await redis.hdel(roomCameraStateKey(code, targetIdentity), 'hostCameraMuted');
    console.log(`[audit] Camera lift-lock-one: code=${code} target=${targetIdentity} by=${callerIdentity}`);
    res.json({ success: true });
  } catch (err) {
    console.error('[error] lift-camera-lock-one failed:', err.message);
    res.status(500).json({ error: 'Failed to lift camera lock' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/mute-camera-all — Host locks all cameras in the room.
// Body: { roomCode, callerIdentity }
// Returns: { success: true, lockedCount: N }
// ---------------------------------------------------------------------------
app.post('/room/mute-camera-all', auth.requireAuth, async (req, res) => {
  const { roomCode, callerIdentity } = req.body;
  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }
  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });
  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  try {
    await redis.set(globalCameraLockKey(code), '1', 'EX', ROOM_CODE_EXPIRY_SECONDS);
    // Count participants for the response (best-effort)
    const count = await getParticipantCount(code);
    console.log(`[audit] Camera mute-all: code=${code} by=${callerIdentity}`);
    res.json({ success: true, lockedCount: count });
  } catch (err) {
    console.error('[error] mute-camera-all failed:', err.message);
    res.status(500).json({ error: 'Failed to lock cameras' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/lift-camera-lock-all — Host lifts the global camera lock.
// Body: { roomCode, callerIdentity }
// Returns: { success: true }
// ---------------------------------------------------------------------------
app.post('/room/lift-camera-lock-all', auth.requireAuth, async (req, res) => {
  const { roomCode, callerIdentity } = req.body;
  if (!roomCode || !callerIdentity) {
    return res.status(400).json({ error: 'roomCode and callerIdentity are required' });
  }
  const code = roomCode.toUpperCase();
  const roomData = await getRoomData(code);
  if (!roomData) return res.status(404).json({ error: 'Invalid or expired room code' });
  const validation = await validateModerator(code, callerIdentity);
  if (!validation.valid) return res.status(403).json({ error: validation.error });

  try {
    await redis.del(globalCameraLockKey(code));
    console.log(`[audit] Camera lift-lock-all: code=${code} by=${callerIdentity}`);
    res.json({ success: true });
  } catch (err) {
    console.error('[error] lift-camera-lock-all failed:', err.message);
    res.status(500).json({ error: 'Failed to lift camera lock' });
  }
});

// ---------------------------------------------------------------------------
// POST /room/remove — Remove a participant from the room
```

- [ ] **Step 3: Add `participant:camera-on` guard to Socket.IO handlers**

Find the `participant:lower-hand` handler at the end of the existing Socket.IO handlers. After it (but still inside the `io.on('connection', ...)` block), add:

```javascript
  // participant:camera-on — participant is re-enabling their camera.
  // Reject if host has camera-muted this participant or if global lock is active.
  socket.on('participant:camera-on', async ({ roomCode, identity }) => {
    if (!roomCode || !identity) return;
    const code = String(roomCode).toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (!code) return;

    try {
      const [camStateJson, globalLock] = await Promise.all([
        redis.hgetall(roomCameraStateKey(code, identity)),
        redis.get(globalCameraLockKey(code)),
      ]);

      if (camStateJson?.hostCameraMuted === '1') {
        socket.emit('camera-on-rejected', { reason: 'host_muted', identity });
        return;
      }
      if (globalLock === '1') {
        socket.emit('camera-on-rejected', { reason: 'global_lock', identity });
        return;
      }

      // Allow — notify room of camera state change
      io.to(code).emit('participant:camera-state-changed', { identity, cameraOn: true });
    } catch (err) {
      console.error('[socket] participant:camera-on error:', err.message);
    }
  });
```

- [ ] **Step 4: Add camera state to `client:join-room` snapshot**

Find in the `client:join-room` handler:

```javascript
    // Send the participant their current mic state on reconnect
    try {
      const json = await redis.get(micStateKey(code, identity));
      const micState = json ? JSON.parse(json) : defaultMicState();
      socket.emit('room:mic-state-update', { participantId: identity, micState });
    } catch (_) { /* best-effort */ }
```

Replace it with:

```javascript
    // Send the participant their current mic state on reconnect
    try {
      const json = await redis.get(micStateKey(code, identity));
      const micState = json ? JSON.parse(json) : defaultMicState();
      socket.emit('room:mic-state-update', { participantId: identity, micState });
    } catch (_) { /* best-effort */ }

    // Send camera state snapshot for reconnect reconciliation
    try {
      const [camState, globalLock] = await Promise.all([
        redis.hgetall(roomCameraStateKey(code, identity)),
        redis.get(globalCameraLockKey(code)),
      ]);
      socket.emit('room:camera-state-snapshot', {
        participantId: identity,
        hostCameraMuted: camState?.hostCameraMuted === '1',
        globalCameraLockActive: globalLock === '1',
      });
    } catch (_) { /* best-effort */ }
```

- [ ] **Step 5: Verify server starts**

```bash
cd token-server && node -e "require('./index.js')" 2>&1 | head -5
```

- [ ] **Step 6: Manual verification of camera endpoints**

```bash
# Mute camera for a participant
curl -s -X POST http://localhost:3000/room/mute-camera-one \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <HOST_TOKEN>" \
  -d '{"roomCode":"TESTAB","callerIdentity":"host-1","targetIdentity":"user-2"}' \
  | jq .
# Expected: { "success": true }

# Verify Redis
redis-cli HGETALL "room:TESTAB:camerastate:user-2"
# Expected: 1) "hostCameraMuted" 2) "1"

# Mute all cameras
curl -s -X POST http://localhost:3000/room/mute-camera-all \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <HOST_TOKEN>" \
  -d '{"roomCode":"TESTAB","callerIdentity":"host-1"}' \
  | jq .
# Expected: { "success": true, "lockedCount": N }

redis-cli GET "room:TESTAB:global-camera-lock"
# Expected: "1"
```

- [ ] **Step 7: Commit**

```bash
git add token-server/index.js
git commit -m "feat(camera-mute): add camera Redis helpers, REST endpoints, socket guard, and reconnect snapshot"
```

---

### Task 9: Handle `room:camera-state-snapshot` on client (Socket.IO reconnect)

The client connects to Socket.IO and listens for `room:camera-state-snapshot`. When received, it calls the appropriate `apply*` methods.

**Files:**
- Modify: `inter/App/AppDelegate.m` (in the Socket.IO event setup section)

- [ ] **Step 1: Register the `room:camera-state-snapshot` handler**

Find where `room:mic-state-update` is subscribed to in `AppDelegate.m` (search for `room:mic-state-update` in the Socket.IO setup section).

In the same location, add the camera snapshot handler:

```objc
// room:camera-state-snapshot — sent by server on Socket.IO room join
// to reconcile camera lock state after a reconnect.
[self.socketManager on:@"room:camera-state-snapshot" callback:^(NSArray *args, SocketAckEmitter *ack) {
    NSDictionary *payload = [args firstObject];
    if (![payload isKindOfClass:[NSDictionary class]]) return;

    NSString *participantId = payload[@"participantId"];
    NSString *localId = self.roomController.localParticipantIdentity;
    if (![participantId isEqualToString:localId]) return;

    BOOL hostCamMuted = [payload[@"hostCameraMuted"] boolValue];
    BOOL globalLock   = [payload[@"globalCameraLockActive"] boolValue];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (globalLock) {
            [self.normalMediaWiring applyCameraGlobalLock];
        } else if (hostCamMuted) {
            [self.normalMediaWiring applyCameraHostMute];
        } else {
            // No lock — ensure flags are clear (idempotent)
            [self.normalMediaWiring applyCameraHostUnmute];
            [self.normalMediaWiring applyCameraGlobalLockLift];
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
git commit -m "feat(camera-mute): handle camera-state-snapshot for reconnect reconciliation"
```

---

### Task 10: Write XCTest for `deriveCameraButton` priority logic

**Files:**
- Create: `interTests/InterCameraWiringTests.swift`

- [ ] **Step 1: Create the test file**

Create `interTests/InterCameraWiringTests.swift` with:

```swift
// InterCameraWiringTests.swift
// inter
//
// Tests the deriveCameraButton priority logic by verifying that after
// applyCameraHostMute / applyCameraGlobalLock / apply*Lift, the control panel
// button title and enabled state are correct.
//
// NOTE: These tests exercise the apply* methods via their side effects on
// InterLocalCallControlPanel, which is a real NSView (safe to instantiate
// in test context without a running room).

import XCTest

#if canImport(inter)
@testable import inter
#endif

class InterCameraWiringTests: XCTestCase {

    var wiring: InterMediaWiringController!
    var panel: InterLocalCallControlPanel!

    override func setUp() {
        super.setUp()
        wiring = InterMediaWiringController()
        panel = InterLocalCallControlPanel()
        wiring.controlPanel = panel
        // No roomController — apply* methods guard on isConnected, so they will
        // NOT attempt to turn off the camera track. That's fine: we're testing
        // the flag + button state, not the hardware track lifecycle.
    }

    // MARK: - Signal type raw values (compile-time sanity)

    func test_SignalTypes_HaveCorrectRawValues() {
        XCTAssertEqual(InterControlSignalType.requestMuteCameraOne.rawValue, 36)
        XCTAssertEqual(InterControlSignalType.requestMuteCameraAll.rawValue, 37)
        XCTAssertEqual(InterControlSignalType.liftCameraLockOne.rawValue, 38)
        XCTAssertEqual(InterControlSignalType.liftCameraLockAll.rawValue, 39)
    }

    // MARK: - applyCameraHostMute

    func test_ApplyCameraHostMute_SetsHostCameraMuted() {
        wiring.applyCameraHostMute()
        XCTAssertTrue(wiring.hostCameraMuted)
    }

    func test_ApplyCameraHostMute_DisablesButton() {
        wiring.applyCameraHostMute()
        // Panel cameraButton must be disabled and show "Camera Off (Host)"
        XCTAssertFalse(panel.cameraButton.isEnabled)
        XCTAssertEqual(panel.cameraButton.title, "Camera Off (Host)")
    }

    func test_ApplyCameraHostMute_IncrementsCameraStateSequenceNumber() {
        let before = wiring.cameraStateSequenceNumber
        wiring.applyCameraHostMute()
        XCTAssertEqual(wiring.cameraStateSequenceNumber, before + 1)
    }

    // MARK: - applyCameraGlobalLock

    func test_ApplyCameraGlobalLock_SetsGlobalCameraLockActive() {
        wiring.applyCameraGlobalLock()
        XCTAssertTrue(wiring.globalCameraLockActive)
    }

    func test_ApplyCameraGlobalLock_ShowsLockedTitle() {
        wiring.applyCameraGlobalLock()
        XCTAssertFalse(panel.cameraButton.isEnabled)
        XCTAssertEqual(panel.cameraButton.title, "Camera Locked")
    }

    // MARK: - Priority: globalCameraLockActive > hostCameraMuted

    func test_GlobalLock_TakesPriorityOverHostMute() {
        // Both flags set: global lock title wins
        wiring.applyCameraHostMute()
        wiring.applyCameraGlobalLock()
        XCTAssertEqual(panel.cameraButton.title, "Camera Locked")
        XCTAssertFalse(panel.cameraButton.isEnabled)
    }

    // MARK: - applyCameraHostUnmute

    func test_ApplyCameraHostUnmute_ClearsHostCameraMuted() {
        wiring.applyCameraHostMute()
        wiring.applyCameraHostUnmute()
        XCTAssertFalse(wiring.hostCameraMuted)
    }

    func test_ApplyCameraHostUnmute_ButtonBecomesEnabledWhenNoGlobalLock() {
        wiring.applyCameraHostMute()
        wiring.applyCameraHostUnmute()
        XCTAssertTrue(panel.cameraButton.isEnabled)
    }

    func test_ApplyCameraHostUnmute_ButtonRemainsDisabledIfGlobalLockStillActive() {
        wiring.applyCameraGlobalLock()
        wiring.applyCameraHostMute()
        wiring.applyCameraHostUnmute()
        // Global lock still active — button stays disabled with "Camera Locked"
        XCTAssertFalse(panel.cameraButton.isEnabled)
        XCTAssertEqual(panel.cameraButton.title, "Camera Locked")
    }

    // MARK: - applyCameraGlobalLockLift

    func test_ApplyCameraGlobalLockLift_ClearsGlobalLock() {
        wiring.applyCameraGlobalLock()
        wiring.applyCameraGlobalLockLift()
        XCTAssertFalse(wiring.globalCameraLockActive)
    }

    func test_ApplyCameraGlobalLockLift_ButtonBecomesEnabled_HostMuteClearedToo() {
        wiring.applyCameraGlobalLock()
        wiring.applyCameraGlobalLockLift()
        // No host mute either → button enabled (shows "Turn Camera On" since
        // mediaController is nil in tests — setCameraEnabled: gets NO → "Turn Camera On")
        XCTAssertTrue(panel.cameraButton.isEnabled)
    }

    // MARK: - twoPhaseToggleCamera guard

    func test_TwoPhaseToggleCamera_BlockedWhenHostCameraMuted() {
        wiring.applyCameraHostMute()
        // Should return silently without crashing or altering flags
        wiring.twoPhaseToggleCamera()
        XCTAssertTrue(wiring.hostCameraMuted) // unchanged
    }

    func test_TwoPhaseToggleCamera_BlockedWhenGlobalLockActive() {
        wiring.applyCameraGlobalLock()
        wiring.twoPhaseToggleCamera()
        XCTAssertTrue(wiring.globalCameraLockActive) // unchanged
    }
}
```

- [ ] **Step 2: Run tests**

```bash
xcodebuild -scheme inter -destination "platform=macOS" test \
  -only-testing:interTests/InterCameraWiringTests 2>&1 | tail -20
```

Expected: All tests PASS. If `applyCameraHostMute` / `applyCameraGlobalLock` don't actually modify the button because `roomController` is nil and the early-return guard in apply* blocks it: verify whether the guard checks `isConnected` or whether it's safe to proceed without `roomController`. If needed, make the `InterMediaWiringController` flag + `deriveCameraButton` call unconditional (not gated on `isConnected`) — only the physical camera-track-off sequence should be gated.

> **Note on the `isConnected` guard:** The existing `applyRemoteMicMuteOne` does check `isConnected` at the top — this means the tests will fail because there's no room connection. For testability, restructure `applyCameraHostMute` so that the **flag update + `deriveCameraButton`** happens unconditionally, and only the **physical camera-off sequence** is gated on `isConnected`. The mic methods have this design flaw too but tests for them aren't included yet.

- [ ] **Step 3: Commit**

```bash
git add interTests/InterCameraWiringTests.swift
git commit -m "test(camera-mute): add XCTest for deriveCameraButton priority logic"
```

---

### Task 11: End-to-end smoke test

- [ ] **Step 1: Per-participant camera mute flow**

1. Host and Participant 2 are both in a meeting.
2. Host clicks "Mute Camera" on Participant 2's tile.
3. Participant 2's camera LED turns off. Button shows "Camera Off (Host)" (disabled).
4. Redis contains `room:{code}:camerastate:{identity} = { hostCameraMuted: 1 }`.
5. Participant 2 cannot re-enable camera (button disabled).
6. Host clicks "Unmute Camera" → Participant 2 sees a polite toast "Host asked you to turn on your camera" and button re-enables showing "Turn Camera On".
7. Participant 2 clicks "Turn Camera On" → camera resumes.

- [ ] **Step 2: Global camera lock flow**

1. Host clicks "Lock All Cameras" panel button.
2. All participants' cameras turn off. All buttons show "Camera Locked" (disabled).
3. Redis: `room:{code}:global-camera-lock = 1`.
4. Host clicks "Lift Camera Lock".
5. All participants' buttons show "Turn Camera On" (enabled). Cameras do NOT auto-resume.
6. Each participant individually clicks "Turn Camera On" to resume.

- [ ] **Step 3: Reconnect reconciliation**

1. Participant 2 is camera-muted by host.
2. Participant 2 disconnects and reconnects.
3. On reconnect, `client:join-room` fires → server sends `room:camera-state-snapshot { hostCameraMuted: true }` → client calls `applyCameraHostMute` → button shows "Camera Off (Host)".
