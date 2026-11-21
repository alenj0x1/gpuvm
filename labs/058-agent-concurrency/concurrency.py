"""Lab 058: can an agent look at the screen while a command runs, and does delayMs wait what it says?

  python -I concurrency.py [--exe "C:\\Program Files\\GpuVM\\gpuvm.exe"] [--machine NAME | --template agent-tpl]
                           [--memory 4] [--new] [--keep] [--rounds 5]

Drives `gpuvm.exe --mcp` over stdio like an MCP client, but with several calls in flight at once (Claude Code sends
calls one after another when one of them isn't read-only, so it can't show this; the MCP server itself runs every
call on its own thread).

Phases (all against one disposable machine, created here unless --machine is given, destroyed at the end unless
--keep):
- alone:     `screenshot` x rounds, one at a time (the reference).
- during:    `run Start-Sleep 30` in flight; meanwhile `screenshot` x rounds, one every ~4 s (random +-1 s), and a
             `key shift` after each; each call timed from request written to reply read. Then the run's own time.
- --new only (needs a build with `delayMs` and `run background`):
  - delay:   `screenshot delayMs 2000` x rounds (expected ~2 s + the alone time).
  - background: `run Start-Sleep 30 background:true`, screenshots while it runs, then `run_result waitSeconds 60`.
Raw results: out/<time>.json (git-ignored); a summary is printed.
"""
import argparse, json, os, random, statistics, subprocess, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))


class Mcp:
    """A concurrent JSON-RPC client: a reader thread files every reply by id."""

    def __init__(self, exe):
        # Buffered stdout (lab 053: bufsize=0 costs one system call per byte in readline).
        self.p = subprocess.Popen([exe, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=-1)
        self.lock = threading.Lock()
        self.cv = threading.Condition(self.lock)
        self.replies, self.next, self.stderr = {}, 0, []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._drain, daemon=True).start()
        self.wait(self.send("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                           "clientInfo": {"name": "lab058", "version": "1"}}), 30)
        self._write({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _drain(self):
        for line in self.p.stderr:
            self.stderr.append(line.decode("utf-8", "replace").rstrip())

    def _read(self):
        for line in self.p.stdout:
            msg = json.loads(line)
            with self.cv:
                self.replies[msg.get("id")] = (time.perf_counter(), msg)
                self.cv.notify_all()

    def _write(self, msg):
        with self.lock:
            self.p.stdin.write((json.dumps(msg) + "\n").encode())
            self.p.stdin.flush()

    def send(self, method, params):
        with self.lock:
            self.next += 1
            n = self.next
        t0 = time.perf_counter()
        self._write({"jsonrpc": "2.0", "id": n, "method": method, "params": params})
        return n, t0

    def wait(self, sent, timeout):
        n, t0 = sent
        end = time.time() + timeout
        with self.cv:
            while n not in self.replies:
                if time.time() > end:
                    raise TimeoutError(f"no reply to {n} in {timeout} s; stderr: {self.stderr[-3:]}")
                self.cv.wait(0.5)
            t1, msg = self.replies.pop(n)
        res = msg.get("result", {})
        texts = [c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"]
        images = [c for c in res.get("content", []) if c.get("type") == "image"]
        return {"ms": round((t1 - t0) * 1000, 1), "error": bool(res.get("isError")), "text": "\n".join(texts)[:300], "images": len(images)}

    def tool(self, tool_name, timeout=120, **args):
        return self.wait(self.call(tool_name, **args), timeout)

    def call(self, tool_name, **args):
        return self.send("tools/call", {"name": tool_name, "arguments": args})

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(15)
        except Exception:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(self.p.pid)], capture_output=True)


def summary(label, rows):
    ms = [r["ms"] for r in rows if not r["error"]]
    bad = sum(1 for r in rows if r["error"])
    if ms:
        print(f"{label:28} n={len(ms)} min={min(ms):7.0f} median={statistics.median(ms):7.0f} max={max(ms):7.0f} ms" + (f"  errors={bad}" if bad else ""))
    else:
        print(f"{label:28} all {bad} failed: {rows[0]['text'] if rows else ''}")


def screenshots_during(m, machine, run_sent, rounds, with_key):
    shots, keys = [], []
    for _ in range(rounds):
        time.sleep(4 + random.uniform(-1, 1))
        shots.append(m.tool("screenshot", machine=machine, maxWidth=1280))
        if with_key:
            keys.append(m.tool("key", machine=machine, keys="shift"))
    return shots, keys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default=r"C:\Program Files\GpuVM\gpuvm.exe")
    ap.add_argument("--machine")
    ap.add_argument("--template", default="agent-tpl")
    ap.add_argument("--memory", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--new", action="store_true")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    out = {"exe": a.exe, "started": time.strftime("%Y-%m-%d %H:%M:%S"), "rounds": a.rounds}
    m = Mcp(a.exe)
    machine, created = a.machine, False
    try:
        if not machine:
            machine = f"c058-{random.randrange(16**4):04x}"
            t = time.perf_counter()
            r = m.tool("create_disposable", timeout=900, template=a.template, name=machine, memoryGB=a.memory, task="lab 058: concurrency")
            out["create"] = r
            if r["error"]:
                raise SystemExit(f"create_disposable failed: {r['text']}")
            created = True
            print(f"created {machine} in {time.perf_counter() - t:.0f} s")
        else:
            print(m.tool("take_machine", machine=machine)["text"][:120])
        m.tool("screenshot", machine=machine)  # warm-up (screen size, first capture)

        out["alone"] = [m.tool("screenshot", machine=machine, maxWidth=1280) for _ in range(a.rounds)]
        summary("screenshot alone", out["alone"])

        run_sent = m.call("run", machine=machine, command="Start-Sleep 30; 'slept'", timeoutSeconds=60)
        shots, keys = screenshots_during(m, machine, run_sent, a.rounds, True)
        run = m.wait(run_sent, 120)
        out["during"] = {"screenshots": shots, "keys": keys, "run": run}
        summary("screenshot during run", shots)
        summary("key during run", keys)
        print(f"{'run Start-Sleep 30':28} {run['ms']:.0f} ms {'ERROR ' + run['text'] if run['error'] else ''}")

        if a.new:
            out["delay"] = [m.tool("screenshot", machine=machine, maxWidth=1280, delayMs=2000) for _ in range(a.rounds)]
            summary("screenshot delayMs 2000", out["delay"])
            out["click_delay"] = [m.tool("key", machine=machine, keys="shift", delayMs=1000, screenshotAfter=True) for _ in range(3)]
            summary("key delayMs 1000 + after", out["click_delay"])
            started = m.tool("run", machine=machine, command="Start-Sleep 30; 'slept'", timeoutSeconds=60, background=True)
            print(f"{'run background (start)':28} {started['ms']:.0f} ms: {started['text'][:80]}")
            run_id = next((w.strip(".,:") for w in started["text"].split() if w.startswith("run-")), None)
            shots, keys = screenshots_during(m, machine, None, a.rounds, True)
            result = m.tool("run_result", timeout=120, machine=machine, runId=run_id, waitSeconds=60)
            out["background"] = {"start": started, "screenshots": shots, "keys": keys, "result": result}
            summary("screenshot during bg run", shots)
            summary("key during bg run", keys)
            print(f"{'run_result':28} {result['ms']:.0f} ms: {result['text'][:80]!r}")
    finally:
        if created and not a.keep:
            r = m.tool("destroy", timeout=600, machine=machine)
            print(f"destroyed {machine}: {r['text'][:100]}")
        m.close()
        path = os.path.join(HERE, "out", time.strftime("%Y%m%d-%H%M%S") + ".json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1)
        print("raw:", path)


if __name__ == "__main__":
    main()
