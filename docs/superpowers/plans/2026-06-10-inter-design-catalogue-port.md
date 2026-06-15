# Inter — Design Catalogue Port (SwiftUI + AppKit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) to execute this plan **one screen per task** with a review checkpoint between tasks. Steps use checkbox (`- [ ]`) syntax. The authoritative process is `inter-design-handoff/PORTING-PLAYBOOK.md` — **this plan is the execution tracker on top of it**, not a replacement. When this plan and the playbook disagree, the playbook wins.

**Goal:** Recreate the Inter design catalogue's 15 screens in the native macOS app (SwiftUI chrome hosted in AppKit windows; AppKit/Obj-C for call-stage tiles), matching the reference screenshots in both light and dark, with **no dead controls** — every catalogue control is either restyled-over-existing logic or built with real wired logic.

**Architecture:** AppKit keeps owning every `NSWindow` and all security/lifecycle (per the earlier migration research, scope B). New screens are SwiftUI views hosted via `NSHostingController` inside the existing windows; call tiles stay AppKit (`NSView`/Obj-C) on fixed-dark stage colors. All color/type/spacing comes from a single token layer (`DesignTokens.swift`) read by both SwiftUI and AppKit. Source of truth: **live code wins on what-exists/behavior; `DESIGN-SPEC.md` wins on look; STOP-and-ASK on ambiguity; never delete in-progress work** (playbook "Source-of-Truth Ladder").

**Tech Stack:** Swift 5 + Objective-C (module `inter`), SwiftUI, AppKit, `NSHostingController`/`NSViewRepresentable`, General Sans font, XCTest. macOS 15.6 target. Build: `xcodebuild -project inter.xcodeproj -scheme inter -configuration Debug build CODE_SIGNING_ALLOWED=NO`.

---

> ## ⛔ SEQUENCING GATE (user directive, 2026-06-10)
> **This catalogue port does NOT start until the prior work completes:**
> 1. Execute the previous plan `docs/superpowers/plans/2026-06-07-design-system-tile-chrome.md` (tile-chrome design-system).
> 2. Clear all its spikes + the **capture-fidelity BLOCKER** from `docs/superpowers/specs/2026-06-07-swiftui-migration-research.md` (§13): capture fidelity (blocker), S-0 confirmation (non-blocking), S-A6 audit, and the `NSVisualEffectView`-over-live-video spike.
> 3. **Then** begin Task 1 below (the actual UI migration).
>
> **Token reconciliation (confirm):** the previous plan's Task 1 originally built a *bespoke* `InterDesignTokens.swift` bottom-up. The authoritative catalogue token layer (`inter-design-handoff/DesignTokens.swift`) has now arrived. **Recommendation:** re-point that task to **drop in the handoff `DesignTokens.swift`** instead of building a throwaway file; this plan's Task 0 then becomes a no-op for tokens (already done) and only adds the SwiftUI hosting/gallery harness. *Awaiting user confirm — see §F.*

> ## 🧠 NEW-FEATURE DECISION GATE (user directive — applies to EVERY gap)
> When a control/element exists in the handoff but **not** in our app, do **not** auto-build it. For each one:
> 1. **Decide via brainstorm + deep thinking:** do we need it / need it *with modifications* / not need it? (Load the `brainstorming` skill; ASK the user.)
> 2. **If kept:** build it **full-stack** — UI **+ business logic + backend logic** — so the feature actually *works*, not just looks right.
> 3. **It must follow our existing architecture** (e.g. `[G8]` networking isolation, `[G2]` two-phase media, KVO/delegate seams, token-driven styling).
> This **supersedes** the playbook's "wire every GAP" default: the decision-to-build comes first.

---

## How this plan is organized

- **§A — Operating rules** (pointer to the playbook's ladder + gap protocol; read every task).
- **§B — Codebase assessment** (what EXISTS vs GAP vs AHEAD per screen — grounds the work).
- **§C — File structure** (where new SwiftUI lives).
- **Task 0 — Foundation** (tokens, font, appearance, Component Gallery, screenshot protocol). **Hard gate.**
- **Tasks 1–15 — One screen each**, in the playbook's simple→complex order. Each task references its playbook worksheet (`§7.x`) for the full control list + watch-outs, and adds: confirmed target file, reference asset, EXISTS/GAP classification, and done-criteria.
- **§D — Living ledgers** (Discrepancy Log + Gap-Closure Ledger — append as you go).
- **§E — Global Definition of Done.**

> **DRY note:** the playbook's per-screen worksheets (`§7.1`–`§7.15`) are authoritative and in-repo. This plan does **not** duplicate them; it points to them and records the codebase-grounded decisions that turn each into a tracked unit.

---

## §A — Operating rules (read before every task)

1. **Source-of-Truth Ladder** (`PORTING-PLAYBOOK.md` top): for "what exists / what it does" → live code > inventory > mock > screenshot. For "how it looks" → `DESIGN-SPEC.md` + `DesignTokens` > screenshot > mock.
2. **Gap protocol** (playbook §5) **— gated by the New-Feature Decision Gate above.** First classify each control EXISTS / VISUAL / GAP(functional) / AHEAD(live-only). For any GAP/AHEAD-new feature, **brainstorm need/modify/skip with the user FIRST**; only if kept, build it **full-stack** (UI + business + backend) per our architecture. Build VISUAL to spec; preserve + flag AHEAD (never delete).
3. **STOP-and-ASK** triggers: new live-code screen/menu/text no design source mentions; two authoritative sources conflict on behavior/existence; ambiguous intent; a change would modify in-progress work; unclear which real API to wire. Log the question; do not guess.
4. **Visual loop** (playbook §2): build → user provides `out_<id>_<mode>.png` → diff vs `reference-screens/ref_<id>_<mode>.png` in **both** appearances → fix largest diff first → lock. **Never claim a match without the diff** (`verification-before-completion`).
5. **Stage rule:** call/stage surfaces use `InterColor.stage*` (fixed dark in both appearances) and white/neutral text — never theme tokens.
6. **No hardcoded hex in views** — theme via tokens, stage via `stage*`.

---

## §B — Codebase assessment (live inspection, 2026-06-10)

**Foundation:** No SwiftUI UI, no `DesignTokens.swift`, no General Sans font, no `NSHostingController`, no asset catalog exist in the target yet. The only `.swift` files are non-UI (`Networking/`, `Media/`). → Task 0 is fully greenfield. Every screen below already exists as an Obj-C AppKit panel (per `2026-06-08-ui-element-inventory.md`), so each screen task is **restyle + re-host + gap-fill**, not from-scratch.

| # | Screen (`id`) | Target Obj-C file | Assessment | Notable GAPs / AHEAD (verify per §5.1) |
|---|---|---|---|---|
| 1 | `auth` | `InterLoginPanel.m` | **EXISTS** (email/pw, OAuth buttons, strength meter, mode toggle) | OAuth handlers may be GAP (verify wired). |
| 2 | `lobby` | `InterLobbyPanel.m` + `InterLobbyWaitingView.m` | **EXISTS** (admit/deny, count, waiting states) | Mostly restyle. |
| 3 | `teams` | `InterTeamsPanel.m` | **EXISTS** (two-pane, create/invite/members/delete) | **Members-only (user directive):** migrate existing members UI to the design pattern; **do NOT build a channel list** (user has separate plans for Teams). Restyle-only. |
| 4 | `qa` | `InterQAPanel.m` | **EXISTS** (upvote, host highlight/answer/dismiss, anon) | Catalogue **Open/Answered tabs** may be new → GAP. |
| 5 | `poll` | `InterPollPanel.m` | **EXISTS** (create/vote/results bars) | Restyle. |
| 6 | `schedule` | `InterSchedulePanel.m` | **EXISTS** (calendar, form, hosted/invited, join/cancel) | Restyle. |
| 7 | `connection` (Home) | `InterConnectionSetupPanel.m` | **AHEAD-heavy GAP**: app today is fields+buttons+status dot | Identity strip, 4-tile action grid, PMI copy, presence, recents, search, Host-Interview PRO bar are all new. Dev URL fields hidden in release. |
| 8 | `chat` | `InterChatPanel.m` | **EXISTS** (recipient, send, attach, file chips, system msgs) | Catalogue **hover reaction strip** → GAP. |
| 9 | `account` | `InterAccountPanel.m` | **EXISTS** Profile/Password/Email/Sessions/Danger; **AHEAD GAP**: Meeting Defaults / Video / Audio / Background / Security tabs, 2FA badge, timezone+language dropdowns, edit-name, PMI copy are new | Large; build section-by-section. |
| 10 | `pre-meeting` | `InterPreMeetingPanel.m` | **EXISTS** fully | Restyle; shares defaults with Account (one source of truth). |
| 11 | `green-room` | (new screen — routed via pre-meeting flow) | **NEW (GAP, brainstorm-gated):** distinct camera-preview room; does not exist yet | Build when reached, after a **thorough brainstorm** of the pre-meeting ⇄ green-room routing (user's detailed flow — see Task 11). AVCapture device pickers, blur, live preview tile, defaults display, "Meeting Settings" entry. |
| 12 | `secure` (Interviewer) | `SecureWindowController.m` + `InterSecureCodeEditorView.m` + `InterSecureWhiteboardView.m` | **EXISTS** (secure window, editor, whiteboard, tool selector, restricted chat) | Build to **inventory §12**, not the simplified mock. High drift. |
| 13 | `secure-candidate` | `SecureWindowController.m` (candidate role) | **PARTIAL**: candidate-specific chrome (role chip, **read-only** REC, file-share-allowed chat, Leave w/o ⌘Q confirm, no moderation) may be GAP | Verify role split exists; ASK if unclear. |
| 14 | `in-call` | `InterLocalCallControlPanel.m` + tile grid | **EXISTS** (control bar + AppKit tiles); control bar reorganized into 3 zones in catalogue | **React (reactions)** = build full feature (UI + business + backend) per the decision gate. **Raise Hand already exists** → wire/restyle only. Stage-dark. Highest drift. |
| 15 | `host-controls` | `InterLocalCallControlPanel.m` (host mode) | **EXISTS** (recording, share-perm, moderation menu, participants) | **Mute All / Admit All / End for All** may be partial GAP. Interview-tool stays **hidden** here (playbook §7.15). Highest drift. |

---

## §C — File structure (new SwiftUI lives here)

```
inter/
  UI/
    DesignSystem/
      DesignTokens.swift          # drop-in from handoff (the ONE source of truth)
      InterAppearance+Window.swift# helper to apply manual appearance to a hosting window
    SwiftUI/
      Foundation/
        InterHostingController.swift   # generic NSHostingController wrapper (appearance-aware)
        ComponentGallery.swift         # debug window hosting any one screen at fixed size
      Screens/
        AuthView.swift                 # one file per screen (Tasks 1–15)
        LobbyView.swift
        TeamsView.swift
        … (etc.)
      Components/
        InterButtons.swift             # §6 recipes: primary/secondary/danger
        InterField.swift               # text input recipe
        InterBadge.swift               # status badge recipe
        InterCard.swift                # card/panel recipe
        InterStagePopover.swift        # stage-elevated menu recipe
  Fonts/                               # General Sans .otf/.ttf (Regular/Medium/Semibold/Bold)
```

- New files auto-join the target (`PBXFileSystemSynchronizedRootGroup`) — **no `project.pbxproj` edits**.
- Obj-C panels are **replaced screen-by-screen**: a panel's content view becomes an `NSHostingController<SomeScreenView>` swapped into the existing window; the Obj-C controller/logic stays as the wiring backend until fully migrated. Delete an Obj-C view only after its SwiftUI replacement is locked **and** all its logic is re-homed/were-bridged (preserve-in-progress rule).

---

## Task 0 — Foundation (HARD GATE: no screen work until all pass)

**Files:**
- Create: `inter/UI/DesignSystem/DesignTokens.swift` (copy from `inter-design-handoff/DesignTokens.swift`)
- Create: `inter/UI/DesignSystem/InterAppearance+Window.swift`
- Create: `inter/UI/SwiftUI/Foundation/InterHostingController.swift`
- Create: `inter/UI/SwiftUI/Foundation/ComponentGallery.swift`
- Create: `inter/Fonts/` (General Sans faces — **user provides the font files**, README §"Also bring")
- Modify: `inter/Info.plist` (add `ATSApplicationFontsPath = Fonts`)
- Test: `interTests/InterDesignTokensTests.swift`

- [ ] **Step 1 — Drop in tokens.** Copy `inter-design-handoff/DesignTokens.swift` into `inter/UI/DesignSystem/`. Build. Expected: `** BUILD SUCCEEDED **`, no errors.

- [ ] **Step 2 — General Sans is installed (DONE).** Four desktop weights are bundled in `inter/Fonts/` (Regular/Medium/Semibold/Bold `.otf`) + `FFL.txt` license, fetched from the official Fontshare family zip and verified as OpenType (sha256 logged in §D). Remaining: confirm Target Membership is on for `inter/Fonts/*.otf`, and add `ATSApplicationFontsPath = Fonts` to `Info.plist` **or** call `InterFont.registerBundledFonts()` at launch.

- [ ] **Step 3 — Verify the font resolves (test, not eyeball).** Add `interTests/InterDesignTokensTests.swift`:

```swift
import XCTest
import AppKit
@testable import inter

final class InterDesignTokensTests: XCTestCase {
    func testGeneralSansResolvesNotSFFallback() {
        let f = NSFont(name: "General Sans", size: 24)
        XCTAssertNotNil(f, "General Sans is not registered/bundled")
        XCTAssertEqual(f?.familyName, "General Sans",
                       "Font fell back to \(f?.familyName ?? "nil") — registration failed")
    }
    func testStageColorsAreAppearanceIndependent() {
        // Stage must be the SAME in light and dark (fixed dark).
        let dark = NSAppearance(named: .darkAqua)!
        let light = NSAppearance(named: .aqua)!
        let s1 = InterColor.stageSurface.usingAppearance(dark)
        let s2 = InterColor.stageSurface.usingAppearance(light)
        XCTAssertEqual(s1, s2, "stage-surface must not change with appearance")
    }
    func testThemeColorsDoChangeWithAppearance() {
        let dark = NSAppearance(named: .darkAqua)!
        let light = NSAppearance(named: .aqua)!
        XCTAssertNotEqual(InterColor.background.usingAppearance(dark),
                          InterColor.background.usingAppearance(light),
                          "theme background must differ by appearance")
    }
}
```

> If `InterColor` lacks `stageSurface`/`usingAppearance` helpers with these exact names, adjust the test to the real symbol names from `DesignTokens.swift` (do not invent API).

Run: `xcodebuild test -scheme inter -destination 'platform=macOS' -only-testing:interTests/InterDesignTokensTests 2>&1 | tail -20` → **TEST SUCCEEDED**.

- [ ] **Step 4 — Appearance helper.** Create `InterAppearance+Window.swift` exposing `InterAppearance.apply(_:to: NSWindow)` (default `.dark`) so a hosting window's theme colours resolve and stage colours stay fixed.

- [ ] **Step 5 — Hosting wrapper.** Create `InterHostingController.swift`: a generic `NSHostingController` subclass that applies the manual appearance to its view on `viewDidMoveToWindow`. This is the single seam every SwiftUI screen mounts through.

- [ ] **Step 6 — Component Gallery.** Create `ComponentGallery.swift`: a debug `NSWindow` (behind a debug menu item or launch flag) that hosts any one screen view at a fixed logical size, with an appearance toggle (dark/light). This is where every screen is built and screenshotted. Verify it opens and the toggle flips theme surfaces while a sample stage swatch stays dark.

- [ ] **Step 7 — Native screenshot protocol (document, with the user).** Confirm the repeatable capture method (`screencapture -l<windowID> out_<id>_<mode>.png` at @2x, or Xcode view-debug export). Record it in §D so every screen task can request `out_*` from the user. **The user provides native screenshots** — agents cannot capture a native app.

- [ ] **Step 8 — Reference assets present.** Confirm all 30 PNGs exist in `inter-design-handoff/reference-screens/` (they do, verified). No regeneration needed unless the catalogue changes.

- [ ] **Step 9 — Commit.**
```bash
git add inter/UI/DesignSystem inter/UI/SwiftUI/Foundation inter/Fonts inter/Info.plist interTests/InterDesignTokensTests.swift
git commit -m "feat(design-system): foundation — tokens, General Sans, appearance harness, component gallery"
```
> Commit needs the SSH passphrase typed by the user directly in the terminal.

**Task 0 done-criteria:** tokens compile; font resolves (test green); appearance toggle flips theme + keeps stage dark (test green); Component Gallery hosts a sample view in both modes; native screenshot method confirmed; references present.

---

## Tasks 1–15 — Screens (playbook simple→complex order)

> **Each task's procedure is identical** (the playbook §2 loop). For brevity it is stated once here and **referenced** by every screen task. Per screen, do:
> 1. **Inventory + classify** every control EXISTS/VISUAL/GAP/AHEAD (playbook §5.1) against the live Obj-C target and `2026-06-08-ui-element-inventory.md`.
> 2. **Build** the SwiftUI view from §6 recipes + tokens, hosting it in the Component Gallery; **wire GAP controls** to real methods on the existing Obj-C controller / call engine (playbook §5.3). Preserve any AHEAD live-code control; restyle only; flag it.
> 3. **Request `out_<id>_dark.png` + `out_<id>_light.png` from the user**; diff vs `ref_<id>_*`; fix largest diff first; repeat (≤3 iterations before suspecting a translation pattern, playbook §3).
> 4. **Verify GAP functionally** end-to-end (playbook §5.4); add/extend a test where feasible.
> 5. **Record** classifications + wired methods in §D ledgers; mark the screen **locked** when the per-screen DoD (playbook §8) holds.
> 6. **Commit** (`feat(ui): port <id> screen to SwiftUI`).

Each task below = **one tracked unit** (one subagent in subagent-driven-development).

### Task 1 — `auth` (Login / Register)
- **Worksheet:** playbook §7.1 · **Target:** `inter/UI/Views/InterLoginPanel.m` → `AuthView.swift` · **Surface:** SwiftUI · **Ref:** `ref_auth_{dark,light}.png` · **Drift:** Low.
- **Focus:** mode toggle, password visibility, 4-bar strength meter (real calc), field validation, submit loading, auth failure. **Verify OAuth handlers are wired** (GAP if not).
- **Done:** both modes, both appearances; strength reacts to real input; OAuth + submit perform real auth (or documented-disabled); per-screen DoD.

### Task 2 — `lobby` (Lobby & Waiting)
- **Worksheet:** §7.2 · **Target:** `InterLobbyPanel.m` (+ `InterLobbyWaitingView.m`) · **Surface:** SwiftUI · **Ref:** `ref_lobby_*` · **Drift:** Low.
- **Focus:** admit/decline call the **real** lobby API; count badge binds to live queue; empty state; row-removal animation; participant waiting-state machine (joining/waiting/denied/admitted).
- **Done:** admit/decline move real participants; badge reflects real count; both appearances.

### Task 3 — `teams`
- **Worksheet:** §7.3 · **Target:** `InterTeamsPanel.m` → `TeamsView.swift` · **Surface:** SwiftUI (two-pane) · **Ref:** `ref_teams_*` · **Drift:** Low–Med.
- **User directive:** **migrate the existing MEMBERS UI** to the design pattern only. **Do NOT build a channel list** — Teams has a separate roadmap the user owns. Restyle existing create/invite/members/remove/delete; classify those as EXISTS (restyle), not new GAPs.
- **Done:** selection drives detail pane; existing actions restyled and still wired; both appearances; no new channel feature added.

### Task 4 — `qa`
- **Worksheet:** §7.4 · **Target:** `InterQAPanel.m` → `QAView.swift` · **Surface:** SwiftUI · **Ref:** `ref_qa_*` · **Drift:** Low.
- **Focus:** upvote/highlight/answer/dismiss wired; row tints; anonymous tag; empty state. **Verify Open/Answered tabs** (GAP if new — wire real filter).
- **Done:** tabs filter real data; pin/answer reorder; counts bind; empty states.

### Task 5 — `poll`
- **Worksheet:** §7.5 · **Target:** `InterPollPanel.m` → `PollView.swift` · **Surface:** SwiftUI · **Ref:** `ref_poll_*` · **Drift:** Low.
- **Focus:** result bars animate from **real** vote distribution; live count binds; pre-vote vs results vs ended states; winning-option emphasis.
- **Done:** bars reflect real votes; live count binds; both appearances.

### Task 6 — `schedule`
- **Worksheet:** §7.6 · **Target:** `InterSchedulePanel.m` → `ScheduleView.swift` · **Surface:** SwiftUI (`LazyVGrid` calendar) · **Ref:** `ref_schedule_*` · **Drift:** Med.
- **Focus:** 7-col grid math matches ref; selection + month nav; form validation; "Schedule Meeting" creates a **real** meeting; hosted/invited filter; join/cancel rows.
- **Done:** grid matches; nav + selection work; create wired; both appearances.

### Task 7 — `connection` (Home / Launch)
- **Worksheet:** §7.7 · **Target:** `InterConnectionSetupPanel.m` → `HomeView.swift` · **Surface:** SwiftUI · **Ref:** `ref_connection_*` · **Drift:** Med (**AHEAD-heavy**).
- **Focus (mostly GAP):** identity strip (avatar/name/PMI mono **tap-to-copy**/presence dot); 4-tile action grid (New Meeting primary violet → start; Join → join flow; Schedule → sheet; Share → screen-share session); join-by-code field (auto-upper, 6-char, strip confusables — **real input handling**); Host-Interview PRO bar; recents (row + copy code + Start). **Dev WebSocket/Token fields hidden in release** (debug flag).
- **Done:** primary actions wired; copy works; code field sanitizes; dev fields hidden in release; both appearances.

### Task 8 — `chat`
- **Worksheet:** §7.8 · **Target:** `InterChatPanel.m` → `ChatView.swift` · **Surface:** SwiftUI · **Ref:** `ref_chat_*` · **Drift:** Med (bubbles).
- **Focus:** own(trailing violet)/others(leading secondary)/DM(purple) bubble alignment (classic flex→HStack drift); send posts real messages; recipient routes DMs; attach picks + enforces 10 MB; **hover reaction strip** (GAP — wire or visibly disable); empty thread; send-disabled-when-empty.
- **Done:** send/recipient/attach real; reactions wired or disabled; bubbles match both modes.

### Task 9 — `account` (Account & Settings)
- **Worksheet:** §7.9 · **Target:** `InterAccountPanel.m` → `AccountView.swift` · **Surface:** SwiftUI · **Ref:** `ref_account_*` · **Drift:** Med (**volume + AHEAD**).
- **Build section-by-section, screenshot each.** Existing: Profile/Password/Email/Sessions/Danger. **AHEAD GAPs:** Meeting Defaults, Video, Audio, Background, Security tabs; 2FA badge+toggle; timezone+language dropdowns; edit-name; PMI copy. Each GAP wires to a **real** account API (revoke session, change pw, send verification, 2FA, delete account, device test) per §5; pro-gating reflects real entitlement; Meeting Defaults shares one source of truth with Pre-Meeting.
- **Done:** every toggle/dropdown persists to real defaults; security actions perform real effects; destructive confirm; pro gating real; both appearances.

### Task 10 — `pre-meeting` (sheet)
- **Worksheet:** §7.10 · **Target:** `InterPreMeetingPanel.m` → `PreMeetingSheet.swift` · **Surface:** SwiftUI sheet · **Ref:** `ref_pre-meeting_*` · **Drift:** Med.
- **Focus:** conditional password reveal (animate height); ⏎ starts; pro-gated recording + amber callout; settings flow into the **real** meeting config and **share one source of truth with Account → Meeting Defaults**.
- **Done:** conditional fields reveal; ⏎ starts; settings configure the real session; pro gating real.

### Task 11 — `green-room`  *(NEW screen — brainstorm gate REQUIRED before building)*
- **Worksheet:** §7.11 · **Target:** new `GreenRoomView.swift` (routed via the pre-meeting flow) · **Surface:** SwiftUI + **AppKit preview tile** (`NSViewRepresentable`, stage-dark) · **Ref:** `ref_green-room_*` · **Drift:** Med–High.
- **⚠️ Mandatory brainstorm gate (user directive):** load the `brainstorming` skill and design the **pre-meeting ⇄ green-room routing** with the user before coding. The user's intended flow (the pre-meeting form is **kept**, not deleted — only *when* it auto-appears changes):
  - **First-time meeting creators** (no defaults yet) see the **Pre-Meeting Setup form**, set their settings, and proceed. (Same as today.)
  - **Once defaults are saved** (implicitly on first use, or explicitly via the settings panel), that full form **no longer auto-appears**. Instead the user lands in the **Green Room**, which shows their **current defaults** (read-only summary) + **Meeting Name** + **optional Password** inline.
  - The green room has a **"Meeting Settings"** button labelled e.g. **"Using default settings. Want to change?"** — clicking it opens the **same pre-meeting form** (now as a modal/sheet) to modify defaults or any advanced setting.
  - Net: the form **still exists and is fully reachable**; it simply changes from an *auto-shown gate* (first run) to an *on-demand sheet* (after defaults exist), surfaced through the green room. The current behaviour — a panel that appears showing defaults + name + optional password + advanced-modify — maps onto the green room + its Meeting Settings sheet.
- **Focus (GAP-heavy, only after the gate):** live camera preview tile (stage, fixed dark even in light mode); editable name overlay; blur toggle (**real** background processor); device rows (mic/cam/speaker on-off + caret → **real AVCapture device picker**); "Test speaker & microphone…"; room code mono; network dot; **defaults summary**; **Meeting Name + optional Password inline**; **"Meeting Settings" → pre-meeting form sheet**; "Join Now" enters the **real** room; "Join without video".
- **Done:** routing matches the agreed brainstorm design; the pre-meeting form is preserved (first-run gate + on-demand sheet); preview shows real camera; device pickers list + switch real devices; defaults summary + name/password present; join enters room; stage stayed dark in light mode.

### Task 12 — `secure` (Secure Interview — Interviewer)
- **Worksheet:** §7.12 (build to **inventory §12**, not the simplified mock) · **Target:** `SecureWindowController.m` + `InterSecureCodeEditorView.m` + `InterSecureWhiteboardView.m` · **Surface:** AppKit-heavy + SwiftUI chrome · **Ref:** `ref_secure_*` · **Drift:** High.
- **Focus:** Exit (⌘Q confirm) + Chat (⌘⇧C) overlay; control panel with **visible Off/Code/Board tool selector** (only screen it appears), hidden share-mode dropdown + system-audio toggle; stage center video↔tool; preview rail (selected = 2px blue); Code editor (13pt mono, **all smart-substitutions OFF**, ⌃F, ⌘Z); whiteboard (3pt pen, 32pt grid); restricted chat overlay. **Editor keeps `#1e1e2e/#cdd6f4` theme (not a stage token).** Do **not** add scoring/console UI from the mock.
- **Done:** tool selector drives shared surface; editor edits with substitutions off; whiteboard draws; chat restrictions enforced; matches **inventory §12**; both modes.

### Task 13 — `secure-candidate` (Secure Interview — Candidate)
- **Worksheet:** §7.13 · **Target:** `SecureWindowController.m` (candidate role) · **Surface:** AppKit-heavy + SwiftUI chrome · **Ref:** `ref_secure-candidate_*` · **Drift:** High.
- **Focus:** "Candidate" role chip + E2E chip; **read-only** REC indicator (no record controls); Off/Code/Board selector over **their own** editable surfaces; Share Tool publishes selected surface; chat overlay with **file sharing ALLOWED**; **Leave** (no ⌘Q confirm); **no moderation affordances**. **Verify the candidate role split exists in `SecureWindowController`** (ASK if unclear).
- **Done:** candidate picks tool + Share publishes; editor editable, substitutions off; chat attaches a file; REC visible-not-controllable; no moderation; matches ref both modes.

### Task 14 — `in-call` (In-Call Window)
- **Worksheet:** §7.14 · **Target:** `InterLocalCallControlPanel.m` + AppKit tile grid · **Surface:** AppKit tiles + SwiftUI control bar · **Ref:** `ref_in-call_*` · **Drift:** Highest · **Frame:** ~16:9, `max-w-4xl`. **Everything here is stage (fixed dark).**
- **Focus:** tile chrome as absolute overlays (name scrim bottom-left, mic state bottom-right red-when-muted, ✋ raise-hand top-left amber, co-host top-right, **active-speaker emerald inset ring that doesn't shift layout**); 3-zone control bar (primary mic/cam+device chevrons · secondary Participants/Chat/Share/React/RaiseHand/More · destructive Leave isolated right). Every control wires to the **real** call engine — **no dead call buttons**; counts/badges bind to live state.
- **GAP decisions (user directive):** **React (reactions) = BUILD the full feature** — UI + business logic + backend (broadcast/receive reactions over the existing data-channel/signaling layer, following `[G8]` isolation), not just the tray UI. **Raise Hand already exists** → wire/restyle to the existing logic. Both go through the New-Feature Decision Gate brainstorm for exact behavior (emoji set, persistence, who-sees-what) before building React.
- **Done:** tiles render real video; chrome reflects real participant state; every control performs its real call action (incl. a working React feature end-to-end); ring/badges correct; stage dark in both app appearances; matches ref.

### Task 15 — `host-controls` (Host In-Meeting Controls)
- **Worksheet:** §7.15 · **Target:** `InterLocalCallControlPanel.m` (host mode) · **Surface:** AppKit + SwiftUI · **Ref:** `ref_host-controls_*` · **Drift:** Highest · **Frame:** `1040×596`.
- **Focus:** host control-bar additions (Recording start/stop + elapsed timer; Recordings folder; Screen-Share Permission segmented Everyone/Ask/Host-Only); **per-tile moderation menu** (stage-elevated popover, 13pt items): Mute/Unmute Mic, Mute/Unmute Camera, Pin for All(≤5), Make/Remove Co-Host, Rename…, **Remove from Meeting**(red, confirm); Participants panel (per-row mic, Admit All, Mute All); End actions (Leave vs **End for All**, confirm). **Interview-Tool selector stays HIDDEN here** (only Secure shows it). Every moderation item is a **real** host action; destructive paths confirm.
- **Done:** all host actions perform real effects on real participants; recording works with live timer; segmented changes real share permission; destructive confirm; stage dark; matches ref at 1040×596 both modes.

---

## §D — Living ledgers (append as you execute)

### Discrepancy Log
`{ screen, sourceA ↔ sourceB, differs(look|behavior|existence), resolution OR "ASKED: <q>" }`
- _(empty — populate per screen)_

### Gap-Closure Ledger
`{ screen, control, classification(EXISTS|VISUAL|GAP|AHEAD), wired method, test state }`
- _(empty — populate per screen)_

### Native screenshot method (filled in Task 0 Step 7)
- _(record the exact command/process here)_

---

## §E — Global Definition of Done (whole port)
- [ ] All 15 screens locked (per-screen DoD: matches ref both modes; stage stayed dark; all states; no dead controls; General Sans renders; AA contrast; no hardcoded hex).
- [ ] Appearance toggle flips every theme surface; stage stays fixed in both.
- [ ] Gap-Closure Ledger complete: every GAP has wired method + verification.
- [ ] Discrepancy Log complete: every conflict (incl. live-code-ahead) resolved or asked.
- [ ] One pass comparing full app navigation against `Layout.tsx` (sidebar categories, routing) for structural parity.

---

## §F — Resolved decisions & gates (user answers, 2026-06-10)

| # | Topic | Decision |
|---|---|---|
| 1 | General Sans font | **DONE** — agent fetched + verified the four weights into `inter/Fonts/` from the official Fontshare zip (data-only, no package manager). |
| 2 | Green Room ⇄ Pre-Meeting | **NEW screen, brainstorm-gated** (Task 11). The pre-meeting form is **KEPT** — first-time creators still see it; once defaults are saved it stops **auto-appearing** and is reached on-demand from the green room's **"Using default settings. Want to change?"** button. Green room shows current defaults + inline Meeting Name/optional Password. Full brainstorm when reached. |
| 3 | Teams | **Members-only restyle** (Task 3). Do NOT build channels; user owns a separate Teams roadmap. |
| 4 | Secure-candidate role split | **Research when reached** (Task 13) — verify/brainstorm the candidate vs interviewer role path in `SecureWindowController`. |
| 5 | In-call React / Raise Hand | **Build React full-stack** (UI+logic+backend); **Raise Hand already exists** → wire/restyle (Task 14). |
| 6 | Sequencing | **Previous plan first.** Execute `2026-06-07-design-system-tile-chrome.md` + all spikes + the capture-fidelity **blocker**, THEN start this catalogue port. |
| — | **Global operating rule** | **New-Feature Decision Gate:** every handoff element absent from our app → brainstorm need/modify/skip → if kept, build **full-stack** (UI+business+backend) following our architecture. Ask via `brainstorming` on any ambiguity throughout. |

**One remaining confirmation (blocks nothing now; needed before the previous plan's token task runs):**
- The previous plan's Task 1 built a *bespoke* `InterDesignTokens.swift`. Now that the authoritative `inter-design-handoff/DesignTokens.swift` exists, should that task instead **drop in the handoff token file** (recommended), so we don't build-then-discard? *(Default if unanswered: yes, use the handoff tokens.)*

---

## Self-Review (writing-plans)
- **Spec coverage:** all 15 catalogue screens have a task; Task 0 covers the foundation gate (tokens/font/appearance/gallery/screenshot) the playbook §1 requires. ✔
- **Placeholder scan:** no TBD/TODO; each task names the confirmed target file, the reference asset, the classification, and concrete done-criteria; full control lists are referenced (not duplicated) from the in-repo authoritative worksheets. ✔
- **Consistency:** symbol names used in Task 0 tests are flagged to match the real `DesignTokens.swift` API rather than invented. Target files match `screens.ts` `source:` fields and the live inventory. ✔
- **Scope:** one plan, one shared foundation, 15 ordered units — matches the playbook's single ordered port and subagent-driven execution. ✔
- **Known ambiguities** are NOT silently resolved — they are recorded in §F (resolved) and kept as brainstorm/ASK gates in Tasks 11 (green-room routing), 13 (secure-candidate role), and 14 (React behavior), plus the one token-reconciliation confirm in §F. ✔
