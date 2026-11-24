# Lab 073: internet for an isolated HCS machine through a relay over its Hyper-V socket

Question: labs 070-072 showed that no Windows NAT can be filtered on client editions. Can an isolated HCS machine
get full internet (TCP and UDP) with no Windows NAT in its path, so the host checks every destination and the guest
cannot reach the LAN even as administrator?

Design under test:

- The machine's only network adapter sits on an HCN Internal network: no NAT, no forwarding, only the host. Host WFP
  filters on that interface (ALE receive/accept, arrival interface) leave only Moonlight (lab 071).
- In the guest, a Wintun adapter (WireGuard LLC, signature checked) takes the default route. `relay/` ends each TCP
  or UDP flow in a user-mode stack (`ipstack`) and opens one Hyper-V socket per flow to the host with
  "kind, IPv4, port".
- On the host, `netrelay host <vm-id>` accepts only that VM (the peer VM id comes from Hyper-V), refuses every
  destination that is not public (private, CGNAT, loopback, link-local, multicast, broadcast, documentation,
  benchmarking, reserved and the host's own addresses; unit test in `relay/src/main.rs`) and opens the connection
  itself. It never parses the guest's packets.

`run.ps1 -Wintun <folder>` runs the control arm first (same machine on GpuVM's ICS network, DHCP) and then the relay
arm, with the same probes. `lanRouterData` and `hostLanData` fetch real data with curl (exit 0 = data, 28 = no
answer); a bare TCP connect is not evidence in the relay arm, because the guest's stack completes the handshake
before the host decides. `hostRefused` is the host relay's own log: what the enforcement point refused.

## Results (2026-11-24, Windows 10 Pro 19045, RTX 4060, about 850 Mbit/s line)

| Probe | Control (ICS) | Relay |
| --- | --- | --- |
| Internet by IP / by name (TCP 443) | open / open | open / open |
| DNS over UDP to 1.1.1.1 | answers | answers |
| Download, 50 MB from Cloudflare, two runs | 80.5 / 101.6 MB/s | 101.3 / 107.3 MB/s |
| Mean TCP connect to 1.1.1.1:443 (5 runs) | 13.0 ms | 15.6 ms |
| LAN router, HTTP data | 200 | no answer |
| Host's LAN address, port 135 data | no answer (host firewall) | no answer, refused by relay |
| Host's address on the machine's network, RPC 135 | open | blocked (WFP) |
| 10.0.0.1:80 | blocked | refused by relay |
| Moonlight port 47989 from the host | open | open |
| Agent answering after start | 4.0 s | 4.0 s |
| Wintun adapter up after the relay starts | | 3-6 s |

Refused by the host relay during the run: 10.0.0.1:80, 192.168.100.1:53 and :80 (router), 192.168.100.8:135 and
:445 (host's LAN address), and the guest's own LAN chatter (NetBIOS 10.255.255.255:137, mDNS 224.0.0.251:5353,
LLMNR 224.0.0.252:5355, SSDP 239.255.255.250:1900).

Findings:

- An isolated HCS machine gets internet at the same speed as on the ICS network (the line is the limit), with UDP,
  and connects 2.6 ms slower. Nothing it sends reaches a private address: the relay refuses it on the host.
- A refused TCP connection hangs until the guest app's timeout instead of failing at once, because `ipstack`
  answers the SYN itself. For the product, the guest side should check the same public-only rule before it
  answers (only to fail fast; the host check stays the enforcement) or reset the flow as soon as the host refuses.
- One `curl https://www.microsoft.com/` in the relay arm got no answer from `sys.exec` while every other HTTPS probe
  and both downloads worked; not reproduced yet.
- IPv6 has no route through the relay (the guest gets none), so nothing leaks over it.
