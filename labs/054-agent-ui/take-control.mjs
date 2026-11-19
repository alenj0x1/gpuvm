// Lab 054, real machine: an agent session over `gpuvm.exe --mcp` (as Claude Code would), the person's input over the
// viewer, and how long until the broker says the agent is paused (take control). Also the hidden viewer's GPU cost
// while GpuVM records an agent's work (option B).
//   node labs/054-agent-ui/take-control.mjs <machine> [rounds=10]
// Needs the installed build, the machine running with GpuVM's agent, and its viewer open (gpuvm.exe --view <machine>).
import { spawn, execFileSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const machine = process.argv[2];
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
const guard = setTimeout(() => { console.error("timed out"); mcp.kill(); process.exit(3); }, 10 * 60000);

await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "lab054", version: "1.0" } });
mcp.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
const took = await tool("take_machine", { machine, task: "Lab 054: take-control latency" });
console.log("take_machine:", text(took).slice(0, 200));

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
  const t0 = Number(execFileSync("pwsh", ["-NoProfile", "-File", join(here, "input.ps1")]).toString().trim());
  if (!Number.isFinite(t0)) { console.error("no viewer window"); break; }
  let t1 = null;
  for (let i = 0; i < 400 && t1 === null; i++) { if (await paused()) t1 = Date.now(); else await sleep(5); }
  samples.push(t1 === null ? null : t1 - t0);
  console.log(`round ${r + 1}: ${t1 === null ? "not paused in 2 s" : `${t1 - t0} ms`}`);
  // Back to the agent for the next round: the person's Resume, as the notch's button does.
  execFileSync("pwsh", ["-NoProfile", "-Command", `Import-Module 'C:\\Program Files\\GpuVM\\gpuvm\\src\\GpuVM' -ErrorAction Stop; Resume-GpuVMAgent -Name '${machine}' | Out-Null`], { stdio: "ignore" });
  await sleep(2500);
}
const ok = samples.filter((s) => s !== null).sort((a, b) => a - b);
const pct = (p) => ok[Math.min(ok.length - 1, Math.floor(p * ok.length))];
const report = { machine, rounds, samples, p50: pct(0.5), p95: pct(0.95), misses: samples.filter((s) => s === null).length };
writeFileSync(join(out, "take-control.json"), JSON.stringify(report, null, 1));
console.log(JSON.stringify(report));
await tool("release_machine", { machine });
clearTimeout(guard);
mcp.kill();
process.exit(0);
