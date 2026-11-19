"""Lab 053 part 5: withdrawing the agent's own request to the person (cancel_request) on a real disposable.

  python cancel.py --exe <gpuvm.exe> --template agent-tpl

Session A (the agent) creates a disposable. The person's side is played by the module's own commands (what the app
calls): Suspend-GpuVMAgent / Resume-GpuVMAgent. Session B is a second MCP client. Each case records the tool's text
and whether it was an error; the run fails loudly if a refusal doesn't happen. Results: out/<time>-cancel.json.
"""
import argparse, json, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drive import Mcp, save  # noqa: E402

MODULE = r"C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1"


def person(command):
    """The person's side, through the module (administrators-only pipe), like the app."""
    script = f"Import-Module '{MODULE}' -Force -DisableNameChecking; {command} | ConvertTo-Json -Compress -Depth 5"
    r = subprocess.run(["pwsh", "-NoProfile", "-Command", script], capture_output=True, text=True, timeout=120)
    return (r.stdout.strip() or r.stderr.strip())[:300]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--template", default="agent-tpl")
    a = ap.parse_args()
    rows, failures = [], []

    def case(label, out, expect_error, must_contain):
        ok = out["error"] == expect_error and must_contain.lower() in out["text"].lower()
        rows.append({"case": label, "error": out["error"], "ms": round(out["ms"]), "text": out["text"][:300], "ok": ok})
        print(("OK  " if ok else "BAD ") + label + ": " + out["text"][:160].replace("\n", " "), flush=True)
        if not ok:
            failures.append(label)

    A = Mcp(a.exe, False, "modern")
    B = None
    machine = None
    try:
        c = A.tool("create_disposable", template=a.template, memoryGB=4, task="Lab 053: cancel_request")
        assert not c["error"], c["text"]
        machine = c["text"].split("machine ")[1].split(" ")[0]
        print("created", machine, round(c["ms"]), "ms", flush=True)
        A.tool("screenshot", machine=machine)

        # 1. The agent's own request: paused for it, withdrawn, usable again.
        case("request_human", A.tool("request_human", machine=machine, message="Lab 053: nothing to do, the agent withdraws this."), False, "paused")
        case("acting while waiting", A.tool("screenshot", machine=machine), True, "cancel_request")
        case("cancel own request", A.tool("cancel_request", machine=machine), False, "yours again")
        # The pause is over when the broker no longer refuses with it; the guest may still show a secure screen
        # (a clone that just started), which is the guest's state, not the pause.
        out = A.tool("screenshot", machine=machine)
        paused = any(k in out["text"] for k in ("waiting for the person", "took control"))
        rows.append({"case": "usable again (no pause)", "error": out["error"], "text": out["text"][:300], "ok": not paused})
        print(("OK  " if not paused else "BAD ") + "usable again (no pause): " + out["text"][:160], flush=True)
        if paused:
            failures.append("usable again")
        case("cancel with nothing pending", A.tool("cancel_request", machine=machine), True, "no request to the person pending")

        # 2. The person took control on top of the agent's request: the agent can't end that pause.
        A.tool("request_human", machine=machine, message="Lab 053: the person takes control next.")
        rows.append({"case": "person: Suspend-GpuVMAgent -Reason control", "text": person(f"Suspend-GpuVMAgent -Name '{machine}' -Reason control")})
        case("cancel a pause the person started", A.tool("cancel_request", machine=machine), True, "took control")
        case("acting while the person has it", A.tool("screenshot", machine=machine), True, "took control")
        rows.append({"case": "person: Resume-GpuVMAgent", "text": person(f"Resume-GpuVMAgent -Name '{machine}'")})
        case("usable after the person resumes", A.tool("screenshot", machine=machine), False, "Screenshot")

        # 3. A request the person already answered (resumed) can't be withdrawn.
        A.tool("request_human", machine=machine, message="Lab 053: the person answers this one.")
        rows.append({"case": "person: Resume-GpuVMAgent (answers)", "text": person(f"Resume-GpuVMAgent -Name '{machine}'")})
        case("cancel an answered request", A.tool("cancel_request", machine=machine), True, "already answered")
        case("usable after the answer", A.tool("screenshot", machine=machine), False, "Screenshot")

        # 4. Another session: it has no request of A's to withdraw and can't take A's machine.
        A.tool("request_human", machine=machine, message="Lab 053: session B tries to withdraw this.")
        B = Mcp(a.exe, False, "modern")
        case("session B cancels A's request", B.tool("cancel_request", machine=machine), True, "no request to the person pending")
        case("session B takes A's machine", B.tool("take_machine", machine=machine, waitSeconds=0), True, "another agent")
        case("A's request still pending", A.tool("screenshot", machine=machine), True, "cancel_request")
        case("A withdraws it", A.tool("cancel_request", machine=machine), False, "yours again")

        # 5. Destroy: gone at once.
        case("destroy", A.tool("destroy", machine=machine), False, "deleted")
        time.sleep(3)
        gone = subprocess.run(["pwsh", "-NoProfile", "-Command", f"[bool](Get-VM -Name '{machine}' -ErrorAction SilentlyContinue)"],
                              capture_output=True, text=True).stdout.strip()
        rows.append({"case": "VM exists after destroy", "text": gone, "ok": gone == "False"})
        print(("OK  " if gone == "False" else "BAD ") + "VM gone after destroy: " + gone, flush=True)
        if gone != "False":
            failures.append("VM gone after destroy")
        machine = None
    finally:
        if machine:
            A.tool("cancel_request", machine=machine)
            A.tool("destroy", machine=machine, force=True)
        for m in (A, B):
            if m:
                m.close()
        path = save("cancel", {"rows": rows, "failures": failures, "stderr": A.stderr[-30:]})
        print("saved", path, "failures:", failures or "none", flush=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
