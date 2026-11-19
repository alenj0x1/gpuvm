"""Where a tool call's time goes between the MCP client and the server (lab 053, overhead).

  python overhead.py --exe <gpuvm.exe> [--fake | --template T | --machine NAME] [--n 30]

For each call it records the client's time (request written -> reply parsed) and the server's own time for the same
call (GPUVM_MCP_LOG=1 makes the server log "<tool> <ms> ms" on stderr); the difference is the stdio transfer plus
the client's parsing. The client runs with an unbuffered pipe (bufsize=0, what drive.py used first: Python's
readline then reads one byte per system call) and a buffered one, interleaved. With --template it creates its own
disposable in each session and destroys it.
"""
import argparse, json, os, re, statistics, subprocess, threading, time


def session(a, bufsize):
    env = dict(os.environ, GPUVM_MCP_LOG="1")
    args = [a.exe, "--mcp"] + (["--fake"] if a.fake else [])
    p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=bufsize, env=env)
    server, lock = [], threading.Lock()

    def drain():
        for line in p.stderr:
            m = re.search(rb"\] (\w+) (\d+) ms", line)
            if m:
                with lock:
                    server.append((m.group(1).decode(), int(m.group(2))))
    threading.Thread(target=drain, daemon=True).start()
    meta = {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientInfo": {"name": "lab053-overhead", "version": "1"},
            "io.modelcontextprotocol/clientCapabilities": {}}
    i = [0]

    def tool(name, **args):
        i[0] += 1
        msg = {"jsonrpc": "2.0", "id": i[0], "method": "tools/call", "params": {"name": name, "arguments": args, "_meta": meta}}
        p.stdin.write((json.dumps(msg) + "\n").encode())
        p.stdin.flush()
        while True:
            reply = json.loads(p.stdout.readline())
            if reply.get("id") == i[0]:
                return reply["result"]

    machine = a.machine
    created = None
    try:
        if a.template:
            r = tool("create_disposable", template=a.template, memoryGB=4, task="Lab 053: overhead")
            assert not r.get("isError"), r
            machine = created = r["content"][0]["text"].split("machine ")[1].split(" ")[0]
        else:
            r = tool("take_machine", machine=machine)
            assert not r.get("isError"), r
        tool("screenshot", machine=machine)  # warm-up
        rows = []
        for k in range(a.n):
            for name, args in (("screenshot", {"maxWidth": a.max, "maxHeight": a.max}), ("ui_tree", {})):
                t0 = time.perf_counter()
                r = tool(name, machine=machine, **args)
                ms = (time.perf_counter() - t0) * 1000
                size = len(r["content"][0].get("data", "")) if r.get("content") else 0
                rows.append({"tool": name, "client": ms, "b64": size, "error": r.get("isError", False)})
    finally:
        if created:
            tool("destroy", machine=created, force=True)
        elif not a.template:
            tool("release_machine", machine=machine)
        p.stdin.close()
        p.wait(60)
        time.sleep(0.3)
    with lock:
        srv = [s for s in server if s[0] in ("screenshot", "ui_tree")][1:]  # without the warm-up
    for row, s in zip(rows, srv):
        assert row["tool"] == s[0], (row, s)
        row["server"] = s[1]
    return rows


def p(v, q=0.5):
    v = sorted(v)
    return round(v[min(len(v) - 1, int(len(v) * q))], 1) if v else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--fake", action="store_true")
    ap.add_argument("--template")
    ap.add_argument("--machine", default="work-pc")
    ap.add_argument("--n", type=int, default=30)
    ap.add_argument("--max", type=int, default=1280)
    a = ap.parse_args()
    out = {}
    for label, bufsize in (("unbuffered", 0), ("buffered", -1), ("unbuffered-2", 0), ("buffered-2", -1))[: 2 if a.template else 4]:
        rows = session(a, bufsize)
        for t in ("screenshot", "ui_tree"):
            r = [x for x in rows if x["tool"] == t and not x["error"] and "server" in x]
            out[f"{label}/{t}"] = {"n": len(r), "client_p50": p([x["client"] for x in r]), "client_p95": p([x["client"] for x in r], 0.95),
                                   "server_p50": p([x["server"] for x in r]), "server_p95": p([x["server"] for x in r], 0.95),
                                   "transfer_p50": p([x["client"] - x["server"] for x in r]),
                                   "b64_kb": round(statistics.mean([x["b64"] for x in r]) / 1024, 1) if r else None}
            print(f"{label}/{t}", out[f"{label}/{t}"], flush=True)
    os.makedirs(os.path.join(os.path.dirname(__file__), "out"), exist_ok=True)
    with open(os.path.join(os.path.dirname(__file__), "out", time.strftime("%Y%m%d-%H%M%S") + "-overhead.json"), "w") as f:
        json.dump({"args": vars(a), "results": out}, f, indent=1)


if __name__ == "__main__":
    main()
