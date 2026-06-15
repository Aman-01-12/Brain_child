# Recording video-freeze fix — Path A (+ minimal layout choice)

Scope: local composed recording only ([G8] isolated). Fixes the freeze where the
host's video stalls once two camera-off participants take both speaker slots.

## Design (council-approved)
- 2-slot model: remote active speaker = PRIMARY; local host = SECONDARY when a
  remote holds primary, PRIMARY when host is the only camera. Host is never an
  "active speaker" → always rendered.
- Frameless slot (audio-only / camera-off) shows avatar placeholder, never a
  stale frame.
- Grid engages at 3+ participants (auto) via wired presence join/leave.
- Camera-off ≠ leave: camera track end → placeholder; removal only on real leave.
- Minimal layout choice: Automatic (default) | Speaker view.
- Pure decision logic extracted → unit-testable.

## Tasks
- [x] T1  Coordinator: `InterRecordingLayoutPreference` @objc enum (auto/speaker)
- [x] T2  Coordinator: `InterRecordingLayoutLogic` pure helpers (useGrid / localSlot / needsPlaceholder)
- [x] T3  Coordinator: state — `_identitiesWithLiveFrame`, `preferredLayout` (+`_layoutPref` snapshot)
- [x] T4  Coordinator: `_startLocalRecording` — snapshot pref, grid via helper
- [x] T5  Coordinator: rewrite `didReceiveRemoteCameraFrame` non-grid branch (host-always + live-frame tracking)
- [x] T6  Coordinator: `_acceptSpeakerSwitch` — placeholder for frameless new active speaker
- [x] T7  Coordinator: `_updateLayoutMode` — honor preference
- [x] T8  Coordinator: remap `remoteTrackDidEnd(.camera)` → camera-off placeholder (not leave)
- [x] T9  Coordinator: implement `remoteParticipantDidJoin/Leave` → participantDidJoin/Leave (+forget live frame)
- [x] T10 Coordinator: `_teardownPipeline` clears `_identitiesWithLiveFrame`
- [x] T11 Subscriber: forward join/leave to `recordingFrameDelegate`; add seed-identities accessor
- [x] T12 Roster: add `remoteIdentitiesSnapshot()` (main-thread read)
- [x] T13 AppDelegate: seed existingParticipants + minimal layout-choice alert; both local-record entry points
- [x] T14 Tests: `InterRecordingLayoutLogicTests` (findings #1/#2/#3/#9)
- [x] T15 Build (xcodebuild) green
- [x] T16 Run `interTests/InterRecordingLayoutLogicTests` green (4/4 passed)
- [ ] T17 Manual: re-run virtual-participants 2-bot scenario; confirm host video no longer freezes

## Verification notes
- Build: ** BUILD SUCCEEDED **
- Tests: 4/4 passed (InterRecordingLayoutLogicTests)
- Phase 5 (paranoid) mitigation→test mapping:
    #1 host always rendered      → testLocalAlwaysHasASlot
    #2 frameless → placeholder   → testFramelessSlotNeedsPlaceholder
    #3 grid engages at 3+        → testAutoGridThreshold
    #9 speaker never grids       → testSpeakerViewNeverGrids
- Findings #4/#5/#6 (leak closure, camera-off≠leave, placeholder ownership) are
  structural (teardown clears state; remoteTrackDidEnd remap; .takeUnretainedValue()
  matching the existing grid path) — verified by code review + build.


---

# In-call mic-switch fix (re-point LiveKit native capture)

Problem: selecting a mic during a call was a silent no-op on transmitted/recorded
audio — the picker only touched the AVCaptureSession (not the network mic), and that
reconfig is skipped while connected. LiveKit captured from the system-default input.

Fix (council + paranoid approved):
- [x] M1 Coordinator-adjacent: `InterRoomController.setNetworkAudioInput(deviceID:name:)`
       → sets `AudioManager.shared.inputDevice` (supported API), matched id→name,
       safe no-op if no match, skips redundant switch (no ADM thrash).
- [x] M2 Pure `InterAudioInputMatcher.matchIndex(...)` extracted for testability.
- [x] M3 AppDelegate `handleNormalAudioInputSelection:` connected branch re-points
       LiveKit capture (was: store-pref + skip); updated stale comment.
- [x] M4 Tests: `InterAudioInputMatcherTests` (deviceId-wins / name-fallback / no-op) — 4/4 pass.
- [x] M5 Build green.
- [ ] M6 Manual: in a call, switch mic in the picker → confirm transmitted/recorded
       audio follows (e.g. mac-mic → earphone drops the fan floor ~9 dB in the recorder WAV).

Notes / scope:
- Surface-share audio fan-out still uses the AVCapture mic (unchanged) — niche path.
- Connect-time device preference → LiveKit is a separate gap (LiveKit uses system
  default at connect); not in scope for this fix.
- Two-instances-on-one-Mac may still contend on switch (test-rig only).


---

# AGC A/B — REVERTED (hypothesis disproved)

- Prior "AGC-on" runs (SSSMPQ etc.) were the OLD binary (user hadn't rebuilt) → actually AGC-off.
- First real AGC-on build = `sdtzv5`: speech ~-15 dBFS, peaks at 0 dBFS (harsh/over-amplified,
  re-loudens AC), choppiness 15.2% (vs 13.3% AGC-off). Worse on both axes → "horrible".
- Reverted `isVoiceProcessingAGCEnabled = false` (back to the better state). Build green.
- Conclusion: choppiness is NS/VAD gating of low-level mic input, NOT an AGC issue.
  Dominant factor is environmental (room AC + mac-mic distance): AC-off halved holes (13.3%→5.7%).
- Open option: investigate whether WebRTC/LiveKit exposes a noise-suppression level to tune
  (A/B), with the caveat that some gating is inherent for a quiet/distant mic in a noisy room.


---

# Mic picker correctness — 3 complementary fixes

Symptom: in-call mic picker checkmark went stale/missing on earphone plug/unplug
(audio routed correctly; only the tick was wrong). Root cause: the tick was
computed from AVCapture state that (a) could point at a just-removed device → no
matching menu item, and (b) diverges from the actual LiveKit capture while connected.

- [x] Fix #1 — `selectedAudioInputDeviceID` now only returns an id present in the
      live `availableAudioInputOptions` list (validates against discovery, not the
      racy `deviceWithUniqueID:`). Checkmark can never orphan onto a removed device.
- [~] Fix #2 — REVERTED (2026-06-15). Deriving the connected checkmark from LiveKit's
      `AudioManager.inputDevice` (via `selectedNetworkAudioInput(optionIDs:optionNames:)`)
      put a synchronous WebRTC `Thread::BlockingCall` into the audio route-change refresh
      path, which blocked the MAIN THREAD during earphone plug/unplug → UI/video freeze.
      Both call sites (`refreshSecureAudioInputOptions`, `refreshNormalAudioInputOptions`)
      and the `selectedNetworkAudioInput` method were removed. The checkmark is now derived
      solely from the AVCapture-validated `selectedAudioInputDeviceID` (Fix #1), which is
      sufficient to keep the tick on a present device. `InterAudioInputMatcher` is kept
      (pure, tested) for a possible future SAFE re-add (off-main-thread + debounced, never
      during a route-change storm). See spec: audio-route-change-crash-fix.
      NOTE: this revert fixed the freeze but NOT the separate EXC_BAD_ACCESS crash on
      route change — that is a WebRTC/AVFAudio AVAudioEngine teardown race inside the SDK
      (tracked separately in the audio-route-change-crash-fix spec).
- [x] Fix #3 — at connect (post mic-publish), apply the user's preferred mic to
      LiveKit (`setNetworkAudioInput`) so capture isn't stuck on the system default
      at join. No-op when preferred == system default (no ADM restart).

Complementary (not exclusive): #1 = tick never orphaned; #2 = tick reflects real
capture when connected; #3 = join-time uses the chosen mic.

Build: ** BUILD SUCCEEDED **. Tests: InterAudioInputMatcherTests + 
InterRecordingLayoutLogicTests = 8/8 pass.
Scope note: applied to the normal call path. Secure-window picker gets Fix #1
automatically (shared `selectedAudioInputDeviceID`); #2/#3 not wired there.
Manual: plug/unplug earphone in-call → tick should always sit on a present device
and match the active mic; at join, the green-room mic choice should be the one used.


## Secure/interview window — parity wiring (done)
- Fix #1: shared via `selectedAudioInputDeviceID` (automatic).
- Fix #2: `refreshSecureAudioInputOptions` reflects LiveKit `inputDevice` when connected.
- Fix #3: applies preferred mic to LiveKit at secure connect (post-publish).
- Bonus: `handleSecureAudioInputSelection` now has the connected-guard (re-points
  LiveKit instead of reconfiguring the shared AVCaptureSession in-call — was a latent
  video-interruption path in secure mode).
- Build: ** BUILD SUCCEEDED **.
