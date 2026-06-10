/**
 * SFSymbol — renders Apple SF Symbols on macOS using the system font.
 *
 * On macOS the font is available after installing Xcode / the SF Symbols app.
 * On other platforms this falls back to a compact text label.
 *
 * Symbol names follow Apple's naming convention (e.g. "mic", "video.fill").
 * Weight variants: ultralight | thin | light | regular | medium | semibold | bold | heavy | black
 */

import React from "react";

// SF Symbol name → Unicode codepoint (private use area, E000–F8FF).
// Codepoints sourced from the SF Symbols 6 font character map.
const SYMBOL_MAP: Record<string, string> = {
  // Audio / Video
  "mic":                    "\uE170",
  "mic.fill":               "\uE171",
  "mic.slash":              "\uE172",
  "mic.slash.fill":         "\uE173",
  "video":                  "\uE18A",
  "video.fill":             "\uE18B",
  "video.slash":            "\uE18C",
  "video.slash.fill":       "\uE18D",
  "speaker.wave.2":         "\uE13C",
  "speaker.wave.2.fill":    "\uE13D",
  "speaker.slash":          "\uE13E",
  "phone.down.fill":        "\uE07B",

  // People / Communication
  "person":                 "\uE08C",
  "person.fill":            "\uE08D",
  "person.2":               "\uE090",
  "person.2.fill":          "\uE091",
  "person.badge.clock":     "\uEB45",
  "bubble.left":            "\uE0A6",
  "bubble.left.fill":       "\uE0A7",
  "hand.raised":            "\uE2A6",
  "hand.raised.fill":       "\uE2A7",

  // Controls / Actions
  "play":                   "\uE04B",
  "play.fill":              "\uE04C",
  "pause":                  "\uE04D",
  "pause.fill":             "\uE04E",
  "stop.fill":              "\uE050",
  "square.and.arrow.up":    "\uE001",
  "square.and.arrow.up.fill": "\uE002",
  "plus":                   "\uE044",
  "plus.circle.fill":       "\uE045",
  "xmark":                  "\uE06E",
  "xmark.circle.fill":      "\uE06F",
  "checkmark":              "\uE066",
  "chevron.up":             "\uE059",
  "chevron.down":           "\uE05A",
  "chevron.left":           "\uE057",
  "chevron.right":          "\uE058",
  "ellipsis":               "\uE076",
  "ellipsis.circle":        "\uE077",

  // Interface
  "magnifyingglass":        "\uE0B8",
  "gearshape":              "\uE292",
  "gearshape.fill":         "\uE293",
  "rectangle.on.rectangle": "\uE1B9",
  "display":                "\uE1C2",
  "calendar":               "\uE0D3",
  "clock":                  "\uE0D0",
  "clock.fill":             "\uE0D1",
  "lock":                   "\uE0C0",
  "lock.fill":              "\uE0C1",
  "shield":                 "\uE2AD",
  "shield.fill":            "\uE2AE",
  "key":                    "\uE0C4",
  "key.fill":               "\uE0C5",

  // Layout
  "square.grid.2x2":        "\uE1C4",
  "square.grid.2x2.fill":   "\uE1C5",
  "rectangle.split.2x1":    "\uE1B4",
  "sidebar.left":           "\uE1D4",
  "pin":                    "\uE2C2",
  "pin.fill":               "\uE2C3",

  // Cloud / Recording
  "cloud":                  "\uE0DA",
  "cloud.fill":             "\uE0DB",
  "record.circle":          "\uE153",
  "record.circle.fill":     "\uE154",

  // Network
  "wifi":                   "\uE107",
  "antenna.radiowaves.left.and.right": "\uE10A",
  "chart.bar":              "\uE225",

  // Misc
  "star":                   "\uE078",
  "star.fill":              "\uE079",
  "arrow.up":               "\uE016",
  "arrow.down":             "\uE017",
  "trash":                  "\uE0BA",
  "trash.fill":             "\uE0BB",
  "pencil":                 "\uE04F",
  "link":                   "\uE0D5",
  "paperclip":              "\uE0BF",
  "doc":                    "\uE0B5",
  "doc.fill":               "\uE0B6",
};

type SFSymbolWeight = "ultralight" | "thin" | "light" | "regular" | "medium" | "semibold" | "bold" | "heavy" | "black";

const WEIGHT_VALUE: Record<SFSymbolWeight, number> = {
  ultralight: 100,
  thin:       200,
  light:      300,
  regular:    400,
  medium:     500,
  semibold:   600,
  bold:       700,
  heavy:      800,
  black:      900,
};

interface SFSymbolProps {
  /** Apple SF Symbol name, e.g. "mic.fill" */
  name: string;
  /** Point size (maps to px on web) */
  size?: number;
  weight?: SFSymbolWeight;
  className?: string;
  style?: React.CSSProperties;
  "aria-label"?: string;
}

export function SFSymbol({
  name,
  size = 16,
  weight = "regular",
  className = "",
  style,
  "aria-label": ariaLabel,
}: SFSymbolProps) {
  const char = SYMBOL_MAP[name];

  return (
    <span
      aria-label={ariaLabel ?? name}
      role="img"
      className={className}
      style={{
        fontFamily: '"SF Symbols", "Apple Symbols", system-ui',
        fontSize:   size,
        fontWeight: WEIGHT_VALUE[weight],
        lineHeight: 1,
        display:    "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        userSelect: "none",
        ...style,
      }}
    >
      {char ?? (
        /* Fallback on non-macOS: render symbol name as tiny badge */
        <span
          style={{
            fontFamily: "system-ui",
            fontSize:   Math.max(8, size * 0.55),
            fontWeight: 500,
            opacity:    0.6,
            letterSpacing: "-0.02em",
          }}
        >
          {name}
        </span>
      )}
    </span>
  );
}
