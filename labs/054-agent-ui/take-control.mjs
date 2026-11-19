// Lab 054, real machine: an agent session over `gpuvm.exe --mcp` (as Claude Code would), the person's input over the
// viewer, and how long until the broker says the agent is paused (take control). Also the hidden viewer's GPU cost
// while GpuVM records an agent's work (option B).
//   node labs/054-agent-ui/take-control.mjs <machine | template:<name>> [rounds=10]
// Needs the installed build, the machine running with GpuVM's agent, and its viewer open (gpuvm.exe --view <machine>).
import { spawn, execFileSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
let machine = process.argv[2];
const rounds = Number(process.argv[3] ?? 10);
if (!machine) { console.error("usage: take-control.mjs <machine> [rounds]"); process.exit(2); }
const exe = "C:\\Program Files\\GpuVM\\gpuvm.exe";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const out = join(here, "out"); mkdirSync(out, { recursive: true });

// The MCP client: newline-delimited JSON-RPC over the server's stdio.
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
// Fail fast instead of hanging (lab-craft).
const guard = setTimeout(() => { console.error("timed out"); mcp.kill(); process.exit(3); }, 25 * 60000);

await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "lab054", version: "1.0" } });
mcp.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
// `template:<name>`: a disposable of our own from that template (create_disposable installs the agent and takes it),
// destroyed at the end. Otherwise an existing machine of ours, taken.
const disposable = machine.startsWith("template:");
// A name of its own each run: a folder left by an earlier run that couldn't be deleted never blocks the next.
const runName = `lab054-${new Date().toISOString().slice(11, 19).replace(/:/g, "")}`;
if (disposable) {
  // Light (2 threads, LAB054_MEMORY_GB or 2 GB): the PC keeps its memory, and the measurement doesn't need more.
  const made = await tool("create_disposable", { template: machine.slice(9), name: runName, task: "Lab 054: take-control latency", cpu: 2, memoryGB: Number(process.env.LAB054_MEMORY_GB ?? 2) });
  console.log("create_disposable:", text(made).slice(0, 300));
  // Fail fast: without the machine there is nothing to measure (lab-craft).
  if (made?.isError) { clearTimeout(guard); mcp.kill(); process.exit(4); }
  machine = runName;
} else {
  const took = await tool("take_machine", { machine, task: "Lab 054: take-control latency" });
  console.log("take_machine:", text(took).slice(0, 200));
}

/** GPU use of the viewer processes (every engine of their pids), averaged over `seconds`. */
const viewerGpu = (seconds) => {
  const ps = `$ids = (Get-Process GpuVMViewer -ErrorAction SilentlyContinue).Id; if (-not $ids) { 'none'; exit }
    $s = Get-Counter '\\GPU Engine(*)\\Utilization Percentage' -SampleInterval 1 -MaxSamples ${seconds} -ErrorAction SilentlyContinue
    $v = foreach ($x in $s.CounterSamples) { if ($ids | Where-Object { $x.InstanceName -like "pid_$($_)_*" }) { $x } }
    $byTime = $v | Group-Object Timestamp | ForEach-Object { ($_.Group | Measure-Object CookedValue -Sum).Sum }
    [math]::Round(($byTime | Measure-Object -Average).Average, 2)`;
  return execFileSync("pwsh", ["-NoProfile", "-Command", ps]).toString().trim();
};
// Option B: with the session working and no viewer open, GpuVM opens one hidden and records. Its GPU cost, then the
// person opens the machine (open_viewer) and that same viewer comes out.
/** Waits (keeping the session working) until a viewer process is up, or `seconds` pass; true when it is. */
const viewerUp = async (seconds, windowed = false) => {
  for (let i = 0; i < seconds / 3; i++) {
    const up = execFileSync("pwsh", ["-NoProfile", "-Command", `@(Get-Process GpuVMViewer -ErrorAction SilentlyContinue${windowed ? " | Where-Object MainWindowHandle -ne 0" : ""}).Count`]).toString().trim();
    if (Number(up) > 0) return true;
    await tool("screenshot", { machine, maxWidth: 320, maxHeight: 200 });
    await sleep(2000);
  }
  return false;
};
// Opening a machine takes a while the first time (Sunshine's first session): up to 2 minutes.
const hiddenStart = Date.now();
const hiddenOpened = await viewerUp(240);
console.log("hidden viewer up after ms:", Date.now() - hiddenStart);
console.log("hidden viewer opened:", hiddenOpened);
await sleep(8000);
const hiddenGpu = viewerGpu(20);
console.log("hidden viewer GPU %:", hiddenGpu);
/** A screenshot of the GpuVM window's area (what's on screen there: the app, the picture and its notch). */
const shot = (name) => { try { console.log(name, execFileSync("pwsh", ["-NoProfile", "-File", join(here, "window-shot.ps1"), "-Out", join(out, `${name}.png`)]).toString().trim()); } catch (e) { console.log(name, "failed"); } };
shot("installed-app-recording-hidden");
// First frame: from open_viewer until the viewer's window shows and until its picture isn't black. With ddx a still
// desktop may stay black until something on screen changes: after 20 s black, the agent opens Start (key win) once.
const tOpen = Date.now();
await tool("open_viewer", { machine });
const luma = () => { try { return execFileSync("pwsh", ["-NoProfile", "-File", join(here, "luma.ps1")]).toString().trim(); } catch { return "none"; } };
let tWindow = null, tPicture = null, poked = null;
while (Date.now() - tOpen < 180000 && tPicture === null) {
  const l = luma();
  if (l !== "none") {
    if (tWindow === null) tWindow = Date.now();
    if (Number(l) > 12) tPicture = Date.now();
    else if (!poked && Date.now() - tWindow > 20000) { poked = Date.now(); await tool("key", { machine, keys: "win" }); }
  } else {
    await tool("screenshot", { machine, maxWidth: 320, maxHeight: 200 });
  }
  if (tPicture === null) await sleep(500);
}
if (poked) await tool("key", { machine, keys: "escape" });
const firstFrame = { windowMs: tWindow && tWindow - tOpen, pictureMs: tPicture && tPicture - tOpen, blackUntilChange: !!poked, pictureAfterChangeMs: poked && tPicture ? tPicture - poked : null };
console.log("first frame:", JSON.stringify(firstFrame));
const windowed = tWindow !== null;
console.log("viewer window:", windowed);
if (!windowed) {
  // Nothing to measure without the picture (Sunshine not answering in the machine, 2026-11-19): say it and clean up.
  writeFileSync(join(out, "take-control.json"), JSON.stringify({ machine, error: "no viewer opened in 3 min", hiddenOpened, hiddenGpu, firstFrame }, null, 1));
  await tool(disposable ? "destroy" : "release_machine", { machine });
  clearTimeout(guard); mcp.kill(); process.exit(5);
}
await sleep(6000);
shot("installed-picture-working");
const shownGpu = viewerGpu(10);
console.log("shown viewer GPU %:", shownGpu);

/** Whether the person paused this machine's agent, as list_machines says. */
const paused = async () => {
  const r = await tool("list_machines", {});
  const all = JSON.stringify(r?.structuredContent ?? text(r));
  const i = all.indexOf(`"${machine}"`);
  return i >= 0 && /"by":\s*"person"|paused by the person|person/i.test(all.slice(i, i + 600));
};

const samples = [];
for (let r = 0; r < rounds; r++) {
  // Keep the session working (activity in the last 15 s), then the person moves the mouse over the picture.
  await tool("screenshot", { machine, maxWidth: 320, maxHeight: 200 });
  await sleep(1500);
  let t0;
  try { t0 = Number(execFileSync("pwsh", ["-NoProfile", "-File", join(here, "input.ps1")]).toString().trim()); } catch { t0 = NaN; }
  if (!Number.isFinite(t0)) { console.error("no viewer window"); break; }
  let t1 = null;
  for (let i = 0; i < 400 && t1 === null; i++) { if (await paused()) t1 = Date.now(); else await sleep(5); }
  samples.push(t1 === null ? null : t1 - t0);
  console.log(`round ${r + 1}: ${t1 === null ? "not paused in 2 s" : `${t1 - t0} ms`}`);
  // The notch "You took control" over the picture, once (agent.rs shows it with the broker's answer).
  if (r === 0) { await sleep(1500); shot("installed-take-control"); }
  // Back to the agent for the next round: the person's Resume, as the notch's button does.
  execFileSync("pwsh", ["-NoProfile", "-Command", `Import-Module 'C:\\Program Files\\GpuVM\\gpuvm\\src\\GpuVM' -ErrorAction Stop; Resume-GpuVMAgent -Name '${machine}' | Out-Null`], { stdio: "ignore" });
  await sleep(2500);
}
const ok = samples.filter((s) => s !== null).sort((a, b) => a - b);
const pct = (p) => ok[Math.min(ok.length - 1, Math.floor(p * ok.length))];
const report = { machine, rounds, hiddenOpened, hiddenGpu, shownGpu, firstFrame, samples, p50: pct(0.5), p95: pct(0.95), misses: samples.filter((s) => s === null).length };
writeFileSync(join(out, "take-control.json"), JSON.stringify(report, null, 1));
console.log(JSON.stringify(report));
await tool(disposable ? "destroy" : "release_machine", { machine });
clearTimeout(guard);
mcp.kill();
process.exit(0);
