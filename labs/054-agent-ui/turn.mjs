// Lab 054, one turn of the shared lock: take-control.mjs, notify.mjs, refresh.mjs one after another (each on its own
// disposable copy, destroyed at its end). A copy that comes up without a display (agent-broker, 2 of 10) fails its
// script early: that script runs once more on a new copy.
//   node labs/054-agent-ui/turn.mjs [template:agent-tpl]
import { spawnSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const template = process.argv[2] ?? "template:agent-tpl";
const results = {};
for (const script of ["take-control.mjs", "notify.mjs", "refresh.mjs"]) {
  for (let attempt = 1; attempt <= 2; attempt++) {
    const t0 = Date.now();
    const r = spawnSync(process.execPath, [join(here, script), template, "10"], { stdio: "inherit", timeout: 40 * 60000 });
    results[script] = { attempt, code: r.status, minutes: Math.round((Date.now() - t0) / 6000) / 10 };
    console.log(`== ${script} attempt ${attempt}: exit ${r.status}`);
    // 4: no copy; 5: no picture (a copy without a display): a new copy once.
    if (r.status !== 4 && r.status !== 5) break;
  }
}
console.log("turn:", JSON.stringify(results));
