# Lab 050: who can use the Hyper-V socket channel, and how the host knows it's GpuVM's agent

Test VM `agentlab` (Windows 10 Pro 22H2 es-MX), host Windows 10 Pro for Workstations, Nov 18, 2026. Desk research
with sources in `research.md`. Probes: `agentprobe hv|regread|read` (lab 048 crate), `hvlab` (lab 047).

## Questions

1. Can the hvsocket service be restricted so only GpuVM's agent (a SYSTEM service) in the guest can connect?
2. If not, can the host authenticate the guest agent, e.g. with a per-VM secret only SYSTEM can read?
3. What can a standard user process inside the guest do against the channel? And a non-elevated process on the host?

## Method (`run.ps1`)

Guest identities: `system` (SYSTEM, session 0), `gpuvm` (signed-in user, medium), `agent` (separate standard user on
the same desktop, medium), `low` (gpuvm running a copy of the probe labelled low integrity). Each one: open
`AF_HYPERV`, dial the host's registered service (one round trip), bind + listen on a guest-side service name. Then: a
GUID the host never registered; squatting the guest-side name before and after a SYSTEM listener holds it, and whether
the host's dial reaches the squatter; a secret as a host -> guest KVP item vs. a 32-byte file pushed with
`Copy-VMFile` into `C:\ProgramData\GpuVMLab050` (ACL: SYSTEM + Administrators only, inheritance off); on the host, a
listener started with the person's non-elevated token, a second listener on the same name, and a listener on an
unregistered GUID. Everything created was removed (user, folder, KVP item, GUID, Guest Service Interface back off).

## Results

| identity in the guest | socket | dial host service | bind + listen a name |
| --- | --- | --- | --- |
| SYSTEM | ok | **ok** (1.4 ms) | ok |
| gpuvm (signed-in user, medium) | ok | **ok** (1.2 ms) | ok |
| agent (standard user, medium) | ok | **ok** (1.2 ms) | ok |
| low integrity | ok | refused, 10013 (WSAEACCES) | listen refused, 10013 |

- **Any medium-integrity process of any user can reach the host's service.** Only low integrity is stopped (an
  AppContainer would be too; not tried). Nothing documented lets a VMMS VM restrict it further: the HCS
  bind/connect security descriptors only exist for HCS compute systems and only check host processes
  (`research.md` 2).
- **The host can't tell them apart:** the 3 connections arrived with the same peer VmId (the VM's Id, 3/3). The VmId
  identifies the VM, never the process or user inside it.
- **Registration gates the guest:** a guest dial to a GUID the host never registered is refused (10061) even while a
  host process listens on it.
- **Squatting the guest-side name:** while a SYSTEM listener holds it, a second bind succeeds but `listen` fails
  (10048, in use): first come wins. When nobody holds it (agent not started yet, or crashed), the standard user
  `agent` listened on it and **received the host's dial** (the host's request then broke, 10053). A host that dials a
  listener in the guest can be answered by any guest user.
- **KVP is not private:** the host -> guest item (`HKLM\SOFTWARE\Microsoft\Virtual Machine\External`) was read by
  every identity, low integrity included (ACL: Authenticated Users ReadKey).
- **Copy-VMFile into a SYSTEM/Administrators folder is private:** 119 ms; the file got owner Administradores and only
  the inherited SYSTEM + Administrators ACEs; SYSTEM read it, gpuvm (filtered admin token), agent and low got
  "access denied". Needs the Guest Service Interface integration service on while copying (off by default).
- **Host side:** a listener started with the person's **non-elevated** token bound `HV_GUID_CHILDREN` on the
  registered GUID and **the guest connected to it**. A second listener on the same name fails (first come wins).
  So any program of the person, unelevated, that starts before GpuVM's listener can take the name and talk to every
  guest agent.

## Security impact

Test VM only, nothing in the product changed; the host's lab GUIDs are removed by `service.ps1 -Remove`.
What this means for the design is below; none of it lowers today's security because the channel doesn't exist yet.

## Recommendation

1. **Direction:** the guest agent (a SYSTEM service, started at boot) dials the host; the host never dials a listener
   in the guest (squattable by any guest user whenever the service isn't up).
2. **The channel is not an identity.** Treat every connection as untrusted until a handshake proves it; the VmId only
   says which VM.
3. **Per-VM secret, mutual proof:** GpuVM generates 32 random bytes per VM, keeps them DPAPI-protected on the host and
   places them in the guest in a folder only SYSTEM and Administrators can read (during install through PowerShell
   Direct, which GpuVM already uses; or `Copy-VMFile` while the Guest Service Interface is on, then off again). Never
   in KVP. Handshake: host nonce + guest nonce, each side answers with HMAC-SHA256(secret, both nonces + VmId +
   direction); the secret never crosses the channel. This also lets the guest agent check it reached GpuVM's
   listener and not a non-elevated host program that grabbed the name (the same handshake fails for it).
4. **Commands the AI runs as `agent` (standard user)** can open the socket too; the secret keeps them from posing as
   the agent service or reaching the host's control API. Anything elevated in the guest can read the secret, but it
   could already control the service; the guest is untrusted anyway: the host validates sizes and message types
   (hvlab already refuses frames over 64 MB) and never acts on guest data beyond the agent protocol.
5. **Host listener:** run it in GpuVM's elevated service, bind at start and alert if the bind fails (name taken).
   Rotate the secret on reinstall; delete it with the VM.
6. **Low integrity / AppContainer** is the only built-in isolation in the guest; GpuVM's own guest pieces that don't
   need the channel can run there.

Open: whether a Windows guest could forge the peer VmId (Linux driver source says the host fills it; Microsoft
doesn't say); AppContainer and Windows 11 guests not tried.
