"""Lab 061: agent recordings, before and after, on the same content.

Cuts 2-minute pieces of real agent recordings (the stream exactly as the viewer received it; read-only), and feeds each
through the viewer's light recorder (tools/rectest.exe: the GPU's decoder + Windows' H.264 encoder + the viewer's MP4
writer) for each variant, in interleaved rounds. Per run: MB per minute, CPU seconds per second of video, worst time
one frame held the recorder; on round 1 also SSIM against the stream (both at 30 fps) and whether Media Foundation
(Windows' own players) opens the file (lab 044's mfprobe, if built).

    python labs/061-agent-recordings/run.py --source "<recording.mp4>@<start s>" [...] [--rounds 2]

Results: out/results.jsonl (one line per run, raw) and a summary table on stdout.
"""
import argparse, json, os, re, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
BIN = os.path.join(OUT, "bin", "rectest.exe")
MFPROBE = os.path.join(HERE, "..", "044-capture-clips", "out", "bin", "mfprobe.exe")

# name: rectest arguments
VARIANTS = {
    "30fps-1M": ["--fps", "30", "--bitrate", "1000000"],
    "30fps-2M": ["--fps", "30", "--bitrate", "2000000"],
    "30fps-3M": ["--fps", "30", "--bitrate", "3000000"],
    "15fps-2M": ["--fps", "15", "--bitrate", "2000000"],
    # Decoding alone (one frame a second encoded): the decoder's share of the cost.
    "decode-only": ["--fps", "1", "--bitrate", "500000"],
}


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def prepare(source, start, name):
    mp4 = os.path.join(OUT, name + ".mp4")
    es = os.path.join(OUT, name + ".es")
    times = os.path.join(OUT, name + ".times")
    if not os.path.exists(times):
        sh(["ffmpeg", "-v", "error", "-y", "-ss", str(start), "-i", source, "-t", "120", "-c", "copy", mp4], check=True)
        codec = sh(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=codec_name", "-of", "csv=p=0", mp4]).stdout.strip()
        bsf = "hevc_mp4toannexb,hevc_metadata=aud=insert" if codec == "hevc" else "h264_mp4toannexb,h264_metadata=aud=insert"
        sh(["ffmpeg", "-v", "error", "-y", "-i", mp4, "-an", "-c:v", "copy", "-bsf:v", bsf, "-f", codec, es], check=True)
        with open(times, "w") as f:
            f.write(sh(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "packet=pts_time", "-of", "csv=p=0", mp4]).stdout)
    codec = sh(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=codec_name", "-of", "csv=p=0", mp4]).stdout.strip()
    dur = float(sh(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", mp4]).stdout)
    fps = sh(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=avg_frame_rate", "-of", "csv=p=0", mp4]).stdout.strip()
    num, den = (fps.split("/") + ["1"])[:2]
    return {"name": name, "mp4": mp4, "es": es, "times": times, "codec": codec, "seconds": dur,
            "bytes": os.path.getsize(mp4), "video_bytes": os.path.getsize(es), "fps": float(num) / float(den)}


def first_key_offset(src):
    # The recorder starts at the stream's first key frame: the source is compared from there, or every frame of the
    # comparison is off by that much (cutB's first round read 0.83-0.89 for that alone).
    rows = sh(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0",
               src]).stdout.split()
    first = None
    for row in rows:
        t, flags = row.split(",")[:2]
        first = float(t) if first is None else first
        if "K" in flags:
            return float(t) - first
    return 0.0


def ssim(out, src):
    lavfi = "[0:v]fps=30,setpts=PTS-STARTPTS[a];[1:v]fps=30,setpts=PTS-STARTPTS[b];[a][b]ssim"
    skip = f"{first_key_offset(src):.6f}"
    r = sh(["ffmpeg", "-hide_banner", "-i", out, "-hwaccel", "d3d11va", "-ss", skip, "-i", src, "-lavfi", lavfi, "-f", "null", "-"])
    m = re.search(r"All:([0-9.]+)", r.stderr)
    return float(m.group(1)) if m else None


def mf_opens(path):
    if not os.path.exists(MFPROBE):
        return None
    r = sh([MFPROBE, path])
    return r.returncode == 0, r.stdout.strip()[-300:]


def gpu_busy():
    r = sh(["nvidia-smi", "--query-gpu=utilization.gpu,utilization.encoder,utilization.decoder", "--format=csv,noheader,nounits"])
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", action="append", required=True, help="recording.mp4@start_seconds")
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--only", nargs="*")
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    cuts = []
    for i, s in enumerate(a.source):
        path, start = s.rsplit("@", 1)
        cuts.append(prepare(path, float(start), f"cut{chr(65 + i)}"))
    for c in cuts:
        print(f"{c['name']}: {c['codec']} {c['fps']:.0f} fps, {c['bytes'] / 2**20 / c['seconds'] * 60:.1f} MB/min as recorded today", flush=True)
    rows = []
    with open(os.path.join(OUT, "results.jsonl"), "a", encoding="utf-8") as log:
        for rnd in range(1, a.rounds + 1):
            for c in cuts:
                for name, args in VARIANTS.items():
                    if a.only and name not in a.only:
                        continue
                    out = os.path.join(OUT, f"{c['name']}-{name}.mp4")
                    gpu = gpu_busy()
                    r = sh([BIN, "--codec", c["codec"], "--video", c["es"], "--times", c["times"], *args, "--out", out])
                    try:
                        res = json.loads(r.stdout.strip().splitlines()[-1])
                    except Exception:
                        res = {"ok": False, "error": (r.stdout + r.stderr)[-400:]}
                    row = {"at": time.strftime("%Y-%m-%d %H:%M:%S"), "round": rnd, "cut": c["name"], "variant": name,
                           "args": args, "gpu_before": gpu, "src_mb_min": c["bytes"] / 2**20 / c["seconds"] * 60, **res}
                    if res.get("ok"):
                        size = os.path.getsize(out)
                        row["out_bytes"] = size
                        row["mb_min"] = size / 2**20 / res["seconds"] * 60
                        if rnd == 1 and name != "decode-only":
                            row["ssim"] = ssim(out, c["mp4"])
                            row["mf"] = mf_opens(out)
                    log.write(json.dumps(row) + "\n")
                    log.flush()
                    rows.append(row)
                    print(json.dumps({k: row.get(k) for k in ("round", "cut", "variant", "ok", "mb_min", "cpu_per_video_s", "worst_push_ms", "ssim", "mf", "gpu_before", "error")}), flush=True)
    print("\nvariant | MB/min (A, B) | CPU s per video s (median) | SSIM (A, B)")
    for name in VARIANTS:
        rs = [r for r in rows if r["variant"] == name and r.get("ok")]
        if not rs:
            continue
        mb = ", ".join(f"{statistics.median(r['mb_min'] for r in rs if r['cut'] == c['name']):.1f}" for c in cuts)
        cpu = statistics.median(r["cpu_per_video_s"] for r in rs)
        ss = ", ".join(str(r.get("ssim")) for r in rs if r["round"] == 1)
        print(f"{name} | {mb} | {cpu:.2f} | {ss}")


if __name__ == "__main__":
    main()
