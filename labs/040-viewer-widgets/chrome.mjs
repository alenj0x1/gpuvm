// Lab 040's headless Chrome: started with a profile of its own and always ended with its whole process tree, even when
// the lab fails or is interrupted. (Nov 17, 2026: `proc.kill()` ended only the launcher; five headless Chromes kept
// running for hours and took ~37 % of the GPU that the VMs share, which made every stream measure 5x slower.)
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const killTree = (pid) => { try { spawnSync("taskkill", ["/PID", String(pid), "/T", "/F"], { stdio: "ignore" }); } catch { /* gone */ } };

// Leftovers of an earlier run (a lab040- profile in the command line): ended before starting a new one.
export function sweepLeftovers() {
  spawnSync("powershell", ["-NoProfile", "-Command",
    "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | Where-Object CommandLine -match 'lab040-' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"],
    { stdio: "ignore" });
}

export async function startChrome(extraArgs = []) {
  sweepLeftovers();
  const profile = mkdtempSync(join(tmpdir(), "lab040-"));
  const debug = 9300 + Math.floor(Math.random() * 500);
  const proc = spawn("C:/Program Files/Google/Chrome/Application/chrome.exe",
    ["--headless=new", `--remote-debugging-port=${debug}`, `--user-data-dir=${profile}`, "--no-first-run", ...extraArgs, "about:blank"], { stdio: "ignore" });
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    killTree(proc.pid);
    sweepLeftovers();
    try { rmSync(profile, { recursive: true, force: true }); } catch { /* still locked: the next sweep's profile is new anyway */ }
  };
  process.on("exit", close);
  for (const signal of ["SIGINT", "SIGTERM", "SIGBREAK"]) process.on(signal, () => { close(); process.exit(130); });
  process.on("uncaughtException", (e) => { console.error(e); close(); process.exit(1); });
  let target;
  for (let i = 0; i < 50 && !target; i++) {
    await new Promise((r) => setTimeout(r, 200));
    try { target = (await (await fetch(`http://127.0.0.1:${debug}/json`)).json()).find((t) => t.type === "page"); } catch { /* not up yet */ }
  }
  return { target, close };
}
