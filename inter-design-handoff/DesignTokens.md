# Inter — Design Tokens (macOS / SwiftUI + AppKit reference)

> Companion to `DESIGN-SPEC.md` and `DesignTokens.swift`. This is the **value
> reference** for the native port. Every value here is the exact translation of
> `src/styles/theme.css`. OKLCH source colors were converted to sRGB hex.
>
> **Architecture mapping**
> - **SwiftUI app chrome** → use the **theme** colors (appearance-aware).
> - **AppKit call tiles (Obj-C/NSView)** → use the **stage** colors (fixed dark in both modes).

---

## 1. Color tokens

### 1.1 Theme — appearance-aware (Light = Glitter · Dark = Obsidian)

| Token | Light | Dark | Usage |
| --- | --- | --- | --- |
| `background` | `#E2E5F8` | `#0B0F19` | Window / canvas |
| `foreground` | `#201C34` | `#F1F5F9` | Primary text |
| `card` | `#F5F6FD` | `#11161F` | Raised surface |
| `card-foreground` | `#201C34` | `#F1F5F9` | Text on card |
| `popover` | `#F5F6FD` | `#11161F` | Menus / popovers |
| `secondary` | `#CED2F3` | `#1E293B` | Quiet fills / chips |
| `secondary-foreground` | `#201C34` | `#F1F5F9` | Text on secondary |
| `muted` | `#D4D7F4` | `#1E293B` | Subtle fills |
| `muted-foreground` | `#635F89` | `#94A3B8` | **Secondary / helper text** |
| `accent` | `#C2C6F0` | `#1E293B` | Hover fills |
| `accent-foreground` | `#201C34` | `#F1F5F9` | Text on accent |
| `input-background` | `#D4D7F4` | `#1E293B` | Field fills |
| `switch-background` | `#B7BBE4` | `#1E293B` | Toggle track (off) |
| `border` | `rgba(45,40,110,0.108)` | `rgba(148,163,184,0.14)` | Hairlines |
| `primary` | `#7C3AED` | `#8B5CF6` | Brand actions |
| `primary-foreground` | `#FFFFFF` | `#FFFFFF` | Text on brand |
| `ring` | `#7C3AED` | `#8B5CF6` | Focus ring |
| `destructive` | `#D4183D` | `#82181A` | Danger fill |
| `destructive-foreground` | `#FFFFFF` | `#FB2C36` | Danger text/icon |
| `sidebar` | `#DADDF6` | `#0B0F19` | Sidebar bg |
| `sidebar-foreground` | `#201C34` | `#F1F5F9` | Sidebar text |
| `sidebar-accent` | `#CACEF2` | `#1E293B` | Sidebar hover |
| `sidebar-border` | `rgba(45,40,110,0.087)` | `rgba(148,163,184,0.12)` | Sidebar hairline |

### 1.2 Stage — FIXED DARK in both appearances

> The call window reads dark like Zoom/Teams even when the app is in light mode.
> **Never** make these appearance-aware.

| Token | Value | Usage |
| --- | --- | --- |
| `stage` | `#101012` | Deepest chrome — footers, side rails |
| `stage-surface` | `#18181B` | Main video canvas / panels |
| `stage-elevated` | `#27272A` | Menus / popovers on the stage |

On stage, text is white / light-neutral (`#FFFFFF`, `#E5E5E5`, `#D4D4D4`, `#A3A3A3`)
and dividers are white at 5–10% opacity. This is the one place white-on-dark
neutrals are correct.

### 1.3 Status hues (same in both appearances)

| Role | Hex | Tailwind |
| --- | --- | --- |
| Success / live | `#10B981` | emerald-500 |
| Warning / Pro | `#F59E0B` | amber-500 |
| Danger / leave / record | `#EF4444` | red-500 |
| DM / private | `#9333EA` | purple-600 |
| Brand | `#7C3AED` | violet-600 |

Badges use a tinted bg + saturated text, e.g. light `#ECFDF5` bg / `#047857` text,
dark `rgba(emerald, .2)` bg / `#34D399` text.

### 1.4 Chart palette (only if you build charts)

| Slot | Light | Dark |
| --- | --- | --- |
| chart-1 | `#F54900` | `#1447E6` |
| chart-2 | `#009689` | `#00BC7D` |
| chart-3 | `#104E64` | `#FE9A00` |
| chart-4 | `#FFB900` | `#AD46FF` |
| chart-5 | `#FE9A00` | `#FF2056` |

---

## 2. Typography — General Sans

### 2.1 Standard scale (use in SwiftUI chrome)

| Role | Size (pt) | Weight | CSS origin |
| --- | --- | --- | --- |
| Display / page title | 24 | Semibold | `text-2xl` |
| Section heading | 20 | Semibold | `text-xl` |
| Subheading | 18 | Semibold | `text-lg` |
| Body | 16 | Regular | `text-base` |
| Secondary body | 14 | Regular/Medium | `text-sm` |
| Caption / label | 12 | Medium/Semibold | `text-xs` |

### 2.2 Dense scale (use in AppKit call HUD / rails — keep exact)

| Role | Size (pt) | CSS origin |
| --- | --- | --- |
| Compact label / badge | 11 | `text-[11px]` |
| Micro label / count / time | 10 | `text-[10px]` |
| Tag fragment | 9 | `text-[9px]` |
| Stage menu item | 13 | `text-[13px]` |

### 2.3 Tracking & line-height (the two big gotchas)

- **Tracking:** CSS letter-spacing is in `em`; SwiftUI `.tracking()` is in **points**.
  `points = em × fontSize`. Headings `-0.018em`, body `-0.006em`.
  → 24pt heading = `.tracking(-0.43)`.
- **Line-height:** CSS `line-height` is the **total** line box multiple; SwiftUI
  `.lineSpacing()` only **adds** space between lines. Use
  `lineSpacing ≈ (cssLineHeight − ~1.2) × fontSize`, or for exactness set
  `NSParagraphStyle.lineHeightMultiple = cssLineHeight` (AppKit / attributed text).
  Body paragraphs use `1.6`; everything else `1.5`.

`DesignTokens.swift` has `InterFont.tracking(em:size:)` and
`InterFont.lineSpacing(cssLineHeight:size:)` helpers.

### 2.4 Font bundling & registration (macOS)

1. Download **General Sans** `.otf`/`.ttf` from fontshare.com/fonts/general-sans
   (ITF Free Font License — embedding permitted). **Do not** use `.woff2` (web only).
2. Add the faces (at least Regular, Medium, Semibold, Bold) to the app bundle in a
   `Fonts/` folder, Target Membership checked.
3. Register either way:
   - **Info.plist:** add `ATSApplicationFontsPath` = `Fonts` (auto-registers at launch), **or**
   - **Code:** call `InterFont.registerBundledFonts()` once at startup.
4. Verify the usable name in **Font Book**. If `Font.custom("General Sans", …)` won't
   apply a weight, use the face PostScript name (e.g. `GeneralSans-Semibold`).

---

## 3. Spacing — 4 / 8 pt grid

| Step | Points | CSS | Note |
| --- | --- | --- | --- |
| x1 | 4 | gap-1 | |
| x1.5 | 6 | gap-1.5 | dense controls |
| x2 | 8 | gap-2 | **preferred rhythm** |
| x2.5 | 10 | gap-2.5 | dense controls |
| x3 | 12 | gap-3 / p-3 | dense row padding |
| x4 | 16 | gap-4 / p-4 | **default card padding** |
| x5 / x6 / x8 | 20 / 24 / 32 | | section spacing |

Forbidden: off-grid arbitrary values (no 5, 7, 13 pt). Pick a step.

---

## 4. Corner radius (base = 10 pt)

| Token | Points | Usage |
| --- | --- | --- |
| sm | 6 | checkboxes, tiny items |
| md | 8 | micro buttons, icon tiles |
| lg | 10 | buttons, inputs, list rows, chips |
| xl | 14 | cards, input groups |
| 2xl | 16 | modals, major panels, call window |
| full | — | `Capsule()` / `Circle()` (avatars, pills) |

---

## 5. Control sizing (canonical)

| Control | Height | CSS |
| --- | --- | --- |
| Primary CTA | 40 | h-10 |
| Secondary button | 36 | h-9 |
| Text input | 36 | h-9 |
| Compact button | 32 | h-8 |
| Toolbar button | 28 | h-7 |

Minimum interactive target ≥ 32 pt.

---

## 6. Elevation (shadow approximations — tune visually)

| Token | color · radius · y |
| --- | --- |
| sm | black 10% · 2 · 1 |
| lg | black 18% · 8 · 4 — floating buttons / CTAs |
| xl | black 22% · 14 · 8 — nested panels |
| 2xl | black 28% · 24 · 12 — modals, call window, stage popovers |
| CTA (colored) | **fill color @ 20%** · 10 · 4 — only `/20`, no other opacity |

---

## 7. Icons — lucide + SF Symbols (use both per need)

- The catalogue uses **lucide** (`lucide-react`). For **pixel-exact** parity, bundle the
  raw **lucide SVGs** (lucide.dev) as template images:
  `NSImage(contentsOf:)` → `.isTemplate = true` → tint with `foreground`/token color;
  in SwiftUI use `Image(...).renderingMode(.template).foregroundStyle(...)`.
- Where a crisp native feel is preferred (toolbars, menus, system affordances), map to
  the nearest **SF Symbol** — they differ slightly in stroke/metrics, so don't mix the
  two for the *same* icon in the *same* view. Keep stroke width ~1.5–2pt to match lucide.
- Common map: `mic`→`mic`, `mic-off`→`mic.slash`, `video`→`video`, `video-off`→`video.slash`,
  `phone-off`→`phone.down.fill`, `monitor-up`→`rectangle.on.rectangle`, `users`→`person.2`,
  `settings`→`gearshape`, `shield`→`lock.shield`, `x`→`xmark`, `chevron-down`→`chevron.down`,
  `more-horizontal`→`ellipsis`.

---

## 8. SwiftUI ↔ AppKit bridges

- **SwiftUI inside AppKit** (your default): `NSHostingController` / `NSHostingView`.
  Set the manual appearance on this host (`host.view.appearance = …` or
  `InterAppearance.apply(.dark, to: window)`) so theme colors resolve correctly.
- **AppKit call tile inside a SwiftUI call window:** wrap the Obj-C/NSView tile in
  `NSViewRepresentable`. The tile uses **stage** colors (fixed dark), so it needs no
  appearance wiring.

---

## 9. Component recipes → SwiftUI

```swift
// Primary CTA — h-10, violet, /20 shadow
Text("Join Now")
    .font(InterFont.swiftUI(InterFont.Size.secondary, .semibold))
    .foregroundStyle(.interPrimaryForeground)
    .frame(height: InterControl.primaryHeight).frame(maxWidth: .infinity)
    .background(.interPrimary, in: RoundedRectangle(cornerRadius: InterRadius.lg))
    .interShadow(.cta(.interPrimary))

// Card / panel — p-4, rounded-xl, hairline, sm shadow
VStack { /* content */ }
    .padding(InterSpacing.x4)
    .background(.interCard, in: RoundedRectangle(cornerRadius: InterRadius.xl))
    .overlay(RoundedRectangle(cornerRadius: InterRadius.xl).stroke(.interBorder))
    .interShadow(.sm)

// Status badge
Text("Active")
    .font(InterFont.swiftUI(InterFont.Size.dense10, .semibold))
    .padding(.horizontal, InterSpacing.x1_5).padding(.vertical, 2)
    .foregroundStyle(Color(nsColor: InterStatus.success))
    .background(Color(nsColor: InterStatus.success).opacity(0.12), in: Capsule())

// Stage context menu item (AppKit-hosted call) — fixed dark
Text("Mute Camera")
    .font(InterFont.swiftUI(InterFont.Size.menu13))
    .foregroundStyle(.white.opacity(0.9))
    .padding(.horizontal, InterSpacing.x3).padding(.vertical, InterSpacing.x2)
    .background(.interStageElevated)
```

---

## 10. Accessibility (enforce)

- Body/secondary text ≥ **WCAG AA 4.5:1** (3:1 for ≥18pt or bold ≥14pt). Use
  `muted-foreground` for secondary text — it's tuned to pass in both modes. Never use
  raw light neutrals for readable text on light surfaces (only white-on-dark on stage).
- Every interactive control shows a visible focus state (`ring`).
- Don't signal state by color alone — pair with icon/label (e.g. REC dot + "REC").
