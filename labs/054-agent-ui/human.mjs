// Lab 054: what the person sees when an agent needs them (request_human), in Spanish, dark: the dock over the picture,
// the Agents page with the request and the sidebar's count, and the machine's Agent section.
//   node labs/054-agent-ui/human.mjs [port] [outDir]
import { mkdirSync, writeFileSync } from "node:fs";
import { startChrome } from "../040-viewer-widgets/chrome.mjs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.argv[2] ?? 1440);
const out = process.argv[3] ?? join(here, "out", "human");
mkdirSync(out, { recursive: true });
const chrome = await startChrome(["--lang=es"]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ws = new WebSocket(chrome.target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let id = 0; const pending = new Map();
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const call = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
const js = async (expression) => (await call("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result?.result?.value;
const base = `http://localhost:${port}`;
const shot = async (name) => writeFileSync(join(out, `${name}.png`), Buffer.from((await call("Page.captureScreenshot", { format: "png" })).result.data, "base64"));
const open = async (url, w, h) => {
  await call("Page.navigate", { url: `${base}/?vms=0` }); await sleep(400);
  await js(`localStorage.setItem("gpuvm.prefs", JSON.stringify({ theme: "dark", lang: "es" })); 1`);
  await call("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false });
  await call("Page.navigate", { url: base + url }); await sleep(2200);
};
await call("Page.enable");
// The dock over the machine's picture (a plain fill stands for the picture).
await open("/?agent-dock=human", 1280, 720);
await js(`document.documentElement.style.background = "linear-gradient(135deg,#1f4e79,#3a6ea5)"; 1`); await sleep(800);
await shot("human-dock");
// Agents: the request with View and Return to agent; the sidebar counts it.
await open("/?agents=human#:agents", 1280, 760); await shot("human-agents");
// The machine's Agent section.
await open("/?agents=human#win-agent", 1280, 760);
await js(`(async () => { [...document.querySelectorAll(".section-nav button")].find((b) => /Agente/.test(b.textContent))?.click(); })()`); await sleep(1000);
await shot("human-machine");
chrome.close();
console.log("ok", out);
process.exit(0);
