// Screenshots of the app for the README, the docs and the landing, taken from the dev server with its sample data.
//
//   npm --prefix app run dev -- --port 1430          (in another terminal)
//   node tools/screenshots/shoot.mjs [--url http://localhost:1430] [--out tools/screenshots/out] [--only home,machine]
//
// Every shot is taken in Spanish and English, light and dark: <out>/<name>-<lang>-<mode>.png at 2x.
// Needs Playwright: PLAYWRIGHT_PKG points to a package.json whose node_modules has it (or it is resolved from here).
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import path from "node:path";

const arg = (name, def) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : def; };
const URL = arg("url", "http://localhost:1430");
const OUT = arg("out", "tools/screenshots/out");
const ONLY = arg("only", "")?.split(",").filter(Boolean);
const LANGS = (arg("langs", "es,en")).split(",");
const MODES = (arg("modes", "light,dark")).split(",");
const require = createRequire(process.env.PLAYWRIGHT_PKG || path.resolve("package.json"));
const { chromium } = require("playwright");
mkdirSync(OUT, { recursive: true });

// A decoration for each sample machine, the same in every shot (Decorate at random would change every time).
const DECOR = {
  win10: { color: "violet", led: { text: "PLAYER ONE", color: "amber", live: false, y: 0.35 },
    stickers: [{ id: "s1", sticker: "logo", face: "front", u: -0.45, v: 0.35, rot: -8, size: 0.62 }, { id: "s2", sticker: "bolt", face: "right", u: 0.3, v: 0.1, rot: 12, size: 0.6 }],
    figures: [{ id: "f1", figure: "cat", x: 0.45, z: -0.35, rot: -20, size: 1.05 }, { id: "f2", figure: "succulent", x: -0.45, z: 0.4, rot: 10, size: 0.95 }] },
  "win11-pruebas": { color: "teal", led: { text: "RTX ON", color: "green", live: false, y: 0.2 },
    stickers: [{ id: "s3", sticker: "rocket", face: "front", u: 0.4, v: 0.3, rot: 10, size: 0.65 }], figures: [{ id: "f3", figure: "robot", x: -0.4, z: -0.3, rot: 25, size: 1 }] },
  estudio: { color: "amber", led: null, stickers: [{ id: "s4", sticker: "heart", face: "left", u: 0, v: 0.2, rot: -6, size: 0.6 }], figures: [{ id: "f4", figure: "bunny", x: 0.4, z: 0.35, rot: -15, size: 1 }] },
};
const SPACES = [{ id: "main", name: "Mis máquinas", ambient: "blocks", time: "day", machines: ["win10", "win11-pruebas"] }, { id: "lab", name: "Laboratorio", ambient: "board", machines: ["estudio"] }];

/** name, URL query, hash route, and what to do before the shot. */
const SHOTS = [
  { name: "home", hash: ":inicio" },
  { name: "home-board", hash: ":inicio", shown: "lab" },
  { name: "machine", hash: "win10" },
  { name: "personalize", hash: "win10", section: "Personalizar|Customize" },
  { name: "options", hash: "win10", section: "Imagen y control|Picture and control" },
  { name: "windows", hash: "estudio", section: "Windows" },
  { name: "library", hash: ":biblioteca" },
  { name: "settings", hash: ":preferencias" },
  { name: "create", hash: ":inicio", click: "Crear máquina|Create machine" },
  { name: "games", hash: ":inicio", click: "Jugar|Play" },
  { name: "empty", query: "?vms=0", hash: ":inicio" },
  { name: "agents", query: "?agents=working", hash: ":agentes" },
];

// An installed Chrome (CHROME=path) works when Playwright's own browser is not downloaded.
const browser = await chromium.launch({ executablePath: process.env.CHROME || undefined });
for (const lang of LANGS) for (const mode of MODES) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, colorScheme: mode });
  await ctx.addInitScript(([prefs, decor, spaces]) => {
    if (sessionStorage.getItem("seeded")) return;
    sessionStorage.setItem("seeded", "1");
    localStorage.setItem("gpuvm.prefs", JSON.stringify(prefs));
    for (const [name, d] of Object.entries(decor)) localStorage.setItem(`gpuvm.decor.${name}`, JSON.stringify(d));
    localStorage.setItem("gpuvm.spaces", JSON.stringify(spaces));
  }, [{ theme: mode, lang, accent: "blue" }, DECOR, SPACES]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  for (const s of SHOTS) {
    if (ONLY?.length && !ONLY.includes(s.name)) continue;
    await page.evaluate((id) => localStorage.setItem("gpuvm.space.shown", id), s.shown ?? "main").catch(() => {});
    await page.goto(`${URL}/${s.query ?? ""}#${encodeURIComponent(s.hash)}`);
    await page.reload();
    await page.waitForTimeout(2500);
    if (s.section) {
      const re = new RegExp(`^(${s.section})$`);
      await page.getByRole("tab", { name: re }).first().click().catch(() => errors.push(`no section ${s.section}`));
      await page.waitForTimeout(1500);
    }
    if (s.click) {
      await page.getByRole("button", { name: new RegExp(`^(${s.click})$`) }).first().click().catch(() => errors.push(`no button ${s.click}`));
      await page.waitForTimeout(2200);
    }
    await page.screenshot({ path: `${OUT}/${s.name}-${lang}-${mode}.png` });
    console.log(`${s.name}-${lang}-${mode}`);
  }
  if (errors.length) console.log("errors:", errors);
  await ctx.close();
}
await browser.close();
