# Wintun 0.14.1 (amd64)

`wintun.dll` from https://www.wintun.net/builds/wintun-0.14.1.zip (zip SHA-256
`07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51`), unmodified, signed by WireGuard LLC.
SHA-256 of the DLL: `e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce`.

GpuVM's agent uses it only through its API (`wintun.h`), to give isolated HCS machines their internet through the
host relay. It ships next to the agent under the terms in `LICENSE.txt`. `build.ps1` copies it into `dist\` and the
host only installs a file with the hash above.
