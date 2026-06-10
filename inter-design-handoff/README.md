# Inter — Design Handoff Package

This folder is a **self-contained** package for porting the Inter catalogue's UI into
the native macOS app (SwiftUI + AppKit). Drop the whole folder into your project repo.

---

## Start here (reading order)

1. **`DESIGN-SPEC.md`** — the authoritative design system (colors, type, spacing,
   radius, elevation, component recipes, **screen archetypes for building screens not in
   the catalogue (§7)**, accessibility). **This wins over any code on *look*.**
2. **`DesignTokens.swift`** — drop-in native token layer (SwiftUI `Color` + AppKit
   `NSColor`, fonts, spacing, radius, shadows, appearance control). Add to your target.
3. **`DesignTokens.md`** — the value reference behind the Swift file (every hex, the
   font-registration steps, and the macOS gotchas: `em`→pt tracking, `lineSpacing` ≠
   CSS `line-height`).
4. **`2026-06-08-ui-element-inventory.md`** — the **authoritative element-level spec**:
   every button/field/dropdown/menu/state, mapped to its real `Inter*.m` source file.
   **When the inventory and a catalogue mock disagree, the inventory wins.**
5. **`PORTING-PLAYBOOK.md`** — the screen-by-screen process: the build→screenshot→
   compare→fix loop, the **gap-handling protocol** (build missing UI + real business
   logic), the React→SwiftUI/AppKit translation table, and 14 per-screen worksheets.

---

## Contents

| Path | What it is | How to use |
|---|---|---|
| `DESIGN-SPEC.md` | Authoritative design rules | Follow it; it wins over code |
| `DesignTokens.swift` | Native tokens (code) | Add to the Xcode target |
| `DesignTokens.md` | Token value reference + gotchas | Look up exact values |
| `2026-06-08-ui-element-inventory.md` | **Authoritative** element/state spec → real `Inter*.m` | Source of truth for *what exists where* |
| `PORTING-PLAYBOOK.md` | The porting process | Work screen-by-screen |
| `reference-screens/` | **30 PNGs** — every screen, light + dark, @2x | The visual ground truth to match |
| `react-reference/` | The original React code (read-only) | Understand *what* to build, not *how* to write Swift |
| `react-reference/mocks/` | 14 screen mocks (`*.tsx`) | Structure + control inventory per screen |
| `react-reference/ui/` | Base UI primitives (shadcn/Radix) | Resolve what `<Button>`, `<Badge>`, etc. render |
| `react-reference/styles/` | `theme.css`, `fonts.css`, … | Source of the tokens (already translated to Swift) |
| `react-reference/screens.ts` | Screen index → real `Inter*.m` source + spec | Maps each screen to its AppKit target file |
| `react-reference/Layout.tsx` | App shell / navigation | Structural parity of the sidebar/routing |
| `scripts/capture-reference.mjs` | Reference screenshot generator | Regenerate `reference-screens/` from the catalogue |
| `prinsiples.md` | UX principles (context) | The "why" behind the rules |

---

## One-line brief for the porting agent

> Recreate these screens exactly in SwiftUI + AppKit. **`DESIGN-SPEC.md` is the
> authoritative system** — follow it over any conflicting code. Use `DesignTokens.swift`
> for all color/type/spacing. Work **one screen at a time** per `PORTING-PLAYBOOK.md`:
> build it, screenshot your build, diff it against the matching `reference-screens/ref_<id>_<mode>.png`
> in **both** light and dark, and iterate until it matches. The `react-reference/` code shows
> structure and controls — **don't port class strings literally**. **No dead controls:** if a
> control isn't in the app yet, build its UI *and* wire its real business logic (playbook §5).
> **Call/stage surfaces stay dark in both appearances.**

---

## Two things to remember

- **Native screenshots are yours to provide.** Browser tools can capture the *web*
  reference automatically, but they cannot screenshot a native macOS app. After each
  porting session, capture your build (both appearances) as `out_<id>_<mode>.png` and
  give them to the agent to diff against `reference-screens/`.
- **Regenerating references** (only needed if you change the catalogue): run the web
  catalogue and `npm run capture` **in the catalogue repo** (not here) — it rewrites
  `reference-screens/`. The script is included for reference.

---

## Known mock ⚠️ inventory discrepancies (inventory wins)

> **General rule for ALL conflicts** (incl. cases where your *live app code* is newer than these
> docs): follow the **Source-of-Truth Ladder & Conflict Resolution** section at the top of
> `PORTING-PLAYBOOK.md`. In short — **live app code wins on what-exists/behavior, `DESIGN-SPEC.md`
> wins on look, never delete in-progress work, and STOP and ask when intent is ambiguous.**

Two catalogue mocks are simplified or ahead of the real app. The agent must build to the
inventory, **not** the mock/screenshot, for these:

- **Host In-Meeting (`host-controls`):** the mock shows an **Interview Tool (Off/Code/Board)**
  segmented control. In the real app this is **hidden in normal calls** — do **not** build it
  into the normal host view. (Inventory §4A.)
- **Secure Interview (`secure`):** the mock shows console output, difficulty tags, and 1–5
  star scoring with "Submit Score" — **none of which exist**. The real Secure window
  (inventory §12) is a full call window with a **Code Editor** + **Whiteboard**, a visible
  **Off/Code/Board** tool selector, an interview stage, a preview rail, and a restricted chat
  overlay. **This is the only screen where the Code/Board tools appear.** The catalogue now has
  **two** secure screens — `secure` (interviewer) and `secure-candidate` (interviewee, the
  active sharer who can also attach files) — both built to inventory §12.

---

## Also bring (not in this folder)

- **General Sans font files** (`.otf`/`.ttf`) to bundle in the app — download from
  fontshare.com/fonts/general-sans (ITF Free Font License; embedding permitted).
  `.woff2` is web-only; use `.otf`/`.ttf` for macOS. See `DesignTokens.md` §2.4.
