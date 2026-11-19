// Lab 054: the machine header at 620 px (dark) and 800 px (light) with a long name, in a headless Chrome of its own.
//   node labs/054-agent-ui/header.mjs [port] [outDir]
import { mkdirSync, writeFileSync } from "node:fs";
import { startChrome } from "../040-viewer-widgets/chrome.mjs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.argv[2] ?? 1440);
const out = process.argv[3] ?? join(here, "out", "header");
mkdirSync(out, { recursive: true });
const chrome = await startChrome(["--lang=es"]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ws = new WebSocket(chrome.target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let id = 0; const pending = new Map();
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const call = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
const js = async (expression) => (await call("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result?.result?.value;
const LONG = "maquina-de-pruebas-del-instalador-largo";
await call("Page.enable");
for (const [width, theme] of [[620, "dark"], [800, "light"]]) {
  await call("Page.navigate", { url: `http://localhost:${port}/?vms=0` });
  await sleep(500);
  await js(`localStorage.setItem("gpuvm.prefs", JSON.stringify({ theme: "${theme}", lang: "es" })); 1`);
  await call("Emulation.setDeviceMetricsOverride", { width, height: 700, deviceScaleFactor: 1, mobile: false });
  await call("Page.navigate", { url: `http://localhost:${port}/#juegos-desechable` });
  await sleep(2500);
  // A 39-character name (the longest a machine can have is 40).
  const box = await js(`(() => { const h = document.querySelector(".scene-head h1"); h.textContent = "${LONG}"; h.title = "${LONG}";
    const r = document.querySelector(".scene-head").getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; })()`);
  await sleep(400);
  const shot = await call("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width, height: Math.ceil(box.y + box.height + 16), scale: 1 } });
  writeFileSync(join(out, `header-${width}-${theme}.png`), Buffer.from(shot.result.data, "base64"));
}
chrome.close();
console.log("ok", out);
process.exit(0);
