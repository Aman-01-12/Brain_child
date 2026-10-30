# Exit Interview Flow Check — Candidate Side (Secure Interview Mode)

## Verdict: WORKS WITH MINOR GAP

The candidate's "Leave Interview" button is fully wired end-to-end — it unpublishes
media, notifies the backend, disconnects from the LiveKit room, tears down the secure
window completely, and returns the user to the normal setup/login screen. No stub, no
dead end, no risk of getting stuck. The one real gap: **tapping it triggers two
sequential confirmation dialogs**, not one, because the secure-window confirm and the
shared app-level confirm both fire in the same chain. Cosmetic/UX, not a functional
break, but worth knowing before clicking it live.

---

## 1. Where the action lives

- **Button/view model**: `SecureCandidateBottomBarView` (SwiftUI), driven by
  `SecureCandidateChromeViewModel.onLeave`, in
  `inter/UI/SwiftUI/Screens/InterSecureChromeBridge.swift:52-66` — the bridge exposes
  `@objc public var leaveHandler: (() -> Void)?` (line 52-53) and wires
  `viewModel.onLeave = { [weak self] in self?.leaveHandler?() }` (line 66).
- **Handler assignment**: `SecureWindowController.m:431-434` (`attachControlPanelInView`):
  ```objc
  chrome.leaveHandler = ^{
      // [paranoid #5] The candidate's only escape from kiosk mode...
      [weakSelf exitSession];
  };
  ```
- **First confirm + dispatch**: `SecureWindowController.m:257-274` (`exitSession`) — shows
  "Are you sure you want to end this session?" (buttons: "End Session" / "Cancel"), and
  on confirm calls `self.exitSessionHandler()`.
- **Handler registration**: `AppDelegate.m:784-787` — in `enterMode:` when entering
  interviewee mode, `self.secureController.exitSessionHandler = ^{ [weakSelf
  requestExitCurrentMode]; };`.
- **Second confirm + role branch**: `AppDelegate.m:572-588` (`requestExitCurrentMode`) —
  checks `self.roomController.isHost`. For a candidate this is `false` (server-attested
  via the join response, confirmed by the prior curl check that interviewee tokens carry
  `role:"interviewee"`), so it calls `confirmEndCallWithMessage:@"Leave this call?"` with
  confirm title `"Leave"` (lines 584-586), and on confirm runs `exitCurrentMode`.
- **Actual teardown**: `AppDelegate.m:525-567` (`exitCurrentMode` → `finalizeCurrentModeExit`
  at line 6516).

## 2. Step-by-step of what actually happens today

1. Candidate clicks "Leave Interview" → `exitSession` alert #1 ("Are you sure you want to
   end this session?"). (`SecureWindowController.m:258-274`)
2. Candidate confirms ("End Session") → `exitSessionHandler()` fires →
   `requestExitCurrentMode` → since not host → alert #2 ("Leave this call?" / "Leave").
   (`AppDelegate.m:572-588`, `confirmEndCallWithMessage` at `AppDelegate.m:657-680`)
3. Candidate confirms again ("Leave") → `exitCurrentMode` (`AppDelegate.m:525-567`) →
   no fullscreen window involved in secure mode, so it goes straight to
   `finalizeCurrentModeExit` (`AppDelegate.m:6516-6547`):
   - Unlocks the meeting-tier lock (`AppDelegate.m:6518`).
   - Stops screen monitoring / resets presentation options (kiosk restrictions lifted).
   - Hides the secure window immediately (`[self.secureController hideSecureWindow]`,
     line 6538) — instant visual feedback before the slower teardown below.
   - Calls `[self.roomController disconnect]` (line 6540), which in
     `InterRoomController.swift:742-830` (`disconnect(reason:)`):
     - Notifies the backend: `tokenService.leaveRoom(serverURL:roomCode:identity:)`
       (lines 752-759) → **fire-and-forget**, no blocking on the result.
     - Exports/stops the call-stats collector.
     - Unpublishes all local tracks, detaches the subscriber, cancels grace/refresh
       timers, stops the memory monitor.
     - Calls `room.disconnect()` on the LiveKit room object (`Task { await
       room.disconnect() }`, ~line 800) — the actual LiveKit SDK leave.
     - Resets `configuration`, connection state, room code/type, participant counts.
   - Calls `[self teardownActiveWindows]` (line 6543), which at the end calls
     `[self.secureController destroySecureWindow]` (`AppDelegate.m` inside
     `teardownActiveWindows`, confirmed by direct read) — this runs
     `SecureWindowController.m:289-359` (`destroySecureWindow`):
     - `[self.controlPanel invalidateHandlers]` — drops every chrome block
       (leaveHandler, shareToggleHandler, etc.) so nothing outlives the session.
     - Removes the SwiftUI top/bottom bars and self-preview strip from the view
       hierarchy.
     - Stops any active surface share, clears the network publish sink.
     - Shuts down `localMediaController` (camera/mic), tears down KVO on the room
       controller, tears down remote video layout and track renderer bridge.
     - Tears down the chat overlay window/panel.
     - `[self.secureWindow orderOut:nil]; self.secureWindow = nil;` and clears
       `exitSessionHandler`.
   - Calls `[self.sessionCoordinator finishExit]` (phase → idle, re-entrancy guard
     released) and `[self launchSetupUI]` (line 6547-6548) — rebuilds the normal
     "Secure Call Setup" window (`AppDelegate.m:802+`), i.e. the candidate lands back
     on the app's home/setup screen, not a blank or frozen window.
4. Backend side (`token-server/index.js:3327-3372`, `POST /room/leave`): validates a
   single-use `leaveToken` (issued to the client at join time and cached in
   `InterTokenService.leaveTokenStore`, confirmed populated from all three join-response
   code paths at `InterTokenService.swift:990-991, 1104-1105, 2305-2306`), removes the
   identity from the room's participant/role/name sets in Redis, reconciles against
   LiveKit if the room is now empty, and cleans up uploaded files if it was the last
   participant. This is the same `/room/leave` the earlier curl-based investigation did
   not exercise interactively — it is now confirmed reachable and correctly scoped from
   the actual client code path.

## 3. Gaps / risks found

- **Double confirmation dialog (real gap, low severity).** As shown above, the
  candidate must click through *two* separate "are you sure" alerts
  ("End Session" then "Leave") to actually leave, because `SecureWindowController.exitSession`
  (its own confirm) feeds into `AppDelegate.requestExitCurrentMode` (a second confirm for
  non-hosts). Functionally harmless — worst case is mild annoyance or a "why did it ask
  twice" question if a reviewer is watching closely — but it is almost certainly not the
  intended design: the comment at `SecureWindowController.m:257` frames `exitSession` as
  *the* confirmation gate ("paranoid #5... routes through the confirmation alert in
  exitSession"), suggesting the author did not realize `requestExitCurrentMode` adds a
  second one for non-host exits. Recommend (not implemented): either have
  `exitSessionHandler` call `exitCurrentMode` directly instead of
  `requestExitCurrentMode` (skipping the second alert, since `exitSession` already
  confirmed), or drop `exitSession`'s own alert and let `requestExitCurrentMode` be the
  single gate. Either is a one-line change; did not implement per read-only scope.
- **No stub/TODO found.** Grepped the whole chain (`exitSession`, `requestExitCurrentMode`,
  `exitCurrentMode`, `finalizeCurrentModeExit`, `disconnect`, `destroySecureWindow`,
  `/room/leave`) — every step has a real implementation, no "TODO"/"FIXME"/no-op found
  near this code.
- **Backend-notify failure is non-blocking (good, not a gap).** If `/room/leave` fails
  (network hiccup), `InterTokenService.leaveRoom`'s completion handler only logs the
  error (`InterTokenService.swift:1186-1192`) — it does not retry, block, or propagate
  failure back into the UI thread. The rest of `disconnect(reason:)` and the whole
  `finalizeCurrentModeExit` teardown run unconditionally and synchronously regardless of
  that HTTP call's outcome. **A network hiccup during leave cannot strand the candidate
  in the locked secure window** — the window still closes and the app still returns to
  the setup screen; only the Redis-side participant-count cleanup would be delayed (it
  self-heals: the room's participant set has a TTL, and `reconcileEmptyRoom` cross-checks
  LiveKit's live room state on subsequent calls).
- **Consistency with normal (non-interview) call leave.** The normal in-call "Leave"
  button (`AppDelegate.m:2844`, `bar.leaveHandler = ^{ [weakSelf requestExitCurrentMode];
  };`) goes straight into `requestExitCurrentMode` with exactly one confirmation dialog.
  So the secure/candidate flow is the odd one out with its extra pre-confirmation — this
  supports the double-dialog being an oversight rather than an intentional
  "interview leaving is more serious" design choice.

## 4. Candidate vs. host — confirmed distinct

- `requestExitCurrentMode` (`AppDelegate.m:572-588`) branches on
  `self.roomController.isHost`. For a candidate this is `false`, server-attested: the
  client only sets `configuration.isHost = true` if the server's own response says so
  (`InterRoomController.swift` ~line 405: `if r.isHost { self.configuration?.isHost =
  true }`), consistent with the earlier curl-verified `role:"interviewee"` token scoping.
- Only the host branch reaches `confirmHostEndCall` (`AppDelegate.m:594-624`), which can
  call `[self.moderationController endMeetingForAll:...]` — the destructive,
  room-deleting, everyone-disconnected action. The candidate's leave path never touches
  `endMeetingForAll` or the moderation controller at all; it only ever reaches
  `exitCurrentMode`, which is purely "disconnect myself, clean up my own window." No
  code path lets a candidate accidentally trigger the host-only end-for-everyone action.

## 5. What to watch for when demoing this specific button

- **Expect two click-throughs**, not one: "End Session" then "Leave". If you only click
  once and the window is still up, that's expected — the second alert is on top (likely
  as a sheet on the secure window per `exitSession`'s `beginSheetModalForWindow:` at
  `SecureWindowController.m:267-274`), not a hang.
- After both confirms, the full-screen kiosk window should visibly disappear almost
  immediately (it's hidden before the slower teardown runs — `AppDelegate.m:6538` vs.
  6540+), and the app should land back on the "Secure Call Setup" window. If the
  professor asks "does leaving the interview end it for the interviewer" — the answer
  from the code is clearly no; only `endMeetingForAll` (host-only, different button/flow)
  does that.
- No network dependency risk for the demo: even if local Wi-Fi/network hiccups during
  the leave click (relevant given this session's earlier network-outage history), the
  window will still close and the app will still return to setup — the LiveKit/backend
  leave notification is best-effort and does not gate the UI teardown.
