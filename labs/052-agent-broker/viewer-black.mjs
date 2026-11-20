// Lab 052 (from lab 054's refresh.mjs): the viewer black on agent machines, with Sunshine's log for each connect.
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

const here = join(dirname(fileURLToPath(import.meta.url)), "..", "054-agent-ui");
const mine = dirname(fileURLToPath(import.meta.url));
const template = (process.argv[2] ?? "template:agent-tpl").replace(/^template:/, "");
const connects = Number(process.argv[3] ?? 10);
const exe = "C:\\Program Files\\GpuVM\\gpuvm.exe";
const out = join(mine, "out"); mkdirSync(out, { recursive: true });
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
/** The same measure, also saving the picture it read (what "black" was on screen). */
const lumaShot = (file) => { try { return pwsh(`& '${join(mine, "luma-shot.ps1")}'${file ? ` -Save '${join(out, file)}'` : ""}`); } catch { return "none"; } };
/** "mean spread" → {mean, spread}; a picture has spread (a flat area is black or GpuVM's empty panel). */
const parseLuma = (s) => { const [m, sp] = String(s).split(" ").map(Number); return { mean: m, spread: sp ?? 0 }; };
// 60: a black stream framed by the panel spreads 22 (lab 052 shots), a desktop over 200.
const PICTURE_SPREAD = 60;
const viewers = () => Number(pwsh("@(Get-Process GpuVMViewer -ErrorAction SilentlyContinue).Count"));


const stamp = new Date().toISOString().slice(0, 19).replace(/[:T-]/g, "");
/** Sunshine's log and config and the guest's displays, to see which output it duplicated on each connect. */
function dumpGuest(vm) {
  // String.raw: the backslashes of the Windows paths reach PowerShell as they are.
  const ps = String.raw`$m = Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -PassThru; ` +
    String.raw`$c = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } '${vm}'; ` +
    String.raw`Invoke-Command -VMName '${vm}' -Credential $c { $d = 'C:\Program Files\Sunshine\config'; ` +
    String.raw`'=== conf'; Get-Content (Join-Path $d 'sunshine.conf'); '=== displays'; Get-CimInstance Win32_VideoController | % { "$($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" }; ` +
    String.raw`'=== agent logs'; Get-ChildItem 'C:\ProgramData\GpuVM\Agent\logs' -Filter *.log -ErrorAction SilentlyContinue | % { "--- $($_.Name)"; Get-Content $_.FullName -Tail 300 }; ` +
    String.raw`'=== log'; Get-Content (Join-Path $d 'sunshine.log') -Tail 200000 }`;
  writeFileSync(join(out, `viewer-black-${stamp}-guest.txt`), execFileSync("pwsh", ["-NoProfile", "-Command", ps], { maxBuffer: 256 << 20 }).toString());
}
let machine = null;
const report = { template, connects, with: [], without: [] };
async function finish(code) {
  clearTimeout(guard);
  // GpuVM as the person had it: no lab flag.
  try { report.appRestoredWithoutFlag = await startApp(false); } catch { report.appRestoredWithoutFlag = false; }
  report.approvalAtEnd = approval();
  if (machine) { try { dumpGuest(machine); } catch (e) { report.dumpError = String(e); } }
  if (machine) { try { await tool("destroy", { machine }); } catch { /* left */ } }
  writeFileSync(join(out, `viewer-black-${stamp}.json`), JSON.stringify(report, null, 1));
  console.log(JSON.stringify(report));
  mcp.kill();
  process.exit(code);
}

await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "lab054-refresh", version: "1.0" } });
mcp.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
/** The service's time to answer: it must stay 600 s however often GpuVM starts (the app used to write its own). */
const approval = () => { try { return JSON.parse(pwsh("Import-Module 'C:\\Program Files\\GpuVM\\gpuvm\\src\\GpuVM' -ErrorAction Stop; Get-GpuVMAgentSettings | ConvertTo-Json -Compress")).approvalTimeoutSec; } catch { return null; } };
report.approvalBefore = approval();
report.appStarted = await startApp(false);
report.approvalAfterStart = approval();
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
// LAB052_VARIANT=novideo: the Hyper-V display turned off once the copy is ready (only the virtual display stays on
// the desktop: no second display for Windows to reattach and the agent to take off again every 5 s).
if (process.env.LAB052_VARIANT === "novideo") {
  const ps = String.raw`$m = Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -PassThru; ` +
    String.raw`$c = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } '${machine}'; ` +
    String.raw`Invoke-Command -VMName '${machine}' -Credential $c { Get-PnpDevice -Class Display | ? FriendlyName -like '*Hyper-V*' | Disable-PnpDevice -Confirm:$false; ` +
    String.raw`Start-Sleep 5; (Get-CimInstance Win32_VideoController | % { "$($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" }) -join '; ' }`;
  report.novideo = execFileSync("pwsh", ["-NoProfile", "-Command", ps]).toString().trim();
  await sleep(8000);
  const shot = await tool("screenshot", { machine, maxWidth: 96, maxHeight: 64 });
  report.novideoScreenshot = shot?.isError ? text(shot) : "ok";
  console.log("novideo:", report.novideo, "| agent screenshot:", report.novideoScreenshot);
}
// LAB052_VARIANT=vddundo: the virtual display's settings as they were before 4652a80 (800x600@30 first, 1920x1080
// at 30), then a power cycle, to tell whether that change made the reopens slower.
if (process.env.LAB052_VARIANT === "vddundo") {
  // This branch's module (read-only): the installed one's power cycle could end its PowerShell (484930b).
  const ps = `$m = Import-Module '${join(mine, "..", "..", "src", "GpuVM", "GpuVM.psd1")}' -PassThru; ` +
    String.raw`$c = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } '${machine}'; ` +
    String.raw`$r = Invoke-Command -VMName '${machine}' -Credential $c { $p = 'C:\VirtualDisplayDriver\vdd_settings.xml'; [xml]$x = Get-Content -Raw $p; $l = $x.SelectSingleNode('//resolutions'); ` +
    String.raw`foreach ($e in @($l.SelectNodes('resolution'))) { if ($e.width -in '800', '1920') { [void]$l.RemoveChild($e) } }; ` +
    String.raw`foreach ($wh in @(@(1920, 1080), @(800, 600))) { $n = $x.CreateElement('resolution'); foreach ($kv in @(@('width', $wh[0]), @('height', $wh[1]), @('refresh_rate', 30))) { $e = $x.CreateElement($kv[0]); $e.InnerText = "$($kv[1])"; [void]$n.AppendChild($e) }; [void]$l.PrependChild($n) }; ` +
    String.raw`$x.Save($p); (@($l.SelectNodes('resolution')) | % { "$($_.width)x$($_.height)@$($_.refresh_rate)" }) -join ' ' }; ` +
    String.raw`& $m { param($n) Restart-GpuVMCold -Name $n } '${machine}'; $r`;
  report.vddundo = execFileSync("pwsh", ["-NoProfile", "-Command", ps]).toString().trim();
  console.log("vddundo:", report.vddundo);
  for (let i = 0; i < 30; i++) {
    await sleep(10000);
    const r = text(await tool("take_machine", { machine, task: "Lab 054: screen.refresh" }));
    if (!/not ready|keep waiting/i.test(r)) break;
  }
}
// LAB052_VARIANT=mttclear: what 4501f1b adds, on this copy (this branch's module, read-only): the stream mode first
// in vdd_settings.xml and Windows' saved layouts of the virtual display forgotten, then a power cycle.
// LAB052_SUNSHINE_DEBUG=1 (with mttclear): Sunshine's min_log_level = debug written into sunshine.conf before that
// power cycle, so Sunshine starts with it (why its capture restarts: DuplicateOutput's HRESULT).
if (process.env.LAB052_VARIANT === "mttclear") {
  const args = ["-NoProfile", "-File", join(mine, "prepare-copy.ps1"), "-Name", machine];
  if (process.env.LAB052_SUNSHINE_DEBUG === "1") args.push("-SunshineDebug");
  if (process.env.LAB052_STOP_AGENT === "1") args.push("-StopAgent");
  try { report.mttclear = execFileSync("pwsh", args).toString().trim(); }
  catch (e) { report.mttclear = `failed: ${String(e.stdout ?? "")}${String(e.stderr ?? e)}`.slice(-600); console.log("mttclear:", report.mttclear); await finish(5); }
  console.log("mttclear:", report.mttclear);
  for (let i = 0; i < (process.env.LAB052_STOP_AGENT === "1" ? 0 : 30); i++) {
    await sleep(10000);
    const r = text(await tool("take_machine", { machine, task: "Lab 054: screen.refresh" }));
    if (!/not ready|keep waiting/i.test(r)) break;
  }
}
// LAB052_DEBUG=1: Sunshine logs at debug level on this copy (why it restarts its capture), set the way GpuVM sets
// Sunshine's config (its API and a restart, Update-SunshineConfig), before any connect. (Editing sunshine.conf
// directly and restarting the service clashed with GpuVM's own update and left Sunshine refusing connections.)
if (process.env.LAB052_DEBUG === "1") {
  const ps = String.raw`$m = Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -PassThru; ` +
    String.raw`& $m { param($n) $s = Get-GpuVMState -Name $n; $a = Get-GpuVMAddress -Name $n -TimeoutSec 60; ` +
    String.raw`$null = Update-SunshineConfig -Address $a -Credential (Get-SunshineCredential -State $s) -Settings @{ min_log_level = 'debug' } -Name $n -GuestCredential (Get-GpuVMGuestCredential -State $s); 'debug on' } '${machine}'`;
  console.log(execFileSync("pwsh", ["-NoProfile", "-Command", ps]).toString().trim());
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
    // LAB052_NO_AGENT_SHOTS=1: no agent screenshot while waiting (each one opens a WGC capture of the display in the
    // guest, and the helper keeps it open): a call that doesn't touch the guest's screen instead.
    if (process.env.LAB052_NO_AGENT_SHOTS === "1") await tool("list_machines", {}); else await tool("screenshot", { machine, maxWidth: 96, maxHeight: 64 });
    // Every tool call is a step of the session's budget (500): asked every 5 s, not 1.5 s (the 2026-11-20 final run
    // used it up waiting and measured nothing).
    await sleep(5000);
  }
  if (hiddenMs === null) return { error: "no hidden viewer in 3 min" };
  await sleep(6000); // connected and settled, still desktop
  const tOpen = Date.now();
  // LAB052_VARIANT=nudge: screen.refresh every ~0.3 s for 10 s from the open (one PowerShell, in the background).
  if (process.env.LAB052_VARIANT === "nudge") {
    const ps = String.raw`Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1'; $t = [Diagnostics.Stopwatch]::StartNew(); ` +
      String.raw`while ($t.Elapsed.TotalSeconds -lt 10) { try { $null = Invoke-GpuVMAgent -Name '${machine}' -Method screen.refresh -TimeoutSec 3 } catch { }; Start-Sleep -Milliseconds 250 }`;
    spawn("pwsh", ["-NoProfile", "-Command", ps], { stdio: "ignore", detached: true }).unref();
  }
  await tool("open_viewer", { machine });
  let first = null, firstSpread = null, windowMs = null, pictureMs = null;
  const n = ++connectNo;
  while (Date.now() - tOpen < 20000 && pictureMs === null) {
    const raw = windowMs === null ? lumaShot(`viewer-black-${stamp}-c${n}-first.png`) : lumaShot(null);
    const l = raw === "none" ? "none" : parseLuma(raw);
    if (l !== "none") {
      if (windowMs === null) {
        windowMs = Date.now() - tOpen; first = l.mean; firstSpread = l.spread;
        // LAB052_VARIANT=nudgelate: the 10 s burst starts when the viewer's window shows (what the app does when it
        // reveals the viewer or it says "connected"), not when the open is asked.
        if (process.env.LAB052_VARIANT === "nudgelate") {
          const ps = String.raw`Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1'; $t = [Diagnostics.Stopwatch]::StartNew(); ` +
            String.raw`while ($t.Elapsed.TotalSeconds -lt 10) { try { $null = Invoke-GpuVMAgent -Name '${machine}' -Method screen.refresh -TimeoutSec 3 } catch { }; Start-Sleep -Milliseconds 250 }`;
          spawn("pwsh", ["-NoProfile", "-Command", ps], { stdio: "ignore", detached: true }).unref();
        }
      }
      if (l.spread > PICTURE_SPREAD) pictureMs = Date.now() - tOpen;
    }
    if (pictureMs === null) await sleep(250);
  }
  const last = parseLuma(lumaShot(`viewer-black-${stamp}-c${n}-end.png`));
  return { hiddenMs, windowMs, firstLuma: first, firstSpread, pictureMs, lastLuma: last.mean, lastSpread: last.spread };
}
let connectNo = 0;

for (const [variant, noRefresh] of [["with", false]]) {
  if (noRefresh) report.flagApp = await startApp(true);
  for (let i = 0; i < connects; i++) {
    const at = new Date().toISOString();
    const r = { at, ...(await connect()), done: new Date().toISOString() };
    report[variant].push(r);
    console.log(variant, i + 1, JSON.stringify(r));
  }
}
const sum = (list) => {
  const ok = list.filter((r) => r.windowMs !== null && r.windowMs !== undefined);
  const black = ok.filter((r) => r.pictureMs === null).length;
  const times = ok.filter((r) => r.pictureMs !== null).map((r) => r.pictureMs).sort((a, b) => a - b);
  return { measured: ok.length, blackAfter20s: black, blackAtFirstSample: ok.filter((r) => !(r.firstSpread > PICTURE_SPREAD)).length, medianMsToPicture: times[Math.floor(times.length / 2)] ?? null };
};
report.summary = { with: sum(report.with) };
await finish(0);
