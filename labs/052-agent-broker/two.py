"""Lab 052: two agent machines at once, through two MCP servers (two `gpuvm.exe --mcp` processes = two agent
sessions), like two Claude Code windows.

  python two.py --exe <gpuvm.exe> [--template agent-tpl] [--rounds 30]

Phases: both create a disposable copy at the same time; each tries the other's machine (must be refused); latency of
screenshot/click/run with ONE session working (the other idle), then with BOTH working at once; crossed replies
(each runs/writes/reads its own marker while the other does the same); the person takes control of A (Suspend-
GpuVMAgent through the module) while B keeps working; both destroy their copies. A sampler records the host's CPU,
free RAM and GPU use per phase. Results go to out/<time>-two.json.
"""
import argparse, json, os, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "053-mcp"))
from drive import Mcp, stats, save  # noqa: E402

PHASE = {"name": "start"}
SAMPLES = []


def sampler(stop):
    while not stop.is_set():
        row = {"t": time.time(), "phase": PHASE["name"]}
        try:
            g = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu,memory.used", "--format=csv,noheader,nounits"],
                               capture_output=True, text=True, timeout=10).stdout.strip().split(",")
            row["gpu"], row["gpuMemMB"] = float(g[0]), float(g[1])
        except Exception:
            pass
        try:
            # WMI, not Get-Counter: counter names are translated on a Spanish Windows.
            ps = ("$p = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter \"Name='_Total'\").PercentProcessorTime;"
                  "$f = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024); \"$p,$f\"")
            v = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True, timeout=20).stdout.strip().split(",")
            row["cpu"], row["freeMB"] = float(v[0]), float(v[1])
        except Exception:
            pass
        SAMPLES.append(row)
        stop.wait(2)


def machine_of(text):
    return text.split("machine ")[1].split(" ")[0].strip(".,:") if "machine " in text else None


def work(m, machine, rounds, label, rows):
    """screenshot, click and run, interleaved; each run echoes a marker that must come back to this session."""
    for r in range(rounds):
        for name, args in (("screenshot", {"machine": machine}), ("click", {"machine": machine, "x": 5, "y": 5}),
                           ("run", {"machine": machine, "command": f"echo {label}-{r}", "shell": "cmd"})):
            out = m.tool(name, **args)
            crossed = name == "run" and not out["error"] and f"{label}-{r}" not in out["text"]
            rows.append({"who": label, "round": r, "tool": name, "ms": out["ms"], "error": out["error"], "crossed": crossed,
                         "text": out["text"][:120]})


def summary(rows):
    s = {}
    for tool in ("screenshot", "click", "run"):
        ok = [x["ms"] for x in rows if x["tool"] == tool and not x["error"]]
        s[tool] = stats(ok)
        s[tool]["errors"] = sum(1 for x in rows if x["tool"] == tool and x["error"])
    s["crossed"] = sum(1 for x in rows if x["crossed"])
    return s


def module(cmd):
    path = os.path.join(os.environ["ProgramFiles"], "GpuVM", "gpuvm", "src", "GpuVM", "GpuVM.psd1")
    return subprocess.run(["pwsh", "-NoProfile", "-Command", f"Import-Module '{path}'; {cmd} | ConvertTo-Json -Compress -Depth 4"],
                          capture_output=True, text=True, timeout=120)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--template", default="agent-tpl")
    ap.add_argument("--rounds", type=int, default=30)
    a = ap.parse_args()
    report = {"rounds": a.rounds}
    stop = threading.Event()
    threading.Thread(target=sampler, args=(stop,), daemon=True).start()
    A, B = Mcp(a.exe, False, "modern"), Mcp(a.exe, False, "modern")
    made = {}
    try:
        # 1. Both create a disposable at the same time.
        PHASE["name"] = "create"
        created = {}

        def create(label, m):
            c = m.tool("create_disposable", template=a.template, memoryGB=4, task=f"Lab 052: two agents ({label})")
            created[label] = c
        ts = [threading.Thread(target=create, args=(k, v)) for k, v in (("A", A), ("B", B))]
        [t.start() for t in ts]
        [t.join() for t in ts]
        for k in ("A", "B"):
            c = created[k]
            made[k] = machine_of(c["text"]) if not c["error"] else None
            report[f"create{k}"] = {"ms": round(c["ms"]), "error": c["error"], "text": c["text"][:300], "machine": made[k]}
            print(f"create {k}: {round(c['ms'])} ms -> {made[k]} {c['text'][:160]}", flush=True)
        if not (made["A"] and made["B"]):
            raise SystemExit("a copy failed")
        ma, mb = made["A"], made["B"]

        # 2. Each tries the other's machine.
        PHASE["name"] = "isolation"
        iso = {}
        for who, m, other in (("A", A, mb), ("B", B, ma)):
            for name, args in (("screenshot", {"machine": other}), ("run", {"machine": other, "command": "echo x", "shell": "cmd"}),
                               ("click", {"machine": other, "x": 5, "y": 5}), ("destroy", {"machine": other})):
                out = m.tool(name, **args)
                iso[f"{who}->{name}"] = {"refused": out["error"], "text": out["text"][:160]}
        report["isolation"] = iso
        print("isolation:", json.dumps({k: v["refused"] for k, v in iso.items()}), flush=True)

        # 3. One session working, the other idle.
        PHASE["name"] = "one"
        rows_one = []
        work(A, ma, a.rounds, "A", rows_one)
        report["one"] = summary(rows_one)
        print("one:", json.dumps(report["one"]), flush=True)

        # 4. Both at once, each its own markers (crossed replies counted).
        PHASE["name"] = "both"
        rows_a, rows_b = [], []
        ts = [threading.Thread(target=work, args=(A, ma, a.rounds, "A", rows_a)), threading.Thread(target=work, args=(B, mb, a.rounds, "B", rows_b))]
        [t.start() for t in ts]
        [t.join() for t in ts]
        report["bothA"], report["bothB"] = summary(rows_a), summary(rows_b)
        print("both A:", json.dumps(report["bothA"]), flush=True)
        print("both B:", json.dumps(report["bothB"]), flush=True)
        # Files: each writes its own content at the same time and reads it back.
        files = {}

        def files_of(label, m, machine):
            ok = 0
            for r in range(10):
                content = f"{label}-{r}-" + label * 500
                m.tool("write_file", machine=machine, path="Desktop\\lab052two.txt", content=content)
                got = m.tool("read_file", machine=machine, path="Desktop\\lab052two.txt")
                ok += content in got["text"]
            files[label] = ok
        ts = [threading.Thread(target=files_of, args=("A", A, ma)), threading.Thread(target=files_of, args=("B", B, mb))]
        [t.start() for t in ts]
        [t.join() for t in ts]
        report["filesOwnContentBack"] = files
        print("files back:", files, flush=True)

        # 5. The person takes control of A; B goes on.
        PHASE["name"] = "control"
        s = module(f"Suspend-GpuVMAgent -Name '{ma}' -Reason control")
        a_paused = A.tool("screenshot", machine=ma)
        b_works = B.tool("screenshot", machine=mb)
        b_run = B.tool("run", machine=mb, command="echo still-B", shell="cmd")
        r = module(f"Resume-GpuVMAgent -Name '{ma}'")
        a_back = A.tool("screenshot", machine=ma)
        report["control"] = {"suspend": s.returncode == 0, "AWhilePaused": {"error": a_paused["error"], "text": a_paused["text"][:160]},
                             "BWhileAPaused": {"screenshotError": b_works["error"], "runOk": "still-B" in b_run["text"], "ms": round(b_works["ms"])},
                             "resume": r.returncode == 0, "AAfterResume": {"error": a_back["error"]}}
        print("control:", json.dumps(report["control"]), flush=True)
        PHASE["name"] = "idle-end"
        time.sleep(6)
    finally:
        PHASE["name"] = "destroy"
        for k, m in (("A", A), ("B", B)):
            if made.get(k):
                d = m.tool("destroy", machine=made[k])
                report[f"destroy{k}"] = {"error": d["error"], "text": d["text"][:200], "ms": round(d["ms"])}
        A.close()
        B.close()
        stop.set()
        time.sleep(1)
        host = {}
        for ph in sorted({s["phase"] for s in SAMPLES}):
            rows = [s for s in SAMPLES if s["phase"] == ph]
            host[ph] = {k: stats([r[k] for r in rows if k in r]) for k in ("cpu", "freeMB", "gpu", "gpuMemMB")}
        report["host"] = host
        print("host:", json.dumps({p: {k: v.get("p50") for k, v in d.items()} for p, d in host.items()}), flush=True)
        print("saved", save("two", report), flush=True)


if __name__ == "__main__":
    main()
