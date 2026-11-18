// Lab 040 runner: opens the dev server's panel in a headless Chrome of its own (so nobody's window moves and the
// page's clock runs at full speed) and runs check.js there. Needs the dev server up (npm --prefix app run dev).
//   node labs/040-viewer-widgets/run.mjs [port] [options-json]
// e.g. node run.mjs 1440 '{"themes":["dark"],"widths":[340]}'. Writes the report next to this file (report.json).
import { readFileSync, writeFileSync } from "node:fs";
import { startChrome } from "./chrome.mjs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.argv[2] ?? 1420);
const opts = process.argv[3] ?? "{}";
const chrome = await startChrome(["--window-size=1200,1000"]);
const done = (code) => { chrome.close(); process.exit(code); };
const fail = setTimeout(() => { console.error("timed out"); done(2); }, 20 * 60000);

const target = chrome.target;
if (!target) { console.error("chrome did not start"); done(2); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let id = 0;
const pending = new Map();
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const call = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });

await call("Page.enable");
await call("Page.navigate", { url: `http://localhost:${port}/?vms=0` });
await new Promise((r) => setTimeout(r, 2500));
const script = `window.LAB040 = ${opts};\n` + readFileSync(join(here, "check.js"), "utf8");
const res = await call("Runtime.evaluate", { expression: script, awaitPromise: true, returnByValue: true, timeout: 19 * 60000 });
clearTimeout(fail);
if (res.result?.exceptionDetails) { console.error(JSON.stringify(res.result.exceptionDetails, null, 1)); done(1); }
const full = await call("Runtime.evaluate", { expression: "window.__lab040", returnByValue: true });
// No report when the page reloaded under the run (the dev server reloads on every saved change): run it again
// without editing meanwhile.
if (!full.result?.result?.value) { console.error("no report: the page reloaded during the run", JSON.stringify(res.result)); done(1); }
writeFileSync(join(here, "report.json"), JSON.stringify(full.result.result.value, null, 1));
console.log(JSON.stringify(res.result.result.value, null, 1));
done(0);
