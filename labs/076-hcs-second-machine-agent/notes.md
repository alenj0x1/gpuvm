# Lab 076: an HCS machine that takes two minutes to boot

Question: with two HCS machines, the agent of one of them answered only after ~125 s (4-7 s otherwise). Where does
the time go, and what triggers it?

`run.ps1` makes two machines from `normal-tpl` (2 GB, 2 CPUs), starts them one after the other (`-Serial` waits for
the first agent), times every `sys.info` call, reads each machine's agent log on the host and in the guest, the
guest's firmware boot order and boot times, and restarts the first machine at once and after a 150 s pause.
`-Isolated false` uses GpuVM's ICS network, `-Gpu none|nvidia|default` chooses the GPU. The host's
`Microsoft-Windows-Hyper-V-Worker-Admin` log gives, per start, when the GPU's PCI device was added (33103),
removed (33104) and when the guest OS booted (18601).

## Findings (2026-11-24, Windows 10 Pro 19045, RTX 4060)

- The delay is before Windows runs at all: the guest's agent connects 3 s after Windows' boot, firmware POST takes
  91-212 ms, and Windows' boot moment is ~121 s after the host started the machine.
- In every slow start the GPU's PCI device is added at +0.1-1 s, removed and added again at +120 s, and the guest
  boots right after. Fast starts add it once.
- Without a GPU (`-Gpu none`): 6 of 6 starts fast (4.2-7.2 s).
- Not the network: the same with the isolated network and with GPUVM's ICS network.
- Not the firmware's boot order: the guest's firmware lists only Windows Boot Manager (timeout 0); pinning the boot
  device (`Uefi.BootThis`) made it worse.
- Not the moment the GPU is added: adding it before the start instead of right after gives the same retry.
- Over 70 starts from the worker log: before any second GPU machine ran (labs 065-075, one machine at a time) 22 of
  22 starts were fast; with another GPU machine running, about half of the starts waited for the retry, whatever
  the time since the last start or stop.
- Separate: a start right after a power-off failed with "a virtual machine with the specified identifier already
  exists"; HCS releases a terminated system a moment later. `power_off` and `start` now wait (up to 30 s) until the
  old system is gone.
- Separate: a machine whose plug was pulled twice in a row early in its boot never came back (Windows booted, but
  the agent didn't connect in five minutes): after two unexpected shutdowns during boot Windows opens Automatic
  Repair, which waits for someone at its screen, with or without Hyper-V. With an orderly shutdown (GpuVM's default)
  8 of 8 restarts, right away and after a 150 s pause, came back.

Known issue for the release: while one GPU machine runs, starting a second one sometimes takes about two minutes
longer, because Windows' GPU sharing retries the device. Machines without a GPU and the first GPU machine are not
affected. Next step: the same check on the Hyper-V path (two GPU-P machines), and whether removing and adding the
device as soon as the guest hasn't booted after a few seconds shortens the wait.
