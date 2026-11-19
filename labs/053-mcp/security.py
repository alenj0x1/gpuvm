"""Lab 053 part 6: the security fixes on the installed build, with a direct MCP client (no model).

  python security.py --exe <gpuvm.exe> --template agent-tpl

The person's side (answering requests, taking control) is played through the module, as the app does. Cases:
create with only cpu/memory; the normal flow (screenshot, click, run); open_viewer on a machine that isn't ours;
send_file → a pending `send` request with the service's own title, nothing copied while it waits, the person says no;
destroy while the person has control (refused), then destroy. Results: out/<time>-security.json; host screenshots of the
pending request in out/host-*.png.
"""
import argparse, json, os, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from drive import Mcp, save  # noqa: E402

MODULE = r"C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1"


def person(command):
    script = f"Import-Module '{MODULE}' -Force -DisableNameChecking; {command} | ConvertTo-Json -Compress -Depth 6"
    r = subprocess.run(["pwsh", "-NoProfile", "-Command", script], capture_output=True, text=True, timeout=120)
    out = r.stdout.strip()
    try:
        return json.loads(out) if out else None
    except ValueError:
        return {"raw": (out or r.stderr.strip())[:400]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--template", default="agent-tpl")
    a = ap.parse_args()
    rows, failures = [], []

    def case(label, out, expect_error, contains):
        ok = out["error"] == expect_error and all(c.lower() in out["text"].lower() for c in contains)
        rows.append({"case": label, "error": out["error"], "ms": round(out["ms"]), "text": out["text"][:400], "ok": ok})
        print(("OK  " if ok else "BAD ") + label + ": " + out["text"][:170].replace("\n", " "), flush=True)
        if not ok:
            failures.append(label)
        return out

    def check(label, ok, detail):
        rows.append({"case": label, "ok": ok, "text": str(detail)[:400]})
        print(("OK  " if ok else "BAD ") + label + ": " + str(detail)[:170], flush=True)
        if not ok:
            failures.append(label)

    A = Mcp(a.exe, False, "modern")
    machine = None
    host_file = os.path.join(os.environ.get("TEMP", HERE), f"lab053-send-{os.getpid()}.bin")
    try:
        # Create with only cpu/memory (the service denies anything else to an agent).
        c = case("create_disposable cpu/memory only", A.tool("create_disposable", template=a.template, cpu=2, memoryGB=4, task="Lab 053: security"), False, ["Created disposable machine"])
        if c["error"]:
            raise SystemExit("no machine")
        machine = c["text"].split("machine ")[1].split(" ")[0]

        # The normal flow.
        case("screenshot", A.tool("screenshot", machine=machine), False, ["Screenshot"])
        case("click", A.tool("click", machine=machine, x=5, y=5), False, ["Done"])
        case("run", A.tool("run", machine=machine, command="echo lab053", shell="cmd"), False, ["Exit code 0", "lab053"])

        # open_viewer only on our own machines.
        case("open_viewer on a machine that isn't ours", A.tool("open_viewer", machine="win-gpu"), True, [])

        # send_file: a pending `send` request; nothing copied meanwhile; the person says no.
        with open(host_file, "wb") as f:
            f.write(os.urandom(1 << 20))
        result = {}
        t = threading.Thread(target=lambda: result.update(A.tool("send_file", machine=machine, hostPath=host_file, reason="Lab 053: checking the send approval")))
        t.start()
        pending = None
        for _ in range(60):
            reqs = person("Get-GpuVMAgentRequest")
            reqs = reqs if isinstance(reqs, list) else [reqs] if reqs else []
            pending = next((r for r in reqs if isinstance(r, dict) and r.get("kind") == "send" and r.get("state") == "pending"
                            and str(r.get("machine", "")).lower() == machine.lower()), None)
            if pending:
                break
            time.sleep(1)
        check("send request pending (as the person sees it)", bool(pending), pending)
        if pending:
            title = pending.get("title", "")
            check("title written by the service", "send" in title.lower() and "1 file" in title.lower(), title)
            check("request carries the measure", pending.get("files") == 1 and pending.get("bytes") == (1 << 20), {k: pending.get(k) for k in ("paths", "files", "bytes")})
            # The person's view while it waits (the app should show the request).
            subprocess.run(["pwsh", "-NoProfile", "-File", os.path.join(HERE, "host-shot.ps1")], capture_output=True, timeout=60)
            time.sleep(3)
            subprocess.run(["pwsh", "-NoProfile", "-File", os.path.join(HERE, "host-shot.ps1")], capture_output=True, timeout=60)
            rows.append({"case": "person: Resolve-GpuVMAgentRequest -Allow:$false", "text": str(person(f"Resolve-GpuVMAgentRequest -Id '{pending['id']}' -Allow:$false"))[:300]})
        t.join(timeout=600)
        check("send_file refused after the person said no", result.get("error") is True and "said no" in result.get("text", ""), result.get("text"))
        name = os.path.basename(host_file)
        case("nothing was copied", A.tool("read_file", machine=machine, path=f"Desktop\\Received\\{name}"), True, [])

        # destroy while the person has control: refused; after they hand it back, destroyed.
        rows.append({"case": "person: Suspend-GpuVMAgent -Reason control", "text": str(person(f"Suspend-GpuVMAgent -Name '{machine}' -Reason control"))[:300]})
        case("destroy while the person has control", A.tool("destroy", machine=machine), True, ["took control"])
        exists = subprocess.run(["pwsh", "-NoProfile", "-Command", f"[bool](Get-VM -Name '{machine}' -ErrorAction SilentlyContinue)"], capture_output=True, text=True).stdout.strip()
        check("machine still there", exists == "True", exists)
        rows.append({"case": "person: Resume-GpuVMAgent", "text": str(person(f"Resume-GpuVMAgent -Name '{machine}'"))[:300]})
        case("destroy", A.tool("destroy", machine=machine), False, ["deleted"])
        time.sleep(3)
        gone = subprocess.run(["pwsh", "-NoProfile", "-Command", f"[bool](Get-VM -Name '{machine}' -ErrorAction SilentlyContinue)"], capture_output=True, text=True).stdout.strip()
        check("VM gone after destroy", gone == "False", gone)
        machine = None
    finally:
        if machine:
            person(f"Resume-GpuVMAgent -Name '{machine}'")
            A.tool("destroy", machine=machine, force=True)
        A.close()
        try:
            os.remove(host_file)
        except OSError:
            pass
        path = save("security", {"rows": rows, "failures": failures, "stderr": A.stderr[-40:]})
        print("saved", path, "failures:", failures or "none", flush=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
