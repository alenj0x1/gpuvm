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
writeFileSync(join(out, "notify.json"), JSON.stringify({ machine, shots }, null, 1));
await tool("destroy", { machine });
clearTimeout(guard); mcp.kill();
console.log("ok");
process.exit(0);
