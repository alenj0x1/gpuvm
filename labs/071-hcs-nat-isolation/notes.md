# Labs 070-072: network isolation of HCS machines

Question: can GpuVM give an HCS machine the isolation its Hyper-V machines get from port ACLs on the virtual switch
(from the host only Moonlight comes in; to the host only DHCP and DNS go out; no private networks; internet open),
without Hyper-V, and in a way the guest cannot undo?

Every lab runs one machine from `normal-tpl` with GpuVM's agent, probes from inside the guest through `sys.exec`, and
runs the same probes on a control arm. `hostLan*` targets the host's own LAN address; `lanRouter*` is another device
on the LAN (the host's default gateway).

## Results (2026-11-24, Windows 10 Pro 19045)

| Lab | Mechanism | Isolated arm | Control arm | Verdict |
| --- | --- | --- | --- | --- |
| 070 | HCN endpoint ACL policies on GpuVM's ICS network | everything open | everything open | ACLs stored, not enforced |
| 070 | Same, with the switch's WFP extension (`e9b59cfa…`) enabled on the network | no DHCP address (169.254) | no DHCP address | breaks the network |
| 071 | HCN NAT network, fixed address set by the agent, endpoint ACLs | internet, LAN RPC open | identical | ACLs not enforced |
| 071 | NAT network with the switch's WFP extension enabled | everything blocked, Moonlight too | everything blocked | breaks the network |
| 072 | ICS network, extension enabled, permit-all filters on the switch layers | 169.254 | 169.254 | the cut is not a filter |
| 072 | ICS network, host WFP filters (forward, ALE receive) on its interface | host gateway RPC blocked; LAN router and host LAN address open | all open | host gateway only |
| 072 | Diagnostic: block the LAN router at IP forward / outbound packet / ALE connect | router still open | | NAT traffic skips these layers |
| 071 | NAT network, host WFP filters incl. inbound IP packet layer | host gateway RPC blocked; LAN router and host LAN address open | all open | host gateway only |
| 071 | NAT network, endpoint ACLs with `RuleType: Host` (WFP) instead of `Switch` | all open | all open | not enforced either |
| 072 | ICS network, extension enabled, permit-all filters on all six vSwitch layers | 169.254 | 169.254 | the cut is not a filter |
| 071 | HCN **Internal** network (no NAT, no forwarding), fixed address, host WFP filters | internet, LAN, host services blocked; Moonlight to the guest works | only the host reachable (RPC open), Moonlight works | host-only leg works |

Findings:

- On client Windows HNS keeps endpoint ACL policies but programs nothing that enforces them, on ICS or NAT networks.
  Enabling the switch's WFP extension drops all of the machine's traffic, and permit-all filters on the vSwitch WFP
  layers do not bring it back; no HNS filters appear on those layers.
- Host WFP filters matching the host interface of GpuVM's network work for traffic addressed to that interface's
  address (ALE receive/accept with the arrival interface): the guest can no longer open the host's services there,
  and DHCP and DNS still answer.
- Both NAT engines (ICS and WinNAT) translate traffic bound for any other address, the host's LAN address included,
  before the IP forward, inbound packet, outbound packet or ALE layers classify it. User-mode WFP filters cannot
  keep an HCS guest off the LAN.
- The guest's own firewall would work but is under the guest's control, so it is not isolation.
- An HCN Internal network exists on Windows 10 client: the guest reaches only the host, and the host WFP filters
  (which do see traffic addressed to the host) leave only Moonlight. The Hyper-V firewall that filters WSL's traffic
  on Windows 11 (`New-NetFirewallHyperVRule`) does not exist on Windows 10 19045.

Design that follows: an isolated HCS machine sits on its own Internal network (the host and Moonlight only, locked by
host WFP filters) and reaches the internet only through a relay over its Hyper-V socket, where the host checks every
destination (public addresses only) before opening the connection itself. No Windows NAT is in the path, so nothing
skips the check, and the guest cannot reach the LAN even as administrator.
