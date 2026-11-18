# Lab 041: the whole stream path, per variant

`run.ps1` measures, per variant and in interleaved rounds, with GpuVM's viewer as the app starts it: the host GPU's
load (idle and while streaming), the viewer's own numbers (received/rendered FPS, host processing, decode and network
latency), how often a bar drawn on the GPU in the VM moves on this screen, and key/click/move latency. Variants are
data (`variants.ps1`: a setup, an undo and stream settings), so a hypothesis is one entry, not a new lab.
