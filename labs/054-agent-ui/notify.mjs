// Lab 054, installed app: what the person gets when an agent calls request_human. A disposable of our own, the request,
// screenshots of the Windows notification (bottom-right) and of GpuVM's window (dock and sidebar), then cancel and destroy.
//   node labs/054-agent-ui/notify.mjs [template:agent-tpl]
import { spawn, execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const template = (process.argv[2] ?? "template:agent-tpl").replace(/^template:/, "");
const exe = "C:\\Program Files\\GpuVM\\gpuvm.exe";
const out = join(here, "out"); mkdirSync(out, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
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
const guard = setTimeout(() => { console.error("timed out"); mcp.kill(); process.exit(3); }, 15 * 60000);
const ps = (file, args) => { try { return execFileSync("pwsh", ["-NoProfile", "-File", join(here, file), ...args]).toString().trim(); } catch { return "failed"; } };

await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "lab054", version: "1.0" } });
mcp.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
const machine = `lab054n-${new Date().toISOString().slice(11, 19).replace(/:/g, "")}`;
const made = await tool("create_disposable", { template, name: machine, task: "Lab 054: request_human notification", cpu: 2, memoryGB: Number(process.env.LAB054_MEMORY_GB ?? 4) });
console.log("create_disposable:", text(made).slice(0, 300));
if (made?.isError) { clearTimeout(guard); mcp.kill(); process.exit(4); }
// Ready: take_machine again until it says so (the copy may still be starting).
for (let i = 0; i < 30; i++) {
  const r = text(await tool("take_machine", { machine, task: "Lab 054: notifications" }));
  if (!/not ready|keep waiting/i.test(r)) break;
  await sleep(10000);
}
// The request, without waiting: the notification, the dock and the sidebar's count should come at once.
const t0 = Date.now();
const asked = await tool("request_human", { machine, message: "Accept the UAC prompt to install the printer driver." });
console.log("request_human:", text(asked).slice(0, 200));
const shots = {};
// The app polls the broker every 2-5 s: shots up to 14 s (the first run's 6 s showed nothing yet).
for (const ms of [2000, 5000, 9000, 14000]) {
  await sleep(Math.max(0, t0 + ms - Date.now()));
  shots[`toast-${ms}`] = ps("screen-shot.ps1", ["-Out", join(out, `installed-human-toast-${ms}.png`)]);
}
shots.app = ps("window-shot.ps1", ["-Out", join(out, "installed-human-app.png")]);
// What the broker says meanwhile (the app reads the same command).
try {
  shots.broker = execFileSync("pwsh", ["-NoProfile", "-Command", `Import-Module 'C:\\Program Files\\GpuVM\\gpuvm\\src\\GpuVM' -ErrorAction Stop; Get-GpuVMAgentClient | Where-Object machine -eq '${machine}' | Select-Object name,state,reason | ConvertTo-Json -Compress`]).toString().trim();
} catch (e) { shots.broker = "failed: " + String(e.message).slice(0, 200); }
console.log("broker:", shots.broker);
const cancel = await tool("cancel_request", { machine });
console.log("cancel_request:", text(cancel).slice(0, 200));

// A copy from this PC (send) with GpuVM out of view (minimized; agent-mcp saw nothing with it in the tray): its
// Windows notification must come anyway, and the tray icon carries the mark. Windows' own history says whether
// GpuVM posted it, whatever Focus Assist does with the banner.
const history = () => { try { return execFileSync("powershell.exe", ["-NoProfile", "-Command",
  "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null; $h = [Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory('dev.alejandro.gpuvm'); foreach ($t in $h) { $t.Content.GetXml() }"]).toString(); } catch { return ""; } };
const win = (cmd) => { try { execFileSync("pwsh", ["-NoProfile", "-Command", `Add-Type -Namespace L54 -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);'; $p = Get-Process gpuvm -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1; if ($p) { [L54.W]::ShowWindow($p.MainWindowHandle, ${cmd}) | Out-Null }`]); } catch { /* no window */ } };
win(6); // SW_MINIMIZE
await sleep(1500);
const before = history();
const tSend = Date.now();
const sending = tool("send_file", { machine, hostPath: join(here, "README.md"), reason: "Lab 054: the notification of a copy from the PC" });
for (const ms of [2500, 6000]) {
  await sleep(Math.max(0, tSend + ms - Date.now()));
  shots[`send-toast-${ms}`] = ps("screen-shot.ps1", ["-Out", join(out, `installed-send-toast-${ms}.png`)]);
}
await sleep(2000);
const after = history();
const sendToast = after.split("<toast").find((t) => /wants to copy to|quiere copiar a/.test(t) && t.includes(machine) && !before.includes(t)) ?? null;
shots.sendToastPosted = !!sendToast;
shots.sendToastXml = sendToast ? `<toast${sendToast}`.slice(0, 400) : null;
shots.sendToastMs = Date.now() - tSend;
// The tray area (bottom-right corner, where the icon with its dot is).
shots.tray = ps("screen-shot.ps1", ["-Out", join(out, "installed-send-tray.png"), "-Width", "360", "-Height", "60"]);
console.log("send notification posted:", shots.sendToastPosted);
try {
  execFileSync("pwsh", ["-NoProfile", "-Command", `Import-Module 'C:\\Program Files\\GpuVM\\gpuvm\\src\\GpuVM' -ErrorAction Stop; Get-GpuVMAgentRequest | Where-Object { $_.machine -eq '${machine}' -and $_.state -eq 'pending' } | ForEach-Object { Resolve-GpuVMAgentRequest -Id $_.id -Allow:$false | Out-Null }`]);
} catch { /* answered */ }
await sending;
win(9); // SW_RESTORE
writeFileSync(join(out, "notify.json"), JSON.stringify({ machine, shots }, null, 1));
await tool("destroy", { machine });
clearTimeout(guard); mcp.kill();
console.log("ok");
process.exit(0);
