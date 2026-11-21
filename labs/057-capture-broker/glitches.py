# Lab 057: counts the frames of a recording (any file ffmpeg reads) where a big area turns near-black for that frame
# only (black there, not black in the frames before and after): the half-composed desktops of the WGC helper.
# Usage: python -I glitches.py <video> [seconds]. Prints frames, glitches, rate and when they happened.
import subprocess, sys
W, H = 96, 54
N = W * H
src = sys.argv[1]
cmd = ['ffmpeg', '-v', 'error', '-i', src]
if len(sys.argv) > 2:
    cmd[3:3] = ['-t', sys.argv[2]]
cmd += ['-vf', f'scale={W}:{H}:flags=area,format=gray', '-fps_mode', 'passthrough', '-f', 'rawvideo', '-']
raw = subprocess.run(cmd, capture_output=True).stdout
frames = [raw[i * N:(i + 1) * N] for i in range(len(raw) // N)]
hits = []
for i in range(1, len(frames) - 1):
    a, b, c = frames[i - 1], frames[i], frames[i + 1]
    k = sum(1 for x, y, z in zip(a, b, c) if y < 6 and x > 30 and z > 30)
    if k >= 20:  # >= 20 of 5184 cells (~0.4 % of the picture)
        hits.append((i, k))
dur = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', src], capture_output=True, text=True).stdout.strip() or 0)
if len(sys.argv) > 2:
    dur = min(dur, float(sys.argv[2]))
print(f'frames={len(frames)} seconds={dur:.1f} glitches={len(hits)} per_min={len(hits) / dur * 60 if dur else 0:.1f}')
print('first:', ', '.join(f'#{i}({k})' for i, k in hits[:15]))
