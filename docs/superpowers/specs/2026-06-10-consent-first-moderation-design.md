# Consent-First Moderation State Model — Design Spec

**Date:** 2026-06-10
**Project:** inter (macOS, Obj-C + Swift, LiveKit)
**Feature:** Host moderation that mirrors real participant state and never force-activates a mic/camera
**Status:** Draft — awaiting user review before implementation planning
**Builds on:** `2026-05-31-mic-unlock-request-design.md` (one-time slot / approve flow), and the
P1/P3/P4 correctness fixes shipped 2026-06-10.

---

## 1. Summary

Two changes, derived from a brainstorm + decision council on 2026-06-10:

1. **Consent-first principle.** A host can *restrict* (mute, block self-unmute, lock camera,
   global mute/lock) and *request* (ask to unmute / ask to turn on camera), but **never
   force-activates** a participant's microphone or camera. The participant always makes the
   final tap through their own real mic/camera buttons. **Exception:** *interview mode* retains
   today's force-restore behavior for **both mic and camera** (the interviewer may directly enable
   the interviewee's device), because the interviewee consents to proctoring-style control by
   joining — but every such force-activation MUST show the interviewee a persistent *"Host turned
   on your microphone/camera"* indicator (never silent). Normal mode never force-activates.

2. **Host UI mirrors real state.** The host's view of each participant shows the participant's
   *actual* mic/camera state and its *cause* (self-muted vs muted-by-host vs mute-all), as an
   always-visible tile caption — not a stale, intent-only menu label. The 3-dot menu carries
   *actions* only; *status* lives on the tile.

The whole thing rests on one pure, exhaustively unit-tested derivation function so that no UI
surface can silently drift from real state again (the root cause of the original desync report).

Delivered in two phases: **PR #1 = microphone**, **PR #2 = camera** (identical pattern, after a
live 2-client test of PR #1).

---

## 2. Background — why

The original report: under Mute-All, host per-tile-unmutes one participant, the participant
self-mutes, and the host's per-tile menu label goes stale. Investigation found the host tile
has two decoupled representations — a LiveKit-driven **badge** (real state) and an intent-driven
**menu label** (`isHostMuted`) — and several host actions optimistically wrote the real-state
channel. The P1/P3/P4 fixes removed the worst optimistic writes. This spec addresses the
*design* the user chose: the host surface should mirror real participant state, and the host
should never seize a mic/camera.

---

## 3. Core component — `deriveRemoteTileState` (pure function)

A single pure function is the source of truth for every host-side per-participant surface.
It has no side effects and is trivially unit-testable (a small, fully enumerable input set).

### Inputs (all already available)

| Input | Source today |
|---|---|
| `reallyMicMuted` | LiveKit roster → `tile.isMicMuted` (driven by `didUpdateIsMuted`) |
| `hostMicBlocked` | host intent → `hostMutedParticipants` / `tile.isHostMuted` |
| `globalMute` | `moderationController.isAllMuted` |
| `cameraOn` | LiveKit roster → `!cameraOff` |
| `hostCameraLocked` | host intent → `tile.isHostCameraLocked` |
| `globalCameraLock` | room state |
| `isInterviewMode` | room type (interview vs normal) |
| `micPendingSelfAction` | NEW (fixes Finding A): host has lifted the per-tile block (or sent an ask) while the track is still off, and the participant has not yet unmuted. Set when `requestUnmuteOne`/`askToUnmute` is issued against an off track; cleared the moment `reallyMicMuted→false` (they tapped) or on re-block / Mute-All. Distinguishes "freely self-muted" from "permitted, awaiting their tap". |
| `camPendingSelfAction` | NEW: camera equivalent of `micPendingSelfAction`. |

### Outputs

The host's per-tile menu shows **one primary action derived from the same cause as the caption**
(plus an optional secondary). Because caption and action come from one cause, they can never
contradict — this is the root-cause fix for the old "`Muted (mute-all)` caption next to a `Mute
Mic` button" mismatch (the `Mute` action now only appears when the participant is actually live).

| Output | Meaning |
|---|---|
| `micStatusCaption` | `"Mic on"` \| `"Self-muted"` \| `"Muted by you"` \| `"Muted (mute-all)"` \| `"Off — can unmute"` (block lifted, awaiting their tap; `"Asked to unmute"` when an ask is pending) |
| `micPrimaryAction` | the single cause-derived action — one of: `Mute` \| `AskToUnmute` \| `RemoveMuteAndAsk` \| `AllowToSpeak` (see table below) |
| `micSecondaryAction` | `None` \| `BlockMic` — an optional enforce-block, shown only when the participant is already muted by something other than the host's own block (so the host can pre-emptively prevent self-unmute) |
| camera equivalents | `camStatusCaption`, `camPrimaryAction` (`Lock` \| `AskToTurnOn` \| `RemoveLockAndAsk` \| `AllowCamera`), `camSecondaryAction` (`None` \| `LockCamera`) |

### Action derivation (the key rule)

Both the caption and the primary action are computed from one cause, in this precedence:

```
(caption, micPrimaryAction, micSecondaryAction) =
  hostMicBlocked   -> ("Muted by you",      RemoveMuteAndAsk, None)     // lift my block + nudge, one click
  globalMute       -> ("Muted (mute-all)",  AllowToSpeak,     BlockMic) // grant slot; may also enforce-block
  !reallyMicMuted  -> ("Mic on",            Mute,             None)     // the only state where Mute appears
  micPendingSelfAction
                   -> ("Off — can unmute"   AskToUnmute,      BlockMic) // ("Asked to unmute" if ask pending)
  else             -> ("Self-muted",        AskToUnmute,      BlockMic)
```

Key properties:
- **No contradiction by construction:** `Mute` is reachable only from the `"Mic on"` cause, so it
  never sits beside a `"Muted (…)"` caption — the original mismatch is impossible.
- **`RemoveMuteAndAsk` (host-muted case):** one click lifts the host's block **and** sends the
  consent affordance (§4.3). It still does **not** force the mic on — the participant taps. This is
  a deliberate, scoped exception to the otherwise-strict "lift never auto-asks" rule (user
  decision), justified because the host muted them, so inviting them straight back is the obvious
  intent. All other causes keep lift and ask separate (there is no lift to perform in those causes).
- **`BlockMic` secondary:** lets the host enforce-mute someone who is already self/globally muted
  (prevent self-unmute). Choosing it transitions the cause to `"Muted by you"`, after which the
  primary becomes `RemoveMuteAndAsk` — consistent.
- **`micPendingSelfAction`** only changes the *caption* (`"Off — can unmute"` / `"Asked to unmute"`),
  not the action, so the post-lift window never misreports as `"Self-muted"` (Finding A). While an
  ask is in cooldown the primary renders as `"Asked ✓"` (disabled) per §4.3.

The same precedence applies to camera. This is the entire "mirror real state" logic, in one
place, fully enumerable in tests.

---

## 4. Surfaces

### 4.1 Always-visible tile caption (host view)

Each remote tile shows a small caption/badge with `micStatusCaption` (+ camera equivalent).
This is what the host glances at — no menu open required. Driven directly from
`deriveRemoteTileState`, recomputed on every roster snapshot and every host action.

### 4.2 3-dot menu — one cause-derived action (+ optional secondary)

The menu shows **one primary mic action**, derived from the same cause as the caption (§3), so
the two can never disagree. An optional secondary appears only where a real capability would
otherwise be lost.

| Cause (caption) | Primary action | Secondary action |
|---|---|---|
| `"Mic on"` | **"Mute Mic"** — apply host block | — |
| `"Self-muted"` / `"Off — can unmute"` | **"Ask to Unmute"** — send consent affordance (§4.3); no force-on | **"Block mic"** — enforce-mute (prevent self-unmute) |
| `"Muted by you"` | **"Remove Mute & Ask"** — lift the host block **and** nudge, one click; still no force-on | — |
| `"Muted (mute-all)"` | **"Allow to Speak"** — grant a speak slot (existing approve flow) | **"Block mic"** — keep them muted after Unmute-All |

Camera mirrors this exactly (PR #2): `"Camera on" -> "Stop Video"`; `"Self-off"/"Off — can turn
on" -> "Ask to Turn On Camera"` (+ secondary `"Lock camera"`); `"Locked by you" -> "Remove Lock &
Ask"`; `"Off (lock-all)" -> "Allow Camera"` (+ secondary `"Lock camera"`).

Rules that still hold:
- **`Mute`/`Lock` appears only in the live state**, so it never contradicts a `"Muted (…)"` /
  `"Off (…)"` caption (the mismatch fix).
- **No host action force-activates** a mic/camera; `"Remove Mute & Ask"` lifts + invites but the
  participant always makes the final tap (normal mode). Interview mode keeps force-restore per §5.
- **Lift and ask are separate** everywhere **except** the host-muted `"Remove Mute & Ask"`, where
  the user chose to couple them in one click (the host muted them, so inviting them back is the
  obvious intent).

### 4.3 Participant-side prompt — persistent affordance until resolved

When a host clicks `"Ask to Unmute"` / `"Ask to Turn On Camera"`, the participant sees a
**persistent affordance that stays until resolved** (Finding D, resolved). Two coordinated cues:

- The participant's **own real mic/camera button pulses/highlights** to draw the eye to the
  control they will use, and the button is enabled.
- A small **"Host asked you to unmute"** / **"Host asked you to turn on your camera"** chip remains
  visible (it does **not** auto-dismiss) until the request is resolved.

The affordance is purely an invitation — there is still **no force-activation and no separate
accept/decline dialog**. It resolves (chip clears, pulsing stops) in exactly these ways:

- **Acted:** the participant taps their own button and turns the mic/camera on → resolved.
- **Dismissed:** the participant taps the chip's small dismiss (×) → resolved locally; they stay
  muted/off. Dismiss is local-only (no "declined" signal is sent — consistent with the host
  having no accept/decline control).
- **Superseded:** a re-block, Mute-All/Lock-All, or the host re-issuing the ask replaces/clears it.

This keeps "the participant always makes the final tap" intact while fixing the transient-toast
flaw where looking away for a few seconds lost the request with no trace. The `micPendingSelfAction`
input (§3) is set exactly while this affordance is live, so the host's tile caption reads
`"Asked to unmute"` for the same window.

**Host-side delivery feedback (Finding D, additive).** Because there is no accept/decline
round-trip, after issuing an ask the per-tile action shows a transient `"Asked ✓"` state and is
disabled for a short cooldown (e.g. 10 s) so the host does not re-click repeatedly. The host also
sees the participant's live state via the tile caption/badge, which flips to `"Mic on"` the moment
they act. A delivery/seen receipt is possible later but is out of scope (§9).

---

## 5. Semantics changes

### 5.1 Microphone (PR #1)

| Path | Before | After (normal mode) | After (interview mode) |
|---|---|---|---|
| `requestUnmuteOne` (per-tile unmute) | force-unmutes the participant's track | **lift `hostMuted` only**; participant's button enabled; they tap to turn on | force-unmute retained |
| New `"Ask to Unmute"` action | n/a (or raise-hand) | sends `askToUnmute` (signal 12, exists) → participant persistent affordance (§4.3) | same |
| Mute-All approve | grant one-time slot (exists) | unchanged | unchanged |
| Per-tile `"Mute Mic"` | force-mute + block | unchanged (restricting is always allowed) | unchanged |

### 5.2 Camera (PR #2)

| Path | Before | After (normal mode) | After (interview mode) |
|---|---|---|---|
| Camera lock lift | auto-restores camera if it was on pre-lock | **lift lock only**; no auto-on; participant taps | auto-restore retained |
| New `"Ask to Turn On Camera"` | n/a | sends `askToUnmuteCamera` (signal 35, exists) → participant persistent affordance (§4.3) | same |
| Lock-All approve | grant slot (exists) | unchanged | unchanged |
| Per-tile `"Lock Camera"` | lock + turn off | unchanged | unchanged |

Interview mode is detected from the room type already known to `InterRoomController` /
`InterModerationController`. The interview exception is implemented by **gating the existing
force-on/restore behavior behind the interview check**, and routing all other modes through the
new lift-only + ask path — minimal new logic on the force path.

**Interview-mode visibility requirement (Finding B, resolved).** Whenever interview mode
force-activates a participant's mic **or** camera (the retained force-restore path), the
participant MUST see a clear, **persistent** indicator that the host enabled their device
(e.g. a *"Host turned on your microphone"* / *"Host turned on your camera"* banner that stays
visible while the host-enabled state is active) — activation is **never silent**. This is the
ratified **Option 2** decision (force-restore stays in interview mode, for both mic and camera)
plus the mandatory indicator, pulling the interview path toward the same consent-first
transparency as the rest of the app. Option 3 (explicit, revocable, join-time consent) was
considered and declined for now (see §8).

**Interview-mode action labels (resolved 2026-06-11).** Because interview mode force-turns the
device on, the primary action reads a **direct "Unmute" / "Turn On Camera"** (not the consent
wording "Ask to Unmute" / "Remove Mute & Ask" / "Allow to Speak"). The caption and which action
is offered stay mode-independent; only the label and the force-execution differ. The secondary
**"Block mic"** (and camera lock) **remains available in interview mode** — interview is a
*superset* of host control (the interviewer may force-activate AND enforce-block), so the block
capability is never removed. In `InterModerationTileState`, `primaryActionTitle` returns
`"Unmute"` exactly when `activationForcesDevice` (= `interview && primaryAction.isActivation`).

---

## 6. What stays untouched

- Restricting (mute, block, lock, Mute-All, Lock-All) — hosts can always *remove* audio/video.
- The existing one-time-slot approve flow under global restrictions.
- Raise-hand as a general intent signal.
- The mic-muted badge and camera avatar (already LiveKit-driven; now joined by the cause caption).
- Server authority for roles/locks; LiveKit-native events as the real-state source (no Socket.IO).

---

## 7. Phasing & testing

- **PR #1 (microphone):** `deriveRemoteTileState` (mic portion) + full unit-test matrix;
  `requestUnmuteOne` → lift-only (normal) / force + persistent "host enabled" indicator
  (interview); `"Ask to Unmute"` per-tile action + participant persistent affordance (§4.3) + host
  `"Asked ✓"`/cooldown; host tile mic-cause caption. Build + existing suites green. Then a live
  2-client manual test of the scenarios that unit tests cannot see.
- **PR #2 (camera):** port the identical pattern; camera lift → lift-only (normal) / restore +
  persistent "host enabled" indicator (interview); `"Ask to Turn On Camera"` + participant
  persistent affordance; camera-cause caption. After PR #1 is live-verified.

### Unit-test matrix (PR #1)

Enumerate the reachable `(reallyMicMuted × hostMicBlocked × globalMute × micPendingSelfAction)`
combinations × `{normal, interview}` and assert the full output tuple `(micStatusCaption,
micPrimaryAction, micSecondaryAction)`. This is the verification lever that substitutes for the
live call. Required rows include, at minimum:
- **Precedence lock:** `hostMicBlocked && globalMute` both true → caption `"Muted by you"`,
  primary `RemoveMuteAndAsk` (block wins over mute-all), so the §3 ordering is fixed by the suite,
  not by reading order.
- **Mismatch fix (the reason for this revision):** `globalMute && !hostMicBlocked` → caption
  `"Muted (mute-all)"` **and** primary `AllowToSpeak` (NEVER `Mute`); assert `Mute` is unreachable
  whenever `reallyMicMuted` is true.
- **`Mute` only when live:** `!reallyMicMuted` → caption `"Mic on"`, primary `Mute`.
- **Block-lift transition (Finding A):** `reallyMicMuted && !hostMicBlocked && !globalMute &&
  micPendingSelfAction` → caption `"Off — can unmute"` (NOT `"Self-muted"`), primary `AskToUnmute`.
- **Genuine self-mute:** same but `micPendingSelfAction == false` → caption `"Self-muted"`,
  primary `AskToUnmute`, secondary `BlockMic`.
- **Host-muted bring-back:** `hostMicBlocked` → primary `RemoveMuteAndAsk` (one click = lift +
  ask), and assert it does **not** set the track live in normal mode.
- **Enforce-block availability:** secondary `BlockMic` present for `"Self-muted"` and
  `"Muted (mute-all)"`, absent for `"Mic on"` and `"Muted by you"`.

---

## 8. Open questions / risks

- **[DECISION — RESOLVED] Interview-mode consent model:** keep **Option 2 — force-restore in
  interview mode only, for BOTH mic and camera** — plus a mandatory **persistent visible
  indicator** whenever the host force-activates a device (§5). Option 3 (explicit, revocable,
  join-time consent) was considered and declined for now; if revocability is wanted later it can
  be layered on without changing the derivation function. Normal (non-interview) mode never
  force-activates.
- **[DECISION — RESOLVED] Participant request affordance:** resolved to a **persistent affordance
  until acted-on or dismissed** (§4.3) — pulsing own button + lingering chip — chosen over the
  earlier transient toast because the toast conflated "declined" with "never saw it." Host-side
  `"Asked ✓"` + cooldown ships alongside. No force-activation; dismiss is local-only.
- **[DECISION — RESOLVED] Cause-derived single action (mismatch fix):** the per-tile menu shows
  **one primary action derived from the same cause as the caption** (§3/§4.2), so caption and
  action can never contradict — this dissolves the old `"Muted (mute-all)"`-caption-next-to-`Mute`
  mismatch (the `Mute`/`Lock` action now appears only in the live state). Self-muted → `Ask to
  Unmute`; host-muted → `Remove Mute & Ask` (one click, scoped exception to lift≠ask); mute-all →
  `Allow to Speak`. Enforce-`Block mic` kept as a secondary on self/global-muted people. Grounded
  in Google Meet's privacy model (host can mute, not force-unmute), Jakob's & Hick's Laws, and the
  state-drives-action schema (§6.1) from `inter-design-handoff/prinsiples.md`.
- **Final word-smithing (non-blocking):** exact button strings (e.g. `"Remove Mute & Ask"` vs
  `"Unmute & Invite"`, `"Block mic"` vs `"Mute (lock)"`) are settled during implementation. The
  *structure* (one cause-derived primary + optional secondary) is fixed; only the words are open.
- **Live-test dependency:** UI timing (affordance/indicator appearance, caption updates under
  rapid toggles) cannot be verified without a 2-client call; this is the residual risk the phasing
  contains.

---

## 9. Out of scope (future)

Reusing the consent/request primitive for screen-share, suspend, and recording-consent;
a host "dashboard" roster view rendered from the same derivation function.
