# Work Done — LiveKit Integration Changelog

> **Reference**: See `tasks.md` for the full implementation plan.  
> **Convention**: Each entry includes the date, what changed, which files, and why.

---

## Format

```
## [DATE] — Brief Title

**Phase**: X.Y.Z from tasks.md  
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

## Log

> Phase 0 complete. Phase 1 complete (all 11 files created + all unit tests). Phase 2 next (modify existing ObjC files).  
> Stats JSON export 1.10.5 still pending.

<!-- 
TEMPLATE — copy this for each new entry:

## [YYYY-MM-DD] — Title

**Phase**: X.Y.Z  
**Files changed**:
- `path/to/file` — description

**Why**: ...  
**Notes**: ...
-->
