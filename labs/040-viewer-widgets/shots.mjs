// Lab 040 screenshots: the panel at each width and theme, normal and while editing, in a headless Chrome of its own.
//   node labs/040-viewer-widgets/shots.mjs [port] [outDir]
// Layouts: the default one, and a crowded one with every widget at a bigger size.
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.argv[2] ?? 1420);
const out = process.argv[3] ?? join(here, "shots");
mkdirSync(out, { recursive: true });
const profile = mkdtempSync(join(tmpdir(), "lab040-"));
const debug = 9300 + Math.floor(Math.random() * 500);
const proc = spawn("C:/Program Files/Google/Chrome/Application/chrome.exe", ["--headless=new", `--remote-debugging-port=${debug}`, `--user-data-dir=${profile}`, "--no-first-run", "--lang=es", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) { await sleep(200); try { target = (await (await fetch(`http://127.0.0.1:${debug}/json`)).json()).find((t) => t.type === "page"); } catch { /* starting */ } }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let id = 0; const pending = new Map();
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const call = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
const js = (expression) => call("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });

const figs = (list) => list.map((f, i) => ({ id: "f" + i, figure: f, x: 0, z: 0, rot: 0, size: 1 }));
const LAYOUTS = {
  default: null,
  big: [{ type: "machines", w: 3, h: 3, x: 0, y: 0 }, { type: "clock", w: 1, h: 2, x: 0, y: 3 }, { type: "stats", w: 2, h: 2, x: 1, y: 3 }, { type: "weather", w: 1, h: 1, x: 0, y: 5 }, { type: "actions", w: 2, h: 1, x: 1, y: 5 }, { type: "games", w: 3, h: 3, x: 0, y: 6 }, { type: "shelf", w: 3, h: 2, x: 0, y: 9 }],
};
await call("Page.enable");
await call("Page.navigate", { url: `http://localhost:${port}/?vms=0` });
await sleep(1500);
for (const [name, layout] of Object.entries(LAYOUTS)) for (const theme of ["dark", "light"]) for (const width of [300, 340, 440, 560]) for (const edit of [false, true]) {
  await js(`localStorage.setItem("gpuvm.decor.win10", ${JSON.stringify(JSON.stringify({ color: null, led: null, stickers: [], figures: figs(["duck", "cactus", "robot"]) }))});
    localStorage.setItem("gpuvm.decor.win11-pruebas", ${JSON.stringify(JSON.stringify({ color: null, led: null, stickers: [], figures: figs(["lucky-cat", "mushroom", "penguin", "bonsai"]) }))});
    localStorage.setItem("gpuvm.prefs", JSON.stringify({ theme: "${theme}", lang: "es" }));
    ${layout ? `localStorage.setItem("gpuvm.viewerPanelWidgets", ${JSON.stringify(JSON.stringify(layout))});` : `localStorage.removeItem("gpuvm.viewerPanelWidgets");`} 1`);
  await call("Emulation.setDeviceMetricsOverride", { width, height: 960, deviceScaleFactor: 1, mobile: false });
  await call("Page.navigate", { url: `http://localhost:${port}/?viewer-panel&vm=win10` });
  await sleep(2600);
  if (edit) { await js(`document.querySelector(".vp-edit").click(); 1`); await sleep(500); }
  const shot = await call("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
  writeFileSync(join(out, `${name}-${theme}-${width}${edit ? "-edit" : ""}.png`), Buffer.from(shot.result.data, "base64"));
}
proc.kill();
await sleep(800);
try { rmSync(profile, { recursive: true, force: true }); } catch { /* locked */ }
console.log("ok", out);
process.exit(0);
