# Templates

**Hypothesis:** A VM's disk saved as a read-only dynamic base (Convert-VHD) lets new VMs start from a differencing disk in seconds and a few GB, each with its own streaming identity and computer name, and Hyper-V still opens the base with the folder readable only by Administrators and SYSTEM.

## Procedure

`run.ps1` (elevated, PowerShell 7) on `win10`: shuts it down, saves it as `lab016-base` (`New-GpuVMTemplate -ShutdownIfRunning`), restricts `.templates` to Administrators and SYSTEM, creates `lab016-copia` on top with the `balanced` profile and 7 GB, boots it, runs GpuVM's pending work (rename), checks inside (Sunshine identity, apps, cleanup level), restarts it to check automatic sign-in with the new name, tries to delete the template while in use, and removes the copy. `-UseExisting` reuses a template from an earlier run.

## Observations

### Runs of Oct 28, 2026

| Step | Result |
|---|---|
| Template from `win10` (fixed 200 GB disk, with GTA V) | 1157 s, **159.4 GB** |
| Copy on top | 7.3 s, differencing disk of 78 MB, parent correct |
| Boot to PowerShell Direct | 50 s, with `.templates` readable only by Administrators and SYSTEM |
| Inside the copy | VLC and the cleanup level (privacy) came along; Sunshine's `uniqueid` cleared (win10's was `EBE15864-…`) |
| Rename + restart | `LAB016-COPIA`, signed in automatically as `LAB016-COPIA\gpuvm` |
| Delete the template while in use | refused |
| Copy's disk after first boot | 2.73 GB |

The first run failed creating the copy: `$template` (a variable) and `-Template` (the parameter) are the same name in PowerShell, so the template's data was turned into a string. Renamed and re-run with `-UseExisting`.

## Conclusion

Adopted. Copies are ready in seconds and take a few GB. Open point: a template takes the space the source VM's disk *ever* used, not what Windows uses now (159 GB from a 200 GB fixed disk with a big game). Next lab: zero the free space inside Windows before copying, and check Convert-VHD then skips those blocks.
