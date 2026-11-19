// Lab 054, status notch: every placement, with and without a dock down, with one notice and with several, composed
// over a picture the way status.rs places the windows (the real notch and dock pages in frames of their own size).
//   node labs/054-agent-ui/status.mjs [port] [outDir]
// Checks, besides the screenshots: the notch stays inside the picture, never overlaps the dock, and a top-center notch
// sits right under an open dock (attached: no gap, no overlap).
import { mkdirSync, writeFileSync } from "node:fs";
import { startChrome } from "../040-viewer-widgets/chrome.mjs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.argv[2] ?? 1420);
const out = process.argv[3] ?? join(here, "out", "status");
mkdirSync(out, { recursive: true });
const chrome = await startChrome(["--lang=es"]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
if (!chrome.target) { console.error("chrome did not start"); process.exit(2); }
const ws = new WebSocket(chrome.target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let id = 0; const pending = new Map();
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const call = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
const js = async (expression) => (await call("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result?.result?.value;
const base = `http://localhost:${port}`;

const W = 1280, H = 720, GAP = 12;
await call("Page.enable");
await call("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: 1, mobile: false });
await call("Page.navigate", { url: `${base}/?vms=0` });
await sleep(800);
await js(`localStorage.setItem("gpuvm.prefs", JSON.stringify({ theme: "dark", lang: "es" })); 1`);

const report = [];
for (const placement of ["bottom", "top", "top-left", "top-right"]) for (const dock of [false, true]) for (const n of [1, 3]) {
  const name = `status-${placement}-${dock ? "dock" : "nodock"}-${n}`;
  const res = await js(`(async () => {
    document.body.innerHTML = "";
    document.documentElement.style.background = "linear-gradient(135deg,#1f4e79,#3a6ea5)";
    const pic = document.createElement("div");
    pic.style.cssText = "position:fixed;inset:0;background:linear-gradient(135deg,#1f4e79,#3a6ea5)";
    document.body.appendChild(pic);
    const frame = (src, css) => new Promise((ok) => { const f = document.createElement("iframe"); f.src = src; f.style.cssText = "position:fixed;border:0;background:transparent;" + css; f.allowTransparency = true; f.onload = () => ok(f); document.body.appendChild(f); });
    let dockRect = null;
    if (${dock}) {
      const d = await frame("/?agent-dock=network", "left:0;top:0;width:${W}px;height:${H}px");
      await new Promise((r) => setTimeout(r, 900));
      dockRect = d.contentDocument.querySelector(".dock").getBoundingClientRect().toJSON();
    }
    const f = await frame("/?status-notch&placement=${placement}&n=${n}", "left:0;top:0;width:900px;height:400px");
    await new Promise((r) => setTimeout(r, 900));
    const sn = f.contentDocument.querySelector(".sn");
    const w = sn.offsetWidth, h = sn.offsetHeight;
    // The same rule as status.rs place(): the dock's real size (as dockSize.ts reports it, offsetWidth/Height), and a
    // notch that would touch it moves under it (attached at the top center, with the gap in a corner).
    let [x, y] = "${placement}" === "top" ? [(${W} - w) / 2, 0]
      : "${placement}" === "top-left" ? [${GAP}, ${GAP}] : "${placement}" === "top-right" ? [${W} - w - ${GAP}, ${GAP}] : [(${W} - w) / 2, ${H} - h];
    let under = false;
    if (dockRect) {
      const d = f.ownerDocument.querySelector("iframe").contentDocument.querySelector(".dock");
      const dw = d.offsetWidth, dh = d.offsetHeight, dx = (${W} - dw) / 2;
      under = "${placement}" !== "bottom" && x < dx + dw && dx < x + w && y < dh;
      if (under) y = dh + ("${placement}" === "top" ? 0 : ${GAP});
    }
    f.style.left = x + "px"; f.style.top = y + "px"; f.style.width = w + "px"; f.style.height = h + "px";
    const notch = { x, y, w, h };
    const inside = x >= 0 && y >= 0 && x + w <= ${W} && y + h <= ${H};
    const overlap = dockRect ? !(x + w <= dockRect.x || dockRect.x + dockRect.width <= x || y + h <= dockRect.y + dockRect.height - 0.5 || dockRect.y + dockRect.height <= y) && !(y >= dockRect.y + dockRect.height - 0.5) : false;
    const attached = under && "${placement}" === "top" ? Math.abs(y - (dockRect.y + dockRect.height)) <= 1 : null;
    return { notch, dock: dockRect, inside, overlap, attached };
  })()`);
  await sleep(500);
  const shot = await call("Page.captureScreenshot", { format: "png" });
  writeFileSync(join(out, `${name}.png`), Buffer.from(shot.result.data, "base64"));
  report.push({ name, ...res });
}
// Placement "panel": the same rows at the top of the side panel.
await call("Emulation.setDeviceMetricsOverride", { width: 340, height: 520, deviceScaleFactor: 1, mobile: false });
await call("Page.navigate", { url: `${base}/?viewer-panel&vm=win-agent&placement=panel` });
await sleep(1800);
const shot = await call("Page.captureScreenshot", { format: "png" });
writeFileSync(join(out, "status-panel.png"), Buffer.from(shot.result.data, "base64"));

writeFileSync(join(out, "report.json"), JSON.stringify(report, null, 1));
const bad = report.filter((r) => !r.inside || r.overlap || r.attached === false);
console.log(`${report.length} cases, ${bad.length} failing`);
for (const b of bad) console.log(JSON.stringify(b));
chrome.close();
process.exit(bad.length ? 1 : 0);
