# Inter — Design System Specification

> **Audience:** an AI coding agent porting this catalogue's visual language into a
> production macOS desktop app. **This document is authoritative.** Where a mock
> screen predates a rule below, the rule wins. The mocks in
> `src/app/components/mocks/` are *reference implementations* — copy their
> patterns, but follow the canonical values here when they conflict.
>
> Stack assumed: **React + Tailwind CSS v4** with CSS variables. If the target app
> uses a different stack (SwiftUI/AppKit), translate the **tokens and rules**, not
> the literal class strings.

---

## 1. Brand foundations

| Aspect | Value |
| --- | --- |
| Product | **Inter** — video calling / live interviewing |
| Typeface | **General Sans** (Indian Type Foundry, ITF Free Font License) |
| Brand accent | **Inter Violet** — `#7C3AED` (light) / `#8B5CF6` (dark) |
| Light identity | **Glitter** — pale periwinkle canvas `#E2E5F8` |
| Dark identity | **Deep Obsidian Ink** — canvas `#0B0F19` + slate structure `#1E293B` |
| Always-dark video surfaces | **Stage** ramp `#101012 / #18181b / #27272a` |

### Font loading
```css
@import url("https://api.fontshare.com/v2/css?f[]=general-sans@300,400,500,600,700,301,401,501,601,701&display=swap");
```
Font stack (set on `html`/`body`):
```
"General Sans", ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif
```
Rendering defaults (apply globally): `-webkit-font-smoothing: antialiased`,
`-moz-osx-font-smoothing: grayscale`, `text-rendering: optimizeLegibility`,
base `line-height: 1.5`, body `letter-spacing: -0.006em`, headings `-0.018em`,
paragraphs `line-height: 1.6`.

> macOS note: for a native app, General Sans is the brand face. Use **SF Pro** only
> as the OS fallback. Keep the negative heading tracking — General Sans is a
> geometric sans and reads best slightly tightened at display sizes.

---

## 2. Color tokens (single source of truth)

Never hardcode hex in components. Always reference a semantic token. The catalogue
defines these in `src/styles/theme.css`.

### 2.1 Semantic UI tokens

| Token | Light (Glitter) | Dark (Obsidian) | Use |
| --- | --- | --- | --- |
| `--background` | `#E2E5F8` | `#0B0F19` | App canvas |
| `--foreground` | `#201C34` | `#F1F5F9` | Primary text |
| `--card` / `--popover` | `#F5F6FD` | `#11161F` | Raised surfaces |
| `--secondary` | `#CED2F3` | `#1E293B` | Quiet fills / chips |
| `--muted` | `#D4D7F4` | `#1E293B` | Subtle fills |
| `--muted-foreground` | `#635F89` | `#94A3B8` | **Secondary / helper text** |
| `--accent` | `#C2C6F0` | `#1E293B` | Hover fills |
| `--border` | `rgba(45,40,110,.108)` | `rgba(148,163,184,.14)` | Hairlines |
| `--input-background` | `#D4D7F4` | `#1E293B` | Field fills |
| `--primary` | `#7C3AED` | `#8B5CF6` | Brand actions |
| `--primary-foreground` | `#FFFFFF` | `#FFFFFF` | Text on brand |
| `--ring` | `#7C3AED` | `#8B5CF6` | Focus ring |
| `--destructive` | `#d4183d` | (oklch red) | Danger |

Tailwind usage: `bg-background`, `text-foreground`, `bg-card`, `text-muted-foreground`,
`border-border`, `bg-primary`, `ring-ring`, etc.

### 2.2 Stage tokens — always dark, in BOTH themes

A live call window reads as dark like Zoom/Teams even when the app is in light mode.
These are defined once and never change with theme:

| Token | Value | Use |
| --- | --- | --- |
| `--stage` | `#101012` | Deepest chrome — footers, side rails |
| `--stage-surface` | `#18181b` | Main video canvas / panels |
| `--stage-elevated` | `#27272a` | Menus / popovers / modals on the stage |

Usage: `bg-[var(--stage)]`, `bg-[var(--stage-surface)]`, `bg-[var(--stage-elevated)]`.
On stage surfaces, text is `text-white` / `text-neutral-200/300/400` and dividers
are `border-white/5` and `border-white/10`. **This is the one place white-on-dark
neutrals are correct** — do not convert them to theme tokens (that would turn the
call light in light mode).

### 2.3 Status colors (semantic, same hues in both modes)
- **Success / live:** `emerald` (`emerald-500/600/700`, tint `emerald-50` / `emerald-900/20`)
- **Warning / Pro:** `amber` (`amber-400/500/600`)
- **Danger / leave / record:** `red` (`red-500/600`)
- **DM / private:** `purple`
- **Brand / primary:** `violet`

Use the `-50` / `-900/20` tint + `-700` / `-400` text pairing for badges
(e.g. `bg-emerald-50 dark:bg-emerald-900/20 text-emerald-700 dark:text-emerald-400`).

---

## 3. Typography scale

General Sans, with two scales: a **standard scale** for normal UI, and an explicit
**dense scale** for information-dense surfaces (call HUD, participant rails, status
bars). The dense scale is intentional — do not "round it up" to 12px.

### 3.1 Standard scale (named Tailwind sizes)
| Role | Class | px | Weight |
| --- | --- | --- | --- |
| Display / page title | `text-2xl` | 24 | `font-semibold` |
| Section heading | `text-xl` | 20 | `font-semibold` |
| Subheading | `text-lg` | 18 | `font-semibold` |
| Body / default | `text-base` | 16 | `font-normal` |
| Secondary body | `text-sm` | 14 | `font-normal`/`medium` |
| Caption / label | `text-xs` | 12 | `font-medium`/`semibold` |

Headings carry `line-height: 1.5`; paragraphs `1.6`.

### 3.2 Dense scale (call/HUD micro-text — keep as arbitrary px)
| Role | Class | px |
| --- | --- | --- |
| Compact label / badge | `text-[11px]` | 11 |
| Micro label / count / timestamp | `text-[10px]` | 10 |
| Tag fragment (co-host, "Co") | `text-[9px]` | 9 |
| Menu item (stage popovers) | `text-[13px]` | 13 |

**Rule for the agent:** in dense call UIs reproduce these exact sizes. In normal
app surfaces (settings, schedule, account, auth) prefer the **standard scale** —
use `text-xs` (12px) for labels rather than inventing new px values.

### 3.3 Label convention
Section/eyebrow labels: `text-[10px] font-bold uppercase tracking-widest text-muted-foreground`.
Inline field labels: `text-xs font-medium`. Keep one convention per context; do not
mix `font-semibold` and `font-bold` for the same label role on the same screen.

---

## 4. Spacing & layout

- **Grid:** 4px base (Tailwind default). Prefer the **8px rhythm** (`gap-2`, `p-4`,
  `gap-4`) for structural layout; the 2px sub-steps (`gap-1.5`, `py-2.5`) are
  allowed only for dense controls.
- **Forbidden:** off-scale arbitrary values like `p-[5px]`, `gap-[7px]`,
  `m-[13px]`. Use a named step.
- **Section padding:** cards/panels `p-4` (16px); dense rows `px-3 py-2` (12/8);
  list items `px-3 py-2.5`.
- **Gaps:** icon↔label `gap-1.5`/`gap-2`; field stacks `gap-2`/`gap-3`; card grids `gap-3`.

---

## 5. Radius, elevation, borders

### Radius (standardized — do not introduce `rounded-[Npx]`)
| Token | Use |
| --- | --- |
| `rounded-md` | micro buttons, icon tiles, small badges |
| `rounded-lg` | buttons, inputs, list rows, chips |
| `rounded-xl` | cards, input groups |
| `rounded-2xl` | modals, major panels, call window |
| `rounded-full` | avatars, pills, toggle thumbs |

Base `--radius: 0.625rem` (10px); `lg = --radius`, `md = -2px`, `sm = -4px`, `xl = +4px`.

### Elevation (shadows)
| Class | Use |
| --- | --- |
| `shadow-sm` | resting small controls |
| `shadow-lg` | floating buttons, primary CTAs |
| `shadow-xl` | nested panels |
| `shadow-2xl` | modals, the call window, popovers on stage |

**Colored shadows** only for emphasis CTAs, always at `/20` opacity matching the fill:
`shadow-lg shadow-violet-600/20` (primary), `shadow-lg shadow-red-500/20` (danger).
Do not use other opacities (no `/30`).

### Borders
Hairlines use `border-border`. On stage surfaces use `border-white/5` (quiet) and
`border-white/10` (visible).

---

## 6. Component recipes (canonical)

### Primary button
```
h-10 px-4 rounded-lg bg-violet-600 hover:bg-violet-700 text-white
text-sm font-semibold transition-colors shadow-lg shadow-violet-600/20
```
### Secondary button
```
h-9 px-4 rounded-lg border border-border bg-card hover:bg-accent
text-sm font-semibold text-foreground transition-colors
```
### Danger button
```
h-10 px-4 rounded-lg bg-red-500 hover:bg-red-600 text-white
text-sm font-semibold shadow-lg shadow-red-500/20 transition-colors
```
### Text input
```
h-9 px-3 rounded-lg border border-border bg-card text-sm text-foreground
placeholder:text-muted-foreground focus:outline-none focus:border-violet-400 transition-colors
```
### Card / panel
```
rounded-xl border border-border bg-card p-4 shadow-sm
```
### Badge (status)
```
text-[10px] font-semibold px-1.5 py-0.5 rounded-full
bg-emerald-50 dark:bg-emerald-900/20 text-emerald-700 dark:text-emerald-400
```
### Modal / dialog container
```
rounded-2xl border border-border bg-card shadow-2xl
```
### Stage popover / context menu (on a call)
```
bg-[var(--stage-elevated)] border border-white/10 rounded-xl shadow-2xl
/* items: */ px-3 py-2 text-[13px] text-neutral-200 hover:bg-white/10
```

**Control sizing canon:** primary CTA `h-10` (40px); secondary `h-9` (36px);
inputs `h-9` (36px); compact toolbar buttons `h-7`/`h-8`. Pick from this set —
don't invent intermediate heights.

---

## 7. Screen archetypes & composition patterns

The catalogue's 15 screens reduce to **6 reusable archetypes**. To build a screen that
isn't in the catalogue, pick the matching archetype and compose it from the §6 recipes —
don't invent a new layout language. Each archetype lists structure, the recipes it uses,
and the states it must implement.

### 7.0 Surface selection — modal vs sheet vs popover vs panel vs window
Choose the container **by intent**, not by habit:

| Use | When | Container | Recipe |
| --- | --- | --- | --- |
| **Inline panel** | Persistent side content (chat, participants, Q&A, poll) | Docked panel, full height | header + scroll + footer (§7.4) |
| **Sheet** | A focused task tied to the current window (pre-meeting setup, schedule) | Slide-over / sheet attached to window | `rounded-2xl bg-card` (§6 modal) |
| **Modal/dialog** | A blocking decision that needs an answer (recording consent, destructive confirm, rename) | Centered, backdrop blocks interaction | §6 modal container |
| **Popover / menu** | Contextual actions off a control (device picker, moderation 3-dot, dropdown) | Anchored popover | §6 stage popover (on call) / `bg-popover` (chrome) |
| **Full window** | An independent mode (call, secure interview) | Own window | full-stage (§7.5) |

Rule of thumb: **blocking + needs a decision → modal; focused task → sheet; contextual →
popover; ongoing reference → panel.** Don't use a modal where a popover suffices (Hick's law).

### 7.1 Centered / focused-entry  *(e.g. Login–Register, lobby waiting)*
- **Structure:** one centered card (`max-w-sm`–`max-w-md`), vertical stack, title → fields →
  primary CTA → secondary link. Generous outer padding; everything else quiet.
- **Recipes:** card (§6), input, primary button, secondary/text button.
- **States:** default, validating, field error, submitting (spinner), server error, success.
- **Watch:** one primary action only; secondary actions are links/secondary buttons.

### 7.2 List–detail / two-pane  *(e.g. Teams, Chat roster, recents)*
- **Structure:** fixed-width list rail (`240–280px`) + flexible detail pane. List = scrollable
  rows; detail = header + body. Selection drives the detail.
- **Recipes:** list row (`px-3 py-2.5 rounded-lg hover:bg-muted`), card, badge, avatar.
- **Row anatomy:** leading avatar/icon → title + subtitle (truncate) → trailing meta/actions
  (often reveal on hover). Selected row: subtle `bg-accent` or left accent.
- **States:** nothing selected (empty detail), empty list (centered `muted-foreground`),
  loading skeleton, hover-reveal actions.

### 7.3 Form / settings  *(e.g. Account, Pre-Meeting, Schedule form)*
- **Structure:** grouped sections under eyebrow labels (§3.3); within a section, a vertical
  stack of label-over-field rows (`gap-2`/`gap-3`). Long settings use grouped **tabs**.
- **Recipes:** input, dropdown/select, checkbox/switch, eyebrow label, section card, primary
  CTA, inline status label.
- **Patterns:** conditional reveal (a toggle that exposes a field — animate height); pro-gating
  (disabled control + amber callout); a save action + a transient status line.
- **States:** pristine, edited/dirty, validating, saved (success), error, disabled/locked.
- **Watch:** one settings value = one source of truth (Pre-Meeting ⇄ Account defaults share state).

### 7.4 Live collaboration panel  *(e.g. Chat, Q&A, Poll, Lobby)*
- **Structure:** three vertical zones — **header** (title + live badge + close) / **scroll body**
  (feed of rows) / **footer** (composer or bulk action). Body is the only scroll region.
- **Recipes:** panel header, list row, status badge (`Live • N`), input + send, primary/secondary
  action buttons.
- **Real-time:** counts/badges bind to live state; results bars animate width on change.
- **States (all required):** empty ("No questions yet"), loading, one vs many, item added,
  optimistic-pending, error. Empty/loading are first-class, not afterthoughts.

### 7.5 Full-stage / call surface  *(e.g. In-Call, Host Controls, Green Room preview, Secure)*
- **Structure:** fixed-dark **stage** window — main canvas (tile grid or tool) + a control bar in
  **three zones**: primary (mic/cam, left) · secondary (grouped session actions, center) ·
  destructive (leave/end, isolated right). Optional side rail (participants/preview cards).
- **Tokens:** **always** `--stage` / `--stage-surface` / `--stage-elevated` (fixed dark in both
  app appearances); white/neutral text; dividers `border-white/5` & `/10`.
- **Tile chrome:** name over scrim (bottom-left), mic state (bottom-right), badges as absolute
  overlays (raise-hand top-left amber, co-host top-right), active-speaker = inset colored ring
  (must not shift layout).
- **States:** media on/off, sharing, speaking, hand-raised, recording (read-only for non-hosts),
  counts, menus open, waiting / all-left, compact vs normal tiles.
- **Watch:** controls grouped by frequency + criticality; destructive isolated to prevent mis-taps
  (Fitts's law). No dead call buttons — wire to the engine or disable visibly.

### 7.6 Sheet / modal / dialog  *(e.g. Pre-Meeting sheet, Recording consent, confirms)*
- **Structure:** overlay container (`rounded-2xl bg-card shadow-2xl`), title → body → action row
  (Cancel + primary, primary on the right). Modal has a backdrop that blocks interaction.
- **States:** present/dismiss (animate), validating, submitting, success/close, destructive confirm.
- **Watch:** destructive primaries use the danger recipe and require explicit confirm; support
  ⏎ for the primary and Esc to cancel.

### 7.7 Adding a NEW screen to the app shell
A new screen isn't done until it's reachable and consistent with navigation:
1. **Classify** it into one of the 6 archetypes above; compose from §6 recipes.
2. **Place it** in the sidebar under the right category (mirror `Layout.tsx` / `screens.ts`
   categories: Core Flows / Access / Live Session / Collaboration / Management / Security).
3. **Route + title + description** consistent with siblings; give it the same header treatment.
4. **States:** implement empty/loading/error/first-run for the archetype.
5. **Both appearances**; stage surfaces stay dark.
6. If it has controls not yet in the app, follow the **gap protocol** (PORTING-PLAYBOOK §5);
   if it exists only in live code, follow the **Source-of-Truth Ladder** (don't delete it).

---

## 8. Accessibility rules (enforce)

- **Contrast:** body/secondary text must meet **WCAG AA 4.5:1** (3:1 for ≥18px or
  bold ≥14px). For secondary text use `text-muted-foreground` — it is tuned to pass
  in both themes. **Never** use raw `text-neutral-400`/`text-neutral-500` for
  meaningful text on light/themed surfaces (they fail AA). Raw neutrals are allowed
  **only** as white-on-dark on `--stage` surfaces.
- **Focus:** every interactive element shows a visible focus state (`ring-ring` or
  `focus:border-violet-400`). Don't remove outlines without a replacement.
- **Targets:** primary touch/click targets ≥ 32px (`h-8`) tall; prefer 36–40px.
- **Don't rely on color alone** for state — pair with icon/label (e.g. REC dot + "REC").

---

## 9. Do / Don't for the porting agent

**Do**
- Reference semantic tokens (`bg-card`, `text-muted-foreground`, …) so theming works.
- Use `--stage*` tokens for any live-call surface (keeps it dark in light mode).
- Reuse the component recipes in §6 verbatim where possible.
- For a screen not in the catalogue, pick a **§7 archetype** and compose from §6 recipes.
- Keep General Sans + the negative heading tracking.
- Keep the dense scale (§3.2) for call HUDs; standard scale elsewhere.

**Don't**
- Hardcode hex colors in components (except via the documented `--stage*` vars).
- Use `text-neutral-400/500` for readable text on light surfaces.
- Invent new radii (`rounded-[7px]`) or off-grid spacing (`p-[5px]`).
- Add shadow opacities other than `/20` for colored CTA shadows.
- Turn call/stage surfaces light in light mode.

---

## 10. File map (where the canon lives)

| Concern | File |
| --- | --- |
| Color tokens, stage tokens, base typography | `src/styles/theme.css` |
| Font loading | `src/styles/fonts.css` |
| Tailwind entry | `src/styles/tailwind.css` |
| Theme mode provider (dark/light) | `src/app/context/ThemeContext.tsx` |
| Reference screens | `src/app/components/mocks/*.tsx` |
| Primitive UI components | `src/app/components/ui/*.tsx` |
