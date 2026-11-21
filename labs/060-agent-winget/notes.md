# Lab 060: winget for the agent's standard user

Why: in lab 057 the agent's `winget install Mozilla.Firefox` failed ("winget no se reconoce") and it fell back to a
hand download. Windows 10 19045 guests carry an old App Installer without a working winget for a new user.

## What GpuVM now does

- `streaming/components.json` pins one release of Microsoft's own winget (github.com/microsoft/winget-cli, the
  location Microsoft documents): `winget` (App Installer msixbundle), `winget-dependencies` (the frameworks zip) and
  `winget-license` (the provisioning license), each with its SHA-256 (they match the digests GitHub publishes).
  v1.29.380 (2026-09-21) = App Installer 1.29.380.0.
- `Install-GuestWinget` (src/GpuVM/Private/Winget.ps1), called by `Install-GpuVMAgent` in its own PowerShell Direct
  session: reads `C:\ProgramData\GpuVM\Agent\winget` (the stamp; that folder is SYSTEM + Administrators only) and
  stops there when it names this release. Otherwise: the three files from the host cache (downloaded once, hash
  checked), Microsoft's exact Authenticode subject checked on the host, only the x64 frameworks taken out of the zip
  by plain names, all copied into an administrators-only temp folder in the guest, hash and signature checked again
  there, `Add-AppxProvisionedPackage -Online` with the license (every user, existing and new; no Store), policies,
  stamp, folder removed (also on failure).
- Policies (HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller, names from the release's ADMX), all 0:
  EnableMicrosoftStoreSource (its agreement prompt would leave a `winget` run without `--accept-source-agreements`
  waiting for input nobody types, and agents don't need Store apps), EnableMSAppInstallerProtocol,
  EnableHashOverride, EnableLocalManifestFiles, EnableLocalArchiveMalwareScanOverride,
  EnableBypassCertificatePinningForMicrosoftStore, EnableWindowsPackageManagerConfiguration. The `winget` source
  stays. Nothing runs elevated for the agent: anything that wants administrator rights still hits UAC.
- Templates: the stamp is a new key of `Get-BundledComponentStamp` (the hash of its text) for agent templates, so an
  agent template without this release is stale and `Update-GpuVMTemplate` refuses a layer that lacks it.
- A failure installing winget only warns: the agent install goes on (`winget = 'failed'` in its result).

## Measured so far (host side, 2026-11-21)

| step | result |
| --- | --- |
| download of the three files (first time, into the cache) | 8.1 s, 207.2 MB bundle + 93 MB zip + license |
| `Get-WingetPackage` from cache (hashes + 4 signature checks + x64 extraction) | 6.1 s, paid only when a machine needs it |
| files that go into a machine | 238 MB: bundle 207.2, WindowsAppRuntime 1.8 24.3, VCLibs UWPDesktop 6.4, VCLibs 0.9 |
| Authenticode on the host | Valid, `CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US` for all four packages |
| x64 AppxManifest | MinVersion 10.0.17763.0 (19045 is fine); dependencies exactly WindowsAppRuntime.1.8, VCLibs.140.00, VCLibs UWPDesktop; aliases include `winget.exe` |
| Pester | 206/206 (11 new: manifest, stamp, policies, template keys, Install-GuestWinget paths, Get-WingetPackage checks) |

## Not run yet: the guest part (no RAM for a second VM)

On 2026-11-21 the coordinator's an agent machine (4 GB) was running and other sessions were compiling; free memory
went between 2.8 and 4.7 GB and three `create_disposable` (4 GB; the balanced profile refuses 3) failed with "needs
4.3 GB". So the end-to-end check is a ready script:

```powershell
# elevated, from this checkout, with the coordinator's machine off (needs ~4.4 GB free)
Copy-Item ..\..\..\guest\agent\dist -Destination guest\agent\ -Recurse -Force   # agent build, git-ignored
pwsh -NoProfile -File labs\060-agent-winget\run.ps1
```

It makes `lab060` from `agent-tpl` (4 GB), runs this checkout's `Install-GpuVMAgent` (the same step
`Update-GpuVMTemplate` runs in its temporary copy), power-cycles it as the template update does, then as `agent`
through the agent's `exec.run` (the MCP `run` tool's exact command line): `winget --version` (retried 2 min while
AppX registers the package at sign-in), `whoami` (Medium label), `winget source list`, `winget search` without
`--accept-*` flags (must not time out), `winget install --id Mozilla.Firefox -e --scope user --silent
--accept-package-agreements --accept-source-agreements --disable-interactivity`, firefox.exe present and signed by
Mozilla, `winget list`; then `Install-GpuVMAgent` again (must say `current`) and what Windows says as administrator.
Prints `PASS`/`FAIL`, keeps `out\run-<time>.json`, deletes the copy (`-Keep` leaves it).

Expected: ~6-9 min in all (copy ~1 min, agent install + winget ~1.5-2 min of which copying 238 MB over PowerShell
Direct and provisioning are the new part, power cycle ~1.5 min, Firefox ~1 min).

Open questions the run answers:
1. Does `agent`, whose profile exists before the provisioning, get App Installer at its next sign-in? (Provisioned
   packages register for existing users at sign-in; if not, the fallback is `Add-AppxPackage -RegisterByFamilyName
   -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe` run as `agent`, which needs no administrator.)
2. Does the agent's `exec.run` environment have `%LOCALAPPDATA%\Microsoft\WindowsApps` on PATH (the alias)?
3. Cost of the stamp check on every later `Install-GpuVMAgent` (expected well under 1 s: one file read).

## Applying it to agent-tpl

Nothing by hand once this build is installed: the new stamp key makes `agent-tpl` stale, and GpuVM's service runs
`Update-GpuVMTemplate -Stale` 2 min after it starts and every hour. To do it at once (elevated, installed module):

```powershell
Update-GpuVMTemplate -Name agent-tpl
```

Expected ~6-7 min (5.4 min in lab 053 part 7, plus copying and provisioning winget) and a layer ~0.3-0.4 GB
larger. Copies made afterwards get winget with no extra time (stamp read only); copies made before get it the next
time their agent is installed or updated.
