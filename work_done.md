# Work Done — LiveKit Integration Changelog

> **Reference**: See `tasks.txt` for the full implementation plan.  
> **Convention**: Each entry includes the date, what changed, which files, and why.

---

## Format

```
## [DATE] — Brief Title

**Phase**: X.Y.Z from tasks.txt  
**Files changed**:
- `path/to/file` — what was done

**Why**: Reason for the change.  
**Notes**: Any caveats, follow-ups, or things to watch.
```

---

## [3 March 2026] — Phase 0.3 Kickoff: Bridging Header + Network Entitlement

**Phase**: 0.3.2, 0.3.5
**Files changed**:
- `inter/inter-Bridging-Header.h` — CREATED. Imports all ObjC headers needed by Swift: AppSettings, CallSessionCoordinator, LocalMediaController, SurfaceShareController, ShareTypes, ShareVideoFrame, ShareSink, ShareVideoSource, RecordingSink, MetalRenderEngine, MetalSurfaceView.
- `inter/inter.entitlements` — MODIFIED. Added `com.apple.security.network.client = YES` for outbound TCP/UDP (WebRTC + WebSocket).

**Why**: These are the two Phase 0.3 steps that can be done without Xcode GUI. They unblock SPM integration (0.3.1) and Swift file compilation.
**Notes**: Still need Xcode GUI for: 0.3.1 (add LiveKit SPM), 0.3.3 (pin SWIFT_VERSION), set `SWIFT_OBJC_BRIDGING_HEADER` build setting to `inter/inter-Bridging-Header.h`, 0.3.4 (verify inter-Swift.h), 0.3.6 (validate build).

## [3 March 2026] — Phase 0.3 Completed + Phase 1.1/1.2 Started

**Phase**: 0.3.1, 0.3.3, 0.3.4, 0.3.6, 1.1, 1.2
**Files changed**:
- `inter.xcodeproj/project.pbxproj` — MODIFIED (via Xcode). Added LiveKit Swift SDK via SPM (main branch, swift-tools-version:6.0). Set SWIFT_VERSION=5. Set SWIFT_OBJC_BRIDGING_HEADER.
- `inter/Networking/InterNetworkTypes.swift` — CREATED. All foundation types: InterRoomConnectionState, InterTrackKind, InterParticipantPresenceState, InterCameraNetworkState/Action (G2 two-phase state machine), InterMicrophoneNetworkState/Action, InterRoomConfiguration (NSCopying), InterNetworkErrorDomain + InterNetworkErrorCode. G8 isolation invariant at top.
- `inter/Networking/InterLogSubsystem.swift` — CREATED. G9 logging: InterLog class with .networking, .media, .room, .stats OSLog categories. Convenience functions: interLogInfo/Error/Debug/Fault. Privacy-aware formatting.

**Why**: Phase 0.3 unblocks all Swift compilation. Phase 1.1/1.2 are the foundation types that every subsequent networking file depends on.
**Notes**: Build succeeded with LiveKit SDK + both new Swift files. inter-Swift.h auto-generated. PBXFileSystemSynchronizedRootGroup auto-includes new files.

## [3 March 2026] — Phase 0.1/0.2 Completed: LiveKit Server + Token Server

**Phase**: 0.1 (all), 0.2 (all)
**Infrastructure**:
- LiveKit Server v1.9.11 installed via `brew install livekit`. Running in dev mode on `ws://localhost:7880`. Dev keys: API Key = `devkey`, API Secret = `secret`.
- LiveKit CLI v2.13.2 installed via `brew install livekit-cli`.
- Token server created at `token-server/index.js` (~200 lines). Node.js + Express + livekit-server-sdk.
  - `POST /room/create` — generates 6-char alphanumeric code, signs JWT with host privileges (roomCreate, roomAdmin)
  - `POST /room/join` — validates code, signs JWT with guest privileges. 404 on invalid, 410 on expired
  - `POST /token/refresh` — issues fresh JWT preserving host/guest status
  - Rate limiting: 10 req/min per identity (in-memory)
  - G9 audit logging (room creates/joins, never logs tokens)
  - G7 room codes: 30^6 = 729M combinations, 24h expiry, confusable chars excluded
  - Health check: `GET /health`

**Validation**: All 5 curl tests passed:
- `/room/create` → 200 with roomCode + JWT + serverURL
- `/room/join` → 200 with JWT (guest grants, no roomCreate/roomAdmin)
- `/token/refresh` → 200 with fresh JWT
- Invalid code → 404
- Missing fields → 400

**Why**: Token server is required before InterTokenService.swift (Phase 1.3) can be tested. LiveKit server must be running for any WebRTC connection testing.
**Notes**: Both servers running as background processes. Token server on port 3000, LiveKit server on port 7880.

## [3 March 2026] — Phase 1.3: InterTokenService.swift

**Phase**: 1.3.1–1.3.8  
**Files changed**:
- `inter/Networking/InterTokenService.swift` — CREATED. `@objc class InterTokenService: NSObject`. URLSession-based with 10s timeout. 1 retry on 5xx/timeout, no retry on 4xx. Token caching with JWT expiration parsing (base64 decode payload, read "exp" field). Three public methods: `createRoom`, `joinRoom`, `refreshToken`. HTTP status mapping: 404→roomCodeInvalid, 410→roomCodeExpired, 429→tokenFetchFailed. Completions on main queue. Response models: InterCreateRoomResponse (roomCode, roomName, token, serverURL), InterJoinRoomResponse (roomName, token, serverURL).

**Why**: Required for all room connection workflows. Hosts create rooms, joiners join with room codes, both need token refresh.  
**Notes**: Fixed `@objc` on top-level `let` error (InterNetworkErrorDomain in InterNetworkTypes.swift). Unit tests deferred to Phase 4.

## [3 March 2026] — Phase 1.4: InterLiveKitAudioBridge.swift

**Phase**: 1.4.1–1.4.11  
**Files changed**:
- `inter/Networking/InterLiveKitAudioBridge.swift` — CREATED (~554 lines). Conforms to InterShareSink + AudioCustomProcessingDelegate + @unchecked Sendable. SPSC AudioRingBuffer (UnsafeMutablePointer<Float>, atomic head/tail, 0.5s capacity). appendAudioSampleBuffer → Unmanaged.passRetained → conversionQueue → convertAndWrite (CMSampleBuffer → AVAudioPCMBuffer → Float32 Int16-scaled → ring buffer). audioProcessingProcess → ring buffer read → deinterleave into LKAudioBuffer per-channel rawBuffers. G2 mute/unmute state machine with pendingUnmuteCallback. Handles PCM Float32, Int16, Int32 formats. Nearest-neighbor sample rate conversion.

**Why**: LiveKit SDK has NO direct audio buffer injection API (BufferCapturer is video-only). This solution uses AudioManager.shared.capturePostProcessingDelegate to replace WebRTC ADM's mic data in-place before encoding. WebRTC still opens the mic (unavoidable) but its data is overwritten.  
**Notes**: Key design decision documented in file header. Fixed: InterShareSink Swift import naming (isActive, append(_:), stop(completion:)), AudioCaptureOptions parameter order, Unmanaged API for CMSampleBuffer across async boundaries.

## [3 March 2026] — Phase 1.5: InterLiveKitCameraSource.swift

**Phase**: 1.5.1–1.5.10  
**Files changed**:
- `inter/Networking/InterLiveKitCameraSource.swift` — CREATED (~256 lines). AVCaptureVideoDataOutputSampleBufferDelegate. Creates AVCaptureVideoDataOutput with BGRA forced format, alwaysDiscardsLateVideoFrames=true. Dedicated captureOutputQueue. LocalVideoTrack.createBufferTrack(source: .camera). Zero-copy CMSampleBuffer → BufferCapturer.capture(). G2 camera state machine. Frame counting (sent/dropped). start/stop take captureSession + sessionQueue params.

**Why**: Adds AVCaptureVideoDataOutput to the existing session — zero-copy camera frames to LiveKit without disturbing preview layer or recording.  
**Notes**: Build succeeded alongside Phase 1.6.

## [3 March 2026] — Phase 1.6: InterLiveKitScreenShareSource.swift

**Phase**: 1.6.1–1.6.11  
**Files changed**:
- `inter/Networking/InterLiveKitScreenShareSource.swift` — CREATED. InterShareSink conformant. 15 FPS throttle (minFrameInterval = 1/15). Resolution cap 1920×1080, downscale via vImageScale_ARGB8888 (kvImageHighQualityResampling). Private encoderQueue (serial, .userInitiated). LocalVideoTrack.createBufferTrack(source: .screenShareVideo). ARC-managed CVPixelBuffer in closures.

**Why**: Screen share frames from ScreenCaptureKit → LiveKit network. Resolution cap prevents 280 MB explosion at 5K.  
**Notes**: Fixed BufferCapturer.createTimeStampNs() extension clash (parent class already has it) — renamed to private interCreateTimeStampNs(). Fixed CVPixelBufferRetain/Release unavailable in Swift (ARC manages them).

## [3 March 2026] — Phase 1.7: InterLiveKitPublisher.swift

**Phase**: 1.7.1–1.7.12  
**Files changed**:
- `inter/Networking/InterLiveKitPublisher.swift` — CREATED. Orchestrates publishing local media tracks. Owns InterLiveKitCameraSource, InterLiveKitAudioBridge, InterLiveKitScreenShareSource. publishCamera: H.264 + simulcast, 720p, 1.5 Mbps. publishMicrophone: speech-optimized encoding (24 kbps), DTX + RED. publishScreenShare: 2.5 Mbps, 15 FPS, no simulcast. G2 two-phase mute/unmute delegated to sources. G4 detachAllSources() for mode transitions. unpublishAll() with dispatch group.

**Why**: Central orchestrator for all local track publishing. Keeps publish/unpublish logic out of the UI layer.  
**Notes**: weak localParticipant reference set by InterRoomController. InterShareSessionConfiguration.default() is the correct Swift import name (ObjC +defaultConfiguration gets renamed).

## [3 March 2026] — Phase 1.8: InterLiveKitSubscriber.swift

**Phase**: 1.8.1–1.8.11  
**Files changed**:
- `inter/Networking/InterLiveKitSubscriber.swift` — CREATED. RoomDelegate for didSubscribeTrack/didUnsubscribeTrack (takes RemoteTrackPublication, not Track). Internal RemoteFrameRenderer conforming to VideoRenderer protocol with os_unfair_lock single-slot storage. Format detection on first frame (CVPixelBufferGetPixelFormatType). Adaptive streaming (isAdaptiveStreamEnabled=true). InterRemoteTrackRenderer protocol for delegate callbacks. Camera/screenShare/audio routing by Track.Source.

**Why**: Receives and routes decoded remote video frames. Remote audio handled automatically by LiveKit.  
**Notes**: Fixed `any Participant` → `Participant` (concrete type, no existential needed). RoomDelegate didUpdateIsMuted uses `Participant` not `RemoteParticipant`.

## [3 March 2026] — Phase 1.9: InterRoomController.swift

**Phase**: 1.9.1–1.9.14  
**Files changed**:
- `inter/Networking/InterRoomController.swift` — CREATED. Central orchestrator owning Room, publisher, subscriber, tokenService, statsCollector. KVO-observable connectionState, participantPresenceState, remoteParticipantCount, roomCode. Host/joiner connect flow (createRoom vs joinRoom → room.connect). disconnect() with session duration logging. G4 transitionMode() - unpublish + detach, keep subscriber active. G6 participant presence with 3s grace timer (DispatchSourceTimer). RoomDelegate: didUpdateConnectionState, roomDidConnect/Reconnect/IsReconnecting, didDisconnectWithError, participantDidConnect/Disconnect. Token refresh stub.

**Why**: Single entry point for all room lifecycle management. Owned by AppDelegate, outlives mode transitions.  
**Notes**: Fixed didDisconnectWithError parameter type: LiveKitError?, not (any Error)?. ConnectOptions: autoSubscribe=true, reconnectAttempts=3, reconnectAttemptDelay=2.0.

## [3 March 2026] — Phase 1.10: InterCallStatsCollector.swift

**Phase**: 1.10.1–1.10.4, 1.10.6  
**Files changed**:
- `inter/Networking/InterCallStatsCollector.swift` — CREATED. 10s polling timer on background queue. Pre-allocated circular buffer of 360 InterCallStatsEntry objects (1 hour). os_unfair_lock for thread-safe access. captureDiagnosticSnapshot() returns formatted string with room state, participant info, last 10 entries. latestEntry() accessor. Fields: timestamp, bitrates, FPS, RTT, packetLoss, jitter, connectionQuality.

**Why**: Observability for call quality. 36 KB memory footprint. Zero-cost when not queried.  
**Notes**: 1.10.5 (JSON export on disconnect) deferred. Stats currently captures connectionQuality only; full WebRTC stats API integration deferred to Phase 4 hardening.

## [3 March 2026] — Phase 1.11: InterRemoteVideoView.swift

**Phase**: 1.11.1–1.11.12  
**Files changed**:
- `inter/Networking/InterRemoteVideoView.swift` — CREATED (~500 lines). CAMetalLayer + CVDisplayLink rendering. Reuses MetalRenderEngine.shared().device + commandQueue. CVMetalTextureCache for zero-copy GPU access (IOSurface shared memory). Two inline MSL pipelines: NV12 (Y r8Unorm + CbCr rg8Unorm → BT.709 matrix → sRGB) and BGRA (passthrough). Fullscreen triangle vertex shader (no vertex buffer). Aspect-fit via vertex uniforms. os_unfair_lock single-slot frame storage (latest-frame-wins). CVDisplayLink with semaphore=2 in-flight limit. Format detection on first frame (NV12 video-range, NV12 full-range, BGRA). No-frame: re-present previous. Never-set: render black.

**Why**: Remote video must render NV12 (WebRTC decoder output) which the existing BGRA-only Metal pipeline cannot handle.  
**Notes**: Fixed MetalRenderEngine.sharedEngine() → .shared() (Swift import rename). BT.709 video-range and full-range matrices both implemented. 4–8 MB per view.

---

## [8 March 2026] — Phase 1.11.13: InterRemoteVideoView Tests

**Phase**: 1.11.13  
**Files changed**:
- `interTests/InterRemoteVideoViewTests.swift` — CREATED (18 tests). Aspect-fit (wider, taller, exact, degenerate). Format detection (NV12 video/full, BGRA, unknown). BT.709 matrix verification (pure white Y=235/Cb=128/Cr=128 → RGB≈1.0; black Y=16 → RGB≈0.0). Pipeline creation non-nil. Frame storage (hasReceivedFrame, latest-frame-wins). NV12 offscreen rendering (white + black via IOSurface-backed CVPixelBuffer → Metal GPU readback). BGRA offscreen rendering (solid red, solid green). No allocation growth (1000 frames).
- `inter/Networking/InterRemoteVideoView.swift` — MODIFIED. Exposed internals for @testable import: bt709VideoRangeMatrix, bt709FullRangeMatrix, DetectedFormat, AspectFitUniforms, computeAspectFitUniforms, classifyFormat → internal. nv12PipelineState/bgraPipelineState → private(set). Added renderToOffscreenTexture() + renderNV12Offscreen/renderBGRAOffscreen helpers (storageMode .shared on Apple Silicon, .managed on Intel with blit synchronize).
- `inter.xcodeproj/project.pbxproj` — MODIFIED. Added interTests unit test target (PBXNativeTarget, PBXFileSystemSynchronizedRootGroup, PBXContainerItemProxy, PBXTargetDependency, build phases, configs with BUNDLE_LOADER/TEST_HOST).

**Why**: Complete test coverage for InterRemoteVideoView per spec item 1.11.13.  
**Notes**: All 18 tests pass. TEST SUCCEEDED. Test target injected into host app via TEST_HOST for @testable import.

---

## Phase 1 — Remaining Unit Tests (1.3.9, 1.4.12, 1.5.11, 1.6.12, 1.7.13, 1.8.12, 1.9.15)

**Phase**: 1.3.9, 1.4.12, 1.5.11, 1.6.12, 1.7.13, 1.8.12, 1.9.15  
**Files changed**:
- `inter/Networking/InterLiveKitCameraSource.swift` — `framesSent`/`framesDropped` → `private(set)` for testability
- `inter/Networking/InterLiveKitScreenShareSource.swift` — `framesSent`/`framesDropped`/`framesThrottled` → `private(set)` for testability
- `inter/Networking/InterRoomController.swift` — `isConnecting` → `private(set)` for testability
- `interTests/InterTokenServiceTests.swift` — 11 tests: URLProtocol mock, happy path, 401/404/410/500, timeout, malformed JSON, token cache
- `interTests/InterLiveKitAudioBridgeTests.swift` — 8 tests: lifecycle, nil-buffer safety, performance (<5000ns avg), double-start/stop idempotency
- `interTests/InterLiveKitCameraSourceTests.swift` — 6 tests: initial state, start/stop, frame counters, allocation growth
- `interTests/InterLiveKitScreenShareSourceTests.swift` — 8 tests: lifecycle, 15 FPS throttle verification, audio no-op, allocation growth
- `interTests/InterLiveKitPublisherTests.swift` — 14 tests: publish error paths, unpublish safety, rapid mute/toggle x10, detach
- `interTests/InterLiveKitSubscriberTests.swift` — 7 tests: state, weak track renderer, detach safety, allocation
- `interTests/InterRoomControllerTests.swift` — 21 tests: full lifecycle, double-connect prevention, disconnect guards, KVO, mode transition, state machines, error codes, config copy

**Why**: Complete all remaining Phase 1 unit test items.  
**Notes**: All 93 tests pass (18 prior + 75 new). TEST SUCCEEDED. Access-level changes use `private(set)` pattern to preserve encapsulation while enabling test reads.

---

## [11 March 2026] — Phase 2: Modifications to Existing ObjC Files

**Phase**: 2.1–2.7 (all items)  
**Files changed**:
- `inter/Media/InterLocalMediaController.h` — Added 2 readonly properties: `captureSession` (AVCaptureSession *) and `sessionQueue` (dispatch_queue_t). Documented: callers MUST use sessionQueue, MUST NOT call startRunning/stopRunning.
- `inter/Media/InterLocalMediaController.m` — Added getter implementations returning `_session` and `_sessionQueue` ivars.
- `inter/Media/Sharing/InterShareTypes.h` — Added `networkPublishEnabled` BOOL property with `isNetworkPublishEnabled` getter.
- `inter/Media/Sharing/InterShareTypes.m` — Updated `defaultConfiguration` (sets NO) and `copyWithZone:` (copies value).
- `inter/Media/InterSurfaceShareController.h` — Added `#import "InterShareSink.h"`, added nullable `networkPublishSink` property (id<InterShareSink>).
- `inter/Media/InterSurfaceShareController.m` — Added `#import <mach/mach_time.h>`. Updated `sinksForConfiguration:` to include networkPublishSink when non-nil. Added G5 debug timing assertion in `routeVideoFrame:` (asserts < 5ms via mach_absolute_time).
- `inter/inter.entitlements` — Already had `com.apple.security.network.client` (no change needed).
- `inter/App/AppDelegate.m` — Major additions:
  - `#import "inter-Swift.h"` with `__has_include` guard
  - `roomController` property (InterRoomController, strong) + `isObservingRoomController` flag
  - Traditional ObjC KVO on `connectionState` and `participantPresenceState` with static void* contexts
  - `wireNormalNetworkPublish` — publishes camera + mic when room connected
  - `wireNetworkSinkOnSurfaceShareController:` — creates screen share sink from publisher
  - `twoPhaseToggleNormalCamera` / `twoPhaseToggleNormalMicrophone` — G2 ordering (mute first → stop device; start device → unmute)
  - `handleModeTransitionIfNeeded:` — G4 mode transition with completion
  - `finalizeCurrentModeExit` calls `[self.roomController disconnect]`
  - `applicationWillTerminate:` teardowns KVO and disconnects
  - `applicationDidFinishLaunching:` creates roomController with @try/@catch (G8)
  - KVO handlers map connection/presence states to UI label text
- `inter/UI/Controllers/SecureWindowController.h` — Added `@class InterRoomController` forward declaration, weak `roomController` property.
- `inter/UI/Controllers/SecureWindowController.m` — Major additions:
  - `#import "inter-Swift.h"` with `__has_include` guard
  - Traditional ObjC KVO (same pattern as AppDelegate, separate static contexts)
  - `wireSecureNetworkPublish` / `wireNetworkSinkOnSurfaceShareController:`
  - `twoPhaseToggleCamera` / `twoPhaseToggleMicrophone` — G2 two-phase toggles
  - `destroySecureWindow` clears networkPublishSink, teardowns KVO, does NOT disconnect room (G4)
  - Toggle handlers in control panel wired to two-phase methods
- `inter/Rendering/MetalSurfaceView.m` — No modifications needed (2.7.1 confirmed).

**Why**: Wire the Swift networking layer (Phase 1) into the existing ObjC app architecture. Room lifecycle owned by AppDelegate, mode-specific media wiring in each controller, two-phase toggles everywhere for G2 compliance.  
**Notes**: All 93 tests still pass. BUILD SUCCEEDED. Key patterns: traditional KVO (not block-based), @try/@catch for G8 crash resilience, weak roomController reference from SecureWindowController (room outlives modes per G4).

---

## [11 March 2026] — Phase 3 Complete: UI Layer

**Phase**: 3.1 (Connection UI), 3.2 (Remote Video Normal), 3.3 (Remote Video Secure), 3.4 (Call Controls)

**Files created**:
- `inter/UI/Views/InterConnectionSetupPanel.h/.m` — Self-contained connection setup form. Four fields (Server URL, Token Server URL, Display Name, Room Code) with NSUserDefaults persistence. Host Call / Host Interview / Join buttons with delegate pattern. G7 room code auto-uppercase with confusable-char filtering (0O1IL removed). Connection indicator dot (green/yellow/red/gray). Hosted room code display (monospaced bold green).
- `inter/UI/Views/InterRemoteVideoLayoutManager.h/.m` — Owns two InterRemoteVideoView instances (camera + screen share) and participant overlay. Four layout modes (none/cameraOnly/screenShareOnly/cameraAndShare) with NSAnimationContext 200ms ease-in-out transitions. Camera+share mode: screen share 80% width + PiP 160×120 top-right.
- `inter/UI/Views/InterParticipantOverlayView.h/.m` — Semi-transparent overlay for participant states. G6 "Waiting for participant…" state with pulsing green dot (CABasicAnimation). "Participant left." state with Wait / End Call buttons. Delegate-driven actions.
- `inter/UI/Views/InterTrackRendererBridge.h/.m` — ObjC adapter conforming to Swift InterRemoteTrackRenderer protocol. Routes didReceiveRemoteCameraFrame/ScreenShareFrame and mute/unmute/end callbacks to InterRemoteVideoLayoutManager.
- `inter/UI/Views/InterNetworkStatusView.h/.m` — Custom drawRect 4-bar signal indicator. InterNetworkQualityLevel enum (unknown/lost/poor/good/excellent). Progressive bar heights (4→16px), color-coded (green/yellow-green/orange/red/gray). Intrinsic size 40×16.

**Files modified**:
- `inter/App/AppDelegate.m` — Setup window expanded 660×560. Old 3-button panel replaced with InterConnectionSetupPanel. Connection setup delegate: host flow (create room → display code → connect), join flow (validate → connect with 404/410 mapping). Remote video layout wired in normal call window with TrackRendererBridge. Participant overlay driven by KVO on participantPresenceState. Network status bars + triple-click diagnostic gesture (G9 clipboard copy). Connection status text driven by KVO on connectionState.
- `inter/UI/Views/InterLocalCallControlPanel.h/.m` — Added connectionStatusLabel, roomCodeLabel, networkStatusContainerView. New methods: setConnectionStatusText:, setRoomCodeText:.
- `inter/UI/Controllers/SecureWindowController.m` — Remote video layout + TrackRendererBridge wired in secure window (inherits NSWindowSharingNone). Participant overlay driven by KVO. Network status bars + triple-click diagnostic. Connection status text driven by KVO.

**Why**: Phase 3 builds the complete UI layer for LiveKit integration — connection management, remote video rendering with adaptive layouts, participant presence feedback, and network diagnostics. All UI views are self-contained with delegate patterns, matching the existing codebase conventions.

**Build**: ✅ Clean build. 93 tests passing (unchanged from Phase 2).
**Notes**: InterRoomConfiguration uses designated initializer with serverURL/tokenServerURL/roomCode/participantIdentity/participantName/isHost. UUID generated for participantIdentity at connect time. G8 isolation preserved — nil roomController gracefully falls through to local-only mode.

---

## Log

> Phase 0 complete. Phase 1 complete. Phase 2 complete. Phase 3 complete.
> Post-Phase 3 bug fixes complete. UI polish complete. Window picker implemented.
> PF.6 recording logic removal complete.
> PF.7 system-audio share + audio-path hardening + permission handoff UX fixes complete.
> Phase 4 next (Production Hardening).
> Stats JSON export 1.10.5 still pending.

---

## [12 March 2026] — Bug Fixes: Screen Share Publish, G5 Crash, Double-Publish Guard

**Phase**: Post-Phase 3 bug fixes  
**Files changed**:
- `inter/App/AppDelegate.m` — Added `publishScreenShare` call inside the `statusHandler` block for `normalSurfaceShareController`, so network publishing actually starts when sharing is active and room is connected. Previously `publishScreenShare()` was never called.
- `inter/UI/Controllers/SecureWindowController.m` — Same fix: added `publishScreenShare` call in the secure window `statusHandler`.
- `inter/Networking/InterLiveKitScreenShareSource.swift` — Moved IOSurface retain off the router queue. Previously, `CVPixelBufferRetain` was called on the router queue before dispatch, which could block under kernel lock contention. Now the pixel buffer is retained inside the async dispatch block on the encoder queue.
- `inter/Networking/InterLiveKitPublisher.swift` — Added double-publish guard to `publishScreenShare`: returns early with error if `screenShareSource` is already non-nil, preventing duplicate track publication.

**Why**: Screen share was silently not publishing to the network. G5 crash occurred due to IOSurface kernel lock contention on the router queue. Double-publish caused track duplication.  
**Notes**: All three bugs were independently discovered during testing. Build succeeded, all 93 tests pass.

---

## [12 March 2026] — Google Meet/Zoom-Style Remote Video Layout Rewrite

**Phase**: Post-Phase 3 UI polish  
**Files changed**:
- `inter/UI/Views/InterRemoteVideoLayoutManager.h` — Complete API rewrite. New public API: `addRemoteCameraViewForParticipant:`, `removeRemoteCameraViewForParticipant:`, `setRemoteScreenShareView:forParticipant:`, spotlight support, filmstrip layout constants.
- `inter/UI/Views/InterRemoteVideoLayoutManager.m` — Full rewrite (~600 lines). New components:
  - `InterRemoteVideoTileView` (NSView wrapper): name label, hover highlight (tracking area), click-to-spotlight gesture, rounded corners, semi-transparent label bar.
  - **Stage + Filmstrip layout**: When screen share is active, main stage takes 75% width with the shared screen, filmstrip sidebar takes 25% (min 160px, max 280px) with scrollable camera tiles.
  - **Layout modes**: None, SingleCamera, MultiCamera (grid), ScreenShareOnly, ScreenShareWithCameras (stage+filmstrip).
  - **Spotlight**: Click any tile to spotlight it to the main stage. Click again to unspotlight.
  - **Animated transitions**: 300ms ease-in-out via `NSAnimationContext`.
  - `NSScrollView` filmstrip with vertical scroller for many participants.
  - Constants: `kFilmstripWidthFraction=0.25`, `kFilmstripMinWidth=160`, `kFilmstripMaxWidth=280`, `kAnimationDuration=0.3`.

**Why**: Previous layout was basic PiP overlay. New layout matches Google Meet/Zoom experience — dedicated stage for primary content (screen share or spotlighted participant), scrollable filmstrip sidebar for other cameras.  
**Notes**: Build succeeded, all tests pass.

---

## [12 March 2026] — Background Color Consistency Fix

**Phase**: Post-Phase 3 UI polish  
**Files changed**:
- `inter/UI/Controllers/SecureWindowController.m` — Changed `grayColor` background to `blackColor` on secure window content view.
- `inter/App/AppDelegate.m` — Added `blackColor` background on normal call window and its content view. Added `blackColor` on setup window content view.
- `inter/UI/Views/InterRemoteVideoLayoutManager.m` — Changed `clearColor` to `blackColor` on layout manager view. Changed tile background from `colorWithWhite:0.12` to `blackColor`.
- `inter/Rendering/MetalRenderEngine.m` — Changed Metal clear color from off-black `(0.03, 0.03, 0.03, 1.0)` to pure black `(0.0, 0.0, 0.0, 1.0)`.
- `inter/Rendering/MetalSurfaceView.m` — Added `layer.backgroundColor = [NSColor blackColor].CGColor` on the CAMetalLayer.

**Why**: 7 different sources produced inconsistent black/grey shades, causing visible seams between Metal render views, window backgrounds, and layout containers.  
**Notes**: All backgrounds now uniform pure black. Build succeeded, all tests pass.

---

## [12 March 2026] — Window Picker UI (ScreenCaptureKit)

**Phase**: Post-Phase 3 feature — Window-specific sharing  
**Files created**:
- `inter/UI/Views/InterWindowPickerPanel.h` — Public API: `+showPickerRelativeToWindow:completion:` presents modal sheet, calls `InterWindowPickerCompletion` with selected window identifier string or nil on cancel.
- `inter/UI/Views/InterWindowPickerPanel.m` (~580 lines) — Full Google Meet/Zoom-style window picker:
  - **ScreenCaptureKit** enumeration via `SCShareableContent getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:` — no deprecated CG APIs.
  - **Thumbnails**: `SCScreenshotManager captureImageWithFilter:configuration:` for each window (480×320 thumbnail). Parallel capture with `dispatch_group`.
  - **Grid UI**: 3-column scrollable grid of `InterWindowTileView` tiles. Each tile shows: window thumbnail (NSImageView, aspect-fit), app icon (20×20), window title (truncated), app name subtitle.
  - **Interaction**: Hover highlight (grey border via NSTrackingArea), click-to-select (blue border), click again to deselect. Cancel/Share buttons in bottom bar. Share enabled only when a tile is selected. Enter key shortcut.
  - **Internal model**: `InterWindowInfo` (windowID, windowTitle, appName, thumbnail, appIcon). `InterWindowTileView` (custom NSView with tracking area).
  - **Filtering**: Excludes own app windows (by PID and bundle ID), non-layer-0 windows (menus/tooltips), off-screen windows, windows smaller than 100×60.
  - **Dark theme**: Matches app aesthetic — dark backgrounds (0.10/0.12), light text, rounded corners, semi-transparent bottom bar.
  - **Loading state**: NSProgressIndicator spinner while SCShareableContent queries and thumbnails are captured.
  - Presented as NSPanel sheet on the call window.

**Files modified**:
- `inter/Media/Sharing/InterShareTypes.h` — Added `selectedWindowIdentifier` (nullable NSString) to `InterShareSessionConfiguration`. Passes the user's chosen CGWindowID through the share pipeline.
- `inter/Media/Sharing/InterShareTypes.m` — Updated `copyWithZone:` to copy `selectedWindowIdentifier`.
- `inter/Media/InterSurfaceShareController.m` — In `startSharingFromSurfaceView:`, forwards `configuration.selectedWindowIdentifier` to `InterScreenCaptureVideoSource.selectedWindowIdentifier` before calling `startCaptureForSelectedWindow`.
- `inter/App/AppDelegate.m` — Added `#import "InterWindowPickerPanel.h"`. Refactored `toggleNormalSurfaceShare`: for Window mode, presents the picker sheet first via `showPickerRelativeToWindow:completion:`. On selection, calls new helper `startNormalShareWithMode:windowIdentifier:` which sets the identifier on the configuration. Extracted common share-start logic into `startNormalShareWithMode:windowIdentifier:`.

**Why**: Previously "Share Window" mode had no UI for the user to choose which window to share — it just picked the first available non-own window. Now matches the Google Meet/Zoom experience where users see a visual grid of all available windows with live thumbnails and can select one before sharing starts.  
**Notes**: Build succeeded, all tests pass. Uses only ScreenCaptureKit APIs (macOS 13+), no deprecated CGWindowListCreateImage. Single SCShareableContent query reused for both window filtering and thumbnail capture (no N+1 query pattern).

---

## [12 March 2026] — PF.5: Interview Mode Join Flow Fix (Server-Authoritative Room Type)

**Phase**: PF.5.1–PF.5.10  
**Files changed**:
- `token-server/index.js` — `/room/create` accepts + stores `roomType` ("call"|"interview"), returns it. `/room/join` returns stored `roomType`. `createToken()` accepts optional `metadata` param to stamp role in JWT (`{"role":"interviewer"}` or `{"role":"interviewee"}`)
- `inter/Networking/InterTokenService.swift` — `InterCreateRoomResponse` + `InterJoinRoomResponse` gained `roomType` property (defaults "call"). `createRoom()` sends `roomType` to server. Both parsers extract `roomType` from JSON.
- `inter/Networking/InterNetworkTypes.swift` — `InterRoomConfiguration` gained `roomType` property. `init` + `copy(with:)` updated.
- `inter/Networking/InterRoomController.swift` — Added `roomType` KVO property. Passed through `handleTokenResponse`. Cleared on disconnect.
- `inter/App/AppDelegate.m` — `connectAndEnterMode:` sets config.roomType based on InterCallMode. `joinRoomWithCode:` reads rc.roomType after connect: if "interview" → shows confirmation dialog → enters SecureWindowController as interviewee (or disconnects on cancel). Added `showIntervieweeConfirmationWithCompletion:` method.
- `interTests/InterTokenServiceTests.swift` — Updated helpers with roomType field. Added `testCreateRoom_interviewType` + `testJoinRoom_interviewType`.
- `interTests/InterRoomControllerTests.swift` — `testRoomConfiguration_copy` verifies roomType copy semantics.

**Why**: Critical bug fix — joiners always entered normal mode regardless of room type. The token server now stores the room type, and the join response tells the client whether to enter interview (secure) mode. Architecture designed for future extensibility: URL-based joins, multi-interviewer rooms, and dynamic role switching all use the same `roomType` + JWT metadata pattern.  
**Notes**: BUILD SUCCEEDED, 95 tests pass (0 failures). 2 new tests added. Server backward-compatible (missing roomType defaults to "call"). JWT metadata stamping future-proofs for LiveKit participant metadata broadcasting.

---

## [13 March 2026] — PF.6: Recording Logic Removal

**Phase**: Post-Phase 3 (PF.6)  
**Files changed**:
- `inter/Media/Sharing/Sinks/InterRecordingSink.h` — DELETED. Full AVAssetWriter recording pipeline (452 lines → 0).
- `inter/Media/Sharing/Sinks/InterRecordingSink.m` — DELETED.
- `inter/Media/Sharing/InterShareTypes.h` — Removed `InterShareErrorCodeRecordingUnavailable` error code and `recordingEnabled` property from `InterShareSessionConfiguration`.
- `inter/Media/Sharing/InterShareTypes.m` — Removed `recordingEnabled = YES` from default configuration and `copyWithZone:`.
- `inter/Media/InterSurfaceShareController.h` — Removed `recordingEnabled:` parameter from `configureWithSessionKind:shareMode:` method.
- `inter/Media/InterSurfaceShareController.m` — Removed `InterRecordingSink.h` import, recording sink creation in `sinksForConfiguration:`, recording-related status text in `activeStatusTextForConfiguration:` and `startingStatusTextForConfiguration:`.
- `inter/App/AppDelegate.m` — Removed `settingsRecordingPathValueLabel` property, `recordingEnabled:YES` from 3 configure calls, entire recording storage Settings UI (folder chooser, path display, NSOpenPanel), `refreshSettingsRecordingPathLabel` and `selectRecordingFolderFromSettings` methods, `InterAppSettings.h` import.
- `inter/UI/Controllers/SecureWindowController.m` — Removed `recordingEnabled:YES` from configure call.
- `inter/inter-Bridging-Header.h` — Removed `#import "InterRecordingSink.h"`.
- `inter/App/InterAppSettings.h` — Gutted to empty class shell (placeholder for future settings).
- `inter/App/InterAppSettings.m` — Gutted to empty implementation (placeholder).
- `inter/Networking/InterLiveKitAudioBridge.swift` — Updated architecture comments to remove InterRecordingSink references.

**What was kept (for future recording)**:
- `InterShareSink` protocol — needed by network publish sink and future composed-layout recording.
- `InterSurfaceShareController` frame/audio routing infrastructure — the sink fan-out architecture supports adding a recording sink back later.
- `InterShareVideoSource` protocol — capture source abstraction.
- `InterShareVideoFrame` — frame container type.
- `InterAppSettings` class shell — ready for future settings (recording directory, preferences).
- `files.user-selected.read-write` entitlement — needed for future file saving.

**Why**: The existing recording pipeline captured raw screen content and auto-triggered on every screen share — this is not how production apps record. Zoom, Google Meet, and Microsoft Teams use **composed server-side recording**: a headless compositor on the SFU (or a dedicated media server) receives all participant tracks, composites them into a single layout (grid/speaker view), and encodes to a single MP4/MKV. The raw-screen approach was removed to avoid shipping incorrect behavior. The InterShareSink protocol and frame routing architecture are retained as the foundation for a future proper recording implementation (either server-side composed or client-side composed using multiple remote tracks).  
**Notes**: BUILD SUCCEEDED, 95 tests pass (0 failures). ~570 lines of recording code removed. Settings window now shows "No configurable settings yet." placeholder.

---

## [13 March 2026] — PF.7: System Audio Screen Share (End-to-End)

**Phase**: Post-Phase 3 (PF.7.1–PF.7.6)  
**Files changed**:
- `inter/Media/Sharing/InterShareTypes.h` + `inter/Media/Sharing/InterShareTypes.m` — Added `shareSystemAudioEnabled` to `InterShareSessionConfiguration` with default/copy support.
- `inter/Media/Sharing/Protocols/InterShareVideoSource.h` — Added audio sample callback contract for source-driven audio (`audioSampleBufferHandler`).
- `inter/Media/Sharing/Sources/InterAppSurfaceVideoSource.m` — Adopted new audio callback property to satisfy updated video source protocol.
- `inter/Media/Sharing/Sources/InterScreenCaptureVideoSource.h` + `inter/Media/Sharing/Sources/InterScreenCaptureVideoSource.m` — Added optional SCStream audio output capture path, wired sample forwarding for app/system audio, and guarded sample forwarding validity checks.
- `inter/Media/InterSurfaceShareController.h` + `inter/Media/InterSurfaceShareController.m` — Added `setShareSystemAudioEnabled:` and conditional routing: source-audio observer for screen share vs mic observer for regular share path.
- `inter/Networking/InterLiveKitScreenShareSource.swift` — Added app/system audio ingestion path and LiveKit mixer capture integration.
- `inter/UI/Views/InterLocalCallControlPanel.h` + `inter/UI/Views/InterLocalCallControlPanel.m` — Added Share System Audio toggle API + callback wiring.
- `inter/App/AppDelegate.m` — Wired toggle state/handlers in normal mode and status sync behavior.
- `inter/UI/Controllers/SecureWindowController.m` — Hid/forced-off system audio toggle in secure interview mode.

**Why**: Add production-ready system audio sharing for screen/window sharing, while preserving existing microphone path and mode-specific behavior.  
**Notes**: End-to-end path now routes SCStream audio samples from source → share controller → screen-share sink → LiveKit mixer.

---

## [13 March 2026] — PF.7 Stability: Screen-Share Audio Crash Hardening

**Phase**: Post-Phase 3 (PF.7.5)  
**Files changed**:
- `inter/Networking/InterLiveKitScreenShareSource.swift` — Replaced fragile conversion with deterministic PCM normalization and strict format validation (Float32/Float64/Int16/Int32). Added dedicated audio queue, safe-drop behavior for unsupported formats, and drop diagnostics counter.
- `inter/Media/Sharing/Sources/InterScreenCaptureVideoSource.m` — Added source-side guards to avoid forwarding invalid audio sample buffers into conversion path.

**Why**: Resolve EXC_BAD_ACCESS and conversion instability during active screen-share audio capture under variable ScreenCaptureKit audio formats.  
**Notes**: Clean focused test run for screen-share source passed after cleanup/rebuild; subsequent project builds succeeded.

---

## [13 March 2026] — PF.7 UX: Share Audio Toggle Placement + Permission Handoff Fix

**Phase**: Post-Phase 3 (PF.7.6–PF.7.8)  
**Files changed**:
- `inter/UI/Views/InterLocalCallControlPanel.m` — Repositioned Share System Audio toggle below the existing control stack.
- `inter/App/AppDelegate.m` — Added preflight permission gate in `toggleNormalSurfaceShare` for window/screen modes; if missing permission, request/open Settings flow and exit local share-start flow immediately with user-facing status text.
- `inter/UI/Views/InterWindowPickerPanel.m` — Removed forced `NSModalPanelWindowLevel` to prevent persistent floating panel behavior during System Settings redirection.

**Why**: Fix UX bug where permission handoff to System Settings left an in-app panel lingering onscreen, and align toggle placement with expected control order.  
**Notes**: BUILD SUCCEEDED after permission-flow and panel-level changes.

---

<!-- 
TEMPLATE — copy this for each new entry:

## [YYYY-MM-DD] — Title

**Phase**: X.Y.Z  
**Files changed**:
- `path/to/file` — description

**Why**: ...  
**Notes**: ...
-->

## [14 March 2026] — PF.8: Secure Interview Tool Surface + Dedicated Stage System

**Phase**: Post-Phase 3 (PF.8)  
**Files changed**:
- `inter/UI/Views/InterSecureToolHostView.h` / `inter/UI/Views/InterSecureToolHostView.m` — CREATED. Dedicated secure tool container used only for interview-mode tools.
- `inter/UI/Views/InterSecureCodeEditorView.h` / `inter/UI/Views/InterSecureCodeEditorView.m` — CREATED. Local secure code editor surface for interview mode.
- `inter/UI/Views/InterSecureWhiteboardView.h` / `inter/UI/Views/InterSecureWhiteboardView.m` — CREATED. Local secure whiteboard surface for interview mode.
- `inter/UI/Views/InterSecureInterviewStageView.h` / `inter/UI/Views/InterSecureInterviewStageView.m` — CREATED. Secure-specific stage system owning center-stage selection and the dedicated right rail for interview mode.
- `inter/Media/Sharing/Sources/InterViewSnapshotVideoSource.h` / `inter/Media/Sharing/Sources/InterViewSnapshotVideoSource.m` — CREATED. App-owned snapshot share source for the authoritative secure tool surface only.
- `inter/Media/InterSurfaceShareController.h` / `inter/Media/InterSurfaceShareController.m` — MODIFIED. Added support for injected/custom secure video sources and stabilized pending-share state flow.
- `inter/UI/Controllers/SecureWindowController.m` — MODIFIED. Rewired interview mode around the secure stage system, secure tool selection, secure share lifecycle, and teardown safety.
- `inter/UI/Views/InterLocalCallControlPanel.h` / `inter/UI/Views/InterLocalCallControlPanel.m` — MODIFIED. Added interview-tool selection UI and shared-button state presentation improvements.
- `inter/UI/Views/InterRemoteVideoLayoutManager.h` / `inter/UI/Views/InterRemoteVideoLayoutManager.m` — MODIFIED. Adjusted secure-mode remote presentation so interview mode no longer depends on the normal-mode internal filmstrip for its final stage layout.
- `inter/UI/Views/InterTrackRendererBridge.h` / `inter/UI/Views/InterTrackRendererBridge.m` — MODIFIED. Supported secure interview-stage preview sourcing and renderer wiring.
- `inter/Networking/InterRemoteVideoView.swift` — MODIFIED. Added stricter synchronous shutdown handling for remote renderer teardown.
- `inter/Rendering/MetalSurfaceView.h` / `inter/Rendering/MetalSurfaceView.m` — MODIFIED. Added synchronous render shutdown to avoid exit races with display-link driven rendering.

**Why**: Interview mode needed a secure tool-share architecture that does not leak local UI, remote feeds, or private chrome into the outgoing stream. The normal call layout model was not a safe or coherent abstraction for secure interview tools, so a separate secure interview stage system was introduced.
**Notes**: The final architecture keeps remote feeds local-only, secure tool capture authoritative, and interview staging independent from the normal-mode filmstrip implementation. Build and test validation succeeded after the stage-system and teardown hardening work.

## [15 March 2026] — PF.9: Share Start UX + Microphone Hot-Plug Refresh

**Phase**: Post-Phase 3 (PF.9)  
**Files changed**:
- `inter/Media/InterSurfaceShareController.h` / `inter/Media/InterSurfaceShareController.m` — MODIFIED. Added explicit `startPending` state so share activation only becomes true after the first live frame arrives.
- `inter/UI/Views/InterLocalCallControlPanel.h` / `inter/UI/Views/InterLocalCallControlPanel.m` — MODIFIED. Added pending-share presentation logic, fixed the recursive `setShareStartPending:` crash, and stabilized the button label so startup disables the button without flashing transient text.
- `inter/App/AppDelegate.m` — MODIFIED. Synced normal-mode control panel with pending-share state and subscribed normal-mode media UI to audio-input option changes.
- `inter/UI/Controllers/SecureWindowController.m` — MODIFIED. Synced secure-mode control panel with pending-share state and subscribed secure-mode media UI to audio-input option changes.
- `inter/Media/InterLocalMediaController.h` / `inter/Media/InterLocalMediaController.m` — MODIFIED. Added audio-device availability observation via `AVCaptureDeviceWasConnectedNotification` / `AVCaptureDeviceWasDisconnectedNotification` and exposed a callback for dropdown refresh.

**Why**: Two user-facing UX issues were addressed together: share buttons felt jittery because they exposed transient start-state text, and microphone dropdowns only refreshed when the mic was enabled because no device-availability observer existed.
**Notes**: The host-interview crash reported on 15 March 2026 was caused by a recursive control-panel setter (`setShareStartPending:` self-assignment) and is fixed in this entry. The microphone source dropdown now refreshes when mics are connected or disconnected even while capture is off. Full project tests passed after these changes.
