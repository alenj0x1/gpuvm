# Shared disk

**Hypothesis:** A dynamic data disk attached as SCSI can move between VMs while they run (hot-add and hot-remove), get a drive letter and a Steam library inside with no manual step, and take a host folder (a Steam library) so games don't download again in the VM.

## Procedure

`run.ps1` (elevated, PowerShell 7) on `win10` running: creates a 64 GB test disk (`New-GpuVMSharedDisk`), attaches it (`Connect-GpuVMSharedDisk`), checks inside the drive letter, `SteamLibrary` and Steam's `libraryfolders.vdf`, detaches it (`Disconnect-GpuVMSharedDisk`, which takes the disk offline in Windows first), imports a 200 MB host folder shaped like a Steam library (`steamapps\appmanifest_480.acf` and `common\Spacewar`), attaches it again and checks the manifest arrived. It removes the test disk and restores Steam's file at the end.

## Observations

### Runs of Oct 28, 2026

| Step | Result |
|---|---|
| Create (64 GB dynamic, GPT, NTFS) | 6-7 s |
| Attach while running | 4-9 s, drive `G:` |
| Steam library | first run: Steam was open, so only a warning; second run, after GpuVM closes Steam (`steam.exe -shutdown` in the user's session), edits the file and opens it again (`-silent`): added |
| Detach while running | 3 s, no error |
| Import 200 MB | 1.3 s, into `SteamLibrary\steamapps` (only `steamapps` is taken from a Steam folder) |
| After attaching again | the game manifest is there |
| Disk file after the test | 0.4 GB for 64 GB virtual |

## Conclusion

Adopted. Attach, detach and import work on the real VM without restarting it; the Steam library is added without a manual step. After the security review, imports fail closed (any link, or folder that can't be listed, under the target stops the copy), refuse GpuVM's and Windows' folders and anything containing them, and the guest refuses a `SteamLibrary` that is a link.
