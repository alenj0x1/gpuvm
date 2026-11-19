// Lab 054 screenshots: every agent screen with mock data, empty and crowded, light and dark, narrow and wide, in
// Spanish, in a headless Chrome of its own (lab 040's chrome.mjs). Needs the dev server (npm --prefix app run dev).
//   node labs/054-agent-ui/shots.mjs [port] [outDir]
import { mkdirSync, writeFileSync } from "node:fs";
import { startChrome } from "../040-viewer-widgets/chrome.mjs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.argv[2] ?? 1420);
const out = process.argv[3] ?? join(here, "out", "shots");
mkdirSync(out, { recursive: true });
const chrome = await startChrome(["--lang=es"]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
if (!chrome.target) { console.error("chrome did not start"); process.exit(2); }
const ws = new WebSocket(chrome.target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let id = 0; const pending = new Map();
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const call = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
const js = (expression) => call("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
const base = `http://localhost:${port}`;

// A picture behind the windows that go over it (dock, notch): a plain desktop-like fill, as in the viewer.
const PICTURE = `document.documentElement.style.background = "linear-gradient(135deg,#1f4e79,#3a6ea5)"; 1`;

// [name, url, setup js, viewport widths]
const SCREENS = [
  ["agents", (s) => `/?agents=${s}#:agents`, null],
  ["machine", (s) => `/?agents=${s}#win-agent`, `[...document.querySelectorAll(".section-nav button")].find((b) => /Agente/.test(b.textContent))?.click(); 1`],
  ["settings", () => `/?agents=working#:settings`, `[...document.querySelectorAll(".pref-nav-item")].find((b) => /Agentes/.test(b.textContent))?.click(); 1`],
  ["use", () => `/?agents=working#win-agent`, `[...document.querySelectorAll(".section-nav button")].find((b) => /Imagen/.test(b.textContent))?.click(); await new Promise((r) => setTimeout(r, 900)); document.querySelector('button.dropdown[aria-label="Tipo de uso"]')?.click(); 1`],
  ["create", () => `/?agents=working#:home`, `document.querySelector(".side-add")?.click(); await new Promise((r) => setTimeout(r, 900)); [...document.querySelectorAll(".create-nav button")].find((b) => /partida/.test(b.textContent))?.click(); await new Promise((r) => setTimeout(r, 700)); [...document.querySelectorAll(".choice")].find((b) => /agentes/.test(b.textContent))?.click(); 1`],
];
const STATES = ["none", "working", "waiting", "many"];
const DOCKS = ["network", "deliver", "revert", "human"];

await call("Page.enable");
const shot = async (file) => {
  const s = await call("Page.captureScreenshot", { format: "png" });
  writeFileSync(join(out, file), Buffer.from(s.result.data, "base64"));
};
const open = async (url, theme, width, height) => {
  await call("Page.navigate", { url: base + "/?vms=0" });
  await sleep(500);
  await js(`localStorage.setItem("gpuvm.prefs", JSON.stringify({ theme: "${theme}", lang: "es" })); 1`);
  await call("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
  await call("Page.navigate", { url: base + url });
  await sleep(2200);
};

let n = 0;
for (const theme of ["dark", "light"]) for (const width of [760, 1400]) {
  for (const [name, url, setup] of SCREENS) {
    const states = name === "agents" || name === "machine" ? STATES : ["working"];
    for (const s of states) {
      if (name === "settings") { for (const sec of ["Agentes", "Apariencia"]) {
        await open(url(s), theme, width, 900);
        await js(`(async () => { [...document.querySelectorAll(".pref-nav-item")].find((b) => b.textContent.includes("${sec}"))?.click(); })()`); await sleep(900);
        if (sec === "Apariencia") { await js(`document.querySelector('button.dropdown[aria-label="Avisos de estado"]')?.click(); 1`); await sleep(500); }
        await shot(`settings-${sec === "Agentes" ? "agents" : "status"}-${theme}-${width}.png`); n++;
      } continue; }
      await open(url(s), theme, width, 900);
      if (setup) { await js(`(async () => { ${setup} })()`); await sleep(1200); }
      await shot(`${name}-${s}-${theme}-${width}.png`); n++;
    }
  }
}
// The windows over the picture are always dark; at two picture sizes.
for (const width of [800, 1600]) {
  for (const d of DOCKS) {
    await open(`/?agent-dock=${d}`, "dark", width, Math.round(width * 0.5625));
    await js(PICTURE); await sleep(900);
    await shot(`dock-${d}-${width}.png`); n++;
  }
  // The status notch alone (status.mjs composes it over the picture with the docks).
  await open(`/?status-notch&placement=bottom`, "dark", width, Math.round(width * 0.5625));
  await js(PICTURE); await sleep(900);
  await shot(`status-${width}.png`); n++;
}
// The widget in the viewer's panel, at its sizes, working and with requests waiting.
for (const theme of ["dark", "light"]) for (const [w, h] of [[2, 1], [2, 2], [3, 3], [2, 4]]) for (const s of ["working", "waiting"]) {
  await call("Page.navigate", { url: base + "/?vms=0" });
  await sleep(400);
  await js(`localStorage.setItem("gpuvm.prefs", JSON.stringify({ theme: "${theme}", lang: "es" }));
    localStorage.setItem("gpuvm.viewerPanelWidgets", JSON.stringify([{ type: "agent", w: ${w}, h: ${h}, x: 0, y: 0 }])); 1`);
  await call("Emulation.setDeviceMetricsOverride", { width: w === 3 ? 440 : 340, height: 520, deviceScaleFactor: 1, mobile: false });
  await call("Page.navigate", { url: `${base}/?viewer-panel&vm=win-agent&agents=${s}` });
  await sleep(1800);
  await shot(`widget-${w}x${h}-${s}-${theme}.png`); n++;
}
chrome.close();
console.log("ok", n, "screenshots in", out);
process.exit(0);
