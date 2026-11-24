# Lab 074: the isolated network of HCS machines as GpuVM ships it

Question: does the design proven in lab 073 work with nothing set up by hand, through the product code, and keep
working after the guest restarts?

What runs (no lab-only steps): `gpuvm-host hcs start` puts an isolated machine (the default) on the HCN Internal
network `GpuVM-Isolated` with the next free fixed address and adds the host's WFP filters on that interface
(`net.rs`, `wfp.rs`). The machine's service table carries the relay's Hyper-V socket service. When the agent
connects, the service sends `sys.net` with the address from the machine's record (`agent.rs`,
`machine::guest_network`). The agent sets the address on the adapter with that MAC, starts its relay on the Wintun
adapter that ships next to it (pinned by SHA-256 in `machine.rs`) and keeps the setting in
`ProgramData\GpuVM\Agent\net.json`, so the next boot has internet before the host asks again (`guest/agent/src/net.rs`).
The service runs the relay (`relay.rs`). The control arm is the same machine with `--isolated false` (ICS, DHCP).

## Results (2026-11-24, Windows 10 Pro 19045, RTX 4060, about 850 Mbit/s line)

| Probe | Isolated | Control (ICS) |
| --- | --- | --- |
| Agent answering after start | 4.1 s | 6.1 s |
| Internet working after the agent answered (first boot: Wintun installs) | 14.2 s | 7.6 s |
| HTTPS to www.microsoft.com, 5 runs | 5 x 200; TCP 3.5-8 ms, TLS 88-117 ms | 5 x 200; TCP 26-33 ms, TLS 101-116 ms |
| DNS (system resolver) | answers | answers |
| Download, 50 MB, two runs | 76.7 / 105.9 MB/s | 98.0 / 102.8 MB/s |
| LAN router: TCP connect / HTTP data | refused in 2.1 s / no data | open / 200 |
| Host's LAN address, SMB | refused in 2.1 s | no answer (host firewall) |
| 10.0.0.1:80 | refused in 2.1 s | no answer |
| Host's address on the machine's network, RPC 135 | no answer (WFP) | open |
| Moonlight port 47989 from the host | open | open |
| Default route | Wintun adapter `GpuVMNet` | the machine's adapter |
| After a guest restart: back / internet after the agent | 14.7 s / 7.6 s; router still no data, host still closed | |

Findings:

- An isolated machine needs nothing but `hcs start`; the setting survives guest restarts.
- A refused destination now fails in about 2 s (the guest answers the SYN with a reset; Windows retries a reset
  connect twice) instead of hanging until the app's timeout.
- The TCP connect time inside the guest is the guest stack's own (the real connection is the host's), so it reads
  lower than the control; TLS handshakes, which cross the whole path, match.
- The one HTTPS probe without an answer in lab 073 did not come back in 10 runs here.
