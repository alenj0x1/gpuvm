// Prepares what the installer carries besides the app (runs before `tauri build`):
// - gpuvm-host.exe, the GpuVM service (app/host), built in release.
// - PowerShell 7 (tools.json: pinned version, SHA-256 checked) extracted to .cache/pwsh. The service runs the
//   module with it: the Store's PowerShell only runs for processes with its package identity, which a process
//   started by a service does not get.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createReadStream, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const app = join(dirname(fileURLToPath(import.meta.url)), "..");
const cache = join(app, ".cache");
const tools = JSON.parse(readFileSync(join(app, "tools.json"), "utf8"));

function sha256(file) {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    createReadStream(file).on("data", (d) => hash.update(d)).on("end", () => resolve(hash.digest("hex"))).on("error", reject);
  });
}

async function download(url, file, expected) {
  if (existsSync(file) && (await sha256(file)) === expected) return;
  console.log(`Descargando ${url}`);
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status}`);
  const partial = `${file}.part`;
  writeFileSync(partial, Buffer.from(await response.arrayBuffer()));
  const actual = await sha256(partial);
  if (actual !== expected) {
    rmSync(partial);
    throw new Error(`SHA-256 distinto para ${url}: ${actual}`);
  }
  renameSync(partial, file);
}

mkdirSync(cache, { recursive: true });

// PowerShell 7: extracted again only when the version changes.
const pwsh = tools.pwsh;
const zip = join(cache, `PowerShell-${pwsh.version}-win-x64.zip`);
const dest = join(cache, "pwsh");
const stamp = join(dest, ".version");
await download(pwsh.url, zip, pwsh.sha256);
if (!existsSync(stamp) || readFileSync(stamp, "utf8") !== pwsh.version) {
  rmSync(dest, { recursive: true, force: true });
  mkdirSync(dest);
  // Windows' own tar (Git's breaks on "C:" paths).
  execFileSync(join(process.env.SystemRoot ?? "C:\\Windows", "System32", "tar.exe"), ["-xf", zip, "-C", dest], { stdio: "inherit" });
  writeFileSync(stamp, pwsh.version);
}

// The service, always into host/target (where tauri.conf.json takes it from), whatever CARGO_TARGET_DIR says.
execFileSync("cargo", ["build", "--release", "--manifest-path", join(app, "host", "Cargo.toml"), "--target-dir", join(app, "host", "target")], { stdio: "inherit" });
