// scripts/capture-reference.mjs
//
// Reference-screenshot generator for the Inter catalogue.
// Solves the in-editor browser's limits: it uses a LARGE fixed viewport (no
// responsive reflow / hidden elements), navigates every screen by URL (deep-link,
// no clicking), renders both dark + light, and captures the mock element full-bleed
// at @2x. Output → ./reference-screens/ref_<id>_<mode>.png
//
// Prereqs (one-time):
//   npm i -D playwright
//   npx playwright install chromium        # downloads a headless Chromium
//   npm run dev                             # dev server must be running
// Run:
//   node scripts/capture-reference.mjs
//   BASE_URL=http://localhost:5173 WIDTH=1680 HEIGHT=1050 SCALE=2 node scripts/capture-reference.mjs
//
// Tip: if you have Chrome installed and don't want the Chromium download, change
// chromium.launch() to chromium.launch({ channel: 'chrome' }).

import { chromium } from "playwright";
import { mkdir } from "node:fs/promises";
import path from "node:path";

const BASE   = process.env.BASE_URL || "http://localhost:5173";
const OUT    = path.resolve(process.env.OUT_DIR || "reference-screens");
const WIDTH  = Number(process.env.WIDTH  || 1680);
const HEIGHT = Number(process.env.HEIGHT || 1050);
const SCALE  = Number(process.env.SCALE  || 2);

// Screen IDs == keys in src/app/data/screens.ts
const SCREENS = [
  "connection", "auth", "account", "in-call", "pre-meeting", "green-room",
  "host-controls", "lobby", "chat", "qa", "poll", "teams", "schedule",
  "secure", "secure-candidate",
];

const MODES = ["dark", "light"];

// The mock renders as the single child of this centered wrapper in ScreenViewer.
const MOCK_SELECTOR = "div.min-h-full.flex.items-center.justify-center > *";
const THEME_KEY = "inter-theme-mode";

async function capture(page, id, mode) {
  const url = `${BASE}/screen/${id}`;
  await page.goto(url, { waitUntil: "networkidle" });

  // Force the appearance, then reload so ThemeContext boots in that mode.
  await page.evaluate(([k, m]) => localStorage.setItem(k, m), [THEME_KEY, mode]);
  await page.reload({ waitUntil: "networkidle" });

  // Let webfonts settle so text metrics are final.
  await page.evaluate(() => document.fonts && document.fonts.ready);

  const file = path.join(OUT, `ref_${id}_${mode}.png`);
  try {
    const target = page.locator(MOCK_SELECTOR).first();
    await target.waitFor({ state: "visible", timeout: 8000 });
    await page.waitForTimeout(250); // settle transitions
    await target.screenshot({ path: file });
  } catch {
    // Fallback: full page if the mock root can't be isolated.
    await page.screenshot({ path: file, fullPage: true });
  }
  console.log("✓", path.relative(process.cwd(), file));
}

async function main() {
  await mkdir(OUT, { recursive: true });
  // CHANNEL=chrome drives your installed Google Chrome (no Chromium download).
  // Unset → Playwright's bundled Chromium (requires `npx playwright install chromium`).
  const channel = process.env.CHANNEL || undefined;
  const browser = await chromium.launch(channel ? { channel } : {});
  const context = await browser.newContext({
    viewport: { width: WIDTH, height: HEIGHT },
    deviceScaleFactor: SCALE,
  });
  const page = await context.newPage();

  console.log(`Capturing ${SCREENS.length} screens × ${MODES.length} modes ` +
    `@ ${WIDTH}×${HEIGHT} ×${SCALE} → ${path.relative(process.cwd(), OUT)}/`);

  for (const id of SCREENS) {
    for (const mode of MODES) {
      try { await capture(page, id, mode); }
      catch (e) { console.error("✗", id, mode, "—", e.message); }
    }
  }

  await browser.close();
  console.log("Done.");
}

main().catch((e) => { console.error(e); process.exit(1); });
