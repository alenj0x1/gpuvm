# Network isolation of the VM

**Hypothesis:** Extended port ACLs on the VM's vSwitch port (enforced by the host, outside the guest) can keep the VM away from the host and the LAN while it keeps internet, DHCP and DNS, and Moonlight still streams through stateful rules for the connections it opens.

## Procedure

`probe.ps1` (elevated, PowerShell 7) measures from inside the VM over PowerShell Direct and from the host:

1. Baseline: no rules.
2. Candidate: the rules added with weights 10001-10012.
3. Reverted: rules removed, everything back as before (also the temporary listener and firewall rules).

`probe.ps1 -Installed` opens the VM with `Connect-GpuVM` (which applies GpuVM's own rules) and measures once.
Raw output goes to `out/` (not committed: it has the LAN addresses).

## Observations

- With the Default Switch the VM reached RPC (135), VMConnect (2179) and Delivery Optimization (7680) on the host, also over IPv6 link-local, and the LAN router.
- Hyper-V evaluates the higher weight first. A stateful inbound allow lets the replies out although a lower outbound deny covers the host's address: Sunshine answered over TCP and UDP.
- The VM keeps internet, DNS and DHCP through the Default Switch NAT with only UDP 67 and UDP/TCP 53 to the host allowed.
- The Default Switch subnet changes when the host restarts (172.29.96.1/20 in this run), so the rules are rebuilt before every start.
