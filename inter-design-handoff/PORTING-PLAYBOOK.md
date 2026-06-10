# Inter — Porting Playbook (React catalogue → SwiftUI + AppKit)

> **Purpose.** A step-by-step, screen-by-screen procedure for an AI coding agent to
> reproduce the Inter catalogue **exactly** in the native macOS app (SwiftUI chrome +
> AppKit call tiles), including a protocol for **building any missing UI with real
> business logic** when a catalogue control doesn't exist in the app yet.
>
> **Read these first, in order:**
> 1. `DESIGN-SPEC.md` — the authoritative design system (rules win over code).
> 2. `DesignTokens.swift` + `DesignTokens.md` — the native token layer.
> 3. `2026-06-08-ui-element-inventory.md` — the **authoritative element-level spec**: every
>    button/field/menu/state, mapped to its real `Inter*.m` source. **When the inventory and a
>    catalogue mock disagree, the inventory wins** (the mocks are presentation previews and a
>    few are simplified or ahead of the app — see §7.12 and §7.14).
> 4. This playbook — the *process*.
>
> **Reference (read-only, never ported verbatim):** `react-reference/mocks/*.tsx`,
> `react-reference/Layout.tsx`. These show *what* to build, not *how* to write Swift.
>
> **Golden rule:** design sources show *intent*; the **live app code is the truth of what
> actually exists**; **screenshots are the visual truth-checker**. When they disagree, follow
> the **Source-of-Truth Ladder (READ FIRST)** below — and when intent is genuinely ambiguous,
> **STOP and ask the user**. Never silently guess, and never delete the user's in-progress work.

---

## ⚠️ Source-of-Truth Ladder & Conflict Resolution (READ FIRST)

There are **six** sources and they will disagree — because the user is **actively building the
real app**. The inventory is dated (`2026-06-08`); the mocks/screenshots are snapshots; the
**live code keeps moving** and may contain new screens, menu items, interfaces, or copy that no
design source mentions yet. Resolve every conflict with the ladders below.

### Split the question first
Discrepancies fall into two kinds, each with its **own** ladder:

**A. “What exists / what does it DO?” (behavior, presence, copy, menu items)**
1. **The live app code you are editing** — the ground truth of what currently exists and does.
   It may be **ahead** of every design source.
2. **`2026-06-08-ui-element-inventory.md`** — authoritative *intended* element/state spec, but
   **dated**; may lag the live code.
3. **Mock `*.tsx` behavior** — illustrative; sometimes simplified or ahead (e.g. the Secure mock
   once showed scoring UI that never existed).
4. **Reference screenshots** — show a render; can be **stale**.

**B. “How should it LOOK?” (color, type, spacing, radius, elevation)**
1. **`DESIGN-SPEC.md` + `DesignTokens`** — canonical look & exact values.
2. **Reference screenshots** — current intended look (but may be stale).
3. **Mock `*.tsx`** — loosest; structure only.
   *(The live app code is **not** a visual authority — in-progress code may be unstyled.)*

> Mental model: **live code wins on “what & does,” DESIGN-SPEC wins on “how it looks.”** The
> inventory is the *intended* feature spec; if it disagrees with live code about existence or
> behavior, suspect the **inventory is stale**, verify against the code, and if still unclear, ASK.

### Decision table (the four cases)
| Situation | What it means | Action |
|---|---|---|
| Live code **has** it; design sources **don’t** | The user’s **new in-progress work** (new screen/menu/text/interface) | **PRESERVE it. Never delete.** Restyle to DESIGN-SPEC only. **Flag it** and ask whether it should also enter the catalogue/spec. |
| Design sources **have** it; live code **doesn’t** | A real **GAP** to build | Run the **§5 gap protocol** — build UI **and** wire real logic. |
| Both have it, **behavior differs** | Spec/mock/screenshot may be stale vs live code | **Live code wins on behavior.** Flag it; if the correct behavior is ambiguous → **ASK**. |
| Both have it, **look differs** | Visual drift | **DESIGN-SPEC wins on look.** Conform; update the screenshot via `npm run capture` if the catalogue itself changed. |

### STOP-and-ASK triggers (do not guess — only the user knows intent)
Ask a specific question (state what each source shows and the options you see) when:
- The live code contains a **new screen, menu item, control, or text string** that **no** design
  source mentions — is it intentional new work, and should it be matched/kept/spec’d?
- Two **authoritative** sources conflict on **what a control does** or **whether it should exist**.
- A control’s **intent/label/wording** is ambiguous or appears mid-change.
- Proceeding would **modify or remove** code that looks like **in-progress work**.
- Business logic (an API/method to wire) is unclear or appears renamed.

### Preserve-in-progress rule (hard)
Never delete, overwrite, or “clean up” unfamiliar code, new menu items, new screens, or new copy
in the live app just because the design docs don’t mention them. **Assume it is intentional
in-progress work** until the user confirms otherwise. Conform its *styling* to the spec if you
touch it; do not change its *behavior or presence* without asking.

### Log every conflict
For each discrepancy, append to the **Discrepancy Log** (extends the §5.5 ledger):
`{ screen, sourceA ↔ sourceB, what differs (look | behavior | existence), resolution OR “ASKED: <question>” }`.
This gives the user a single list of where reality diverged from the design — including their own
newer work the agent detected.

---

## 0. Why this process exists (the failure mode it prevents)

When porting blind (read TSX → imagine render → write SwiftUI → imagine render), the
agent never compares its output to the target and **silently drifts** — it produces
something plausible and *believes* it matched. Every rule below exists to force a
**closed feedback loop**: build → capture → compare → fix → re-verify. Accuracy comes
from the loop, not from careful reading.

---

## 1. One-time setup (do before any screen)

**Gate: do not start screen work until all of these pass.**

- [ ] **Tokens compiled.** Add `DesignTokens.swift` to the target. It builds with no errors.
- [ ] **Font registered.** Bundle General Sans `.otf`/`.ttf` (Regular/Medium/Semibold/Bold)
      in `Fonts/`; register via `ATSApplicationFontsPath=Fonts` (Info.plist) or
      `InterFont.registerBundledFonts()`. Verify the family resolves: render a label in
      `Font.custom("General Sans", size: 24)` and confirm it is **not** falling back to
      San Francisco (compare the lowercase `a`/`g` shapes).
- [ ] **Appearance harness.** A manual toggle exists (`InterAppearance.apply(.dark/.light)`),
      default **dark**. Theme colors must visibly switch; stage colors must **not**.
- [ ] **Reference assets present.** Screenshots of all 15 screens in **both** light and
      dark mode, at a known scale. **These are pre-generated** — run `npm run capture`
      (see §2.1) to produce `reference-screens/ref_<id>_<dark|light>.png` (30 PNGs @2x).
      If the folder is missing/stale, regenerate it. Exact matching is impossible without them.
- [ ] **Screenshot tooling for the native app.** A repeatable way to render one screen in
      isolation and save a PNG (see §2.2). Without this, the loop cannot run.
- [ ] **A "Component Gallery" harness** in the app: a debug window that can host any single
      screen view at a fixed size, in either appearance. This is where you build and compare.

---

## 2. The visual feedback loop (run for EVERY screen)

### 2.1 Capture the reference (automated)
The web references are generated by a headless script — **no manual clicking, no
in-editor browser** (which is too small and clips wide screens like the 1040px call
window). The script uses a large fixed viewport, deep-links every screen by URL, renders
both appearances, and captures each mock element full-bleed at @2x.

```bash
npm run dev        # 1. dev server must be up (http://localhost:5173)
npm run capture    # 2. writes reference-screens/ref_<id>_<dark|light>.png (30 files)
```

- Source: `scripts/capture-reference.mjs`. Drives your installed Chrome (`CHANNEL=chrome`).
- Knobs (env): `BASE_URL`, `WIDTH` (default 1680), `HEIGHT` (1050), `SCALE` (2), `OUT_DIR`.
- Screen IDs are the keys in `src/app/data/screens.ts`; routes are `/screen/<id>`.
- **Re-run after any catalogue change** so references never go stale.
- The agent may also capture on-demand with the browser tools (`open_browser_page` →
  `screenshot_page`), but prefer the script — it guarantees size + framing + both modes.

### 2.2 Capture your build (native — YOU provide)
Browser tools **cannot** screenshot a native SwiftUI/AppKit app (it isn't a webpage), so
the native side is captured outside this loop and handed to the agent each session:
- Host the screen in the Component Gallery at the **same logical size** as the mock.
- Capture at @2x (macOS retina) so DPI matches the reference. Options: Xcode view-debug
  export, `screencapture -l<windowID> out.png` (by window id), or `xcrun simctl io … screenshot`.
- Name them `out_<id>_<dark|light>.png` to mirror the references.
- Provide both appearances after each porting session; the agent diffs `out_*` vs `ref_*`.

### 2.3 Compare deliberately (don't eyeball once)
Check, in this order — each is a common drift source:
1. **Layout skeleton** — element positions, alignment, what's left/right/centered, truncation.
2. **Spacing rhythm** — gaps and padding (overlay a 4/8pt grid mentally; see §4 table).
3. **Type** — size, weight, tracking, line-height, color of every text run.
4. **Color** — backgrounds, borders, text, status hues; **and that stage stayed dark**.
5. **Radius / elevation** — corner radii and shadow weight.
6. **States** — hover/press/focus/disabled/empty/active variants (see per-screen states).
7. **Both appearances** — repeat 1–6 for light *and* dark.

### 2.4 Fix the largest diff first, then re-capture
Iterate until diffs are cosmetic-only. **Budget: converge, don't thrash** — if a diff
persists after 3 attempts, it's usually a translation-pattern issue (§3), not a value.

### 2.5 Lock the screen
Record acceptance (the per-screen checklist), then move on. Do **not** revisit locked
screens except for shared-token changes.

---

## 3. React → SwiftUI / AppKit translation reference (high-drift patterns)

These are where "correctly translated" still looks wrong. Internalize before coding.

| React / Tailwind | Native equivalent | Watch-out |
|---|---|---|
| `flex items-center gap-2` | `HStack(spacing: 8)` + `.firstTextBaseline`/`.center` | Default HStack alignment differs; set it explicitly |
| `flex-1` | `.frame(maxWidth: .infinity)` | Greedy fill; combine with `Spacer()` carefully |
| `justify-between` | `Spacer()` between items | Multiple spacers distribute differently than flex |
| `min-w-0 truncate` | `.lineLimit(1).truncationMode(.tail)` + `.layoutPriority` | SwiftUI won't truncate without a width constraint |
| `absolute -top-2 -right-3` | `.overlay(alignment: .topTrailing){ … .offset(x:12,y:-8) }` | Sign of offset flips vs CSS top/right |
| `w-[1040px]` / `height:596` | `.frame(width:1040, height:596)` | Literal OK; verify resize behavior matches |
| `aspect-[16/9]` | `.aspectRatio(16.0/9, contentMode: .fit)` | |
| `grid grid-cols-7` | `LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: …), count: 7))` | Set `spacing` on GridItem *and* the grid |
| `rounded-xl` | `.clipShape(RoundedRectangle(cornerRadius: InterRadius.xl))` | Use `.clipShape` for fills, `.overlay(stroke)` for borders |
| `border border-border` | `.overlay(RoundedRectangle(...).stroke(.interBorder, lineWidth: 1))` | 1px CSS ≈ 1pt; on @2x it's a hairline |
| `shadow-2xl` | `.interShadow(.xxl)` | Native shadows are softer; tune to ref |
| `bg-violet-600/30` (opacity) | `Color(...).opacity(0.30)` | |
| `backdrop-blur` | `.background(.ultraThinMaterial)` or `NSVisualEffectView` | Material ≠ CSS blur; match by eye |
| `hover:` | `.onHover { }` + state | macOS has hover (unlike iOS); reproduce it |
| `transition-colors` | `.animation(.easeInOut(duration:0.15), value:)` | Keep durations subtle |
| Radix dropdown/menu | `Menu` / `NSMenu` / custom popover | Behavior matches; **visual won't** — restyle to spec |
| Radix dialog | `.sheet` / `NSPanel` | Match padding/radius/elevation from recipes |
| `text-[11px]` (dense) | `InterFont.swiftUI(InterFont.Size.dense11)` | Keep exact; don't round to 12 |
| `leading-relaxed` | `NSParagraphStyle.lineHeightMultiple` or `.lineSpacing(...)` | See `DesignTokens.md` §2.3 formula |
| `tracking-widest` (mono codes) | `.tracking(2)` (points) | em→pt conversion |

**Stage rule (call surfaces):** any element on `--stage*` uses fixed-dark stage colors and
white/neutral text — translate to `InterColor.stage*` and **never** to theme colors.

---

## 4. Spacing & value cheat-sheet (memorize)

`gap-1=4 · gap-1.5=6 · gap-2=8 · gap-2.5=10 · gap-3=12 · gap-4=16 · gap-5=20 · gap-6=24`
`p-2=8 · p-3=12 · p-4=16` · `h-7=28 · h-8=32 · h-9=36 · h-10=40`
Radius: `md=8 · lg=10 · xl=14 · 2xl=16` · Heading tracking `-0.018em` · Body `-0.006em`.

---

## 5. GAP-HANDLING PROTOCOL (build missing UI + real business logic)

The catalogue is ahead of the app in places. When a screen shows a control, menu item, or
state your app doesn't have yet, **do not stub or skip it**. Follow this protocol so every
ported control is real and wired.

### 5.1 Detect
While inventorying a screen (per-screen lists below), mark each control as one of:
- **EXISTS** — already implemented in the app's `Inter…Panel.m`/controller. Restyle only.
- **VISUAL-ONLY** — pure presentation (labels, badges, dividers). Build to spec; no logic.
- **GAP (FUNCTIONAL)** — interactive control with no backing logic in the app yet.
- **AHEAD (live code only)** — present in the live app but **not** in any design source: the
  user's newer work. Do **not** remove it; restyle to spec only, **flag it**, and ASK whether it
  should enter the catalogue (see the Source-of-Truth Ladder).

### 5.2 Classify a GAP before building
Answer, briefly, in your working notes:
1. **What is the user intent?** (e.g. "Mute a remote participant.")
2. **Where does the logic belong?** Name the controller/service — typically the screen's
   source file (`source:` field, e.g. `InterLocalCallControlPanel.m`) or the call engine
   (LiveKit room/participant APIs).
3. **What backend/API exists?** Identify the real method to call (e.g. participant
   mute via the call SDK, `revokeSession()` for Sessions, OAuth handler for "Continue with
   Google"). If none exists, define the smallest real interface and a TODO-backed impl —
   **never a no-op disguised as working.**
4. **What states?** default / hover / pressed / disabled / loading / success / error.

### 5.3 Build (UI + logic together)
- Build the **view** to the design spec (tokens, recipe, both appearances).
- Wire the **action** to the real method from 5.2.2/5.2.3. SwiftUI: bind to a `@MainActor`
  view model that calls the controller/SDK. AppKit tile: target/action or delegate back to
  the Obj-C controller.
- Reflect **real state** back into the UI (e.g. mic button shows muted because the
  participant *is* muted, not a local toggle).
- Handle **failure**: show the error state; don't swallow.

### 5.4 Verify a GAP (both axes)
- **Visual:** passes the §2 loop like any other control.
- **Functional:** the action produces the real effect end-to-end (manually exercise it).
  Add/extend a test where feasible.
- **No dead controls:** every button does what its label says or is explicitly,
  visibly disabled with a reason.

### 5.5 Record
In the screen's notes, log: control name, classification, the wired method, and the state of
the test. This becomes the app's gap-closure ledger.

> **Hard rule:** a ported screen may not contain a control that looks interactive but does
> nothing. Either wire it (5.3) or render it in a documented disabled state.

---

## 6. Recommended porting order (simple → complex)

Build confidence and the token pipeline on simple SwiftUI screens; tackle the dense
AppKit call surfaces last. **Order:**

1. Login / Register (`auth`)
2. Lobby & Waiting (`lobby`)
3. Teams (`teams`)
4. Q&A (`qa`)
5. Poll (`poll`)
6. Schedule (`schedule`)
7. Home / Launch (`connection`)
8. Chat (`chat`)
9. Account & Settings (`account`)
10. Pre-Meeting Sheet (`pre-meeting`)
11. Green Room (`green-room`)
12. Secure Interview — Interviewer (`secure`)
13. Secure Interview — Candidate (`secure-candidate`)
14. **In-Call Window (`in-call`)** — AppKit tiles
15. **Host In-Meeting Controls (`host-controls`)** — AppKit tiles + moderation

---

## 7. Per-screen worksheets

> Each worksheet: **target file · surface · drift risk · inventory (with gap flags) ·
> states · screen-specific watch-outs · acceptance criteria.** Inventories are sourced
> from `screens.ts`. Mark each inventory row EXISTS / VISUAL / GAP during §5.1.

### 7.1 Login / Register — `auth`
- **Target:** `inter/UI/Views/InterLoginPanel.m` · **Surface:** SwiftUI · **Drift:** Low.
- **Inventory:**
  - Title label (switches "Sign In to Inter" ↔ "Create an Account") — VISUAL.
  - Button "Continue with Google" — likely **GAP**: wire OAuth→Google.
  - Button "Continue with Microsoft" — likely **GAP**: wire OAuth→Microsoft.
  - Email field (`you@example.com`) — EXISTS/GAP.
  - Password secure field (`Minimum 8 characters`, hidden by default) — EXISTS/GAP.
  - Password-strength meter (4 bars: Weak/Fair/Strong/Very Strong) — **GAP (logic)**: real
    strength calc.
  - Submit "Log In" / "Create Account" — wire to auth.
- **States:** mode toggle (login/register), password visibility, strength levels, field
  validation error, submit loading, auth failure.
- **Watch-outs:** secure field uses `SecureField`; strength bars are a 4-segment row, equal
  widths, color by level (red/amber/emerald). OAuth buttons are secondary style (recipe §6).
- **Accept:** both modes, both appearances; strength meter reacts to real input; OAuth +
  submit perform real auth (or documented disabled).

### 7.2 Lobby & Waiting — `lobby`
- **Target:** `InterLobbyPanel.m` · **Surface:** SwiftUI · **Drift:** Low.
- **Inventory:** waiting-list rows (name + role + wait time) — EXISTS/VISUAL; "Admit" button
  — wire to admit; "Decline" button — wire to reject; count badge "N Waiting" — bind to queue.
- **States:** empty queue, 1 vs many, admit-in-progress, row removal animation.
- **Watch-outs:** "Admit/Decline" must call the real lobby admission API (GAP if absent).
  Count badge is live — bind, don't hardcode.
- **Accept:** admit/decline move real participants; badge reflects real count; empty state shown.

### 7.3 Teams — `teams`
- **Target:** `InterTeamsPanel.m` · **Surface:** SwiftUI · **Drift:** Low–Med (two-pane).
- **Inventory:** team list (left), team cards (name + member count), status tag
  (Active/Inactive), channel list, "Manage Team" — GAP?, "Create Team" — GAP?.
- **States:** selected team, active vs archived styling, hover on rows, empty channels.
- **Watch-outs:** two-pane layout (list + detail) — use `HSplitView`/fixed sidebar width;
  avatars are rounded-full initials; status tag uses emerald (active) / secondary (archived).
- **Accept:** selection drives detail pane; create/manage wired or disabled; both appearances.

### 7.4 Q&A — `qa`
- **Target:** `InterQAPanel.m` · **Surface:** SwiftUI · **Drift:** Low.
- **Inventory:** question rows (prompt + answered/unanswered state), vote counter (N votes),
  "Pin" button — wire, filter/tab badge ("Open" + counts).
- **States:** tabs (Open/Answered/…), empty tab, pinned row, vote count badge, anonymous tag.
- **Watch-outs:** tab count badges use the dense badge recipe; empty state is centered
  `muted-foreground`. Pin elevates ordering (GAP: real reorder logic).
- **Accept:** tabs filter real data; pin reorders; vote counts bind; empty states correct.

### 7.5 Poll — `poll`
- **Target:** `InterPollPanel.m` · **Surface:** SwiftUI · **Drift:** Low.
- **Inventory:** poll prompt, option rows (label + % bar), response badge ("Live • N
  responses"), progress bars 0–100%.
- **States:** pre-vote vs results, anonymous voting note, live count updating, winning option.
- **Watch-outs:** progress bars must animate width on result change; percentages computed
  from real votes (GAP). Badge "Live" uses emerald.
- **Accept:** bars reflect real distribution; live count binds; both appearances.

### 7.6 Schedule — `schedule`
- **Target:** `InterSchedulePanel.m` · **Surface:** SwiftUI · **Drift:** Med (calendar grid).
- **Inventory:** month nav "‹/›", 7-col day grid (selectable), new-meeting form (time picker,
  title field [required], duration dropdown 15–120, lobby checkbox), "Schedule Meeting".
- **States:** selected day, today marker, days with meetings, hosted vs invited filter, form
  validation, schedule success.
- **Watch-outs:** `LazyVGrid` with 7 columns — match cell size/gaps to ref; day-of-week header
  row is `text-[10px]` semibold muted. Schedule action creates a real meeting (GAP).
- **Accept:** grid math matches ref; selection + nav work; form validates; create wired.

### 7.7 Home / Launch — `connection`
- **Target:** `InterConnectionSetupPanel.m` · **Surface:** SwiftUI · **Drift:** Med.
- **Inventory:** identity strip (avatar+name, Personal Meeting ID monospace tap-to-copy,
  presence dot), 4-tile action grid (New Meeting / Join / Schedule / Share), join-by-code field
  (auto-uppercase, 6-char, strips confusables), Host Interview (PRO), recent meetings (row +
  copy code + Start).
- **States:** presence (online/away/DND), copy confirmation, join validation/disabled, hosted
  room-code reveal, recent hover actions.
- **Watch-outs:** **dev-only** WebSocket/Token fields are hidden in production — gate behind a
  debug flag, do not show in the ported home. Action tiles: first is primary (violet), rest
  secondary. Code field logic (confusable stripping) is real input handling.
- **Accept:** primary actions wired (New Meeting → start, Join → join flow, Schedule → sheet);
  copy works; code field sanitizes; dev fields hidden in release.

### 7.8 Chat — `chat`
- **Target:** `InterChatPanel.m` · **Surface:** SwiftUI · **Drift:** Med (message bubbles).
- **Inventory:** recipient dropdown (Everyone + individuals), message field, Send, Attach
  (📎, max 10 MB), message rows (sender+time+content; public vs DM color), file chips, hover
  reaction strip.
- **States:** own vs others' bubbles, DM (purple) vs public, file attachment, hover reactions,
  empty thread, send disabled when empty.
- **Watch-outs:** bubble alignment (own = trailing violet, others = leading secondary) — classic
  flex→HStack drift; reaction strip is an absolute overlay (offset signs). Attach enforces 10 MB
  (GAP: real picker + limit). DM routing via recipient (GAP).
- **Accept:** send posts real messages; recipient routes DMs; attach picks+limits; reactions
  wired or disabled; bubbles match ref both modes.

### 7.9 Account & Settings — `account`
- **Target:** `InterAccountPanel.m` · **Surface:** SwiftUI · **Drift:** Med (volume of controls).
- **Inventory (grouped):**
  - **Profile:** avatar, editable name, email (mono), plan badge, 2FA badge, timezone dropdown,
    language dropdown, PMI + copy link.
  - **Password:** current/new(8–72)/confirm fields, Change Password, status label.
  - **Email:** password confirm, new email, Send Verification, status.
  - **Sessions:** Refresh, table (Device 8-char / Started / Last Used / Revoke or "This
    Device"), Danger Zone → Delete Account.
  - **Meeting Defaults / Video / Audio / Background / Security:** many toggles + dropdowns,
    pro-gated recording with amber callout, 4 background presets, device test links.
- **States:** tab/section selection, edit-in-progress, save success/error, pro-gated disabled +
  callout, toggle on/off, "This Device" highlight, destructive confirm.
- **Watch-outs:** large screen — build section-by-section, screenshot each section against ref.
  Many **GAPs** likely (revoke session, change password, send verification, 2FA toggle, delete
  account) — each wires to a real account API per §5. Pro-gating reflects real entitlement.
- **Accept:** every toggle/dropdown persists to real defaults; security actions perform real
  effects; destructive paths confirm; pro gating real; both appearances.

### 7.10 Pre-Meeting Sheet — `pre-meeting`
- **Target:** `InterPreMeetingPanel.m` · **Surface:** SwiftUI sheet · **Drift:** Med.
- **Inventory:** meeting-name field; participant checkboxes (mute mic / camera off / allow
  unmuting); security (waiting room, require password → reveals password field, join before
  host); chat/share/takeover dropdowns; pro-gated recording checkboxes + amber callout;
  Cancel / "Start Meeting ⏎".
- **States:** password field reveal on toggle, pro-gated disabled, validation, keyboard ⏎
  shortcut, sheet present/dismiss.
- **Watch-outs:** conditional reveal (password) — animate height like the mock. ⏎ shortcut on
  Start. Settings persist as defaults (shared with Account → keep one source of truth). Start
  actually configures+launches the session (GAP if not).
- **Accept:** conditional fields reveal; ⏎ starts; settings flow into the real meeting config;
  pro gating real.

### 7.11 Green Room — `green-room`
- **Target:** `InterPreMeetingPanel.m` · **Surface:** SwiftUI + **AppKit preview tile** · **Drift:** Med–High.
- **Inventory:** camera preview (live or avatar) — **AppKit/`NSViewRepresentable`** on stage
  surface; editable name overlay; blur-bg toggle; device rows (mic/cam/speaker with on/off +
  change caret → device picker); "Test speaker & microphone…"; room code (mono); network dot;
  "Join Now"; "Join without video".
- **States:** camera on/off (preview vs avatar), blur on/off, device menus open, network levels,
  name editing, joining.
- **Watch-outs:** the **preview is a stage surface** — fixed dark, even in light mode. Device
  pickers are real enumerations (GAP: AVCapture device list). "Join Now" enters the real room
  (GAP). Blur toggles a real background processor (GAP).
- **Accept:** preview shows real camera; device pickers list real devices and switch; join
  enters the room; stage stayed dark in light mode.

### 7.12 Secure Interview — Interviewer — `secure`  *(the ONLY place the Code/Board tools live)*
- **Target:** `inter/UI/Controllers/SecureWindowController.m` + secure sub-views
  (`InterSecureCodeEditorView.m`, `InterSecureWhiteboardView.m`) · **Surface:** AppKit-heavy
  (full call window + editor/whiteboard) + SwiftUI chrome · **Drift:** High.
  > **Inventory note:** `SecureInterviewMock.tsx` is a *simplified* preview. The real Secure
  > window (inventory §12) is **authoritative** where they differ — it has **no** console-output
  > panel, difficulty/topic tags, 1–5 star scoring, or "Submit Score". Build to the inventory.
- **Inventory (real, per §12):**
  - **Main controls (§12A):** "Exit Session" (⌘Q, confirm alert), "💬 Chat" (⌘⇧C, toggles a
    floating overlay).
  - **Control panel / right sidebar (§12B):** same controls as the in-call bar (§4A / 7.14)
    EXCEPT — the **Tool selector (segmented) "Off" / "Code" / "Board" is VISIBLE here** (this is
    the *only* screen it appears on); Share-mode dropdown **hidden** (always "Share This App");
    System-Audio toggle **hidden**; Share toggle publishes the active *tool surface* only.
  - **Interview stage center (§12C):** switches between Remote-video mode and Tool mode (code
    editor or whiteboard fills the workspace when share is active).
  - **Right rail (§12D):** scrollable preview cards (per remote participant, share card, tool
    preview "Code Preview"/"Whiteboard Preview"); click promotes to center; selected = 2px blue border.
  - **Code Editor (§12E):** `NSTextView`, 13pt mono, white-on-dark; placeholder; ⌃F find bar;
    ⌘Z/⌘⇧Z; **ALL smart substitutions OFF** (smart quotes, autocorrect, autocomplete, spell-check);
    standard right-click menu.
  - **Whiteboard (§12F):** freehand pen only (3pt round stroke), subtle 32pt grid; clear via the
    stage controller; intentionally missing: colors, eraser, undo/redo, shapes, width control.
  - **Chat overlay (§12G):** the §5 chat panel restricted — file share/download disabled (alerts),
    no DM recipient selector, no export; button tint gray (no unread) / blue (visible) / orange
    (unread while hidden).
- **States:** tool Off/Code/Board; share off+no-tool / off+tool-ready / active / paused-tool-switched;
  stage mode (video vs tool); card selected; editor focus/find; chat overlay shown/unread.
- **Watch-outs:** the editor is dark (`#1e1e2e`/`#cdd6f4`) — an intentional editor theme, **not** a
  stage token; keep it. Code editor + whiteboard are real surfaces shared over the session
  (GAP-heavy). The tool selector gates what gets shared. **Smart-substitutions-OFF is a real
  integrity requirement**, not cosmetic. Do not add scoring/console UI from the mock.
- **Accept:** tool selector switches Code/Board and drives the shared surface; editor edits with
  substitutions disabled; whiteboard draws; chat overlay enforces its restrictions; matches the
  **real** secure window (inventory §12), not the simplified mock.

### 7.13 Secure Interview — Candidate — `secure-candidate`  *(the interviewee's side)*
- **Target:** `inter/UI/Controllers/SecureWindowController.m` (candidate role) · **Surface:**
  AppKit-heavy (editor/whiteboard) + SwiftUI chrome · **Drift:** High.
  > Same secure window as §7.12 but from the **candidate's** perspective. The candidate is the
  > **active sharer**: they choose a tool and publish their own surface.
- **Inventory:**
  - **Top bar:** E2E Encrypted + "Candidate" role chip; **read-only recording indicator**
    (`REC HH:MM:SS` — they see it, cannot start/stop it); Chat (⌘⇧C); **Leave** (no ⌘Q
    moderator confirm).
  - **Share tool selector (segmented):** "Off" / "Code" / "Board" — candidate picks which of
    *their* surfaces to share.
  - **Code editor (their own, EDITABLE — not collaborative):** they type the solution; smart
    substitutions OFF; ⌃F find; 13pt mono on `#1e1e2e`.
  - **Whiteboard (their own):** freehand pen, 32pt grid.
  - **Center stage + right rail:** interviewer preview card (promote to center) + their shared
    tool preview ("Your Code" / "Your Board") with a live-share dot.
  - **Controls:** Mic / Camera / **Share Tool** (publishes the selected surface) | **Leave Interview**.
  - **Chat overlay:** **file sharing ALLOWED** for the candidate (attach enabled); still no DM
    recipient selector and no export.
- **States:** tool Off/Code/Board; share off+no-tool / off+tool-ready / active / paused; stage
  shows interviewer vs their tool; editor focus; chat open + file message.
- **Watch-outs:** the recording indicator is **read-only** — do NOT give the candidate recording
  controls. **No moderation** (no three-dot menus, no participant management). The editor is the
  candidate's own surface (only they type) — not a collaborative buffer. Stage surfaces stay
  fixed-dark in both appearances; the editor keeps its `#1e1e2e`/`#cdd6f4` theme.
- **Accept:** candidate picks a tool and the Share button publishes that surface; editor is
  editable with substitutions off; chat allows attaching a file; recording shows but is not
  controllable; no moderation affordances; matches `ref_secure-candidate_*` both modes.

### 7.14 In-Call Window — `in-call`  *(AppKit tiles)*
- **Target:** `InterLocalCallControlPanel.m` · **Surface:** **AppKit tile grid + SwiftUI control
  bar** (your stated split) · **Drift:** Highest · **Frame:** ~16:9, `max-w-4xl`.
- **Inventory:**
  - **Tile grid** — AppKit `NSView` tiles on `stage-surface`; per-tile chrome: name label over
    bottom scrim, mic state (red when muted), ✋ raise-hand badge (top-left amber), co-host tag
    (top-right), active-speaker emerald ring.
  - **Control bar (3 zones):** primary (Mic + chevron device menu, Camera + chevron), secondary
    (Participants[count], Chat[unread], Share, React, Raise Hand, More), destructive (Leave, red,
    isolated right).
- **States:** mic/cam on-off, sharing on, speaking (ring), hand raised, unread/participant
  counts, device menus open, compact tile vs normal, reactions tray, more-overflow menu.
- **Watch-outs:** **everything here is stage (fixed dark).** Tile chrome is absolutely-positioned
  overlays — use `.overlay(alignment:)`/AppKit frame math, mind offset signs. Active-speaker ring
  is a colored border that must not shift layout (inset, not added size). Device chevron menus are
  real device enumerations (GAP). Every control wires to the real call engine (mute, video,
  share, leave) per §5 — **no dead call buttons.** Counts/badges bind to live state.
- **Accept:** tiles render real video; chrome states reflect real participant state; every
  control performs its real call action; ring/badges correct; stage dark in both app appearances;
  side-by-side matches ref.

### 7.15 Host In-Meeting Controls — `host-controls`  *(AppKit tiles + moderation)*
- **Target:** `InterLocalCallControlPanel.m` (host mode) · **Surface:** AppKit + SwiftUI · **Drift:** Highest · **Frame:** `w-[1040px] × 596`.
- **Inventory:**
  - Host control-bar additions: Recording (start/stop + elapsed timer), Recordings folder,
    Screen-Share Permission segmented (Everyone/Ask/Host Only).
    *(The "Interview Tool" Off/Code/Board segmented exists in the control-panel code but is
    **HIDDEN in normal calls** — it appears only in the Secure Interview window, §7.12. Do **not**
    render it in normal host mode, even though `HostInMeetingMock.tsx` shows it.)*
  - **Per-tile moderation menu** (three-dot, host only): Mute/Unmute Mic, Mute/Unmute Camera,
    Pin for All (≤5), Make/Remove Co-Host, Rename…, **Remove from Meeting** (red).
  - Participants panel: per-row mic toggle, Admit All Waiting, Mute All.
  - End actions (isolated right): Leave (host leaves, call continues), **End for All**.
- **States:** recording active/paused + timer, share-permission selection, menu open per tile,
  co-host/pin/lock states, session states (active/waiting/all-left), network quality cycling.
- **Watch-outs:** stage popover menu uses `stage-elevated` + `text-[13px]` items (recipe §6).
  Every moderation item is a **real host action on a real participant** (GAP-heavy: mute/remove/
  promote/pin/rename) — wire each to the call engine; destructive items (Remove, End for All)
  require confirm. Recording controls drive the real recorder + timer.
- **Accept:** all host actions perform real effects on real participants; recording works with
  live timer; segmented control changes the real share permission; destructive paths confirm; stage
  dark; matches ref at 1040×596 both appearances.

---

## 8. Definition of Done (per screen)

A screen is **locked** only when ALL hold:
- [ ] Side-by-side vs reference matches in **both** light and dark (layout, spacing, type,
      color, radius, elevation).
- [ ] Stage/call surfaces stayed **dark in light mode**.
- [ ] Every interactive state from the worksheet is reproduced.
- [ ] **No dead controls** — each is wired to real business logic (§5) or visibly disabled
      with a reason.
- [ ] All GAP controls have: spec-built UI + wired action + reflected real state + error
      handling + a recorded ledger entry.
- [ ] General Sans renders (no SF fallback); tracking/line-height per `DesignTokens.md`.
- [ ] Accessibility: AA contrast, visible focus, ≥32pt targets, state not by color alone.
- [ ] No hardcoded hex in views (theme via tokens; stage via `stage*` vars).

## 9. Global Definition of Done (whole port)
- [ ] All 15 screens locked.
- [ ] Appearance toggle flips every theme surface; stage stays fixed.
- [ ] Gap-closure ledger complete: every GAP listed with wired method + verification.
- [ ] **Discrepancy Log complete:** every conflict (incl. live-code-ahead findings) recorded
      with its resolution or the question raised to the user.
- [ ] One pass comparing the full app navigation against `Layout.tsx` (sidebar, categories,
      screen routing) for structural parity.

---

## 10. Anti-patterns (do NOT do these)
- ❌ Porting all screens in one pass without comparing to references.
- ❌ Eyeballing once and declaring a match (run the §2 loop).
- ❌ Leaving interactive-looking controls that do nothing.
- ❌ **Deleting or overwriting live-app code, new menu items, screens, or copy** just because no
  design source mentions them — that is likely the user's in-progress work (preserve + ASK).
- ❌ **Silently guessing** when sources conflict on existence/behavior — STOP and ASK instead.
- ❌ Treating the dated inventory or a stale screenshot as proof a live-code feature is “wrong.”
- ❌ Turning call/stage surfaces light in light mode.
- ❌ Hardcoding hex in views instead of tokens.
- ❌ Rounding the dense scale (`9/10/11/13pt`) up to 12.
- ❌ Using `.lineSpacing(1.5)` thinking it equals CSS `line-height:1.5`.
- ❌ Reimplementing Radix visuals 1:1 — restyle to the native recipes instead.
- ❌ Substituting SF Symbols where lucide parity matters (mixing both for one icon).
