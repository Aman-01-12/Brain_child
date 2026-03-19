# Inter — Comprehensive Architecture & Code Review

> **Date**: June 2025  
> **Scope**: Full codebase (~11,800 lines — 7,363 ObjC + 4,443 Swift)  
> **Purpose**: Deep-dive audit before Phase 4 (Production Hardening)

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture Map](#2-architecture-map)
3. [Layer-by-Layer Analysis](#3-layer-by-layer-analysis)
4. [Feature Flows](#4-feature-flows)
5. [Code Quality Issues](#5-code-quality-issues)
6. [Risk Assessment](#6-risk-assessment)
7. [Recommendations](#7-recommendations)

---

## 1. Project Overview

**Inter** is a macOS desktop application for real-time video calls and secure interviews, built with:

| Component | Technology |
|-----------|-----------|
| Language | Objective-C (primary) + Swift (networking layer) |
| Networking | LiveKit Swift SDK (WebRTC) via SPM |
| Rendering | Metal (custom shaders, CVDisplayLink, CAMetalLayer) |
| Screen Capture | ScreenCaptureKit (macOS 13+) |
| Camera/Mic | AVFoundation (AVCaptureSession) |
| Token Server | Node.js + Express + livekit-server-sdk |

### Two Call Modes

| Mode | Description | Host Role | Joiner Role |
|------|-------------|-----------|-------------|
| **Normal Call** | Standard video call (like Zoom/Meet) | Full controls | Full controls |
| **Secure Interview** | Kiosk-mode interview with tools | Interviewer (standard window) | Interviewee (borderless, screen-saver-level, locked) |

### Codebase Statistics

| Layer | Files | Lines |
|-------|-------|-------|
| App (AppDelegate, Coordinator, Settings) | 3 .m + 3 .h | ~1,650 |
| Networking (Swift) | 10 .swift | ~4,443 |
| Media (Capture + Sharing) | 6 .m + 6 .h + protocols | ~2,400 |
| Rendering (Metal) | 2 .m + 2 .h | ~690 |
| UI (Windows, Views, Controllers) | 10 .m + 10 .h | ~2,600 |
| Token Server | 1 .js | ~273 |
| **Total** | **~50 files** | **~11,800** |

---

## 2. Architecture Map

```
┌──────────────────────────────────────────────────────────────────────┐
│                          AppDelegate.m (GOD OBJECT)                  │
│  Mode transitions · UI creation · KVO hub · Media/Network wiring     │
│  ┌─────────────────────┐    ┌───────────────────────────────┐       │
│  │ Normal Call Path     │    │ Secure Interview Path         │       │
│  │ (inline in AppDel)   │    │ SecureWindowController.m      │       │
│  └─────────┬───────────┘    └───────────────┬───────────────┘       │
└────────────┼────────────────────────────────┼───────────────────────┘
             │                                │
             ▼                                ▼
┌────────────────────────────────────────────────────────────────────┐
│                        MEDIA LAYER                                  │
│  InterLocalMediaController.m        AVCaptureSession owner          │
│  InterSurfaceShareController.m      Frame router (source → sinks)   │
│  InterScreenCaptureVideoSource.m    SCStream capture                │
│  InterAppSurfaceVideoSource.m       This-app capture (MetalSurface) │
│  InterViewSnapshotVideoSource.m     Interview tool capture          │
│  MetalSurfaceView.m                 Local preview + frame egress    │
│  MetalRenderEngine.m                Singleton shader pipeline       │
└───────────────────────┬──────────────────────────────────────────────┘
                        │ InterShareSink protocol
                        ▼
┌────────────────────────────────────────────────────────────────────┐
│                      NETWORKING LAYER (Swift)                       │
│  InterRoomController.swift          Room lifecycle orchestrator      │
│  InterLiveKitPublisher.swift        Track publishing + G2 mute      │
│  InterLiveKitSubscriber.swift       Remote track subscription        │
│  InterLiveKitCameraSource.swift     Camera → BufferCapturer          │
│  InterLiveKitAudioBridge.swift      Mic → SPSC ring buffer → ADM    │
│  InterLiveKitScreenShareSource.swift Share → BufferCapturer          │
│  InterTokenService.swift            JWT fetch/cache/refresh          │
│  InterCallStatsCollector.swift      10s stats collector              │
│  InterNetworkTypes.swift            All foundation types             │
│  InterRemoteVideoView.swift         Metal NV12/BGRA renderer        │
└───────────────────────┬──────────────────────────────────────────────┘
                        │
                        ▼
┌───────────────────────────────────────────────────────────────────┐
│                      UI LAYER                                      │
│  InterConnectionSetupPanel.m   Landing screen (host/join)          │
│  InterLocalCallControlPanel.m  Camera/mic/share controls           │
│  InterRemoteVideoLayoutManager.m   Grid/stage layout               │
│  InterParticipantOverlayView.m     Participant banner               │
│  InterNetworkStatusView.m          Connection quality indicator     │
│  InterTrackRendererBridge.m        ObjC↔Swift renderer bridge      │
│  SecureWindowController.m          Kiosk-mode interview window     │
│  SecureWindow.m / CapWindow.m      Custom NSWindow subclasses      │
└───────────────────────────────────────────────────────────────────┘
```

### Key Architectural Decisions (from tasks.txt)

| ID | Decision | Rationale |
|----|----------|-----------|
| G1 | Single-source audio fan-out | One AVCaptureAudioDataOutput → recording sink + LiveKit bridge. No dual-mic conflict. |
| G2 | Two-phase camera/mic toggle | Mute LiveKit FIRST → stop device. Start device FIRST → wait for frame → unmute. Prevents black/frozen frames. |
| G3 | NV12 format detection at render time | Remote frames may arrive as NV12 or BGRA depending on codec. |
| G5 | Sub-microsecond frame append | Sink callbacks must return immediately; encoding is async on dedicated queues. |
| G6 | 3-second grace timer for participant-left | Prevents UI flicker on transient disconnects. |
| G7 | 6-char room codes (30^6 = 729M) | Confusable chars excluded (I, O, 0, 1, 8, 9). 24h expiry. |
| G8 | Isolation invariant | nil controller = local-only mode. Every networking accessor guards against nil. |

---

## 3. Layer-by-Layer Analysis

### 3.1 App Layer

#### AppDelegate.m (1,555 lines)

The central orchestrator — and the single largest architectural concern. Responsibilities include:

- **Mode transitions**: `enterMode:role:` → creates appropriate UI (normal call window vs. secure interview window)
- **UI creation**: Builds setup window, normal call window, all subviews, control panels
- **Media wiring**: Creates `InterLocalMediaController`, `InterSurfaceShareController`, connects sources to sinks
- **Network wiring**: Binds camera/mic/share publishers via `InterLiveKitPublisher`
- **KVO hub**: Observes `connectionState`, `participantPresenceState`, `remoteParticipantCount` on `InterRoomController`
- **Settings management**: Reads/writes `InterAppSettings` for persistence
- **Alert presentation**: Error dialogs via `NSAlert`
- **Screen monitoring**: Tracks display changes for kiosk mode
- **Diagnostic clipboard**: Triple-click gesture → copies stats to pasteboard

#### InterCallSessionCoordinator.m (78 lines)

Simple state machine: `Idle → Entering → Active → Exiting → Idle`. Guards mode transitions to prevent re-entrant calls. Compact and well-designed.

#### InterAppSettings.m (10 lines)

Empty placeholder — only the interface is declared. Not used by any code.

---

### 3.2 Media Layer

#### InterLocalMediaController.m (1,009 lines)

Manages the `AVCaptureSession` lifecycle: camera + microphone device discovery, output configuration, session start/stop, device hot-plug monitoring.

**Key patterns**:
- All session work dispatched to `_sessionQueue` (serial)
- `prepareWithCompletion:` → `start` → `stop` → `shutdown` lifecycle
- Camera enable/disable guards against session being stopped
- Audio sample buffers forwarded to external handler block
- Device hot-plug via `AVCaptureDeviceWasConnectedNotification`

**Notable detail**: `performSynchronouslyOnSessionQueue:` uses `dispatch_sync` with a re-entrance guard (`_isOnSessionQueue` flag). This prevents deadlocks but is still a dispatch_sync pattern.

#### InterSurfaceShareController.m (441 lines)

Routes video frames and audio samples from capture sources to registered sinks on a serial `_routerQueue`.

**Key patterns**:
- Generation-based invalidation (`_routingGeneration`) — stale captures from a previous session are dropped
- `@synchronized(self)` for state mutations
- Three source types: App surface (MetalSurfaceView readback), Screen/Window (ScreenCaptureKit), Interview tool (view snapshot)
- Frame delivery: source callback → `_routerQueue` dispatch → iterate sinks → `appendVideoFrame:`

#### InterScreenCaptureVideoSource.m (751 lines)

ScreenCaptureKit-based capture for window/display sharing with system audio output.

**Key patterns**:
- Permission wait mechanism via `NSApplicationDidBecomeActiveNotification` (user has to toggle to System Preferences → re-activate app)
- Content filter creation for specific window or full display
- System audio captured via `SCStreamOutputTypeAudio`
- Generation-based state management prevents stale frame delivery
- `_controlQueue` for lifecycle operations, `_sampleQueue` for sample callbacks

#### MetalSurfaceView.m (424 lines)

The local preview renderer — a Metal-backed `NSView` with `CVDisplayLink` for vsync'd rendering.

**Key patterns**:
- `os_unfair_lock` for frame state (no priority inversion)
- 3 in-flight semaphore for triple buffering
- `CVPixelBufferPool` for readback frames (used by `InterAppSurfaceVideoSource` for "This App" sharing)
- `MTLBuffer` blit from capture texture → CPU-accessible buffer → `CVPixelBuffer`
- `shutdownRenderingSynchronously` drains the display link before teardown — critical for crash prevention

#### MetalRenderEngine.m (266 lines)

Singleton Metal pipeline with async shader compilation. Contains inline MSL (Metal Shading Language) source strings for:
- `interFullscreenVertex` — 4-vertex triangle strip (fullscreen quad)
- `interCompositeFragment` — solid dark gray background (placeholder)
- `interPresentFragment` — texture passthrough

---

### 3.3 Networking Layer (Swift)

#### InterRoomController.swift (525 lines)

The top-level networking orchestrator. Owns `Room`, `InterLiveKitPublisher`, `InterLiveKitSubscriber`, `InterTokenService`, `InterCallStatsCollector`.

**Key patterns**:
- KVO-published properties: `connectionState`, `participantPresenceState`, `remoteParticipantCount`, `roomCode`, `roomType`
- `connect(configuration:completion:)` → token service → `Room.connect()`
- `disconnect()` → cascading teardown
- `transitionMode(completion:)` → unpublishes tracks but keeps room alive (for interview→call mode switch)
- G6: 3-second `presenceGraceTimer` before declaring "alone"
- G8: nil publisher/subscriber = local-only mode

**RoomDelegate extension**: Maps LiveKit events (`participantDidJoin`, `participantDidLeave`, track subscription/unsubscription) to KVO state changes.

#### InterLiveKitPublisher.swift (490 lines)

Manages publishing local camera, microphone, and screen share tracks.

**Key patterns**:
- G2 two-phase state machines for camera (`InterCameraNetworkState`) and mic (`InterMicrophoneNetworkState`)
- `screenSharePublishGeneration` monotonic counter for stale publish invalidation
- `publishCamera` creates `InterLiveKitCameraSource` + `LocalVideoTrack`
- `publishMicrophone` creates `InterLiveKitAudioBridge` + enables LiveKit mic capture
- `publishScreenShare` creates `InterLiveKitScreenShareSource` (returns `InterShareSink`)
- `unpublishAll()` tears down all tracks

#### InterLiveKitAudioBridge.swift (553 lines)

The most technically complex file. Bridges app's `AVCaptureSession` microphone audio into LiveKit's WebRTC audio pipeline.

**Architecture**: `CMSampleBuffer` → `Float32` conversion → SPSC ring buffer write (on `conversionQueue`) → WebRTC ADM thread calls `audioProcessingProcess` → ring buffer read → deinterleave into `LKAudioBuffer`.

**Key details**:
- SPSC `AudioRingBuffer`: `UnsafeMutablePointer<Float>`, 500ms capacity, "atomic" head/tail
- Handles PCM Float32, Int16, Int32 sample formats
- Nearest-neighbor resampling when sample rates mismatch
- Mute/unmute state machine with `pendingUnmuteCallback`
- `Unmanaged<CMSampleBuffer>.passRetained` for safe async boundary crossing

#### InterLiveKitCameraSource.swift (256 lines)

Adds `AVCaptureVideoDataOutput` to existing `AVCaptureSession` for zero-copy camera frame delivery to LiveKit.

**Key patterns**:
- BGRA forced format, `alwaysDiscardsLateVideoFrames = true`
- Dedicated `captureOutputQueue`
- G2 camera state machine: `muted → enabling → active → muting → muted`
- Frame counting (sent/dropped stats)

#### InterLiveKitScreenShareSource.swift (376 lines)

Conforms to `InterShareSink` — receives frames from `InterSurfaceShareController` and publishes to LiveKit.

**Key patterns**:
- 15 FPS throttle (`minFrameInterval = 1/15`)
- 1920×1080 resolution cap with `vImageScale_ARGB8888` Lanczos downscaling
- Audio: `CMSampleBuffer` → `AVAudioPCMBuffer` → `AudioManager.shared.mixer.capture(appAudio:)`
- Handles Float32, Float64, Int16, Int32 PCM formats

#### InterLiveKitSubscriber.swift (389 lines)

Maps LiveKit's `RoomDelegate` track events to per-participant `RemoteFrameRenderer` instances.

**Key patterns**:
- `RemoteFrameRenderer` (nested class): `VideoRenderer` conformance, `os_unfair_lock` single-slot latest-frame-wins
- Views keyed by participant identity string
- Adaptive streaming support

#### InterTokenService.swift (526 lines)

JWT management: creates rooms, joins rooms, refreshes tokens, caches results.

**Key patterns**:
- `URLSession` with 10s timeout
- 1 retry on 5xx/timeout, no retry on 4xx
- JWT expiration extraction via base64-decoded payload
- Token refresh threshold: 60s before expiry
- Completions dispatched to main queue

#### InterCallStatsCollector.swift (201 lines)

Periodic stats collection: 10s interval, 360-entry circular buffer (1 hour of history).

**Key patterns**:
- `DispatchSourceTimer` fired on background queue
- `os_unfair_lock` for thread-safe buffer access
- `captureDiagnosticSnapshot` exports all entries for clipboard

#### InterRemoteVideoView.swift (808 lines)

Metal-accelerated `NSView` for rendering remote participant video via `CVMetalTextureCache` zero-copy path.

**Key patterns**:
- NV12 rendering: Y plane (`r8Unorm`) + CbCr plane (`rg8Unorm`) → BT.709 color matrix → sRGB
- BGRA passthrough rendering
- `os_unfair_lock` single-slot: `pendingPixelBuffer` + `lastRenderedPixelBuffer`
- `CVDisplayLink` with 2-semaphore in-flight limit
- `shutdownRenderingSynchronously` drain pattern
- Inline MSL shader source compiled at runtime
- Aspect-fit uniforms computed per-frame
- Offscreen rendering path for unit tests

---

### 3.4 UI Layer

#### InterConnectionSetupPanel.m — Landing screen with server URL, token server URL, display name, room code fields. Buttons: Host Call, Host Interview, Join. Persists to `NSUserDefaults`.

#### InterLocalCallControlPanel.m (462 lines) — Right-side controls with block-based handlers: camera toggle, mic toggle, share toggle, share mode selector (This App / Window / Screen), audio device picker, system audio checkbox, interview tool selector (during secure interviews), leave/end call button.

#### InterRemoteVideoLayoutManager.m (834 lines) — Google Meet-style layout engine:
- **CamerasOnly mode**: NxM grid layout
- **ScreenSharePresent mode**: Large stage view + vertical filmstrip sidebar
- **Spotlight**: Click-to-spotlight a participant
- `InterRemoteVideoTileView` wrapper adds: dark rounded rect, name label, hover highlight, click handler
- Animated transitions between layout modes

#### InterParticipantOverlayView.m — Floating participant count banner.

#### InterNetworkStatusView.m — Connection quality dot indicator (green/yellow/red).

#### InterTrackRendererBridge.m — ObjC↔Swift bridge for `VideoRenderer` protocol.

#### SecureWindowController.m (766 lines) — Manages the secure interviewee window:
- Borderless, `NSScreenSaverWindowLevel`, kiosk-locked
- **Nearly identical wiring to AppDelegate's normal call flow** (see Code Quality Issues)
- Owns its own media controller, surface share controller, control panel, layout manager
- Full KVO setup/teardown for room controller observation
- Two-phase camera/mic toggle (copy-pasted from AppDelegate)

#### SecureWindow.m / CapWindow.m — Custom `NSWindow` subclasses with specific level/behavior overrides.

---

## 4. Feature Flows

### 4.1 Host Creates Room → Normal Call

```
User clicks "Host Call"
  → InterConnectionSetupPanel delegate → AppDelegate
    → InterCallSessionCoordinator: Idle → Entering
      → InterRoomController.connect(configuration)
        → InterTokenService.createRoom(POST /room/create)
          ← { roomCode, token, serverURL }
        → Room.connect(serverURL, token)
          ← RoomDelegate: didConnect
            → KVO: connectionState = .connected
              → AppDelegate observeValueForKeyPath
                → enterMode: InterRoomTypeCall
                  → launchNormalCallWindow
                    → Create NSWindow + split view
                    → Create InterLocalCallControlPanel (right)
                    → Create InterRemoteVideoLayoutManager (left)
                    → startNormalLocalMediaFlow
                      → InterLocalMediaController.prepareWithCompletion
                        → .start (AVCaptureSession running)
                      → Create MetalSurfaceView (local preview in control panel)
                      → wireNormalNetworkPublish
                        → InterLiveKitPublisher.publishCamera(captureSession, sessionQueue)
                        → InterLiveKitPublisher.publishMicrophone + set audioSampleBufferHandler
                    → InterCallSessionCoordinator: Entering → Active
```

### 4.2 Joiner Enters Room Code

```
User enters code + clicks "Join"
  → InterConnectionSetupPanel delegate → AppDelegate
    → InterRoomController.connect(configuration) [joinCode set]
      → InterTokenService.joinRoom(POST /room/join)
        ← { roomName, token, serverURL, roomType }
      → Room.connect()
        ← RoomDelegate: didConnect
          → KVO: connectionState = .connected
            → AppDelegate reads roomType from configuration
              → If "call": enterMode: InterRoomTypeCall → normal flow above
              → If "interview": enterMode: InterRoomTypeInterview
                → createSecureWindow (if interviewee) or normal-ish window (if interviewer)
```

### 4.3 Screen Share Toggle

```
User clicks "Share Screen" toggle
  → InterLocalCallControlPanel → handler block → AppDelegate.toggleNormalSurfaceShare
    → Check Screen Recording permission (ScreenCaptureKit preflight)
      → If denied: show alert, abort
      → If granted:
        → Show InterWindowPickerPanel (window/screen selection UI)
          → User selects target
            → InterSurfaceShareController.startSharingSource: (Window/Screen/App)
              → Create InterScreenCaptureVideoSource / InterAppSurfaceVideoSource
              → Source starts capture → frames flow to _routerQueue
            → wireNetworkSinkOnSurfaceShareController:
              → InterLiveKitPublisher.createScreenShareSink()
                → Returns InterLiveKitScreenShareSource (conforms to InterShareSink)
              → Register sink on InterSurfaceShareController
              → Frames now routed: Source → Controller → Sink → LiveKit → Remote
```

### 4.4 Remote Video Rendering

```
Remote participant publishes video track
  → LiveKit Room receives track
    → RoomDelegate: didSubscribeTrack
      → InterLiveKitSubscriber.handleTrackSubscription
        → Create RemoteFrameRenderer (or reuse existing)
        → track.add(renderer: remoteRenderer)
        → KVO: notify layout manager of new participant
          → InterRemoteVideoLayoutManager.addRemoteCameraView:forParticipant:
            → Create InterRemoteVideoView (Metal layer + CVDisplayLink)
            → Wrap in InterRemoteVideoTileView (name label + hover)
            → Relayout: grid or stage+filmstrip

Frame delivery:
  LiveKit → RemoteFrameRenderer.renderFrame(frame) 
    → os_unfair_lock: store CVPixelBuffer in pendingPixelBuffer
    → CVDisplayLink callback fires at vsync
      → renderSemaphore.wait
      → Lock: grab pendingPixelBuffer (or re-present last)
      → Detect NV12 vs BGRA → render with appropriate Metal pipeline
      → commandBuffer.present(drawable) + commit
      → completedHandler: renderSemaphore.signal
```

### 4.5 Two-Phase Camera Mute (G2)

```
User clicks camera toggle (currently enabled)
  → AppDelegate.twoPhaseToggleNormalCamera
    → InterLiveKitPublisher.setCameraMuted(true)
      → Camera state: active → muting
      → LocalVideoTrack.mute() [LiveKit signal first]
      → Camera state: muting → muted
      → completion(true)
    → InterLocalMediaController.setCameraEnabled(NO)
      → Stop AVCaptureDeviceInput on session queue

User clicks camera toggle (currently disabled)
  → InterLocalMediaController.setCameraEnabled(YES)
    → Restart AVCaptureDeviceInput on session queue
    → completion(YES)
  → InterLiveKitPublisher.setCameraUnmuted(pendingFirstFrame: callback)
    → Camera state: muted → enabling
    → Wait for first real frame from AVCaptureVideoDataOutput
    → On first frame arrival:
      → Camera state: enabling → active
      → LocalVideoTrack.unmute() [signal after real frame]
```

### 4.6 Audio Pipeline (G1)

```
AVCaptureSession (mic)
  → AVCaptureAudioDataOutput
    → InterLocalMediaController captureOutput:didOutputSampleBuffer:
      → audioSampleBufferHandler block (set by AppDelegate)
        → InterLiveKitAudioBridge.appendAudioSampleBuffer(sampleBuffer)
          → Unmanaged.passRetained → dispatch to conversionQueue
            → convertAndWrite:
              → CMSampleBuffer → Float32 PCM (handle Int16/Int32/Float32)
              → Write to SPSC AudioRingBuffer (head advances)

  [Concurrently, on WebRTC audio thread ~every 10ms:]
  → AudioManager.shared calls capturePostProcessingDelegate
    → InterLiveKitAudioBridge.audioProcessingProcess(LKAudioBuffer)
      → Read from SPSC AudioRingBuffer (tail advances)
      → Deinterleave into LKAudioBuffer per-channel rawBuffers
      → WebRTC encodes and transmits
```

---

## 5. Code Quality Issues

### CRITICAL

#### C1: AppDelegate God Object (1,555 lines)

`AppDelegate.m` handles: mode transitions, UI creation, media controller lifecycle, network wiring, KVO observation, surface share toggling, permission checks, settings persistence, alert presentation, screen monitoring, diagnostic triple-click, and kiosk restriction enforcement.

**Impact**: Every new feature touches AppDelegate. High merge conflict risk. Impossible to unit test in isolation.

**Fix**: Extract into focused coordinators:
- `InterNormalCallCoordinator` — owns normal call window + media + network wiring
- `InterSecureInterviewCoordinator` — owns secure window + interview-specific logic  
- `InterMediaWiringController` — shared camera/mic/share publish logic
- AppDelegate reduced to: app lifecycle + mode transition routing only

#### C2: Massive Code Duplication (AppDelegate ↔ SecureWindowController)

~300+ lines of nearly identical code:
- Two-phase camera/mic toggle (`twoPhaseToggleCamera`, `twoPhaseToggleMicrophone`)
- KVO setup/teardown (`addObserver:forKeyPath:` for connectionState, participantPresence, remoteParticipantCount)
- Network publish wiring (`wireNetworkPublish` — camera + mic + audio handler)
- Network sink wiring for screen share
- Connection state KVO handler
- Presence state KVO handler
- Diagnostic triple-click
- Surface share start/stop with permission checks

**Impact**: Bug fixes must be applied in two places. One is always forgotten. Behavioral drift guaranteed over time.

**Fix**: Extract shared logic into `InterMediaWiringController` (or protocol with default implementations). Both AppDelegate and SecureWindowController delegate to it.

#### C3: AudioRingBuffer "Atomics" Are Not Truly Atomic

In `InterLiveKitAudioBridge.swift`, the SPSC ring buffer uses:
```swift
withUnsafeMutablePointer(to: &head) { ptr in
    // treated as "atomic" write
}
```

This is **NOT** an atomic operation. It relies on natural alignment guarantees of `Int` on arm64, which happen to work for single-writer/single-reader but are technically undefined behavior. On x86_64 (Intel Macs), this could tear under very specific conditions.

**Impact**: Rare data corruption or audio glitch on Intel Macs under extreme load.

**Fix**: Use `import Atomics` (Swift Atomics package) or `OSAtomicFifoEnqueue`/`os_unfair_lock` with explicit memory barriers.

---

### HIGH

#### H1: InterCallStatsCollector Only Records connectionQuality

`collectStats()` creates `InterCallStatEntry` with `connectionQuality` populated, but all other fields (`bitrateSend`, `bitrateReceive`, `framerateSend`, `framerateReceive`, `roundTripTime`, `packetLoss`, `jitter`) are always 0.

**Impact**: Diagnostic clipboard output is mostly zeros. Stats are useless for production debugging.

**Fix**: Query `room.localParticipant.getStats()` and `room.remoteParticipants[].getStats()` for real WebRTC stats. Map `RTCStatsReport` entries to the existing fields.

#### H2: Token Refresh Is Dead Code

In `InterRoomController.swift`, `refreshToken()` fetches a new JWT and stores it, but includes the comment:
> "LiveKit SDK currently doesn't expose a public API to update the token on an existing room connection"

The refreshed token is never applied to the active `Room`. If a 6-hour session exceeds TTL, the connection will fail.

**Impact**: Sessions >6 hours will disconnect with no recovery.

**Fix**: Either implement `Room.token` setter (if LiveKit SDK supports it now), or disconnect/reconnect with the fresh token.

#### H3: Nearest-Neighbor Audio Resampling

`InterLiveKitAudioBridge.swift` handles sample rate mismatches with simple nearest-neighbor interpolation:
```swift
let srcIndex = Int(Float(i) * Float(srcFrames) / Float(dstFrames))
```

**Impact**: Audible aliasing artifacts when mic sample rate ≠ WebRTC expected rate (rare but possible with non-standard USB audio interfaces).

**Fix**: Use `vDSP_desamp` or `AVAudioConverter` for proper sinc-interpolated resampling.

#### H4: Network Quality Mapping Is Hardcoded

`InterNetworkStatusView` maps `connectionState` enum values to quality levels instead of querying actual LiveKit connection quality metrics.

**Impact**: Quality indicator doesn't reflect real network conditions.

**Fix**: Observe `Room.connectionQuality` or participant-level quality events from LiveKit.

#### H5: Inconsistent Synchronization Strategy

The codebase uses three different synchronization primitives:
- `os_unfair_lock` — MetalSurfaceView, RemoteVideoView, CallStatsCollector, Subscriber
- `@synchronized(self)` — InterSurfaceShareController
- Serial dispatch queues — everywhere

`InterSurfaceShareController` is the only file using `@synchronized`, which is the slowest option and has different semantics (recursive-safe vs. non-recursive).

**Impact**: Mental overhead. Potential for wrong primitive selection in future code.

**Fix**: Standardize on `os_unfair_lock` for hot paths and serial dispatch queues for lifecycle management. Replace `@synchronized` in `InterSurfaceShareController` with `os_unfair_lock`.

---

### MEDIUM

#### M1: MetalRenderEngine Composite Shader Is Placeholder

`interCompositeFragment` returns a hardcoded solid dark gray color:
```metal
return float4(0.15, 0.15, 0.15, 1.0);
```

This shader is compiled but not used for actual compositing.

**Impact**: Wasted GPU compilation time. Confusing to readers who expect actual compositing logic.

**Fix**: Either implement real compositing or remove the dead shader.

#### M2: InterAppSettings Is Empty

`InterAppSettings.m` has no implementation. The `.h` declares nothing beyond `NSObject`.

**Impact**: Dead code taking up mental space.

**Fix**: Either implement settings management or remove the files.

#### M3: screenSharePublishGeneration Wrap-Around

`InterLiveKitPublisher.swift` uses `&+=` (wrapping addition) for the generation counter. While `UInt` wrap-around is practically impossible (would need 2^64 share starts), the use of `&+=` implies awareness of a theoretical concern without addressing it.

**Impact**: None in practice. Minor code clarity issue.

**Fix**: Use regular `+=` with a comment that overflow is impossible in practice, or keep `&+=` with a comment explaining why.

#### M4: CVPixelBufferPool Not Warmed

`MetalSurfaceView.m` creates a `CVPixelBufferPool` for readback but doesn't pre-warm it. First readback allocation will trigger a pool expansion on the display link thread.

**Impact**: Potential first-frame stutter when starting "This App" sharing.

**Fix**: Pre-allocate and immediately release one buffer after pool creation.

#### M5: performSynchronouslyOnSessionQueue Can Deadlock

`InterLocalMediaController.m` wraps `dispatch_sync` with an `_isOnSessionQueue` boolean guard:
```objc
if (_isOnSessionQueue) {
    block();
} else {
    dispatch_sync(_sessionQueue, ^{ block(); });
}
```

This prevents self-deadlock but the boolean is not thread-safe — it's written on `_sessionQueue` but could theoretically be read on another queue at the exact same moment.

**Impact**: Extremely unlikely race condition. The pattern is defensive but imperfect.

**Fix**: Use `dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)` comparison instead of a manual boolean, or restructure to avoid `dispatch_sync` entirely.

#### M6: KVO Without NSKeyValueObservingOptionInitial Causes First-State Misses

Some KVO registrations don't use `NSKeyValueObservingOptionInitial`, meaning if the observed property already has a value when observation starts, the observer won't be notified.

**Impact**: Potential for stale UI state on fast reconnections.

**Fix**: Add `NSKeyValueObservingOptionInitial` to all KVO registrations.

#### M7: Token Server In-Memory State

Room codes, rate limits, and all state are in-memory `Map` objects. Server restart loses all active rooms.

**Impact**: Acceptable for dev. Unacceptable for production.

**Fix**: Already noted in `tasks.txt` Phase 5.2.3 — migrate to Redis.

#### M8: Rate Limiter Memory Leak

The token server's `rateLimitMap` entries are never cleaned up. Each unique identity adds an entry that persists forever.

**Impact**: Slow memory growth over weeks of continuous operation.

**Fix**: Add cleanup in the hourly `setInterval` that also cleans `roomCodes`, or use a TTL-based map.

---

### LOW

#### L1: Magic Numbers Throughout

Examples:
- `3.0` seconds for presence grace timer (InterRoomController)
- `10.0` seconds for stats interval (InterCallStatsCollector)
- `360` max stats entries
- `15` FPS screen share throttle
- `1920x1080` resolution cap
- `500ms` ring buffer capacity
- `60` seconds token refresh threshold

**Fix**: Extract to named constants at the top of each file (many already are, but some are inline).

#### L2: Test Coverage Gaps

Tests exist for all networking Swift files, but:
- No tests for any Objective-C code
- No integration tests
- No UI tests

**Fix**: Phase 4 item (already planned).

#### L3: Bridging Header Imports Every ObjC Header

`inter-Bridging-Header.h` imports all ObjC headers, even those not needed by Swift code.

**Impact**: Slower incremental compilation times when ObjC headers change.

**Fix**: Import only headers actually referenced from Swift.

---

## 6. Risk Assessment

### What's Most Likely to Break When Adding Features

| Risk | Trigger | Severity |
|------|---------|----------|
| AppDelegate merge conflicts | Any feature touching mode transitions or UI | **High** |
| Forgetting to update SecureWindowController | Any fix to camera/mic/share logic in AppDelegate | **High** |
| KVO key mismatch | Adding new observable property to InterRoomController | **Medium** |
| Thread safety in audio bridge | Changing ring buffer capacity or format support | **High** |
| Display link lifecycle | Window creation/teardown order changes | **Medium** |
| Generation counter invalidation | Changing share source lifecycle | **Medium** |

### Safe Extension Points

| Extension Point | Mechanism | Notes |
|----------------|-----------|-------|
| New share source type | Conform to `InterShareVideoSource` protocol | Clean protocol-based extension |
| New remote track type | Add to `InterLiveKitSubscriber` | Well-isolated |
| New interview tool | Add case to `InterInterviewToolKind` enum | Straightforward |
| New audio sink | Conform to `InterShareSink` | Clean protocol |
| New stats fields | Extend `InterCallStatEntry` | Non-breaking |

---

## 7. Recommendations

### Priority 1: Extract from AppDelegate (Before Any New Feature)

```
AppDelegate.m (1,555 lines) → decompose into:
├── AppDelegate.m (~200 lines) — app lifecycle + mode router
├── InterNormalCallCoordinator.m (~400 lines) — normal call window + wiring
├── InterMediaWiringController.m (~300 lines) — shared camera/mic/share logic
└── (SecureWindowController already exists, just needs to use MediaWiringController)
```

This single refactor eliminates C1 and C2, reduces merge conflict surface by 80%, and makes every future feature safer.

### Priority 2: Fix Audio Ring Buffer Atomics (C3)

Add the Swift Atomics package (already using SPM) and replace the `withUnsafeMutablePointer` hack with `ManagedAtomic<Int>`. ~30 lines of change, high safety impact.

### Priority 3: Wire Real Stats (H1)

`InterCallStatsCollector.collectStats()` should query LiveKit's stats API. This unblocks production diagnostics.

### Priority 4: Address Token Refresh (H2)

Either implement reconnect-with-fresh-token or verify that LiveKit SDK now supports token update on active connections.

### Priority 5: Standardize Synchronization (H5)

Replace `@synchronized` in `InterSurfaceShareController` with `os_unfair_lock`. Document the synchronization strategy in a comment at the top of the file.

---

## Summary

The codebase is well-engineered at the individual component level — the Metal rendering pipeline, the SPSC audio bridge, the generation-based capture invalidation, and the protocol-based sink/source architecture all demonstrate strong systems programming skill. The LiveKit integration decisions (G1–G9) are sound and well-documented.

The primary structural concern is the **AppDelegate god object and its code duplication with SecureWindowController**. This is the #1 risk for regressions when adding new features. Addressing it before Phase 4 will pay for itself immediately.

The audio ring buffer's non-atomic writes (C3) and the dead token refresh path (H2) are the most dangerous latent bugs. Everything else is either cosmetic or already tracked in the task plan.
