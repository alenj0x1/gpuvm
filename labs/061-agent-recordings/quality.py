"""Lab 061, part 2: rate control. A mean bitrate (VBR) blurs text for about a second after a big change (a menu
opening: cutB frame 1579, SSIM 0.75 at 2 Mb/s), because the encoder spreads its budget. Constant quality lets the
bitrate follow the picture. Each variant against the same recorder at 40 Mb/s (same frames kept): mean SSIM, the
worst 1 % of frames, frames under 0.95, MB per minute and CPU.

    python labs/061-agent-recordings/quality.py [--rounds 2]   (after run.py, which leaves out/cut*.es/.times)
"""
import argparse, json, os, re, statistics, subprocess, time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
BIN = os.path.join(OUT, "bin", "rectest.exe")
VARIANTS = {
    "vbr-2M": ["--bitrate", "2000000"],
    "vbr-3M": ["--bitrate", "3000000"],
    "q50": ["--quality", "50"],
    "q60": ["--quality", "60"],
    "q70": ["--quality", "70"],
    "q80": ["--quality", "80"],
}


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def rec(cut, name, args):
    out = os.path.join(OUT, f"{cut}-{name}.mp4")
    r = sh([BIN, "--codec", "hevc", "--video", os.path.join(OUT, cut + ".es"), "--times", os.path.join(OUT, cut + ".times"),
            "--fps", "30", *args, "--out", out])
    res = json.loads(r.stdout.strip().splitlines()[-1])
    res["file"] = out
    res["mb_min"] = os.path.getsize(out) / 2**20 / res["seconds"] * 60
    return res


def frame_ssim(a, ref):
    stats = a + ".ssim.txt"
    lavfi = f"[0:v]setpts=PTS-STARTPTS[a];[1:v]setpts=PTS-STARTPTS[b];[a][b]ssim=stats_file='{os.path.basename(stats)}'"
    subprocess.run(["ffmpeg", "-v", "error", "-i", a, "-i", ref, "-lavfi", lavfi, "-f", "null", "-"], cwd=OUT,
                   capture_output=True)
    vals = sorted(float(m) for m in re.findall(r"All:([0-9.]+)", open(stats).read()))
    return {"ssim": round(statistics.mean(vals), 5), "ssim_p1": round(vals[len(vals) // 100], 4),
            "under_095": sum(v < 0.95 for v in vals), "frames_compared": len(vals)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=2)
    a = ap.parse_args()
    refs = {cut: rec(cut, "ref40M", ["--bitrate", "40000000"])["file"] for cut in ("cutA", "cutB")}
    rows = []
    with open(os.path.join(OUT, "quality.jsonl"), "a", encoding="utf-8") as log:
        for rnd in range(1, a.rounds + 1):
            for cut in ("cutA", "cutB"):
                for name, args in VARIANTS.items():
                    res = rec(cut, name, args)
                    row = {"at": time.strftime("%H:%M:%S"), "round": rnd, "cut": cut, "variant": name,
                           "mb_min": round(res["mb_min"], 2), "cpu_per_video_s": round(res["cpu_per_video_s"], 3),
                           "worst_push_ms": round(res["worst_push_ms"], 1), "summary": res["summary"]}
                    if rnd == 1:
                        row.update(frame_ssim(res["file"], refs[cut]))
                    log.write(json.dumps(row) + "\n")
                    log.flush()
                    rows.append(row)
                    print(json.dumps(row), flush=True)
    print("\nvariant | MB/min A, B | CPU (median) | SSIM A, B | worst 1% A, B | frames < 0.95 A, B")
    for name in VARIANTS:
        rs = [r for r in rows if r["variant"] == name]
        r1 = {r["cut"]: r for r in rs if r["round"] == 1}
        mb = ", ".join(f"{statistics.median(r['mb_min'] for r in rs if r['cut'] == c):.1f}" for c in ("cutA", "cutB"))
        print(f"{name} | {mb} | {statistics.median(r['cpu_per_video_s'] for r in rs):.2f} | "
              f"{r1['cutA']['ssim']}, {r1['cutB']['ssim']} | {r1['cutA']['ssim_p1']}, {r1['cutB']['ssim_p1']} | "
              f"{r1['cutA']['under_095']}, {r1['cutB']['under_095']}")


if __name__ == "__main__":
    main()
