// Lab 054, screen.refresh (agent 0.3.8+): with ddx a still desktop sends no frame, and a viewer that connects to it
// may stay black. GpuVM asks the guest to repaint when the stream comes up (App.tsx refreshAgentScreen). Measured from
// the viewer, as the person sees it: N connects with the refresh and N with GpuVM started with
// GPUVM_LAB_NO_SCREEN_REFRESH=1, on a still desktop. Each connect: the viewer closes, GpuVM opens it again hidden
// (recording B), and the person opens the machine (open_viewer): the picture's luma at once, and the time until it
// isn't black (20 s at most). GpuVM is always started again without the flag at the end.
//   node labs/054-agent-ui/refresh.mjs [template:agent-tpl] [connects=10]
import { spawn, execFileSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const template = (process.argv[2] ?? "template:agent-tpl").replace(/^template:/, "");
const connects = Number(process.argv[3] ?? 10);
const exe = "C:\\Program Files\\GpuVM\\gpuvm.exe";
const out = join(here, "out"); mkdirSync(out, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pwsh = (cmd) => execFileSync("pwsh", ["-NoProfile", "-Command", cmd]).toString().trim();
const guard = setTimeout(() => { console.error("timed out"); finish(3); }, 35 * 60000);

/** GpuVM's window process (not the MCP server, not a --view handoff). */
const appPids = () => pwsh("@(Get-CimInstance Win32_Process -Filter \"Name='gpuvm.exe'\" | Where-Object { $_.CommandLine -notmatch '--mcp|--view|--consent' }).ProcessId -join ','").split(",").filter(Boolean);
const appUp = () => Number(pwsh("@(Get-Process gpuvm -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0).Count")) > 0;
async function startApp(noRefresh) {
  for (const pid of appPids()) { try { pwsh(`Stop-Process -Id ${pid} -Force`); } catch { /* gone */ } }
  await sleep(3000);
  const env = { ...process.env };
  if (noRefresh) env.GPUVM_LAB_NO_SCREEN_REFRESH = "1"; else delete env.GPUVM_LAB_NO_SCREEN_REFRESH;
  spawn(exe, [], { detached: true, stdio: "ignore", env }).unref();
  for (let i = 0; i < 60 && !appUp(); i++) await sleep(1000);
  await sleep(5000);
  return appUp();
}

// The MCP session: it holds the machine the whole time (the hidden viewer and --view need that).
const mcp = spawn(exe, ["--mcp"], { stdio: ["pipe", "pipe", "inherit"] });
let buf = "", next = 1; const waiting = new Map();
mcp.stdout.on("data", (d) => {
  buf += d; let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    try { const m = JSON.parse(line); if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); } } catch { /* not json */ }
  }
});
const rpc = (method, params) => new Promise((ok) => { const id = next++; waiting.set(id, ok); mcp.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n"); });
const tool = async (name, args) => (await rpc("tools/call", { name, arguments: args })).result;
const text = (r) => (r?.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
const luma = () => { try { return pwsh(`& '${join(here, "luma.ps1")}'`); } catch { return "none"; } };
const viewers = () => Number(pwsh("@(Get-Process GpuVMViewer -ErrorAction SilentlyContinue).Count"));

let machine = null;
const report = { template, connects, with: [], without: [] };
async function finish(code) {
  clearTimeout(guard);
  // GpuVM as the person had it: no lab flag.
  try { report.appRestoredWithoutFlag = await startApp(false); } catch { report.appRestoredWithoutFlag = false; }
  if (machine) { try { await tool("destroy", { machine }); } catch { /* left */ } }
  writeFileSync(join(out, "refresh.json"), JSON.stringify(report, null, 1));
  console.log(JSON.stringify(report));
  mcp.kill();
  process.exit(code);
}

await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "lab054-refresh", version: "1.0" } });
mcp.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
report.appStarted = await startApp(false);
const name = `lab054r-${new Date().toISOString().slice(11, 19).replace(/:/g, "")}`;
const made = await tool("create_disposable", { template, name, task: "Lab 054: screen.refresh", cpu: 2, memoryGB: Number(process.env.LAB054_MEMORY_GB ?? 4) });
console.log("create_disposable:", text(made).slice(0, 200));
if (made?.isError) await finish(4);
machine = name;
// Ready: take_machine again until it says so (the copy may still be starting).
for (let i = 0; i < 30; i++) {
  const r = text(await tool("take_machine", { machine, task: "Lab 054: screen.refresh" }));
  if (!/not ready|keep waiting/i.test(r)) break;
  await sleep(10000);
}

/** One connect: the viewer closes, GpuVM opens it hidden again, then the person opens the machine. */
async function connect() {
  try { pwsh("Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force"); } catch { /* none */ }
  const tClosed = Date.now();
  while (viewers() > 0 && Date.now() - tClosed < 10000) await sleep(300);
  // GpuVM's recording opens it again, hidden (no step of the agent touches the screen meanwhile).
  let hiddenMs = null;
  for (const t0 = Date.now(); Date.now() - t0 < 180000;) {
    if (viewers() > 0) { hiddenMs = Date.now() - tClosed; break; }
    await tool("screenshot", { machine, maxWidth: 64, maxHeight: 40 });
    await sleep(1500);
  }
  if (hiddenMs === null) return { error: "no hidden viewer in 3 min" };
  await sleep(6000); // connected and settled, still desktop
  const tOpen = Date.now();
  await tool("open_viewer", { machine });
  let first = null, windowMs = null, pictureMs = null;
  while (Date.now() - tOpen < 20000 && pictureMs === null) {
    const l = luma();
    if (l !== "none") {
      if (windowMs === null) { windowMs = Date.now() - tOpen; first = Number(l); }
      if (Number(l) > 12) pictureMs = Date.now() - tOpen;
    }
    if (pictureMs === null) await sleep(250);
  }
  return { hiddenMs, windowMs, firstLuma: first, pictureMs };
}

for (const [variant, noRefresh] of [["with", false], ["without", true]]) {
  if (noRefresh) report.flagApp = await startApp(true);
  for (let i = 0; i < connects; i++) {
    const r = await connect();
    report[variant].push(r);
    console.log(variant, i + 1, JSON.stringify(r));
  }
}
const sum = (list) => {
  const ok = list.filter((r) => r.windowMs !== null && r.windowMs !== undefined);
  const black = ok.filter((r) => r.pictureMs === null).length;
  const times = ok.filter((r) => r.pictureMs !== null).map((r) => r.pictureMs).sort((a, b) => a - b);
  return { measured: ok.length, blackAfter20s: black, blackAtFirstSample: ok.filter((r) => r.firstLuma <= 12).length, medianMsToPicture: times[Math.floor(times.length / 2)] ?? null };
};
report.summary = { with: sum(report.with), without: sum(report.without) };
await finish(0);
