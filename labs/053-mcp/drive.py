"""Lab 053: drive `gpuvm.exe --mcp` over stdio like an MCP client and measure it.

  python drive.py --exe <gpuvm.exe> [--fake] [--era modern|legacy] [--machine NAME | --template T]
                  [--phases latency,coords,misuse] [--rounds 40]

- latency: every tool end to end (request written -> reply parsed), rounds interleaved with random pauses;
  screenshot payload sizes. With --fake it is the MCP layer alone (the reference).
- coords: real machines only. For several screenshot sizes, pick random screenshot pixels, `act move` there,
  read the real cursor position inside the VM with `run`, and compare with the expected desktop pixel.
- misuse: bad arguments, unknown tools, out-of-range coordinates, paths outside the profile, huge outputs, a
  destroyed machine; records each error text.
Raw results go to out/<time>-<phase>.json (git-ignored); a summary is printed.
"""
import argparse, base64, json, os, random, statistics, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))


class Mcp:
    def __init__(self, exe, fake, era):
        args = [exe, "--mcp"] + (["--fake"] if fake else [])
        # Buffered: with bufsize=0 Python's readline reads one byte per system call, which added ~17 ms per 36 KB of
        # base64 to every screenshot (~85 ms at 1280 px) and was the instrument's cost, not the server's (overhead.py).
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=-1)
        self.era, self.next, self.stderr = era, 0, []
        threading.Thread(target=self._drain, daemon=True).start()
        if era == "legacy":
            r = self.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                        "clientInfo": {"name": "lab053", "version": "1"}})
            self.version = r["result"]["protocolVersion"]
            self._write({"jsonrpc": "2.0", "method": "notifications/initialized"})
        else:
            r = self.rpc("server/discover", {})
            self.version = "2026-07-28" if "2026-07-28" in r["result"]["supportedVersions"] else None

    def _drain(self):
        for line in self.p.stderr:
            self.stderr.append(line.decode("utf-8", "replace").rstrip())

    def _write(self, msg):
        self.p.stdin.write((json.dumps(msg) + "\n").encode())
        self.p.stdin.flush()

    def rpc(self, method, params):
        self.next += 1
        if self.era == "modern":
            params = dict(params)
            params["_meta"] = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                               "io.modelcontextprotocol/clientInfo": {"name": "lab053", "version": "1"},
                               "io.modelcontextprotocol/clientCapabilities": {}}
        self._write({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params})
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("server closed: " + "\n".join(self.stderr[-5:]))
            msg = json.loads(line)
            if msg.get("id") == self.next:
                return msg

    def tool(self, name, **args):
        t0 = time.perf_counter()
        r = self.rpc("tools/call", {"name": name, "arguments": args})
        ms = (time.perf_counter() - t0) * 1000
        res = r.get("result", {})
        texts = [c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"]
        images = [c for c in res.get("content", []) if c.get("type") == "image"]
        return {"ms": ms, "error": res.get("isError", False), "text": "\n".join(texts), "images": images,
                "bytes": sum(len(base64.b64decode(i["data"])) for i in images)}

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(10)
        except Exception:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(self.p.pid)], capture_output=True)


def stats(values):
    v = sorted(values)
    if not v:
        return {}
    return {"n": len(v), "mean": round(statistics.mean(v), 2), "p50": round(v[len(v) // 2], 2),
            "p95": round(v[min(len(v) - 1, int(len(v) * 0.95))], 2), "max": round(v[-1], 2)}


def save(name, data):
    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    path = os.path.join(HERE, "out", time.strftime("%Y%m%d-%H%M%S") + f"-{name}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    return path


def phase_latency(m, machine, rounds):
    calls = [
        ("list_machines", {}),
        ("screenshot", {"machine": machine}),
        ("screenshot_640", {"machine": machine, "maxWidth": 640, "maxHeight": 400}),
        ("screenshot_png", {"machine": machine, "format": "png"}),
        ("click", {"machine": machine, "x": 5, "y": 5}),
        ("key", {"machine": machine, "keys": "shift"}),
        ("ui_tree", {"machine": machine}),
        ("run", {"machine": machine, "command": "echo hi", "shell": "cmd"}),
        ("write_file", {"machine": machine, "path": "Desktop\\lab053.txt", "content": "x" * 1000}),
        ("read_file", {"machine": machine, "path": "Desktop\\lab053.txt"}),
    ]
    rows = []
    for r in range(rounds):
        order = calls[:]
        random.shuffle(order)
        for label, args in order:
            name = label.split("_6")[0].replace("_png", "")
            out = m.tool(name, **args)
            rows.append({"round": r, "tool": label, "ms": out["ms"], "error": out["error"], "bytes": out["bytes"],
                         "text": out["text"][:200]})
            time.sleep(random.uniform(0.0, 0.05))
    summary = {}
    for label, _ in calls:
        ok = [x["ms"] for x in rows if x["tool"] == label and not x["error"]]
        summary[label] = stats(ok)
        summary[label]["errors"] = sum(1 for x in rows if x["tool"] == label and x["error"])
        sizes = [x["bytes"] for x in rows if x["tool"] == label and x["bytes"]]
        if sizes:
            summary[label]["image_kb"] = round(statistics.mean(sizes) / 1024, 1)
    return {"rows": rows, "summary": summary}


def phase_coords(m, machine, samples):
    """Expected desktop pixel = centre of the screenshot pixel's footprint (geometry.rs); the VM reports where the
    cursor really went."""
    boxes = [(1280, 800), (1024, 768), (640, 400), (2576, 2576), (333, 222)]
    rows = []
    read = "Add-Type -AssemblyName System.Windows.Forms; $p=[System.Windows.Forms.Cursor]::Position; \"$($p.X),$($p.Y)\""
    for (bw, bh) in boxes:
        s = m.tool("screenshot", machine=machine, maxWidth=bw, maxHeight=bh)
        if s["error"]:
            rows.append({"box": [bw, bh], "error": s["text"]})
            continue
        # "Screenshot N of m: WxH (desktop DWxDH, scale ...)"
        head = s["text"].split(": ", 1)[1]
        sw, sh = map(int, head.split(" ")[0].split("x"))
        dw, dh = map(int, head.split("desktop ")[1].split(",")[0].split("x"))
        for _ in range(samples):
            x, y = random.randrange(sw), random.randrange(sh)
            a = m.tool("act", machine=machine, actions=[{"type": "move", "x": x, "y": y}])
            got = m.tool("run", machine=machine, command=read)
            try:
                gx, gy = map(int, got["text"].split("---\n")[1].strip().split(","))
            except Exception:
                rows.append({"box": [bw, bh], "x": x, "y": y, "error": got["text"][:200] or a["text"][:200]})
                continue
            ex = ((2 * x + 1) * dw) // (2 * sw)
            ey = ((2 * y + 1) * dh) // (2 * sh)
            same_pixel = (gx * sw) // dw == x and (gy * sh) // dh == y
            rows.append({"box": [bw, bh], "sent": [sw, sh], "desktop": [dw, dh], "x": x, "y": y,
                         "expected": [ex, ey], "got": [gx, gy], "same_pixel": same_pixel,
                         "err_px": max(abs(gx - ex), abs(gy - ey))})
    ok = [r for r in rows if "got" in r]
    return {"rows": rows, "summary": {"samples": len(ok), "same_pixel": sum(r["same_pixel"] for r in ok),
                                      "max_err_px": max([r["err_px"] for r in ok], default=None),
                                      "errors": len(rows) - len(ok)}}


def phase_misuse(m, machine):
    cases = [
        ("unknown tool", "nope", {}),
        ("missing machine", "screenshot", {}),
        ("unknown machine", "screenshot", {"machine": "ghost-machine"}),
        ("x not a number", "click", {"machine": machine, "x": "left", "y": 1}),
        ("x outside", "click", {"machine": machine, "x": 99999, "y": 1}),
        ("old screenshot id", "click", {"machine": machine, "x": 1, "y": 1, "screenshot": 999999}),
        ("bad zoom", "screenshot", {"machine": machine, "zoom": [1, 2]}),
        ("too big box", "screenshot", {"machine": machine, "maxWidth": 10000}),
        ("path outside profile", "read_file", {"machine": machine, "path": "C:\\Windows\\win.ini"}),
        ("dot-dot path", "write_file", {"machine": machine, "path": "C:\\Users\\agent\\..\\Public\\x.txt", "content": "x"}),
        ("offer outside outbox", "offer_file", {"machine": machine, "path": "Desktop\\x.txt", "note": "n"}),
        ("other drive", "read_file", {"machine": machine, "path": "D:\\x.txt"}),
        ("huge output", "run", {"machine": machine, "command": "'x' * 3000000", "timeoutSeconds": 60}),
        ("long type", "type", {"machine": machine, "text": "x" * 6000}),
        ("act with bad item", "act", {"machine": machine, "actions": [{"type": "move", "x": 1, "y": 1}, {"type": "fly"}]}),
    ]
    rows = []
    for label, name, args in cases:
        out = m.tool(name, **args)
        rows.append({"case": label, "tool": name, "error": out["error"], "ms": round(out["ms"], 1),
                     "chars": len(out["text"]), "text": out["text"][:300]})
    return {"rows": rows}


def phase_finale(m, machine):
    """Destroy the disposable, then use it: the error must say it's gone."""
    d = m.tool("destroy", machine=machine)
    after = m.tool("screenshot", machine=machine)
    return {"rows": [{"case": "destroy", "error": d["error"], "ms": round(d["ms"]), "text": d["text"][:200]},
                     {"case": "screenshot after destroy", "error": after["error"], "ms": round(after["ms"]), "text": after["text"][:300]}]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--fake", action="store_true")
    ap.add_argument("--era", default="modern", choices=["modern", "legacy"])
    ap.add_argument("--machine")
    ap.add_argument("--template")
    ap.add_argument("--phases", default="latency,misuse")
    ap.add_argument("--rounds", type=int, default=40)
    ap.add_argument("--samples", type=int, default=12)
    ap.add_argument("--memory", type=int, default=4, help="GB for a created disposable")
    a = ap.parse_args()

    m = Mcp(a.exe, a.fake, a.era)
    report = {"exe": a.exe, "fake": a.fake, "era": a.era, "version": m.version}
    created = None
    try:
        t0 = time.perf_counter()
        if a.template:
            extra = {"name": a.machine} if a.machine else {}
            c = m.tool("create_disposable", template=a.template, memoryGB=a.memory, task="Lab 053: measuring the MCP server", **extra)
            report["create"] = {"ms": c["ms"], "text": c["text"], "error": c["error"]}
            print("create:", round(c["ms"]), "ms", c["text"][:200])
            machine = c["text"].split("machine ")[1].split(" ")[0] if not c["error"] else None
            created = machine
        else:
            machine = a.machine or "work-pc"
            t = m.tool("take_machine", machine=machine)
            report["take"] = {"ms": t["ms"], "text": t["text"], "error": t["error"]}
            print("take:", round(t["ms"]), "ms", t["text"][:200])
        if not machine:
            raise SystemExit("no machine")
        first = m.tool("screenshot", machine=machine)
        report["first_screenshot"] = {"ms": first["ms"], "text": first["text"], "bytes": first["bytes"]}
        if first["images"]:
            img = first["images"][0]
            ext = "png" if img["mimeType"] == "image/png" else "webp"
            path = os.path.join(HERE, "out", time.strftime("%Y%m%d-%H%M%S") + f"-{a.era}-first.{ext}")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(base64.b64decode(img["data"]))
            report["first_screenshot"]["file"] = path
        for ph in a.phases.split(","):
            if ph == "latency":
                r = phase_latency(m, machine, a.rounds)
            elif ph == "coords":
                r = phase_coords(m, machine, a.samples)
            elif ph == "misuse":
                r = phase_misuse(m, machine)
            elif ph == "finale":
                r = phase_finale(m, machine)
                created = None
            else:
                continue
            report[ph] = r
            print(f"== {ph}")
            print(json.dumps(r.get("summary") or r["rows"], indent=1)[:6000])
        report["total_s"] = round(time.perf_counter() - t0, 1)
    finally:
        # A disposable this run created never outlives it (the finale phase destroys it on purpose).
        if created:
            try:
                report["cleanup"] = m.tool("destroy", machine=created)["text"]
            except Exception as e:
                report["cleanup"] = f"failed: {e}"
        m.close()
        report["server_stderr"] = m.stderr[-50:]
        print("saved", save("run", report))


if __name__ == "__main__":
    main()
