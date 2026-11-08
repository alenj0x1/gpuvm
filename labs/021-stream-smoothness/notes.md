# Stream smoothness

**Hypothesis:** For the "Movies" and "Work" uses (lab 020 covered games), frame pacing makes motion more even at the cost of a little latency, and more FPS makes the picture smoother. Moonlight's frame pacing waits on V-Sync and queues up to 3 frames ([pacer.cpp](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/streaming/video/ffmpeg-renderers/pacer/pacer.cpp)), so it should only help when frames arrive unevenly.

## Procedure

- `tools/latency/motion-target.ps1` (in the VM): a white bar the full height of the screen crosses a black background once every 2 s, positioned from a high-resolution clock and redrawn as fast as the loop runs. It draws the new bar before erasing the strip left behind (erasing first let captures catch frames with no bar) and takes a fresh drawing surface twice a second.
- `tools/latency/motion-meter.ps1` (on the host): one GDI read of one row per host refresh (179 per second; each read waits for a newly composed frame, so a second row would halve the rate). From the moments the bar's edge moves: updates per second, the spread of the intervals (sd, p99), stutters (a gap longer than one stream frame plus one host refresh) and how evenly the bar advances (coefficient of variation of its speed between updates).
- `labs/021-stream-smoothness/run.ps1` (elevated): the local reference (the bar on the host, no stream), then 60, 120 and 165 FPS each with V-Sync + pacing, V-Sync only and neither (Moonlight only paces with V-Sync), borderless, in 2 interleaved rounds of 20 s. Before sampling it waits until the bar is seen moving (up to 60 s) and records how long the picture took.
- Tearing can't be measured this way: it happens during scan-out, after composition. It has to be judged by eye.

## Observations

### Runs of Nov 8, 2026 (win10, host 1920x1080 at 179 Hz)

Runs 1-4 (`out/run-20261108-150058`, `-150633`, `-152017`, `-153405`) are discarded: the first target erased the bar before drawing it, and the script sampled 5 s after Moonlight's first frame, while many sessions were still black. Run 5 (`out/run-20261108-154747.json`) is the valid one; local from run 3 (same target fix).

| Variant | Updates/s (r1, r2) | Interval sd, ms | Interval p99, ms | Stutter % | Speed CV % |
|---|---|---|---|---|---|
| local (179 Hz) | 179.6 | 0.56 | 7.5 | 0.06 | 18.6 |
| 60 V-Sync + pacing | 58.9, 59.0 | 2.6, 3.7 | 28, 23 | 1.2, 0.8 | **17.6, 29.0** |
| 60 V-Sync | 57.0, 55.7 | 3.4, 4.1 | 26, 39 | 1.2, 1.8 | 35.4, 31.1 |
| 60 no V-Sync | 56.3, *34.2* | 3.7, 4.3 | 28, 33 | 1.2, 2.7 | 30.7, 47.5 |
| 120 V-Sync + pacing | 111.8, 114.8 | 5.7, 4.1 | 22, 17 | **4.2, 2.2** | 43.3, 49.9 |
| 120 V-Sync | 113.4, 113.1 | 3.7, 3.3 | 17, 12 | 1.2, 0.8 | 42.8, 36.5 |
| 120 no V-Sync | 110.4, *72.4* | 3.6, 3.4 | 13, 17 | 0.9, 1.1 | 45.4, 42.0 |
| 165 V-Sync + pacing | 158.6, 160.1 | 3.0, 2.8 | 12, 12 | 1.0, 0.7 | 49.5, 34.2 |
| 165 V-Sync | 152.7, *13.2* | 5.3 | 13 | 1.0 | 37.5 |
| 165 no V-Sync | 150.2, 156.0 | 2.8, 2.2 | 12, 12 | 0.8, 0.6 | 28.6, 27.7 |

*Italic*: sessions whose picture had not settled (no bar for 60 s, or only partly); left out of the conclusions.

- At 60 FPS, frame pacing gives the most even motion (lowest speed spread in both rounds, fewest stutters) and 59 of 60 frames per second.
- At 120 FPS, frame pacing makes it worse: 2-4 % stutters against about 1 % without it. V-Sync alone is as even as no V-Sync.
- At 165 FPS all three are about the same: about 1 % stutters and the shortest gaps (p99 12 ms). More FPS shortens every gap; at 165 the stream is the closest to the local picture.
- The speed spread is high at 120 and 165 for every variant: those rates don't divide the host's 179 Hz, so updates alternate between one and two host refreshes. It compares variants at the same FPS, not across FPS.
- **The picture takes long to appear after Moonlight reconnects**: 3.6-53 s after its log reports the first frame (median ~25 s); twice it did not appear within 60 s. After a display mode change (the first session at each FPS) it was 37-42 s, matching Sunshine's encoder re-test (labs 008 and 019). Without V-Sync it tended to come sooner (3.6-5.6 s in round 1). Not investigated here; it affects every reconnect, not only this lab.

## Conclusion

Confirmed in part. Frame pacing helps only at 60 FPS, where it gives the most even motion: the "Movies and video" use keeps 60 FPS with V-Sync and pacing. At 120 FPS and above pacing adds stutters, so "Work" (and "Games") use V-Sync without pacing; more FPS is smoother still, and 165 FPS (the most the virtual display accepts on this host) was the smoothest of all.
