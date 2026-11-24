# Lab 068: GpuVM's agent as the admin channel of an HCS machine

Question: can GpuVM's own agent replace PowerShell Direct, KVP and the Hyper-V heartbeat for machines run by HCS
(which have none of them), with the agent installed while the machine is off and the host side gated so only GpuVM's
administrative side reaches the machine-level methods?

`run.ps1` stops the installed GpuVM service for the run (the agent channel's Hyper-V socket name is one per host), runs
this branch's `gpuvm-host broker` as SYSTEM through a one-off scheduled task, makes a machine from `normal-tpl`,
installs the agent offline (`gpuvm-host hcs install-agent`), starts it, and drives `sys.*` through
`gpuvm-host hcs ask` (the administrative pipe). It deletes everything and starts the GpuVM service again at the end.

## Results (2026-11-24, Windows 10 Pro 19045, RTX 4060)

| Step | Result |
| --- | --- |
| Offline install: program, secret and machine id (owner Administrators, protected SYSTEM + Administrators DACL), `GpuVMAgent` service in the offline SYSTEM hive's current control set | 473-728 ms |
| The machine id written = the RuntimeId the host sees on accept | yes (it depends only on the compute system's id) |
| Start | 0.7-2.4 s |
| Agent connected and answering `sys.info` | 4.1 s after start (the service starts before sign-in) |
| `sys.exec whoami` / `cmd /c ver` / `nvidia-smi` | `nt authority\system` / 10.0.19045 / RTX 4060, 8188 MiB; 58-184 ms |
| `sys.write` + `sys.read` of 3 MiB | 336 ms + 30 ms, same SHA-256 |
| `sys.info` asked with an agent client's `Connection` | refused: `denied` |
| Unknown `sys.nope` | refused: `bad_request` |
| `sys.power shutdown` | machine off 6.1 s later |
| Whole run | 14.3 s |

After the security hardening (secret and machine id born with their ACL under a temporary name and renamed by handle,
registry walk with `REG_OPTION_OPEN_LINK` also when creating keys and at the hive root, machine folder protected,
`sys.*` refused to any agent-side caller), two more runs: one with the agent answering 124.5 s after start and the
machine off 76.3 s after `sys.power` (an outlier: the host was busy), the next back at 4.0 s and 8.1 s.

## Notes

- Win32 `SetFileInformationByHandle(FileRenameInfo)` with a bare name renamed the temporary file into the process's
  current directory (the test found `secret` in `app/host`): the rename now uses `NtSetInformationFile` with the
  folder's handle as root. Folders are opened sharing read and write so that rename can write to them. Windows refuses
  to replace a target someone holds open (0xC0000022); the install then fails without exposing anything.

- Hive edits: a private app hive (`RegLoadAppKeyW`) refuses a hive Windows left with pending log changes ("registry
  database is corrupt", 1009), and keeping our own handle on the file while loading it gives a sharing violation.
  `reg.exe load` replays the logs; the hive is loaded under a short random name in HKLM, changed with the registry API
  and unloaded at once. `RegLoadKeyW` called directly from the service returned 87 with the same arguments that work
  through P/Invoke and reg.exe, and `reg.exe load` started from `cargo test` failed with "filename too long" while the
  same call from the CLI works; not chased further, the lab proves the CLI path.
- The handle-walk check of `Windows\System32\config\SYSTEM` (no links on the way) runs right before the load; the
  handle can't stay open during the load (the registry needs the file alone).
- The machine's `user` was still empty at 4.1 s: nobody had signed in yet. GpuVM's guest setup had finished in the
  template already (`setupDone` true at once).
