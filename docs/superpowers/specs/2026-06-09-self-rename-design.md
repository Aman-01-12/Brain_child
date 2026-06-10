# Self-Rename Feature — Design Spec

**Date:** 2026-06-09
**Status:** Implemented (brainstorming + paranoid-implementation + decision-council approved; built + tests green)
**Scope:** Allow a participant to change their own display name during a meeting.

---

## 1. Decisions

| Question | Decision |
|---|---|
| Persistence | **Session-only (ephemeral)** — reuses the existing `.renameParticipant` DataChannel mechanism; reverts to the join name on rejoin. No server/DB changes. |
| Where allowed | Normal calls (any participant) **and** the interviewer may self-rename. **Interviewee in an interview room may NOT.** Enforced on the receive side, not just hidden in UI. |
| Entry points | Both the user's own video tile menu **and** the in-call "More" menu. |
| Works for guests | **Yes** — auth-independent (see §6). |

---

## 2. The effective-name model (also fixes a regression)

The app currently has three disconnected name sources: the attested LiveKit
`participant.name` (server-stamped), the host's session rename (a DataChannel-only UI
overlay), and — newly — self rename. The recent anti-spoofing fix reconciles chat /
control-signal names to the *attested* name, which means a host (or self) rename does
not appear in chat. The fix is a single shared resolver:

> **Effective display name = session rename override (if present) → else attested `participant.name`.**

- Add an authoritative map to `InterRoomController`:
  `sessionDisplayNames[identity] = overrideName`, plus `effectiveDisplayName(for:)`.
- The chat + control reconciliation sites switch from `displayNameForParticipantIdentity`
  to `effectiveDisplayName(for:)` → tiles, chat, and notifications all agree, and the
  host-rename chat regression is resolved.
- An accepted `.renameParticipant` (host **or** self) updates this map.

This resolver is required regardless of the rename UI — it is also what fixes the
regression — so it is built and verified FIRST.

### Name surfaces to keep consistent
tile label, chat message, DM recipient picker, moderation/role notifications, speaker
queue, lobby. Audit: no code path that should show the effective name still calls
`displayNameForParticipantIdentity` directly after the change.

---

## 3. Security / enforcement (receive-side, zero-trust)

Replace the moderator-only check on `.renameParticipant` with one rule, evaluated
against the **attested** sender (already reconciled in `InterChatController`):

```
isModerator  = senderRole hasPermission .canMuteOthers
isSelfRename  = (targetIdentity == senderIdentity)
isInterview   = (roomController.roomType == "interview")

accept if:  isModerator || (isSelfRename && !isInterview)
otherwise   discard
```

Yields: host renames anyone ✓; interviewer self-rename ✓ (moderator); normal-call
participant self-rename ✓; **interviewee self-rename blocked** ✗; non-moderator
renaming others blocked ✗.

---

## 4. UI (both entry points)

- **Own tile menu:** add "Rename…" to the local participant's own tile, reusing the
  existing `NSAlert` + text-field dialog used for host renames.
- **"More" menu:** add "Change my name…" invoking the same dialog. Built as a real menu
  (home for future self-service items).
- Both hidden when `localCanSelfRename == false`, where
  `localCanSelfRename = (roomType != "interview") || localIsModerator`.
  Hiding is UX only; §3 is the real gate.
- New `renameSelf(newDisplayName:)` on `InterModerationController` mirroring
  `renameParticipant(identity:newDisplayName:)`: applies locally + broadcasts.

---

## 5. Validation & edge cases

- **Shared sanitizer** (applied to BOTH self and host rename — the host path is currently
  unsanitized): trim whitespace; reject empty-after-trim; cap length (50 chars); strip
  control characters and newlines. Hardens against UI-breaking names and log injection
  (paranoid finding #1).
- **Map cleanup:** remove `sessionDisplayNames[identity]` on `participantDidDisconnect`
  and in `reset()` so the map cannot grow unbounded (paranoid finding #5).
- **Rejoin:** session-only override is lost on reconnect (expected); name reverts to the
  join name.
- **Rename flood:** already mitigated by the 30/s receive-side control-signal limiter.
- **Concurrency:** map mutated only on the main queue (existing `completeOnMain` pattern).

### Deliberate non-goals (v1)
- No in-meeting name **uniqueness** enforcement (normal-call Bob could self-rename to
  "Alice"; identity stays attested and unforgeable). Future option: verified-name badge
  distinguishing attested vs overridden names.
- No persistence across rejoin; no account/profile-wide rename.

---

## 6. Guest (unauthenticated) support

`/room/join` is intentionally not `requireAuth`. Every joiner — authenticated or guest —
receives role metadata stamped into their LiveKit token
(`createToken(..., { role: joinerRole })`). The feature depends only on:
1. a session-only DataChannel signal (no server endpoint, no `req.user`),
2. the sender's LiveKit metadata role (stamped for guests too),
3. identity equality + room type.

All three are auth-independent, so the feature — including the interviewee block —
works identically for guests.

---

## 7. Build order (decision-council mandate)

1. `effectiveDisplayName` resolver + repoint the two reconciliation sites; build and
   confirm the host-rename chat regression is fixed BEFORE any UI.
2. Shared sanitizer + receive-side rename rule.
3. `renameSelf` + both menu entries with gating.
4. Disconnect cleanup for the map.
5. Final build + regression tests.

## 8. Files touched
- `InterRoomController.swift` — resolver map, `effectiveDisplayName(for:)`, disconnect/reset cleanup.
- `InterChatController.swift` — 2 reconciliation sites → `effectiveDisplayName`.
- `InterModerationController.swift` — `.renameParticipant` rule, `renameSelf`, shared sanitizer, map write on accept.
- `AppDelegate.m` — own-tile "Rename…" + "More" menu entry + gating.
- `InterRemoteVideoLayoutManager.m` — (only if local tile menu lives here) own-tile menu item.

No server changes.
