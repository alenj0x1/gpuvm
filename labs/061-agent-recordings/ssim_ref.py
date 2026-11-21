"""Lab 061, quality without the frame-picking error.

run.py's SSIM compares the light file with the stream resampled by ffmpeg's fps filter, which picks a neighbouring
frame now and then: on moving content (or the stream's single-frame glitches, lab 057) whole frames differ and the
score drops for the instrument's sake (cutB: 0.83-0.89 on a still Paint window). Here the reference is the SAME
recorder at 40 Mb/s (same frames kept, nearly lossless), so the score is only what the bitrate costs; and the
reference against the stream shows what frame picking alone does.

    python labs/061-agent-recordings/ssim_ref.py   (after run.py, which leaves out/cut*.es/.times/.mp4)
"""
import json, os, re, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
BIN = os.path.join(OUT, "bin", "rectest.exe")


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def ssim(a, b, resample=False):
    lavfi = ("[0:v]fps=30,setpts=PTS-STARTPTS[a];[1:v]fps=30,setpts=PTS-STARTPTS[b];[a][b]ssim" if resample
             else "[0:v]setpts=PTS-STARTPTS[a];[1:v]setpts=PTS-STARTPTS[b];[a][b]ssim")
    r = sh(["ffmpeg", "-hide_banner", "-i", a, "-hwaccel", "d3d11va", "-i", b, "-lavfi", lavfi, "-f", "null", "-"])
    m = re.search(r"All:([0-9.]+)", r.stderr)
    return float(m.group(1)) if m else None


def main():
    rows = []
    for cut in ("cutA", "cutB"):
        es, times, src = (os.path.join(OUT, cut + x) for x in (".es", ".times", ".mp4"))
        ref = os.path.join(OUT, f"{cut}-30fps-40M-ref.mp4")
        if not os.path.exists(ref):
            sh([BIN, "--codec", "hevc", "--video", es, "--times", times, "--fps", "30", "--bitrate", "40000000", "--out", ref])
        row = {"cut": cut, "ref_vs_stream_resampled": ssim(ref, src, resample=True)}
        for v in ("30fps-1M", "30fps-2M", "30fps-3M"):
            row[v] = ssim(os.path.join(OUT, f"{cut}-{v}.mp4"), ref)
        print(json.dumps(row), flush=True)
        rows.append(row)
    with open(os.path.join(OUT, "ssim_ref.jsonl"), "a", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


if __name__ == "__main__":
    main()
