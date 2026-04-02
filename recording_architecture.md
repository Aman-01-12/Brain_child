# Inter — Phase 10: Recording Architecture (Research & Design Document)

> **Date**: 31 March 2026 (Session 10) | **Audited**: 1 April 2026 (Concurrency & Edge Case Review)  
> **Status**: Research Complete — Audited for Thread Safety — Ready for Implementation  
> **Sources**: LiveKit Egress API docs, Apple AVFoundation docs, `new_feature.md`, `implementation_plan.md`, codebase audit  
> **Scope**: Complete recording system — local composed recording, watermark, cloud recording (Egress), multi-track  
> **Audit Scope**: Thread safety (5 critical fixes), race conditions (9 mitigations), edge cases (25+ scenarios), layout modes (5 dynamic layouts)

---

## Table of Contents

1. [Product Requirements Summary](#1-product-requirements-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Local Recording Pipeline (Mode 1)](#3-local-recording-pipeline-mode-1)
4. [Concurrency Model & Thread Safety](#4-concurrency-model--thread-safety)
5. [Dynamic Layout Modes](#5-dynamic-layout-modes)
6. [Edge Case Handling Matrix](#6-edge-case-handling-matrix)
7. [Metal Offscreen Compositing](#7-metal-offscreen-compositing)
8. [Audio Pipeline for Recording](#8-audio-pipeline-for-recording)
9. [Watermark System (Free Tier)](#9-watermark-system-free-tier)
10. [Cloud Recording via LiveKit Egress (Pro Tier)](#10-cloud-recording-via-livekit-egress-pro-tier)
11. [Multi-Track Recording (Hiring Tier)](#11-multi-track-recording-hiring-tier)
12. [Consent & Notification System](#12-consent--notification-system)
13. [Recording Coordinator & State Machine](#13-recording-coordinator--state-machine)
14. [Server-Side API Design](#14-server-side-api-design)
15. [File Management & Storage](#15-file-management--storage)
16. [Existing Codebase Integration Points](#16-existing-codebase-integration-points)
17. [Implementation Phases & Session Plan](#17-implementation-phases--session-plan)
18. [Risk Assessment & Mitigations](#18-risk-assessment--mitigations)

---

## 1. Product Requirements Summary

### From `new_feature.md`:

| Feature | Free | Pro | Hiring |
|:--------|:-----|:----|:-------|
| Local Recording | ✅ (watermarked) | ✅ (no watermark) | ✅ (no watermark) |
| Cloud Recording | ❌ | 10 hrs/user/month | 20 hrs/user/month |
| Multi-track Recording | ❌ | ❌ | ✅ |

### Recording Modes

**Mode 1 — Dynamic** — adapts to available sources (see §5 Dynamic Layout Modes):
  - Screen share + active speaker PiP (when screen share is active)
  - Camera-only fullscreen (single camera, no screen share)
  - Side-by-side cameras (two cameras, no screen share)
  - Idle frame (no video sources, audio-only recording)
  - Layout: Screen share (main area) + active speaker PiP (bottom-right corner)
  - Output: Single composed MP4 file (H.264 + AAC)
  - Free tier: watermarked. Pro/Hiring: no watermark
  - Save: locally (all tiers) or cloud (Pro/Hiring)

**Mode 2 — "Record Each Participant as Separate Track" (Hiring only)**
- Each participant gets separate video (.mp4) + audio (.m4a) files
- All tracks saved to cloud
- Manifest JSON describes track-to-participant mapping
- Use case: post-production editing, highlight reels

### Permissions
- Only **Host** or **Co-host** can initiate recording
- `canStartRecording` permission already exists in `InterPermissions.swift` (case 2)
- Host/Co-host roles already implemented in Phase 9

### Consent
- Prominent "REC" icon shown to all participants
- Audio announcement when recording starts
- New participants joining a recorded meeting must consent before entering

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    InterRecordingCoordinator                 │
│  (Swift — orchestrates all recording modes, state machine)  │
├─────────────┬──────────────────┬───────────────────────────┤
│             │                  │                           │
│  Mode 1: Local Composed       │  Mode 2: Multi-Track      │  Mode 3: Cloud
│  ┌─────────────────────┐      │  ┌───────────────────┐    │  ┌─────────────────┐
│  │ InterComposedRenderer│      │  │InterMultiTrackRec  │    │  │ LiveKit Egress   │
│  │ (Metal offscreen)   │      │  │(per-participant    │    │  │ API (server-     │
│  │  Screen + PiP + WM  │      │  │AVAssetWriter)      │    │  │  side, S3/GCS)  │
│  └────────┬────────────┘      │  └────────┬──────────┘    │  └────────┬────────┘
│           │ CVPixelBuffer     │           │                │           │
│  ┌────────▼────────────┐      │  Direct CVPixelBuffer     │  Token Server
│  │ InterRecordingEngine│      │  per participant feed      │  POST /room/record
│  │ (AVAssetWriter      │      │                           │
│  │  H.264+AAC → .mp4)  │      │                           │
│  └─────────────────────┘      │                           │
└───────────────────────────────┴───────────────────────────┘

Frame Sources:
  ├── Local camera: InterLocalMediaController → CVPixelBuffer
  ├── Local screen: InterSurfaceShareController → InterShareVideoFrame
  ├── Remote cameras: InterLiveKitSubscriber → CVPixelBuffer (per participant)
  └── Remote screen: InterLiveKitSubscriber → CVPixelBuffer (screen share)

Audio Sources:
  ├── Local mic: InterSurfaceShareController → CMSampleBuffer (audio)
  └── Remote audio: LiveKit handles mixing; for recording, tap AudioEngine
```

### Key Design Decisions

1. **Local recording uses native AVAssetWriter** — not LiveKit Egress. Egress requires a Docker container with headless Chrome, which is heavy for local use. AVAssetWriter with Metal compositing is native, efficient, and works offline.

2. **Cloud recording uses LiveKit Egress API** — server-side recording via `startRoomCompositeEgress` or `startParticipantEgress`. The Egress service runs as a separate Docker container alongside the LiveKit server. No client-side work needed for the actual recording capture.

3. **Multi-track uses LiveKit Participant Egress** — `startParticipantEgress` per identity records each participant's audio+video to separate files on S3/GCS. More efficient than client-side multi-AVAssetWriter (no re-encoding, no bandwidth duplication).

4. **Recording sink pattern** — For local recording, create a new `InterShareSink` conforming class that receives frames from the existing routing pipeline. This plugs into the already-proven sink architecture.

---

## 3. Local Recording Pipeline (Mode 1)

### 3.1 InterRecordingEngine (AVAssetWriter wrapper)

**Purpose**: Encapsulates AVAssetWriter lifecycle for writing H.264 video + AAC audio to an MP4 file.

**File**: `inter/Media/Recording/InterRecordingEngine.h/.m`

**Key APIs**:
```objc
@interface InterRecordingEngine : NSObject

@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly) BOOL isPaused;
@property (nonatomic, readonly) CMTime recordedDuration;

- (instancetype)initWithOutputURL:(NSURL *)outputURL
                        videoSize:(CGSize)videoSize   // 1920×1080
                        frameRate:(int)frameRate       // 30
                    audioChannels:(int)channels        // 2 (stereo)
                 audioSampleRate:(double)sampleRate;   // 48000.0

- (BOOL)startRecording;
- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer
          presentationTime:(CMTime)presentationTime;
- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)pauseRecording;
- (void)resumeRecording;
- (void)stopRecordingWithCompletion:(void (^)(NSURL *outputURL, NSError *error))completion;

@end
```

**Internal Architecture**:

```
AVAssetWriter (.mp4, AVFileTypeMPEG4)
├── AVAssetWriterInput (video)
│   ├── mediaType: .video
│   ├── outputSettings:
│   │   ├── AVVideoCodecKey: AVVideoCodecType.h264
│   │   ├── AVVideoWidthKey: 1920
│   │   ├── AVVideoHeightKey: 1080
│   │   ├── AVVideoCompressionPropertiesKey:
│   │   │   ├── AVVideoAverageBitRateKey: 4_500_000 (4.5 Mbps)
│   │   │   ├── AVVideoMaxKeyFrameIntervalKey: 60 (2s @ 30fps)
│   │   │   └── AVVideoProfileLevelKey: H264_Main_AutoLevel
│   │   └── AVVideoExpectedSourceFrameRateKey: 30
│   └── expectsMediaDataInRealTime: true
│
├── AVAssetWriterInputPixelBufferAdaptor
│   └── sourcePixelBufferAttributes:
│       ├── kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
│       ├── kCVPixelBufferWidthKey: 1920
│       ├── kCVPixelBufferHeightKey: 1080
│       └── kCVPixelBufferMetalCompatibilityKey: true
│
└── AVAssetWriterInput (audio)
    ├── mediaType: .audio
    └── outputSettings:
        ├── AVFormatIDKey: kAudioFormatMPEG4AAC
        ├── AVSampleRateKey: 48000.0
        ├── AVNumberOfChannelsKey: 2
        └── AVEncoderBitRateKey: 128_000 (128 kbps)
```

**Pause/Resume Strategy**:
- On pause: record `pauseStartTime = currentPTS`; stop appending frames
- On resume: calculate `pauseDuration = currentTime - pauseStartTime`; accumulate into `totalPauseDuration`
- All subsequent frame PTS = `originalPTS - totalPauseDuration`
- This produces a continuous output file with no gaps

**Thread Safety**:
- Dedicated serial dispatch queue (`recordingQueue`) for all AVAssetWriter operations
- `appendVideoPixelBuffer:` and `appendAudioSampleBuffer:` dispatch_async to this queue
- `isReadyForMoreMediaData` checked before each append; drop frame if not ready
- Frame drop counter for diagnostics
- **`_engineLock` (os_unfair_lock)** guards `_isPaused`, `_isStopping`, `_totalPauseDuration`,
  `_pauseStartTime` — these are read from the recording queue and written from the coordinator
  queue. Lock hold time < 100ns (only scalar reads/writes, no blocking calls inside lock).
  This matches the existing `os_unfair_lock` pattern in `InterSurfaceShareController` and
  `InterRemoteVideoView`.
- **Stop drain gate**: When `stopRecordingWithCompletion:` is called, set `_isStopping = YES`
  under the lock FIRST, then `dispatch_async(recordingQueue, ^{ ... finishWriting ... })`.
  All append methods check `_isStopping` before dispatching — this prevents frames from being
  enqueued after the stop sentinel block. The stop block is guaranteed to be the last block
  on the queue, so `finishWriting` cannot race with late appends.
- **Monotonic PTS enforcement**: Track `_lastVideoPTS` and `_lastAudioPTS` on the recording
  queue. If an incoming PTS ≤ the last PTS, drop the sample and increment the drop counter.
  This handles duplicate or out-of-order buffers caused by thread scheduling jitter.

### 3.2 InterComposedRenderer (Metal Offscreen Compositor)

**Purpose**: Takes multiple video sources and composites them into a single 1920×1080 CVPixelBuffer per frame. Supports multiple layout modes depending on which sources are available (see §5 Dynamic Layout Modes).

**File**: `inter/Media/Recording/InterComposedRenderer.h/.m`

**Key APIs**:
```objc
/// Layout mode for the composed recording output.
typedef NS_ENUM(NSInteger, InterComposedLayout) {
    InterComposedLayoutIdle = 0,            // No video sources → dark background + "Recording..." text
    InterComposedLayoutCameraOnlyFull,       // Single camera → fullscreen
    InterComposedLayoutCameraSideBySide,     // Two cameras → side-by-side (50/50 split)
    InterComposedLayoutScreenSharePiP,       // Screen share (main) + active speaker PiP (bottom-right)
    InterComposedLayoutScreenShareOnly,      // Screen share only, no active speaker camera available
};

@interface InterComposedRenderer : NSObject

/// Current layout (read-only, computed from available sources). KVO-observable.
@property (nonatomic, readonly) InterComposedLayout currentLayout;

/// Whether the watermark overlay is rendered (Free tier only).
@property (nonatomic) BOOL watermarkEnabled;

/// Update the screen share pixel buffer. Thread-safe — may be called from any thread.
/// Passing NULL clears the screen share source (triggers layout recalculation).
- (void)updateScreenShareFrame:(CVPixelBufferRef _Nullable)pixelBuffer;

/// Update the active speaker pixel buffer. Thread-safe — may be called from any thread.
/// @param pixelBuffer  Latest camera frame (NULL if camera is off).
/// @param identity     Participant identity string for display name overlay.
- (void)updateActiveSpeakerFrame:(CVPixelBufferRef _Nullable)pixelBuffer
                        identity:(NSString * _Nullable)identity;

/// Update a secondary speaker pixel buffer (for side-by-side layout when no screen share).
/// Thread-safe — may be called from any thread.
- (void)updateSecondarySpeakerFrame:(CVPixelBufferRef _Nullable)pixelBuffer
                           identity:(NSString * _Nullable)identity;

/// Generate a placeholder frame for an audio-only participant (dark background + name).
/// Cached per identity — only regenerated when identity changes.
- (CVPixelBufferRef _Nonnull)placeholderFrameForIdentity:(NSString *)identity;

- (instancetype)initWithDevice:(id<MTLDevice>)device
                  commandQueue:(id<MTLCommandQueue>)commandQueue
                    outputSize:(CGSize)outputSize;

/// Render one composed frame. Must be called from the render timer / recording queue.
/// Returns a CVPixelBuffer from the internal pool (triple-buffered).
- (CVPixelBufferRef _Nullable)renderComposedFrame;

@end
```

**Thread Safety (CRITICAL — addresses InterRemoteVideoView pattern)**:

The composed renderer receives frame updates from multiple producer threads simultaneously:
- Screen share frames: from `_routerQueue` (InterSurfaceShareController)
- Active speaker camera frames: from WebRTC decode thread (InterLiveKitSubscriber)
- Secondary speaker frames: from WebRTC decode thread (another participant)

These are consumed by the 30fps render timer on a background GCD queue.

**Synchronization**: `_frameLock` (`os_unfair_lock`) guards all mutable frame state:
- `_screenSharePixelBuffer`
- `_activeSpeakerPixelBuffer` + `_activeSpeakerIdentity`
- `_secondarySpeakerPixelBuffer` + `_secondarySpeakerIdentity`
- `_currentLayout` (recomputed on every frame update)

```objc
// Producer thread (any thread) — called from subscriber or sink callback
- (void)updateActiveSpeakerFrame:(CVPixelBufferRef)pixelBuffer identity:(NSString *)identity {
    os_unfair_lock_lock(&_frameLock);
    if (_activeSpeakerPixelBuffer) CVBufferRelease(_activeSpeakerPixelBuffer);
    _activeSpeakerPixelBuffer = pixelBuffer ? CVBufferRetain(pixelBuffer) : NULL;
    _activeSpeakerIdentity = [identity copy];
    [self _recalculateLayoutLocked];  // Updates _currentLayout based on which sources are non-NULL
    os_unfair_lock_unlock(&_frameLock);
}

// Consumer thread (render timer) — called every 33ms
- (CVPixelBufferRef)renderComposedFrame {
    // Snapshot all frame state under the lock (hold < 200ns)
    CVPixelBufferRef screenShare = NULL;
    CVPixelBufferRef activeSpeaker = NULL;
    CVPixelBufferRef secondarySpeaker = NULL;
    InterComposedLayout layout;

    os_unfair_lock_lock(&_frameLock);
    screenShare = _screenSharePixelBuffer ? CVBufferRetain(_screenSharePixelBuffer) : NULL;
    activeSpeaker = _activeSpeakerPixelBuffer ? CVBufferRetain(_activeSpeakerPixelBuffer) : NULL;
    secondarySpeaker = _secondarySpeakerPixelBuffer ? CVBufferRetain(_secondarySpeakerPixelBuffer) : NULL;
    layout = _currentLayout;
    os_unfair_lock_unlock(&_frameLock);

    // All Metal rendering happens OUTSIDE the lock with retained copies
    CVPixelBufferRef output = [self _renderLayout:layout
                                      screenShare:screenShare
                                    activeSpeaker:activeSpeaker
                                 secondarySpeaker:secondarySpeaker];

    if (screenShare) CVBufferRelease(screenShare);
    if (activeSpeaker) CVBufferRelease(activeSpeaker);
    if (secondarySpeaker) CVBufferRelease(secondarySpeaker);
    return output;
}
```

This pattern exactly mirrors `InterRemoteVideoView.updateFrame()` / `displayLinkCallback()`:
snapshot under lock, render outside lock, use retained copies to prevent use-after-free.

**Metal Rendering Pipeline**:

```
Step 1: Create offscreen MTLTexture (1920×1080, .bgra8Unorm, .shaderRead | .renderTarget)
         ↓
Step 2: Render screen share → full-frame quad
         ↓  (convert NV12 → BGRA using existing compose shader from MetalRenderEngine)
Step 3: Render active speaker PiP → small quad (e.g., 320×240) at bottom-right
         ↓  (same NV12→BGRA conversion, different viewport)
Step 4: [If watermark] Render watermark texture → semi-transparent quad, bottom-left
         ↓
Step 5: Read back MTLTexture → CVPixelBuffer
```

**MTLTexture → CVPixelBuffer Readback**:

The most efficient approach on macOS is to use `CVMetalTextureCache` with an IOSurface-backed CVPixelBuffer:

```objc
// Create IOSurface-backed CVPixelBuffer
NSDictionary *attrs = @{
    (id)kCVPixelBufferWidthKey: @(1920),
    (id)kCVPixelBufferHeightKey: @(1080),
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}  // IOSurface-backed!
};
CVPixelBufferRef pixelBuffer;
CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080,
                    kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs,
                    &pixelBuffer);

// Create Metal texture from the CVPixelBuffer (zero-copy!)
CVMetalTextureRef metalTexture;
CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
    textureCache, pixelBuffer, NULL,
    MTLPixelFormatBGRA8Unorm, 1920, 1080, 0, &metalTexture);

id<MTLTexture> renderTarget = CVMetalTextureGetTexture(metalTexture);
// Now render into renderTarget → pixels appear in pixelBuffer (shared memory)
```

This is **zero-copy**: the MTLTexture and CVPixelBuffer share the same IOSurface-backed memory. No `getBytes` or memcpy needed.

**CVPixelBuffer Pool**:
- Pre-allocate a pool of 3 CVPixelBuffers for triple buffering
- Rotate through them: one being rendered to, one being written by AVAssetWriter, one as spare
- Use `CVPixelBufferPoolCreate` with the same attributes as above
- **GPU Fence**: After Metal renders into a pool buffer, call `[commandBuffer addCompletedHandler:]`
  and signal a `dispatch_semaphore_t` per buffer slot. Before returning the buffer to the caller
  (or before AVAssetWriter reads it), `dispatch_semaphore_wait` ensures the GPU has finished.
  This prevents AVAssetWriter from reading a half-rendered frame.
  
```objc
// Triple-buffer pool with GPU completion tracking
@implementation InterComposedRenderer {
    CVPixelBufferRef _poolBuffers[3];
    dispatch_semaphore_t _poolSemaphores[3];   // Signaled when GPU finishes rendering to this slot
    NSInteger _poolWriteIndex;                  // Next slot to render into (rotates 0→1→2→0...)
}

- (CVPixelBufferRef)renderComposedFrame {
    NSInteger slot = _poolWriteIndex;
    _poolWriteIndex = (_poolWriteIndex + 1) % 3;

    // Wait for GPU to finish any previous render into this slot before we
    // re-use it as a new render target. This prevents overwriting a buffer
    // that AVAssetWriter or a prior commit is still reading.
    dispatch_semaphore_wait(_poolSemaphores[slot], DISPATCH_TIME_FOREVER);

    CVPixelBufferRef target = _poolBuffers[slot];
    // ... create Metal texture from target, encode render pass ...

    // Commit and wait synchronously for GPU completion before returning.
    //
    // WHY waitUntilCompleted instead of addCompletedHandler + signal:
    //   The caller (the 30fps _renderQueue timer) dispatch_async's the returned
    //   CVPixelBuffer to recordingQueue for AVAssetWriter.appendPixelBuffer.
    //   If we return the buffer before the GPU finishes, AVAssetWriter reads a
    //   half-rendered IOSurface. The triple-buffer pool only prevents SLOT REUSE
    //   races (next render won't touch this slot for 2 more frames), it does NOT
    //   guarantee the CURRENT render is complete before the CPU consumer reads.
    //
    //   Alternatives considered:
    //   - addCompletedHandler + dispatch to recordingQueue from handler: adds
    //     latency jitter and complicates the caller's control flow.
    //   - CVPixelBufferLockBaseAddress on recordingQueue: IOSurface kernel sync
    //     does block until GPU finishes, but this is an undocumented side effect
    //     and may not hold on all GPU drivers / macOS versions.
    //   - waitUntilCompleted on the _renderQueue is safe because Metal compositing
    //     takes < 2ms and the 33ms frame budget has > 30ms of headroom.
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    // GPU is done — the IOSurface backing `target` has valid pixel data.
    // Signal the semaphore so the NEXT render cycle (2 frames later) can
    // re-use this slot as a render target.
    dispatch_semaphore_signal(_poolSemaphores[slot]);

    // Safe to return: AVAssetWriter can read this buffer on recordingQueue
    // without racing with the GPU.
    return target;
}
```

**Frame Timing**:
- Driven at 30fps by a `dispatch_source_t` timer on a dedicated serial queue (`_renderQueue`)
- Each tick: snapshot frame state under `_frameLock` → render → append to engine
- If no new frames since last tick, re-render with last known frames (prevents gaps in output)
- If ALL frame sources are NULL (no video at all), render the idle layout (dark background)
- **Per-frame format detection**: Check `CVPixelBufferGetPixelFormatType()` on every frame,
  not just the first frame. Remote participants can switch cameras mid-call (format changes
  from NV12 to BGRA or vice versa). The shader variant is selected per-frame.

**Active Speaker Debouncing**:
- LiveKit's `activeSpeakerDidChange` can fire rapidly when multiple people speak simultaneously
- Without debouncing, the PiP frame thrashes between speakers every few hundred milliseconds
- **Solution**: Minimum hold time of 2 seconds. When a new active speaker is reported:
  1. If the current speaker has been active < 2 seconds, ignore the change (queue it as pending)
  2. If ≥ 2 seconds have elapsed, accept the switch immediately
  3. A GCD timer checks pending switches every 500ms
  4. This produces smooth, stable PiP even with overlapping speech
- Hold time is stored as `_activeSpeakerHoldUntil` (`CFAbsoluteTime`), checked under `_frameLock`

### 3.3 Recording Sink (Frame Capture)

**Purpose**: An `InterShareSink` conforming class that captures local screen share frames + audio for recording.

**File**: `inter/Media/Recording/InterRecordingSink.h/.m`

**How It Integrates**:

The existing `InterSurfaceShareController` has a sink array pattern:
```objc
// In InterSurfaceShareController.m → sinksForConfiguration:
- (NSArray<id<InterShareSink>> *)sinksForConfiguration:... {
    NSMutableArray *sinks = [NSMutableArray array];
    // Network publish sink (already exists)
    [sinks addObject:self.networkPublishSink];
    // NEW: Recording sink (when recording is active)
    if (self.recordingSink) {
        [sinks addObject:self.recordingSink];
    }
    return sinks;
}
```

**Dynamic Sink Insertion (CRITICAL — recording may start mid-session)**:

Recording can start while screen share is already active. The `sinksForConfiguration:` method only
runs at share start time — it cannot add sinks to an already-running pipeline. Solution:

```objc
// New method on InterSurfaceShareController
- (void)addLiveSink:(id<InterShareSink>)sink {
    os_unfair_lock_lock(&_stateLock);
    NSMutableArray *updated = [_sinks mutableCopy];
    [updated addObject:sink];
    _sinks = [updated copy];
    os_unfair_lock_unlock(&_stateLock);

    // Start the sink with current configuration
    InterShareSessionConfiguration *config = [self.configuration copy];
    [sink startWithConfiguration:config completion:^(BOOL active, NSString *statusText) {
        // Already running — sink joins mid-stream
    }];
}

- (void)removeLiveSink:(id<InterShareSink>)sink {
    os_unfair_lock_lock(&_stateLock);
    NSMutableArray *updated = [_sinks mutableCopy];
    [updated removeObject:sink];
    _sinks = [updated copy];
    os_unfair_lock_unlock(&_stateLock);

    [sink stopWithCompletion:^{}];
}
```

This is safe because:
- The lock matches the existing `_stateLock` pattern in `InterSurfaceShareController`
- `currentSinksSnapshot` (called from `_routerQueue`) takes a snapshot under the same lock
- The snapshot is an immutable `NSArray` — iteration cannot race with mutation
- The new sink may miss 1-2 frames between `addLiveSink:` and the next `routeVideoFrame:` call,
  which is acceptable (< 66ms at 30fps)

**When screen share is NOT active**: The recording sink is not added to `InterSurfaceShareController`.
Instead, the `InterRecordingCoordinator` directly observes `InterLiveKitSubscriber` for remote
frames and feeds them to `InterComposedRenderer`. Local camera frames come from
`InterLocalMediaController` (a new observer hook, see §16).

The recording sink receives:
- `appendVideoFrame:` → feeds screen share CVPixelBuffer to `InterComposedRenderer.updateScreenShareFrame:`
- `appendAudioSampleBuffer:` → feeds local audio to `InterRecordingEngine.appendAudioSampleBuffer:`

For **remote participant frames** (active speaker camera PiP):
- `InterLiveKitSubscriber` already delivers CVPixelBuffers via `InterRemoteTrackRenderer` protocol
- Add a secondary observer in the recording coordinator that picks the active speaker's frame
- Feed to `InterComposedRenderer.updateActiveSpeakerFrame:identity:`

**Recording sink thread contract**:
- `appendVideoFrame:` is called on `_routerQueue` (serial) — no internal locking needed for the
  call itself, but the forwarding call to `InterComposedRenderer.updateScreenShareFrame:` IS
  thread-safe (uses `_frameLock` inside the composed renderer)
- `appendAudioSampleBuffer:` is called on `_routerQueue` — forwards to
  `InterRecordingEngine.appendAudioSampleBuffer:` which dispatch_async's to `recordingQueue`
- `startWithConfiguration:` / `stopWithCompletion:` may be called from any thread — internal
  state (`_isActive`) is guarded by an `os_unfair_lock`

---

## 4. Concurrency Model & Thread Safety

### Thread Map

Every thread boundary in the recording pipeline is documented here. This section is the
single source of truth for which thread owns which data.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Thread                 │ What Runs Here              │ Synchronization       │
├────────────────────────┼─────────────────────────────┼───────────────────────┤
│ Main thread            │ UI buttons (start/stop/     │ coordinatorQueue      │
│                        │ pause/resume), state        │ (dispatch_async)      │
│                        │ observation (KVO)           │                       │
├────────────────────────┼─────────────────────────────┼───────────────────────┤
│ _routerQueue (serial)  │ InterSurfaceShareController │ _stateLock            │
│                        │ frame routing: calls        │ (os_unfair_lock)      │
│                        │ appendVideoFrame: and       │ for sink snapshot     │
│                        │ appendAudioSampleBuffer:    │                       │
│                        │ on each sink                │                       │
├────────────────────────┼─────────────────────────────┼───────────────────────┤
│ WebRTC decode thread   │ RemoteFrameRenderer.render  │ os_unfair_lock per    │
│ (one per remote track) │ → InterRemoteTrackRenderer  │ renderer instance     │
│                        │ → recording coordinator     │ + _frameLock on       │
│                        │ active speaker update       │ composed renderer     │
├────────────────────────┼─────────────────────────────┼───────────────────────┤
│ _renderQueue (serial)  │ 30fps dispatch_source timer │ _frameLock            │
│ (GCD, QOS_USER_INIT)   │ → InterComposedRenderer     │ (os_unfair_lock)     │
│                        │ .renderComposedFrame        │ for frame snapshot    │
│                        │                             │ + pool semaphores     │
├────────────────────────┼─────────────────────────────┼───────────────────────┤
│ recordingQueue (serial)│ AVAssetWriter append calls  │ _engineLock           │
│                        │ + finishWriting             │ (os_unfair_lock)      │
│                        │                             │ for pause/stop flags  │
├────────────────────────┼─────────────────────────────┼───────────────────────┤
│ coordinatorQueue       │ InterRecordingCoordinator   │ Serial queue          │
│ (serial, QOS_USER_INIT)│ state machine transitions   │ serializes all state  │
│                        │                             │ transitions           │
├────────────────────────┼─────────────────────────────┼───────────────────────┤
│ Audio engine RT thread │ AVAudioEngine output node   │ Lock-free ring buffer │
│ (real-time priority)   │ tap callback → ring buffer  │ (atomic head/tail)    │
│                        │ write                       │                       │
├────────────────────────┼─────────────────────────────┼───────────────────────┤
│ audioConversionQueue   │ Ring buffer read → CMSample │ Serial dispatch queue │
│ (serial)               │ Buffer → recordingQueue     │                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Lock Hierarchy (Deadlock Prevention)

Locks MUST be acquired in this order. Never acquire a higher-numbered lock while holding a lower one.

| Priority | Lock | Owner | Protects |
|:---------|:-----|:------|:---------|
| 1 (outermost) | `_frameLock` | InterComposedRenderer | Frame pixel buffers, layout state |
| 2 | `_engineLock` | InterRecordingEngine | isPaused, isStopping, PTS offsets |
| 3 | `_stateLock` | InterSurfaceShareController | Sink array, routing generation |
| 4 | `_sinkLock` | InterRecordingSink | isActive flag |

No lock is ever held while calling into another component that acquires a different lock.
All os_unfair_lock critical sections are < 200ns (only scalar reads/writes + CVBufferRetain/Release).

### Data Flow with Thread Boundaries

```
Screen share source                     Remote camera (WebRTC decode thread)
       │                                              │
       ▼                                              ▼
  _routerQueue ──(appendVideoFrame:)──►  RecordingSink ──► ComposedRenderer.updateScreenShareFrame:
       │                                              │         (acquires _frameLock)
       │                                              │
       │                              Subscriber callback ──► RecordingCoordinator ──►
       │                              (WebRTC thread)         coordinatorQueue
       │                                                           │
       │                                              ComposedRenderer.updateActiveSpeakerFrame:
       │                                                      (acquires _frameLock)
       │
       ▼
  _renderQueue (30fps timer)
       │
       ├── ComposedRenderer.renderComposedFrame (acquires _frameLock for snapshot, renders outside lock)
       │         │
       │         ▼ CVPixelBuffer (from pool, GPU completion guaranteed by semaphore)
       │
       ▼
  recordingQueue (dispatch_async)
       │
       ├── RecordingEngine.appendVideoPixelBuffer: (checks _engineLock for isPaused/isStopping)
       │
       ▼
  AVAssetWriter
```

### Race Condition Mitigations

| Race | How It Manifests | Mitigation |
|:-----|:----------------|:-----------|
| **Producer/consumer frame race** | WebRTC thread writes `activeSpeakerFrame` while render timer reads it | `_frameLock` + CVBufferRetain snapshot (see §3.2) |
| **Active speaker thrashing** | 3+ speakers → `activeSpeakerDidChange` fires every 200ms → PiP flickers | 2-second debounce hold time (see §3.2 Frame Timing) |
| **Stop while frames in-flight** | `finishWriting` called while append blocks are queued on `recordingQueue` | `_isStopping` flag checked before dispatch; stop sentinel is last block on queue |
| **Pause/resume PTS race** | `totalPauseDuration` written on resume thread, read on recording queue | `_engineLock` guards all PTS-related state; math done on `recordingQueue` |
| **Sink add/remove during routing** | `_sinks` array mutated while `routeVideoFrame:` iterates it | `_stateLock` + immutable snapshot copy (existing pattern) |
| **GPU/CPU pixel buffer race** | AVAssetWriter reads buffer while Metal is still rendering to it | Per-slot `dispatch_semaphore_t` signaled in `addCompletedHandler` |
| **Format change mid-recording** | Remote participant switches camera (NV12 → BGRA) | Per-frame `CVPixelBufferGetPixelFormatType()` check, shader selected per frame |
| **Double-stop** | User presses stop twice quickly | `coordinatorQueue` serializes; second stop finds state ≠ recording → no-op |
| **Start then immediate stop** | State = "starting", stop arrives before AVAssetWriter.startWriting() completes | Coordinator queues stop request; applied after state reaches "recording" |

---

## 5. Dynamic Layout Modes

### Layout Decision Matrix

The composed renderer automatically selects a layout based on which video sources are currently available:

| Screen Share | Active Speaker Camera | Secondary Speaker Camera | Layout | Description |
|:------------|:---------------------|:------------------------|:-------|:------------|
| ✅ | ✅ | — | `ScreenSharePiP` | Screen share fullscreen + camera PiP (320×240) bottom-right |
| ✅ | ❌ (camera off) | — | `ScreenShareOnly` | Screen share fullscreen, no PiP |
| ❌ | ✅ | ❌ | `CameraOnlyFull` | Single camera fullscreen (letterboxed to maintain aspect ratio) |
| ❌ | ✅ | ✅ | `CameraSideBySide` | Two cameras side-by-side (960×1080 each, 2px divider) |
| ❌ | ❌ | ❌ | `Idle` | Dark background (#0A0A0A) + "Recording..." text centered |
| ✅ | ❌ (audio-only speaker) | — | `ScreenSharePiP` | Screen share + **placeholder PiP** (dark bg + speaker name) |
| ❌ | ❌ (audio-only, is active speaker) | — | `CameraOnlyFull` | **Placeholder frame** fullscreen (dark bg + speaker name) |

### Layout Recalculation

Layout is recalculated inside `_frameLock` whenever a frame source changes:
```objc
- (void)_recalculateLayoutLocked {
    BOOL hasScreen = (_screenSharePixelBuffer != NULL);
    BOOL hasActiveSpeaker = (_activeSpeakerPixelBuffer != NULL);    // includes placeholder frames
    BOOL hasSecondarySpeaker = (_secondarySpeakerPixelBuffer != NULL);

    if (hasScreen) {
        _currentLayout = hasActiveSpeaker ? InterComposedLayoutScreenSharePiP
                                          : InterComposedLayoutScreenShareOnly;
    } else if (hasActiveSpeaker && hasSecondarySpeaker) {
        _currentLayout = InterComposedLayoutCameraSideBySide;
    } else if (hasActiveSpeaker) {
        _currentLayout = InterComposedLayoutCameraOnlyFull;
    } else {
        _currentLayout = InterComposedLayoutIdle;
    }
}
```

### Layout Transitions During Recording

When a source appears or disappears mid-recording (e.g., someone starts/stops screen sharing):

1. **Screen share starts during camera-only recording**:
   - `updateScreenShareFrame:` receives first non-NULL buffer
   - `_recalculateLayoutLocked` switches from `CameraOnlyFull` → `ScreenSharePiP`
   - Next render tick picks up new layout — transition is instant (no animation needed for recording)

2. **Screen share stops during recording**:
   - `updateScreenShareFrame:(NULL)` clears the screen share source
   - Layout switches from `ScreenSharePiP` → `CameraOnlyFull` or `CameraSideBySide`
   - Previous screen share frame is released — no stale references

3. **Active speaker loses camera mid-recording** (camera mute):
   - `InterLiveKitSubscriber` fires `remoteTrackDidMute(.camera, ...)` 
   - Recording coordinator generates placeholder frame for that identity
   - Calls `updateActiveSpeakerFrame:(placeholder) identity:(name)`
   - PiP shows dark background with participant name instead of frozen last frame

4. **All video sources disappear** (everyone turns off cameras, screen share stops):
   - Layout transitions to `Idle`
   - Composed renderer outputs dark frame with "Recording..." text
   - Recording continues — audio is still captured. The output MP4 has a dark video track
     during this period, which is correct behavior (no gaps in the file).

### Placeholder Frame Generation

For audio-only participants selected as active speaker:

```objc
- (CVPixelBufferRef)placeholderFrameForIdentity:(NSString *)identity {
    // Check cache first (keyed by identity string)
    CVPixelBufferRef cached = _placeholderCache[identity];
    if (cached) return CVBufferRetain(cached);

    // Generate: dark background + centered name text
    CGSize size = CGSizeMake(320, 240);  // PiP resolution
    // 1. Create CGBitmapContext with #1A1A1A background
    // 2. Draw identity string centered, white, SF Pro 24pt
    // 3. Upload to CVPixelBuffer (IOSurface-backed for Metal compatibility)
    // 4. Cache for reuse
    CVPixelBufferRef placeholder = /* ... */;
    _placeholderCache[identity] = placeholder;
    return CVBufferRetain(placeholder);
}
```

Placeholder cache is cleared when recording stops (coordinator teardown).

### Secondary Speaker Selection

When no screen share is active and there are 2+ participants with cameras on:
- **Primary**: Active speaker (determined by LiveKit's `activeSpeakersChanged`)
- **Secondary**: The most recently active speaker who is NOT the current primary
- Tracked via a `_recentSpeakers` NSMutableArray (ordered by last-active timestamp)
- When primary speaker changes, the previous primary becomes secondary (if camera is on)
- This gives a natural "conversation view" with the two current speakers side-by-side

---

## 6. Edge Case Handling Matrix

### Recording Lifecycle Edge Cases

| Edge Case | Scenario | Handling |
|:----------|:---------|:---------|
| **Start-before-video** | Recording starts but no participant has published video yet | Composed renderer outputs `Idle` layout. First frame triggers layout switch. |
| **Start-mid-screenshare** | Screen share is already active when user presses Record | `addLiveSink:` inserts recording sink into running pipeline (see §3.3). May miss 1-2 frames (< 66ms). |
| **Stop-while-starting** | User presses Record then immediately Stop | Coordinator queues stop; transitions idle→starting→recording→stopping→finalized. The recording file may be < 1 second. |
| **Double-start** | User presses Record twice quickly | `coordinatorQueue` serializes. Second start finds state ≠ idle → no-op, returns error to delegate. |
| **Room destroyed** | LiveKit room closes while recording is active | Room disconnect event → coordinator auto-stops recording → `finishWriting` → file saved. |
| **App crash/force-quit** | Process terminates during recording | AVAssetWriter file is incomplete (no moov atom). On next launch, detect orphaned `.tmp` files and delete them. |
| **Disk space exhaustion** | Disk fills up during recording | Pre-check: warn if < 2GB free before starting. During recording: monitor with `statvfs()` every 30 seconds; auto-stop with error if < 500MB free. |
| **Very long recording** | Recording exceeds 1 hour (file > 2GB) | No hard limit. `shouldOptimizeForNetworkUse = true` places moov atom at front progressively. Warn user at 1 hour mark. |

### Participant Edge Cases

| Edge Case | Scenario | Handling |
|:----------|:---------|:---------|
| **Audio-only active speaker** | Speaker has camera off, is loudest → active speaker | Generate placeholder frame with name (see §5). PiP shows name on dark background. |
| **All cameras off** | No participant has video publishing | `Idle` layout with dark background. Audio continues recording normally. |
| **Participant leaves** | Active speaker disconnects mid-recording | `remoteTrackDidEnd` → clear their frame in composed renderer → layout recalculates. If they were active speaker, next loudest becomes active. |
| **Participant joins** | New participant enters room during recording | New frames automatically delivered via subscriber. If they become active speaker, composed renderer picks them up via the debounced speaker change flow. |
| **Multiple screen shares** | Two participants try to share screen simultaneously | LiveKit allows only one screen share publisher per room by default. If configured otherwise, the composed renderer uses the FIRST received screen share source. |
| **Screen share format change** | Sharer switches from display capture (BGRA) to window capture (NV12) | Per-frame format detection in composed renderer shader. Handled transparently. |
| **Local participant is active speaker** | The recording user is speaking | Show local camera frame from `InterLocalMediaController` in PiP instead of remote frame. Recording coordinator checks if active speaker identity matches local identity. |

### Audio Edge Cases

| Edge Case | Scenario | Handling |
|:----------|:---------|:---------|
| **All participants muted** | Everyone is on mute → audio tap produces silence | Continue appending silent CMSampleBuffers. AVAssetWriter needs continuous audio to maintain A/V sync. Silence is valid audio data. |
| **Audio format mismatch** | Local mic is 44.1kHz, remote is 48kHz | The `AVAudioEngine` output node mixes at a single sample rate (48kHz). The tap format is consistent. |
| **Audio engine restart** | AVAudioEngine interrupted (e.g., Bluetooth headset connect/disconnect) | Re-install tap after engine restart. Gap in audio → silent samples fill the gap (PTS continuity preserved). |
| **Priority inversion** | Audio tap runs on real-time thread; recording queue is QOS_USER_INITIATED | Audio tap writes to a lock-free ring buffer (same SPSC pattern as `InterLiveKitAudioBridge`). A non-RT timer drains the ring buffer to the recording queue. NO dispatch or lock acquisition from the RT thread. |

### Pause/Resume Edge Cases

| Edge Case | Scenario | Handling |
|:----------|:---------|:---------|
| **Rapid pause/resume** | User toggles pause 10 times in 1 second | `coordinatorQueue` serializes all transitions. Each pause/resume is valid. Minimum pause duration: none (but PTS offset accumulation is correct regardless). |
| **Pause → participant leaves → resume** | Active speaker leaves during pause, then recording resumes | On resume, composed renderer has stale frame reference cleared (subscriber sent `remoteTrackDidEnd` during pause). Layout recalculates on next render tick. |
| **Pause → screen share stops → resume** | Screen share stops during pause | Same as above — `updateScreenShareFrame:(NULL)` still processes during pause (composed renderer accepts updates regardless of recording pause state). Layout recalculates. |
| **PTS accumulation precision** | Many pause/resume cycles accumulate floating-point error | Use `CMTime` (rational number) for all PTS math, not `double`. `CMTimeSubtract(originalPTS, totalPauseDuration)` is lossless. |

### Concurrent Mode Edge Cases

| Edge Case | Scenario | Handling |
|:----------|:---------|:---------|
| **Local + cloud simultaneous** | User starts local recording, then starts cloud recording | Allowed. They are independent pipelines. Local uses AVAssetWriter on client; cloud uses Egress on server. Coordinator tracks both states independently. |
| **Cloud recording network failure** | Egress service becomes unreachable mid-recording | Egress handles its own resilience. If `stopEgress` fails → retry 3 times with exponential backoff. If still failed → mark recording as `failed` in DB. Notify user. |
| **Multi-track participant count change** | New participant joins during multi-track recording | For LiveKit Participant Egress: the server CANNOT add a new participant egress to an already-running session. Solution: start a new Participant Egress for the new joiner. Update manifest when all egresses complete. |

---

## 7. Metal Offscreen Compositing

### Shader Reuse

The existing `MetalRenderEngine` already has:
- **Compose pipeline**: NV12→BGRA conversion shader (vertex + fragment)
- **Present pipeline**: Texture-to-drawable blit shader
- Shared `MTLDevice` + `MTLCommandQueue` via `[MetalRenderEngine sharedEngine]`

For the composed renderer, we need to:
1. **Reuse the device and command queue** from `MetalRenderEngine.sharedEngine`
2. **Create new pipeline states** for:
   - Full-frame screen share render (same NV12→BGRA shader, full viewport)
   - PiP camera render (same shader, smaller viewport with offset)
   - Watermark alpha-blend render (simple textured quad with alpha)

### New Metal Shader Requirements

```metal
// Watermark fragment shader (new)
fragment float4 watermarkFragment(VertexOut in [[stage_in]],
                                  texture2d<float> watermarkTex [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float4 color = watermarkTex.sample(s, in.texCoord);
    color.a *= 0.3; // 30% opacity
    return color;
}
```

The NV12→BGRA conversion shader already exists in `MetalRenderEngine.m`. We can extend it or create a variant that also handles BGRA input (for camera frames that may arrive in BGRA format from `InterRemoteVideoView`'s frame pipeline).

### Performance Considerations

- **Offscreen rendering**: No drawable/present needed — just render to texture
- **Target**: 1080p @ 30fps = one render pass every 33ms
- **Metal command buffer cost**: ~0.5-1ms per composite pass on Apple Silicon
- **IOSurface zero-copy**: No memory transfer between GPU render target and AVAssetWriter input
- **Total per-frame budget**: < 5ms — well within 33ms interval

---

## 8. Audio Pipeline for Recording

### Challenge

The app has two audio categories:
1. **Local microphone audio**: Captured via `AVCaptureSession` in `InterLocalMediaController`, routed through `InterSurfaceShareController` sinks as `CMSampleBuffer`
2. **Remote participant audio**: Handled by LiveKit's internal audio engine (WebRTC). Not directly accessible as raw samples in the current pipeline.

### Solution: Mixed Audio Recording

**Option A (Recommended for Mode 1 — Local Composed Recording):**
Use macOS `AVAudioEngine` tap to capture the mixed output audio (local mic + all remote participants mixed by LiveKit's audio engine).

**CRITICAL**: The tap callback runs on a **real-time priority audio thread**. It MUST NOT:
- Acquire any lock (os_unfair_lock, NSLock, dispatch_sync, semaphore wait)
- Allocate memory (malloc, ObjC object creation)
- Log (os_log, NSLog)
- Dispatch synchronously to another queue

Instead, use the same lock-free SPSC ring buffer pattern from `InterLiveKitAudioBridge`:

```swift
// Lock-free ring buffer for audio recording (same pattern as InterLiveKitAudioBridge)
// Ring buffer stores interleaved samples: [L0, R0, L1, R1, ...]
private let audioRingBuffer = AudioRingBuffer(frameDuration: 0.5, sampleRate: 48000, channels: 2)
private let audioConversionQueue = DispatchQueue(label: "inter.recording.audio.conversion",
                                                  qos: .userInitiated)

// Pre-allocated interleaving scratch buffer — sized from the actual tap format at
// install time (bufferSize × channelCount). Allocated ONCE before installTap, on a
// non-RT thread. Never reallocated on the RT thread.
// If outputNode has N channels, capacity = 4096 × N floats.
let tapChannelCount = max(1, Int(format.channelCount))   // query BEFORE installTap
let interleaveBuffer: UnsafeMutablePointer<Float> = .allocate(capacity: 4096 * tapChannelCount)
interleaveBuffer.initialize(repeating: 0, count: 4096 * tapChannelCount)

// Install tap — callback runs on real-time audio thread
let outputNode = InterAudioEngineAccess.outputNode()!
let format = outputNode.outputFormat(forBus: 0)
outputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
    guard let self = self else { return }
    // REAL-TIME SAFE: Only pointer reads + atomic writes — no locks, no alloc, no logging
    //
    // AVAudioPCMBuffer.floatChannelData is UnsafePointer<UnsafeMutablePointer<Float>>:
    // an array of per-channel pointers (NON-INTERLEAVED). Each pointer[i] has
    // buffer.frameLength samples for that channel.
    //
    // We must interleave into the scratch buffer before writing to the ring buffer.
    guard let floatData = buffer.floatChannelData else { return }
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    let clampedChannels = min(channelCount, tapChannelCount)
    let interleavedCount = frameCount * clampedChannels

    // Bounds guard: the OS can occasionally deliver a larger-than-requested buffer.
    // Reject it rather than writing past the pre-allocated capacity.
    guard interleavedCount <= 4096 * tapChannelCount else { return }

    // Interleave: [L0, R0, L1, R1, ...] from separate [L0, L1, ...] + [R0, R1, ...] arrays
    for frame in 0..<frameCount {
        for ch in 0..<clampedChannels {
            self.interleaveBuffer[frame * clampedChannels + ch] = floatData[ch][frame]
        }
    }

    self.audioRingBuffer.write(self.interleaveBuffer, count: interleavedCount)
}

// Drain ring buffer on a non-RT queue at 10ms intervals
let drainTimer = DispatchSource.makeTimerSource(queue: audioConversionQueue)
drainTimer.schedule(deadline: .now(), repeating: .milliseconds(10))
drainTimer.setEventHandler { [weak self] in
    guard let self = self else { return }
    // Read from ring buffer → create CMSampleBuffer → append to recording engine
    var samples = [Float](repeating: 0, count: 960)  // 10ms @ 48kHz stereo = 480 frames × 2 ch
    let read = self.audioRingBuffer.read(into: &samples, count: samples.count)
    if read > 0 {
        let sampleBuffer = self.convertFloatsToCMSampleBuffer(samples, count: read)
        self.recordingEngine.appendAudioSampleBuffer(sampleBuffer)
    }
}
drainTimer.resume()

// In deinit: interleaveBuffer.deallocate()
```

This avoids the priority inversion that would occur if the tap callback directly dispatched
to `recordingQueue` — the dispatch_async call itself can contend for the libdispatch work
queue lock, which is held by non-RT threads.

Alternatively, since `InterLiveKitAudioBridge` already taps local mic audio for publishing:
- Create a parallel tap for recording that captures the same local mic samples
- For remote audio, use LiveKit's `AudioTrack.add(audioRenderer:)` to receive PCM frames per remote participant

**Option B (For separate local+remote tracks):**
- Local mic: CMSampleBuffer from existing sink pipeline
- Remote audio: `AudioTrack.add(audioRenderer:)` per remote participant → mix in software

**Recommendation**: Option A (tap output node) for Mode 1 (composed recording). Option B elements needed for Mode 2 (multi-track).

### Audio Format

- Input: Float32 PCM (from AVAudioEngine) or Int16 PCM (from LiveKit)
- Output: AAC (AAC-LC, 128kbps, 48kHz, stereo) via AVAssetWriter audio input
- AVAssetWriter handles the PCM → AAC encoding automatically when output settings specify `kAudioFormatMPEG4AAC`

---

## 9. Watermark System (Free Tier)

### Design

- **Text**: "Inter" logo/text
- **Position**: Bottom-left corner, 15% from edge
- **Appearance**: Semi-transparent (30% opacity), white text with subtle drop shadow
- **Size**: ~150px wide at 1080p (proportional to output resolution)

### Implementation

1. **Pre-render watermark** to an MTLTexture at init time:
   - Use Core Graphics to render text "Inter" into a CGBitmapContext
   - Upload to `MTLTexture` via `texture.replace(region:...)`
   - Cache — never re-render

2. **Composite in Metal pass**:
   - After screen share + PiP renders, add a third draw call
   - Alpha-blend the watermark texture at the designated position
   - Only when `InterComposedRenderer.watermarkEnabled == YES`

3. **Tier check**:
   - `InterRecordingCoordinator` reads user tier from token metadata (already available from Phase 6 auth)
   - Sets `composedRenderer.watermarkEnabled = (userTier == .free)`

### Watermark Texture Generation

```objc
// Generate watermark bitmap, scaled proportionally to outputSize.
// Base metrics are designed for 1920×1080; scale linearly for other resolutions.
CGFloat scaleFactor = outputSize.width / 1920.0;
CGSize watermarkSize = CGSizeMake(ceil(200.0 * scaleFactor), ceil(50.0 * scaleFactor));
CGFloat fontSize = 36.0 * scaleFactor;

CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
NSInteger bytesPerRow = (NSInteger)watermarkSize.width * 4;
CGContextRef ctx = CGBitmapContextCreate(NULL,
    (size_t)watermarkSize.width, (size_t)watermarkSize.height,
    8, bytesPerRow, colorSpace,
    kCGImageAlphaPremultipliedLast);

// Draw "Inter" text with scaled font
NSDictionary *attrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:fontSize weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.3]
};
NSAttributedString *text = [[NSAttributedString alloc] initWithString:@"Inter" attributes:attrs];
// ... draw into context ...

// Upload to MTLTexture at the scaled dimensions
MTLTextureDescriptor *desc = [MTLTextureDescriptor
    texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                width:(NSUInteger)watermarkSize.width
                               height:(NSUInteger)watermarkSize.height
                            mipmapped:NO];
id<MTLTexture> watermarkTexture = [device newTextureWithDescriptor:desc];
[watermarkTexture replaceRegion:MTLRegionMake2D(0, 0,
                                    (NSUInteger)watermarkSize.width,
                                    (NSUInteger)watermarkSize.height)
                    mipmapLevel:0
                      withBytes:CGBitmapContextGetData(ctx)
                    bytesPerRow:bytesPerRow];

CGContextRelease(ctx);
CGColorSpaceRelease(colorSpace);
// Cache watermarkTexture — never re-render unless outputSize changes.
```

---

## 10. Cloud Recording via LiveKit Egress (Pro Tier)

### Architecture Decision

Cloud recording uses **LiveKit's Egress API**, NOT client-side recording + upload. This is the correct architecture because:

1. **Server-side capture**: Egress records directly from the SFU — no extra bandwidth on the client
2. **Reliability**: Client disconnects don't lose the recording
3. **Quality**: Egress captures the full-fidelity SFU streams, not re-encoded client frames
4. **Scalability**: Egress service auto-scales independently

### LiveKit Egress Service Setup

The Egress service runs as a separate Docker container:

```yaml
# egress-config.yaml
api_key: ${LIVEKIT_API_KEY}
api_secret: ${LIVEKIT_API_SECRET}
ws_url: ws://host.docker.internal:7880
insecure: true  # for local dev
redis:
  address: host.docker.internal:6379

# File upload destination
# No static access_key / secret here. The Egress container inherits credentials
# from the platform's automatic provider chain, in priority order:
#   1. EC2 instance profile (attach an IAM role to the instance/ECS task)
#   2. IRSA / EKS Pod Identity (Kubernetes — annotate the service account)
#   3. AWS_ROLE_ARN + web identity token file (any OIDC-enabled platform)
# For local dev only: set AWS_PROFILE in the Docker run environment instead of
# embedding long-lived keys in this file.
s3:
  region: ${AWS_REGION}
  bucket: inter-recordings
  # access_key and secret intentionally omitted — resolved by instance/workload IAM role
```

**IAM least-privilege policy** — attach to the Egress service role; no other principal needs write access to this bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EgressWriteRecordings",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl"
      ],
      "Resource": "arn:aws:s3:::inter-recordings/recordings/*"
    },
    {
      "Sid": "EgressListBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::inter-recordings",
      "Condition": { "StringLike": { "s3:prefix": ["recordings/*"] } }
    }
  ]
}
```

**S3 bucket policy** — block all public access at the bucket level and restrict `s3:GetObject` to the authorized API service role only:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyPublicAccess",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::inter-recordings",
        "arn:aws:s3:::inter-recordings/*"
      ],
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalArn": [
            "arn:aws:iam::ACCOUNT_ID:role/inter-egress-role",
            "arn:aws:iam::ACCOUNT_ID:role/inter-api-role"
          ]
        }
      }
    }
  ]
}
```

Docker run command:
```bash
docker run --rm \
  --cap-add SYS_ADMIN \
  -e EGRESS_CONFIG_FILE=/out/config.yaml \
  -v ~/livekit-egress:/out \
  livekit/egress
```

**Requirements**: 4 CPUs, 4 GB RAM per Egress instance. Uses headless Chrome for RoomComposite rendering.

### Egress API Calls (from token-server)

Using `livekit-server-sdk` (v2.x, already compatible with our Node.js token server):

```javascript
const { EgressClient, EncodedFileOutput, S3Upload,
        EncodingOptionsPreset, RoomCompositeEgressRequest,
        WebhookReceiver } = require('livekit-server-sdk');

// Webhook receiver validates the X-Livekit-Signature header on incoming Egress events
const webhookReceiver = new WebhookReceiver(
    process.env.LIVEKIT_API_KEY,
    process.env.LIVEKIT_API_SECRET
);

const egressClient = new EgressClient(
    process.env.LIVEKIT_WS_URL,
    process.env.LIVEKIT_API_KEY,
    process.env.LIVEKIT_API_SECRET
);

// Allowlist of valid tier values. Any value from req.user.tier that is not in
// this set is coerced to 'free' to prevent S3 path traversal.
const VALID_TIERS = ['free', 'pro', 'hiring'];

function getValidatedTier(rawTier) {
    if (typeof rawTier === 'string' && VALID_TIERS.includes(rawTier)) {
        return rawTier;
    }
    return 'free'; // safe default
}

// Retention thresholds — read from env so they can be changed without a deploy.
// Defaults match the S3 lifecycle rules when the env vars are absent.
const RETENTION_DAYS = {
    free:    parseInt(process.env.FREE_RETENTION_DAYS    ?? '30',  10),
    pro:     parseInt(process.env.PRO_RETENTION_DAYS     ?? '180', 10),
    hiring:  parseInt(process.env.HIRING_RETENTION_DAYS  ?? '365', 10),
};

// Start cloud recording
async function startCloudRecording(roomName, tier) {
    // Validate and normalise the caller's tier so untrusted input can never
    // inject path separators ('/', '..') into the S3 key.
    const validatedTier = getValidatedTier(tier);

    // S3Upload with no accessKey/secret: the livekit-server-sdk delegates to the
    // AWS SDK default credential provider chain (instance profile → IRSA → env vars).
    // Long-lived static keys MUST NOT be set here — use the IAM role on the host.
    const fileOutput = new EncodedFileOutput({
        filepath: `recordings/${validatedTier}/${roomName}/{time}.mp4`,
        output: {
            case: 's3',
            value: new S3Upload({
                bucket: 'inter-recordings',
                region: process.env.AWS_REGION,
                // accessKey and secret intentionally omitted — resolved by IAM role
            }),
        },
    });

    const info = await egressClient.startRoomCompositeEgress(roomName, {
        file: fileOutput,
        layout: 'speaker',  // screen share + active speaker layout
        preset: EncodingOptionsPreset.H264_1080P_30,
    });

    return info; // { egressId, status, ... }
}

// Stop cloud recording
async function stopCloudRecording(egressId) {
    const info = await egressClient.stopEgress(egressId);
    return info; // includes fileResults with S3 URL
}

// Returns true if userId is currently a host or co-host participant in roomName.
// Queries the LiveKit RoomService for live participant metadata — the JWT role claim
// alone is not sufficient here because we need to confirm the participant is actually
// present in this specific room with an elevated role.
async function isHostOrCoHost(userId, roomName) {
    try {
        const participants = await roomServiceClient.listParticipants(roomName);
        for (const p of participants) {
            // Participant identity is set to userId at token-grant time.
            if (p.identity !== String(userId)) continue;
            // Role is stored in participant metadata as JSON: { role: "host"|"co-host"|... }
            const meta = p.metadata ? JSON.parse(p.metadata) : {};
            if (meta.role === 'host' || meta.role === 'co-host') return true;
        }
    } catch {
        // If the LiveKit query fails (e.g. room already closed), deny by default.
    }
    return false;
}
```

### Egress Types for Our Use Cases

| Our Feature | LiveKit Egress Type | Why |
|:------------|:-------------------|:----|
| Mode 1 Cloud (composed) | `startRoomCompositeEgress` | Records entire room with built-in speaker layout |
| Mode 2 Multi-track | `startParticipantEgress` (per participant) | Records each participant separately; handles join/leave/mute automatically |
| Individual track export | `startTrackEgress` | Raw track export, no transcoding |

### Built-in Layouts

LiveKit Egress comes with these layouts that match our needs:
- **`speaker`**: Focused on active speaker with screen share taking most space — **matches our Mode 1 perfectly**
- **`grid`**: Equal-size tiles for all participants
- **`single-speaker`**: Only shows the active speaker

### Metering & Quotas

```sql
-- PostgreSQL schema for recording metering
ALTER TABLE users ADD COLUMN recording_minutes_used INTEGER DEFAULT 0;
ALTER TABLE users ADD COLUMN recording_quota_minutes INTEGER DEFAULT 0;
-- Free: 0 (no cloud), Pro: 600 (10hrs), Hiring: 1200 (20hrs)

CREATE TABLE recording_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id),
    room_name VARCHAR(255) NOT NULL,
    egress_id VARCHAR(255),           -- LiveKit egress ID (cloud only)
    recording_mode VARCHAR(50) NOT NULL, -- 'local_composed', 'cloud_composed', 'multi_track'
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at TIMESTAMPTZ,
    duration_seconds INTEGER,
    file_size_bytes BIGINT,
    storage_url TEXT,                  -- S3/GCS URL (cloud only)
    watermarked BOOLEAN DEFAULT false,
    status VARCHAR(20) DEFAULT 'active', -- 'active', 'completed', 'failed'
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

Quota enforcement:
```javascript
// Before starting cloud recording
const user = await db.query('SELECT recording_minutes_used, recording_quota_minutes FROM users WHERE id = $1', [userId]);

// Cloud recordings MUST supply an explicit estimatedDurationMinutes so quota
// enforcement is never bypassed by an omitted or zero value.
// Reject immediately if the field is absent or not a positive finite number.
const rawEstimate = req.body.estimatedDurationMinutes;
if (
    rawEstimate === undefined ||
    rawEstimate === null ||
    typeof rawEstimate !== 'number' ||
    !Number.isFinite(rawEstimate) ||
    rawEstimate <= 0
) {
    return res.status(400).json({
        error: 'estimatedDurationMinutes is required and must be a positive number',
    });
}
const estimatedDurationMinutes = Math.ceil(rawEstimate);

if (user.recording_minutes_used + estimatedDurationMinutes > user.recording_quota_minutes) {
    return res.status(403).json({ error: 'Recording quota exceeded' });
}
```

### Access Token for Egress

The Egress API requires `roomRecord` permission on the access token:
```javascript
at.addGrant({ roomRecord: true });
```
This is a server-side operation — the token server already has `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`.

---

## 11. Multi-Track Recording (Hiring Tier)

### Architecture

Multi-track recording uses **LiveKit Participant Egress** — one egress per participant, each recording separately to cloud storage.

```javascript
// Start multi-track recording for all current participants
async function startMultiTrackRecording(roomName, participants) {
    const egressIds = [];

    for (const participant of participants) {
        const fileOutput = new EncodedFileOutput({
            filepath: `recordings/${roomName}/multitrack/{publisher_identity}-{time}.mp4`,
            output: {
                case: 's3',
                value: new S3Upload({ /* ... */ }),
            },
        });

        const info = await egressClient.startParticipantEgress(roomName, participant.identity, {
            file: fileOutput,
            preset: EncodingOptionsPreset.H264_1080P_30,
            screenShare: true,  // Include screen share track if participant shares
        });

        egressIds.push({
            participantIdentity: participant.identity,
            egressId: info.egressId,
        });
    }

    return egressIds;
}
```

**Key Participant Egress Behaviors**:
- Waits for participant to publish tracks before recording starts
- Automatically handles mute/unmute (muted audio = silence in recording)
- Stops when participant leaves the room
- Supports `screenShare: true` to also capture screen share from that participant

### Manifest File

After all participant egress sessions complete, generate a manifest:

```json
{
    "roomName": "interview-2026-03-31",
    "recordingMode": "multi_track",
    "startedAt": "2026-03-31T14:00:00Z",
    "endedAt": "2026-03-31T14:45:00Z",
    "tracks": [
        {
            "participantIdentity": "host-uuid",
            "participantName": "Alice (Host)",
            "videoUrl": "s3://inter-recordings/recordings/.../host-uuid-2026-03-31.mp4",
            "duration": 2700,
            "hasScreenShare": false
        },
        {
            "participantIdentity": "candidate-uuid",
            "participantName": "Bob (Candidate)",
            "videoUrl": "s3://inter-recordings/recordings/.../candidate-uuid-2026-03-31.mp4",
            "duration": 2700,
            "hasScreenShare": true
        }
    ]
}
```

Upload manifest JSON to the same S3 bucket alongside the track files.

---

## 12. Consent & Notification System

### When Recording Starts

1. **Visual**: "REC" badge appears in the top-right corner of all participants' windows
   - Red dot (●) + "REC" text + elapsed time counter
   - Uses existing `InterNetworkStatusView` area or a new overlay view

2. **Audio**: Play a short recording notification sound
   - Bundle a 1-2 second chime audio file
   - Play via `NSSound` or `AVAudioPlayer` to all participants via data channel

3. **Data Channel Broadcast**: Host sends `recordingStarted` event to all participants
   ```json
   {
       "type": "recordingStarted",
       "mode": "composed",      // or "multi_track"
       "startedBy": "host-identity",
       "timestamp": 1711893600000
   }
   ```

### Consent for New Joiners

When a new participant joins a room where recording is active:

1. Token server checks room recording state before issuing join token
2. Client displays consent dialog: "This meeting is being recorded. Do you consent to continue?"
3. If consent denied → participant disconnects / stays in lobby
4. Implementation: room metadata includes `"recording": true` flag; client reads on join

### When Recording Stops

1. "REC" badge disappears
2. Data channel broadcast: `recordingStopped` event
3. Room metadata updated: `"recording": false`

---

## 13. Recording Coordinator & State Machine

### InterRecordingCoordinator (Swift)

**File**: `inter/Media/Recording/InterRecordingCoordinator.swift`

**Concurrency Model**: All state transitions are serialized on a dedicated serial dispatch queue
(`coordinatorQueue`, QOS `.userInitiated`). External callers (UI thread, subscriber callbacks)
always `dispatch_async` to this queue. The `state` property is readable from any thread via
an `os_unfair_lock` (read-only snapshot), but all mutations happen exclusively on `coordinatorQueue`.

This is the most critical synchronization point in the recording system — it prevents:
- Double-start (two concurrent `startRecording` calls)
- Stop-during-start (stop arrives before AVAssetWriter is ready)
- Pause/resume interleaving with start/stop
- Delegate callbacks from unexpected threads

```swift
@objc public class InterRecordingCoordinator: NSObject {
    private let coordinatorQueue = DispatchQueue(label: "inter.recording.coordinator",
                                                  qos: .userInitiated)
    private var _stateLock = os_unfair_lock()
    private var _state: InterRecordingState = .idle

    /// Thread-safe read of current state (snapshot under lock).
    @objc public var state: InterRecordingState {
        os_unfair_lock_lock(&_stateLock)
        let s = _state
        os_unfair_lock_unlock(&_stateLock)
        return s
    }

    /// Internal state mutation — MUST only be called on coordinatorQueue.
    private func transitionTo(_ newState: InterRecordingState) {
        dispatchPrecondition(condition: .onQueue(coordinatorQueue))
        let oldState = _state
        guard isValidTransition(from: oldState, to: newState) else {
            interLogError(InterLog.media, "Recording: invalid transition %d → %d", oldState.rawValue, newState.rawValue)
            return
        }
        os_unfair_lock_lock(&_stateLock)
        _state = newState
        os_unfair_lock_unlock(&_stateLock)

        // Notify delegate on main thread
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.recordingStateDidChange(newState)
        }
    }

    /// Valid state transitions (prevents illegal sequences).
    private func isValidTransition(from: InterRecordingState, to: InterRecordingState) -> Bool {
        switch (from, to) {
        case (.idle, .starting),
             (.starting, .recording), (.starting, .failed),
             (.recording, .paused), (.recording, .stopping),
             (.paused, .recording), (.paused, .stopping),
             (.stopping, .finalized), (.stopping, .failed),
             (.finalized, .idle), (.failed, .idle):
            return true
        default:
            return false
        }
    }
}
```

**Queued stop during start**: If `stopRecording()` is called while state is `.starting`,
the coordinator stores a `_pendingStop = true` flag. When the start completion handler fires
(on `coordinatorQueue`), it checks `_pendingStop` and immediately transitions to `.stopping`
instead of `.recording`. This prevents the "stop called before AVAssetWriter is ready" crash.

**State Machine**:
```
                        ┌──────────┐
         startRecording │          │ stopRecording
    ┌──────────────────►│ Recording├──────────────────┐
    │                   │          │                   │
    │                   └───┬──┬───┘                   │
    │                       │  │                       │
    │               pause   │  │  resume               │
    │                       │  │                       │
    │                   ┌───▼──▼───┐                   │
    │                   │  Paused  │                   │
    │                   └──────────┘                   │
    │                                                  │
┌───┴──────┐                                    ┌──────▼────┐
│   Idle   │◄───────────────────────────────────│ Finalizing│
│          │         finishWriting complete      │           │
└──────────┘                                    └───────────┘
```

**State enum**:
```swift
@objc public enum InterRecordingState: Int {
    case idle = 0
    case starting = 1
    case recording = 2
    case paused = 3
    case stopping = 4
    case finalized = 5
    case failed = 6
}
```

**Responsibilities**:
1. Permission check (`InterPermissionMatrix.hasPermission(.canStartRecording, for: currentRole)`)
2. Determine recording mode (local vs cloud vs multi-track) based on user tier + selection
3. Initialize appropriate recording pipeline
4. Broadcast consent notifications via data channel
5. Manage recording state (start/pause/resume/stop)
6. Update room metadata with recording status
7. Handle file output + cleanup

**Coordinator Interface**:
```swift
@objc public class InterRecordingCoordinator: NSObject {
    /// Thread-safe read of current state (snapshot under os_unfair_lock).
    @objc public var state: InterRecordingState { get }

    @objc public weak var delegate: InterRecordingCoordinatorDelegate?

    // Permission check (can be called from any thread — reads immutable role data)
    @objc public func canRecord(role: InterParticipantRole) -> Bool
    
    // All start/stop/pause/resume methods dispatch_async to coordinatorQueue.
    // They return immediately — state changes are reported via delegate.
    
    // Local recording
    @objc public func startLocalRecording(
        screenShareSource: InterSurfaceShareController,
        subscriber: InterLiveKitSubscriber,
        localMediaController: InterLocalMediaController,
        userTier: String
    )
    
    // Cloud recording (via server API)
    @objc public func startCloudRecording(roomName: String)
    
    // Multi-track (via server API)
    @objc public func startMultiTrackRecording(roomName: String)
    
    @objc public func pauseRecording()
    @objc public func resumeRecording()
    @objc public func stopRecording()

    // Called by subscriber when active speaker changes — dispatches to coordinatorQueue
    // with 2-second debounce before updating composed renderer.
    @objc public func activeSpeakerDidChange(_ participantId: String)

    // Called when a participant's camera mutes/unmutes — updates placeholder frame logic
    @objc public func participantCameraDidChange(_ participantId: String, isMuted: Bool)

    // Called when a participant leaves — clears stale frame references
    @objc public func participantDidLeave(_ participantId: String)

    // Called when screen share starts/stops mid-recording
    @objc public func screenShareDidChange(isActive: Bool)
}

@objc public protocol InterRecordingCoordinatorDelegate: AnyObject {
    /// State machine transition. Called on main thread.
    @objc func recordingStateDidChange(_ state: InterRecordingState)

    /// Recording completed (or failed). outputURL is nil for cloud recordings.
    /// Called on main thread.
    @objc func recordingDidComplete(outputURL: URL?, error: Error?)

    /// Duration update (fires every 1 second during recording). Called on main thread.
    @objc func recordingDurationDidUpdate(_ duration: TimeInterval)

    /// Layout changed during recording (e.g., screen share started/stopped).
    /// Called on main thread. UI can update layout indicator.
    @objc optional func recordingLayoutDidChange(_ layout: InterComposedLayout)
}
```

---

## 14. Server-Side API Design

### New Endpoints (token-server)

```
POST   /room/record/start    → Start cloud or multi-track recording
POST   /room/record/stop     → Stop recording
GET    /room/record/status    → Get recording status + elapsed time
GET    /recordings            → List user's recordings  
GET    /recordings/:id        → Get recording details (URL, duration, etc.)
DELETE /recordings/:id        → Delete a recording
```

### Endpoint Details

```javascript
// POST /room/record/start
// Body: { roomName, mode: "cloud_composed" | "multi_track" }
app.post('/room/record/start', requireAuth, requireRole('host', 'co-host'), async (req, res) => {
    const { roomName, mode } = req.body;
    const userId = req.user.id;
    
    // 1. Check quota
    const quota = await checkRecordingQuota(userId);
    if (!quota.allowed) {
        return res.status(403).json({ error: 'Recording quota exceeded', quota });
    }
    
    // 2. Start egress
    let egressInfo;
    if (mode === 'cloud_composed') {
        egressInfo = await startCloudRecording(roomName, req.user.tier);
    } else if (mode === 'multi_track') {
        egressInfo = await startMultiTrackRecording(roomName, await getRoomParticipants(roomName));
    }
    
    // 3. Record in DB
    await db.query(`
        INSERT INTO recording_sessions (user_id, room_name, egress_id, recording_mode, status)
        VALUES ($1, $2, $3, $4, 'active')
    `, [userId, roomName, egressInfo.egressId, mode]);
    
    // 4. Update room metadata
    await roomServiceClient.updateRoomMetadata(roomName, JSON.stringify({
        ...existingMetadata,
        recording: true,
        recordingMode: mode
    }));
    
    res.json({ success: true, egressId: egressInfo.egressId });
});

// POST /room/record/stop
app.post('/room/record/stop', requireAuth, requireRole('host', 'co-host'), async (req, res) => {
    const { roomName, egressId } = req.body;

    // Authorization: load the session record and verify the caller is allowed to stop it.
    // requireRole confirmed the user is a host/co-host in the JWT, but we must also confirm:
    //   (a) This egressId actually belongs to the stated roomName (cross-room tamper prevention).
    //   (b) The caller is EITHER the original starter OR a current host/co-host in that room.
    //       The strict original-starter-only check was too restrictive — it prevented a
    //       co-host from stopping a recording someone else started in the same room.
    const sessionResult = await db.query(
        `SELECT user_id, room_name FROM recording_sessions WHERE egress_id = $1 AND status = 'active'`,
        [egressId]
    );
    if (sessionResult.rows.length === 0) {
        return res.status(404).json({ error: 'Recording session not found' });
    }
    const session = sessionResult.rows[0];

    // Hard block: the egressId must belong to the room the caller claims — always enforced.
    if (session.room_name !== roomName) {
        return res.status(403).json({ error: 'Not authorized to stop this recording' });
    }

    // Soft check: caller owns the session OR is a host/co-host in that room right now.
    const callerOwnsSession = session.user_id === req.user.id;
    const callerIsHostOrCoHost = await isHostOrCoHost(req.user.id, roomName);
    if (!callerOwnsSession && !callerIsHostOrCoHost) {
        // 403 — do not call stopEgress, do not touch DB or metadata
        return res.status(403).json({ error: 'Not authorized to stop this recording' });
    }

    // Signal Egress to stop. This moves the Egress to EGRESS_ENDING status.
    // The final file URL, duration, and size are NOT available in this response —
    // they arrive asynchronously via the POST /webhooks/egress webhook once the
    // Egress service finishes writing and uploading the file.
    await egressClient.stopEgress(egressId);

    // Mark session as finalizing. The webhook handler completes the rest.
    await db.query(
        `UPDATE recording_sessions SET status = 'finalizing' WHERE egress_id = $1`,
        [egressId]
    );

    // Clear room metadata immediately — recording is no longer active from clients' perspective
    await roomServiceClient.updateRoomMetadata(roomName, JSON.stringify({
        ...existingMetadata,
        recording: false
    }));

    res.json({ success: true, message: 'Recording stop initiated; file will be available shortly' });
});

// POST /webhooks/egress
// LiveKit Egress service posts EgressInfo events here as recording progresses.
// Configure this URL in livekit-server's webhook config:
//   webhook:
//     urls:
//       - https://your-api-host/webhooks/egress
app.post('/webhooks/egress', express.raw({ type: 'application/webhook+json' }), async (req, res) => {
    // Validate the X-Livekit-Signature header — reject tampered or unsigned requests
    let event;
    try {
        event = await webhookReceiver.receive(req.body, req.headers['x-livekit-signature']);
    } catch (err) {
        return res.status(400).json({ error: 'Invalid webhook signature' });
    }

    const egressInfo = event.egressInfo;
    if (!egressInfo) {
        // Not an egress event (could be a room or participant event on the same webhook URL)
        return res.status(200).json({ ignored: true });
    }

    const { egressId, status, fileResults, startedAt, endedAt, error: egressError } = egressInfo;

    if (status === 'EGRESS_ENDING') {
        // Egress is shutting down — update status to 'finalizing' (idempotent with stop handler)
        await db.query(
            `UPDATE recording_sessions SET status = 'finalizing' WHERE egress_id = $1`,
            [egressId]
        );

    } else if (status === 'EGRESS_COMPLETE') {
        // File is fully written and uploaded to S3
        const storageUrl = fileResults?.[0]?.location ?? null;
        const fileSizeBytes = fileResults?.[0]?.size ?? null;
        // startedAt / endedAt are in nanoseconds (BigInt in livekit-server-sdk v2)
        const durationSeconds = startedAt && endedAt
            ? Number((BigInt(endedAt) - BigInt(startedAt)) / 1_000_000_000n)
            : null;
        
        // Guard against clock skew or out-of-order events
        if (durationSeconds !== null && durationSeconds < 0) {
            durationSeconds = 0;
        }

        // Fetch the owner so we can update metering
        const sessionResult = await db.query(
            `UPDATE recording_sessions
             SET status = 'completed', ended_at = NOW(),
                 duration_seconds = $1, storage_url = $2, file_size_bytes = $3
             WHERE egress_id = $4
             RETURNING user_id`,
            [durationSeconds, storageUrl, fileSizeBytes, egressId]
        );

        if (sessionResult.rows.length > 0 && durationSeconds !== null) {
            const { user_id: userId } = sessionResult.rows[0];
            await db.query(
                `UPDATE users SET recording_minutes_used = recording_minutes_used + $1 WHERE id = $2`,
                [Math.ceil(durationSeconds / 60), userId]
            );
        }

    } else if (status === 'EGRESS_FAILED') {
        // Mark failed in DB
        await db.query(
            `UPDATE recording_sessions SET status = 'failed', ended_at = NOW() WHERE egress_id = $1`,
            [egressId]
        );

        // Notify the session owner via your notification system
        // (push notification, in-app alert, email — integrate with your NotificationService)
        const sessionResult = await db.query(
            `SELECT user_id FROM recording_sessions WHERE egress_id = $1`,
            [egressId]
        );
        if (sessionResult.rows.length > 0) {
            const { user_id: userId } = sessionResult.rows[0];
            await notifyUser(userId, {
                type: 'recording_failed',
                message: `Recording failed: ${egressError ?? 'unknown error'}`,
                egressId,
            });
        }
    }

    // Always ACK with 200 — LiveKit will retry on non-2xx
    res.status(200).json({ received: true });
});
```

### NPM Dependency

Add to `token-server/package.json`:
```json
{
    "dependencies": {
        "livekit-server-sdk": "^2.15.0"
    }
}
```

The token server already uses `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` environment variables.

---

## 15. File Management & Storage

### Local Recording Files

```
~/Documents/Inter Recordings/
├── {roomName}-{date}-{time}.mp4           # Mode 1 composed recording
└── multitrack/                             # Mode 2 local fallback
    ├── {roomName}-{date}-{time}/
    │   ├── participant-{identity}.mp4
    │   ├── participant-{identity}.mp4
    │   └── manifest.json
```

- Recording coordinator creates the output directory before recording starts
- Use `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)`
- Create "Inter Recordings" subfolder

### Cloud Storage (S3/GCS)

```
s3://inter-recordings/
├── recordings/
│   ├── {roomName}/
│   │   ├── {roomName}-2026-03-31T140000.mp4
│   │   └── multitrack/
│   │       ├── {identity-1}-2026-03-31T140000.mp4
│   │       ├── {identity-2}-2026-03-31T140000.mp4
│   │       └── manifest.json
```

- LiveKit Egress handles the upload automatically
- Egress supports S3, GCS, Azure Blob Storage, Alibaba OSS
- File paths support template variables: `{room_name}`, `{time}`, `{publisher_identity}`

#### Bucket Hardening (apply via Terraform / AWS Console before first recording)

**1. Default encryption** — enable on the bucket so every object is encrypted at rest without requiring per-request headers:

```json
// aws s3api put-bucket-encryption
{
  "Rules": [{
    "ApplyServerSideEncryptionByDefault": {
      "SSEAlgorithm": "aws:kms",
      "KMSMasterKeyID": "arn:aws:kms:REGION:ACCOUNT_ID:key/YOUR_KEY_ID"
    },
    "BucketKeyEnabled": true
  }]
}
```
Use `SSEAlgorithm: "AES256"` (SSE-S3) if a dedicated KMS key is not available. `BucketKeyEnabled: true` reduces KMS API costs by ~99% for high-volume uploads.

**2. Block public access** — prevent any ACL or bucket policy from accidentally making objects public:

```bash
aws s3api put-public-access-block \
  --bucket inter-recordings \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

**3. Versioning** — protect against accidental deletion or overwrite (required for lifecycle transitions to Glacier):

```bash
aws s3api put-bucket-versioning \
  --bucket inter-recordings \
  --versioning-configuration Status=Enabled
```

#### Presigned URL Download Flow

All client downloads MUST go through a server-issued presigned URL. Clients never receive permanent S3 object URLs.

```javascript
// GET /recordings/:sessionId/download
app.get('/recordings/:sessionId/download', requireAuth, async (req, res) => {
    // 1. Load session and verify ownership
    const result = await db.query(
        `SELECT storage_url, user_id FROM recording_sessions WHERE id = $1 AND status = 'completed'`,
        [req.params.sessionId]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Not found' });
    const session = result.rows[0];
    if (session.user_id !== req.user.id) return res.status(403).json({ error: 'Forbidden' });

    // 2. Extract S3 key from stored URL
    const s3Key = new URL(session.storage_url).pathname.slice(1); // strip leading '/'

    // 3. Issue presigned URL (15-minute expiry)
    const { S3Client, GetObjectCommand } = require('@aws-sdk/client-s3');
    const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
    const s3 = new S3Client({ region: process.env.AWS_REGION });
    const command = new GetObjectCommand({ Bucket: 'inter-recordings', Key: s3Key });
    const presignedUrl = await getSignedUrl(s3, command, { expiresIn: 15 * 60 }); // 900 seconds

    // 4. Audit log every URL generation
    await db.query(
        `INSERT INTO recording_download_audit (session_id, user_id, requested_at, ip_address)
         VALUES ($1, $2, NOW(), $3)`,
        [req.params.sessionId, req.user.id, req.ip]
    );

    res.json({ url: presignedUrl, expiresInSeconds: 900 });
});
```

Audit table:
```sql
CREATE TABLE recording_download_audit (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID NOT NULL REFERENCES recording_sessions(id),
    user_id     UUID NOT NULL REFERENCES users(id),
    requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ip_address  INET
);
CREATE INDEX ON recording_download_audit (session_id);
CREATE INDEX ON recording_download_audit (user_id, requested_at);
```

#### S3 Lifecycle Rules (Retention Tiers)

Configure via `aws s3api put-bucket-lifecycle-configuration`. Three tiers keyed on the `recordings/` prefix:

```json
{
  "Rules": [
    {
      "ID": "TransitionToIA",
      "Status": "Enabled",
      "Filter": { "Prefix": "recordings/" },
      "Transitions": [
        { "Days": 30,  "StorageClass": "STANDARD_IA" },
        { "Days": 90,  "StorageClass": "GLACIER_IR"  },
        { "Days": 365, "StorageClass": "DEEP_ARCHIVE" }
      ]
    },
    {
      "ID": "ExpireFreeTierRecordings",
      "Status": "Enabled",
      "Filter": { "Prefix": "recordings/free/" },
      "Expiration": { "Days": 30 }
    },
    {
      "ID": "ExpireProTierRecordings",
      "Status": "Enabled",
      "Filter": { "Prefix": "recordings/pro/" },
      "Expiration": { "Days": 180 }
    },
    {
      "ID": "ExpireHiringTierRecordings",
      "Status": "Enabled",
      "Filter": { "Prefix": "recordings/hiring/" },
      "Expiration": { "Days": 365 }
    },
    {
      "ID": "AbortIncompleteMultipartUploads",
      "Status": "Enabled",
      "Filter": { "Prefix": "recordings/" },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 2 }
    }
  ]
}
```

**Tier routing**: `startCloudRecording` must include the user's tier in the S3 key prefix so lifecycle rules apply correctly. The tier is validated against a strict allowlist before use — never interpolated raw — to prevent path traversal:

```javascript
// Allowlist validation (see getValidatedTier above)
const validatedTier = getValidatedTier(req.user.tier); // 'free' | 'pro' | 'hiring'

filepath: `recordings/${validatedTier}/${roomName}/{time}.mp4`,
// → recordings/free/roomName/timestamp.mp4
// → recordings/pro/roomName/timestamp.mp4
// → recordings/hiring/roomName/timestamp.mp4
```

Retention thresholds are read from environment variables so they can be adjusted without a code deploy; they must match the S3 lifecycle rule `Days` values:

```
FREE_RETENTION_DAYS=30
PRO_RETENTION_DAYS=180
HIRING_RETENTION_DAYS=365
```

### Recording Lifecycle

```
Start → Recording (active) → Stop → Finalizing (AVAssetWriter closing) → Complete
                                                                          ↓
                                                                   File saved to disk
                                                                   (local) or S3 (cloud)
                                                                          ↓
                                                                   Show notification:
                                                                   "Recording saved to X"
```

---

## 16. Existing Codebase Integration Points

### Files That Need Modification

| File | Change | Risk |
|:-----|:-------|:-----|
| `inter/Media/InterSurfaceShareController.h/.m` | Add `recordingSink` property; include in sink array; **add `addLiveSink:` / `removeLiveSink:` for mid-session sink insertion** (uses existing `_stateLock` pattern) | Low — additive, follows existing lock pattern |
| `inter/Networking/InterLiveKitSubscriber.swift` | Add recording frame observer for active speaker PiP; **add `recordingFrameDelegate` weak property** | Low — new delegate method |
| `inter/UI/Views/InterLocalCallControlPanel.m` | Add "Record" button with red dot | Low — new UI element |
| `inter/Rendering/MetalRenderEngine.m` | Expose NV12→BGRA pipeline state for reuse by composed renderer | Low — public accessor |
| `inter/Networking/InterPermissions.swift` | Already has `canStartRecording` — no change needed | None |
| `inter/Networking/InterRoomController.swift` | Wire recording coordinator into room lifecycle; **forward room disconnect event to coordinator for auto-stop** | Medium — integration |
| `token-server/index.js` | Add recording API endpoints + Egress client | Medium — new routes |
| `token-server/package.json` | Add `livekit-server-sdk` dependency | Low |
| `inter/App/InterCallSessionCoordinator.m` | Initialize recording coordinator; **forward participant join/leave/mute events to coordinator** | Medium — lifecycle wiring |
| `inter/Media/InterLocalMediaController.h/.m` | **Add `recordingFrameObserver` block property for local camera frame capture** (when local user is active speaker) | Low — new callback |

### New Files

| File | Purpose |
|:-----|:--------|
| `inter/Media/Recording/InterRecordingEngine.h/.m` | AVAssetWriter wrapper (with `_engineLock`, stop drain, monotonic PTS) |
| `inter/Media/Recording/InterComposedRenderer.h/.m` | Metal offscreen compositor (with `_frameLock`, 5 layouts, placeholder gen, GPU-fenced pool) |
| `inter/Media/Recording/InterRecordingCoordinator.swift` | Recording orchestrator (serial `coordinatorQueue`, state machine with valid transitions) |
| `inter/Media/Recording/InterRecordingSink.h/.m` | ShareSink for frame capture (with `_sinkLock`) |
| `inter/Media/Recording/InterRecordingAudioCapture.swift` | SPSC ring buffer + 10ms drain timer for RT-safe audio capture |
| `inter/UI/Views/InterRecordingIndicatorView.h/.m` | "REC" badge overlay |

### Existing Hooks (Zero Modification Needed)

| Component | How It's Used | Why No Change |
|:----------|:-------------|:--------------|
| `InterShareSink` protocol | Recording sink conforms to same protocol | Protocol is stable |
| `MetalRenderEngine.sharedEngine` | Provides device + commandQueue for offscreen render | Singleton accessor |
| `InterRemoteTrackRenderer` protocol | Already delivers per-participant CVPixelBuffers | Additive observer |
| `InterPermissions.canStartRecording` | Permission check for host/co-host | Already implemented |
| Data channel (room.localParticipant.publish) | Broadcast recording events | Existing transport |

---

## 17. Implementation Phases & Session Plan

### Session 10A: Local Recording Engine + Composed Renderer (Core Pipeline)

| Step | Task | Files |
|:-----|:-----|:------|
| 10A.1 | Create `InterRecordingEngine` (AVAssetWriter wrapper with `_engineLock`, stop drain gate, monotonic PTS enforcement) | `Recording/InterRecordingEngine.h/.m` |
| 10A.2 | Create `InterComposedRenderer` (Metal offscreen with `_frameLock`, 5 layout modes, placeholder frames, GPU-fenced triple-buffer pool) | `Recording/InterComposedRenderer.h/.m` |
| 10A.3 | Create `InterRecordingSink` (ShareSink conformance with `_sinkLock`) | `Recording/InterRecordingSink.h/.m` |
| 10A.4 | Add `addLiveSink:` / `removeLiveSink:` to `InterSurfaceShareController` for mid-session sink insertion | `InterSurfaceShareController.h/.m` |
| 10A.5 | Unit tests for recording engine (PTS monotonicity, pause/resume math, stop drain, concurrent append) | `interTests/InterRecordingEngineTests.swift` |
| 10A.6 | Unit tests for composed renderer (layout selection, thread-safe frame updates, placeholder generation) | `interTests/InterComposedRendererTests.swift` |

### Session 10B: Recording Coordinator + UI

| Step | Task | Files |
|:-----|:-----|:------|
| 10B.1 | Create `InterRecordingCoordinator` (serial coordinator queue, os_unfair_lock state reads, valid transition matrix, pending-stop during start) | `Recording/InterRecordingCoordinator.swift` |
| 10B.2 | Active speaker debounce logic (2-second hold, pending speaker queue) | `InterRecordingCoordinator.swift` |
| 10B.3 | "Record" button in call controls | `InterLocalCallControlPanel.m` |
| 10B.4 | "REC" indicator view | `UI/Views/InterRecordingIndicatorView.h/.m` |
| 10B.5 | Consent notification (data channel broadcast) | `InterRecordingCoordinator.swift` |
| 10B.6 | Pause/Resume support (CMTime PTS math, coordinator state transitions) | `InterRecordingEngine.m`, `InterRecordingCoordinator.swift` |
| 10B.7 | Wire into `InterCallSessionCoordinator` (room disconnect auto-stop, participant leave/join events) | `InterCallSessionCoordinator.m` |
| 10B.8 | Audio ring buffer (SPSC, real-time safe tap, 10ms drain timer) | `InterRecordingCoordinator.swift` or `Recording/InterRecordingAudioCapture.swift` |

### Session 10C: Watermark + Cloud Recording

| Step | Task | Files |
|:-----|:-----|:------|
| 10C.1 | Watermark texture generation + Metal overlay | `InterComposedRenderer.m` |
| 10C.2 | Tier-based watermark toggle | `InterRecordingCoordinator.swift` |
| 10C.3 | Add `livekit-server-sdk` to token server | `token-server/package.json` |
| 10C.4 | Egress API endpoints (start/stop/status) with retry logic | `token-server/index.js` |
| 10C.5 | Recording sessions DB schema | `token-server/migrations/` |
| 10C.6 | Client ↔ server recording flow (HTTP calls) | `InterRecordingCoordinator.swift` |

### Session 10D: Multi-Track + Edge Cases + Polish

| Step | Task | Files |
|:-----|:-----|:------|
| 10D.1 | Multi-track via Participant Egress | `token-server/index.js` |
| 10D.2 | Manifest generation (handles mid-recording joins) | `token-server/index.js` |
| 10D.3 | Metering & quota enforcement | `token-server/index.js`, DB migration |
| 10D.4 | Recording list + management UI | `inter/UI/Views/InterRecordingListPanel.h/.m` |
| 10D.5 | New joiner consent dialog | `inter/UI/Views/InterRecordingConsentPanel.h/.m` |
| 10D.6 | Edge case handling: disk space monitor, orphaned file cleanup, room-close auto-stop, audio engine restart recovery | Multiple files |
| 10D.7 | Comprehensive test suite: concurrency tests (XCTest with `DispatchQueue.concurrentPerform`), layout transition tests, pause/resume PTS tests, start-stop race tests | `interTests/InterRecordingCoordinatorTests.swift`, `interTests/InterComposedRendererTests.swift` |

---

## 18. Risk Assessment & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|:-----|:-------|:-----------|:-----------|
| AVAssetWriter frame drops at 30fps | Video stutters/gaps | Low (Metal compositing < 5ms) | Triple-buffer CVPixelBuffer pool; drop frame counter; fallback to last frame |
| Audio sync drift | A/V out of sync in recording | Medium | Use `CMTime` (rational) for all PTS math — not doubles. Align to `mach_absolute_time` clock. Ring buffer drain at fixed 10ms interval. |
| Remote participant NV12 vs BGRA format inconsistency | Rendering artifacts in composed view | Low | Per-frame `CVPixelBufferGetPixelFormatType()` check; shader variant selected per frame, not per session |
| LiveKit Egress Docker not running | Cloud recording fails silently | Medium | Health check endpoint; fail fast with user-visible error if egress unavailable |
| Recording quota bypass | Users exceed cloud recording limits | Low | Server-side enforcement before Egress API call; periodic background check |
| Large recording files (1080p × 30min = ~1.5GB) | Disk space exhaustion | Medium | Pre-check disk space before recording; monitor every 30s; auto-stop at < 500MB free; show warning at 2GB remaining |
| Paused recording timestamp discontinuity | Broken timeline in output MP4 | Low | `CMTime` rational arithmetic for PTS offsets — lossless across unlimited pause/resume cycles |
| Concurrent recording + screen share performance | CPU/GPU contention | Medium | Offscreen render is lightweight (< 5ms); monitor frame rate; degrade to 720p if needed |
| `AVAssetWriterInputPixelBufferAdaptor` deprecated on macOS 11+ | Future compatibility | Low | Use `PixelBufferReceiver` (new API) as alternative; adaptor still works and is not removed |
| **Active speaker thrashing (multiple simultaneous speakers)** | **PiP flickers rapidly** | **High** | **2-second debounce hold time. Active speaker only changes if new speaker is loudest for > 2s. (See §4, §5)** |
| **Audio-only participant as active speaker** | **PiP shows stale/no frame** | **Medium** | **Placeholder frame (dark bg + name). Generated and cached per identity. (See §5)** |
| **Screen share starts/stops during recording** | **Layout must dynamically switch** | **High** | **`_recalculateLayoutLocked` automatically selects correct layout. 5 layout modes defined. (See §5)** |
| **finishWriting while frames in-flight** | **Crash / corrupted file** | **Medium** | **`_isStopping` flag checked before dispatch; stop sentinel is last block on queue. (See §4)** |
| **GPU/CPU pixel buffer race** | **AVAssetWriter reads half-rendered frame** | **Medium** | **`waitUntilCompleted` on _renderQueue after Metal commit; safe within 33ms budget. (See §3.2)** |
| **Audio tap priority inversion** | **Real-time audio thread blocks** | **High** | **Lock-free SPSC ring buffer (no locks/alloc/log on RT thread). 10ms drain timer on non-RT queue. (See §8)** |
| **Recording starts mid-screenshare** | **Sink cannot be added to running pipeline** | **High** | **`addLiveSink:` / `removeLiveSink:` methods on InterSurfaceShareController. Thread-safe via existing `_stateLock`. (See §3.3)** |
| **Room destroyed during recording** | **Orphaned AVAssetWriter / incomplete file** | **Medium** | **Room disconnect event → auto-stop → finishWriting. On next launch, clean orphaned `.tmp` files. (See §6)** |
| **Participant leave during recording** | **Stale frame reference in composed renderer** | **Medium** | **`remoteTrackDidEnd` → coordinator clears frame → layout recalculates. No stale CVPixelBuffer retained. (See §5, §6)** |
| **Coordinator state machine race** | **Concurrent start/stop/pause from UI + callbacks** | **High** | **Dedicated serial `coordinatorQueue` for all transitions. State reads via `os_unfair_lock`. Valid transition matrix enforced. (See §13)** |
| **GDPR / Privacy Compliance** | **Legal liability; regulatory fines (GDPR, CCPA)** | **High** | **Consent logging table in DB (identity, timestamp, accepted/declined). Server-side retention policy: auto-delete after N days. Deletion API callable by user at any time. Cross-border residency: store in S3 bucket matched to user's region. (See §12 Consent, §14 Server API)** |
| **Data Security / Encryption** | **Recording files exposed at rest or in transit** | **High** | **S3 SSE-S3 or SSE-KMS encryption at rest. TLS 1.2+ on all API calls and presigned upload URLs. KMS key rotation policy where applicable. (See §18 Risk Assessment & Mitigations, §15 File Management)** |
| **Access Control** | **Unauthorized download of recordings** | **High** | **Presigned S3 URLs with ~15-minute expiry; regenerated on demand. Bucket ACL: block all public access. Server validates caller identity (JWT) before issuing presigned URL. (See §14 Server API, §15 File Management)** |
| **Distributed Race Conditions** | **Multiple server hosts start the same recording simultaneously** | **Medium** | **Distributed lock via Redis `SET NX EX 30` before calling Egress API, or a DB unique partial index on `(room_id) WHERE status = 'active'`. Only the lock-holder proceeds; others return 409. (See §18 Risk Assessment & Mitigations, §14 Server API)** |
| **Client Crash Recovery** | **Recording metadata lost; orphaned `.tmp` file on disk** | **Medium** | **Persist `RecordingSession` state to `~/Library/Application Support/inter/recording_state.json` before starting. On next launch, scan for orphaned `.tmp` files: offer resume or finalize via `AVAssetWriter`. (See §18 Risk Assessment & Mitigations, §15 File Management)** |
| **Permission Revocation** | **OS revokes camera or microphone mid-session** | **Medium** | **Observe `AVCaptureDevice` authorization change notifications. On revocation: flush audio ring buffer, call `finishWriting`, stop coordinator state machine, surface user-facing error. Recording saved up to point of revocation. (See §8 Audio Pipeline, §13 Coordinator)** |
| **Background Transitions** | **App deactivated; Metal rendering stops, frames stall** | **Low (macOS)** | **Observe `NSApplicationDidResignActiveNotification`: pause Metal compositing queue, flush pending CVPixelBuffers to writer. On `NSApplicationDidBecomeActiveNotification`: resume or finalize recording depending on policy. (See §7 Metal Compositing, §13 Coordinator)** |

---

## Appendix A: LiveKit Egress API Quick Reference

### Egress Types

| API Method | What It Records | Output |
|:-----------|:---------------|:-------|
| `startRoomCompositeEgress(roomName, opts)` | Entire room as one composed video (headless Chrome layout) | MP4, HLS, RTMP |
| `startParticipantEgress(roomName, identity, opts)` | Single participant (audio+video+optional screen share) | MP4, HLS |
| `startTrackEgress(roomName, trackId, opts)` | Single track (no transcoding) | MP4/WebM/OGG |
| `startTrackCompositeEgress(roomName, opts)` | Specific audio+video track pair | MP4, HLS |
| `startWebEgress(url, opts)` | Any web page | MP4, HLS, RTMP |

### Control Methods
| Method | Purpose |
|:-------|:--------|
| `stopEgress(egressId)` | Stop an active egress |
| `updateLayout(egressId, layout)` | Change layout on RoomComposite egress |
| `updateStream(egressId, addUrls, removeUrls)` | Add/remove RTMP stream URLs |
| `listEgress()` | List all active egresses |

### Encoding Presets
| Preset | Resolution | FPS | Bitrate |
|:-------|:-----------|:----|:--------|
| `H264_720P_30` | 1280×720 | 30 | 3000 kbps |
| `H264_1080P_30` | 1920×1080 | 30 | 4500 kbps |
| `H264_1080P_60` | 1920×1080 | 60 | 6000 kbps |

### Egress Statuses
| Status | Value | Meaning |
|:-------|:------|:--------|
| `EGRESS_STARTING` | 0 | Starting up |
| `EGRESS_ACTIVE` | 1 | Recording/streaming |
| `EGRESS_ENDING` | 2 | Shutting down |
| `EGRESS_COMPLETE` | 3 | Done successfully |
| `EGRESS_FAILED` | 4 | Failed |
| `EGRESS_ABORTED` | 5 | Aborted |

## Appendix B: AVAssetWriter Quick Reference

### Key Classes
- `AVAssetWriter` — Single-use file writer (MP4/MOV)
- `AVAssetWriterInput` — One per track (video, audio); `expectsMediaDataInRealTime = true` for recording
- `AVAssetWriterInputPixelBufferAdaptor` — Appends CVPixelBuffers with presentation times; provides pixel buffer pool
- `isReadyForMoreMediaData` — Check before appending; drop frame if false

### Lifecycle
```
init(url:, fileType:) → add(videoInput) → add(audioInput) → startWriting() → 
startSession(atSourceTime:) → [appendPixelBuffer / appendSampleBuffer loop] → 
finishWriting(completionHandler:)
```

### Critical Notes
- Single-use: one writer per output file
- Thread safety: append calls must be serialized (use a serial dispatch queue)
- PTS must be monotonically increasing per input
- `finishWriting` is async — file is incomplete until completion handler fires
- `shouldOptimizeForNetworkUse = true` for progressive MP4 (moov atom at front)

---

*End of Recording Architecture Document*
