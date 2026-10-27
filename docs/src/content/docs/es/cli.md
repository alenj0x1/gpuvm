---
title: Referencia de la CLI
description: Los comandos de gpuvm.ps1 y los cmdlets del módulo de PowerShell GpuVM.
---

`gpuvm.ps1`, en la raíz del repositorio, es un atajo para el módulo `GpuVM`. Ejecútalo desde PowerShell 7 **como administrador** para crear y modificar VMs.

```powershell
./gpuvm.ps1 <comando> [-Parámetro valor ...]
```

- Sin comando (o con uno desconocido) muestra la lista de comandos.
- Si se abre desde Windows PowerShell 5.1, se vuelve a ejecutar en PowerShell 7 con los mismos argumentos.
- Los parámetros se escriben como en PowerShell: `-Nombre valor`, un switch solo (`-Start`) o `-Nombre:valor` (`-Confirm:$false`). Un número negativo después de un parámetro es un valor, no otro parámetro.
- Ayuda de cada comando: `Get-Help <Cmdlet> -Detailed`.

## Comandos

| Comando | Cmdlet | Qué hace |
|---|---|---|
| `check` | `Test-GpuVMHost` | Revisa si el equipo está listo para crear una VM con el perfil indicado. |
| `new` | `New-GpuVM` | Crea una VM Windows 10/11 con la GPU del host, instalada de forma desatendida desde un ISO. |
| `set` | `Set-GpuVM` | Cambia una VM existente y apagada (perfil u override). |
| `list` | `Get-GpuVM` | Lista las VMs creadas con GpuVM e indica si su driver de GPU coincide con el del host. |
| `sync-driver` | `Sync-GpuVMDriver` | Copia al invitado el driver de GPU del host. |
| `connect` | `Connect-GpuVM` | Abre la VM en Moonlight y deja todo listo solo. |
| `client-install` | `Install-GpuVMClient` | Instala Moonlight en el host con winget. |
| `components-update` | `Update-GpuVMComponent` | Busca versiones nuevas de los componentes de streaming. |
| `remove` | `Remove-GpuVM` | Quita la VM de Hyper-V. |
| `repair` | `Repair-GpuVMState` | Reconstruye el archivo de estado de una VM creada con GpuVM. |
| `profiles` | `Get-GpuVMProfile` | Lista los perfiles o muestra uno ya resuelto. |
| `lab-new` | `New-GpuVMLab` | Abre un laboratorio. |
| `lab-add` | `Add-GpuVMLabResult` | Registra una medición en un laboratorio. |
| `lab` | `Get-GpuVMLab` | Lista los laboratorios o muestra uno con su comparación. |
| `lab-close` | `Close-GpuVMLab` | Cierra un laboratorio con su conclusión. |

## Parámetros

### check

| Parámetro | Por defecto | |
|---|---|---|
| `-Profile` | `balanced` | Perfil contra el que se revisa. |
| `-Override` | | Hashtable que se mezcla sobre el perfil. |

Revisa la edición de Windows, los permisos de administrador, la virtualización, Hyper-V, las GPU particionables, la selección de GPU en Windows 10, el switch de red, el perfil contra tu hardware, la memoria libre, la GPU, el espacio en disco, Moonlight y los componentes de streaming.

### new

| Parámetro | Por defecto | |
|---|---|---|
| `-Name` | obligatorio | Letras, números, `_` o `-`, hasta 40 caracteres. |
| `-IsoPath` | obligatorio | ISO de Windows 10/11. |
| `-Profile` | `balanced` | |
| `-Override` | | Hashtable que se mezcla sobre el perfil. |
| `-Edition` | `guest.edition` del perfil (`Pro`) | Edición de Windows del ISO. |
| `-Credential` | se pide | Cuenta local del invitado. |
| `-Start` | | Enciende la VM al crearla. |

### set

`-Name` (obligatorio), `-Profile`, `-Override`. La VM debe estar apagada. Sin `-Profile` parte de la configuración actual de la VM; con `-Profile` conserva el disco, la carpeta y las preferencias de Moonlight.

### list

`-Name` (por defecto `*`). Muestra nombre, estado, perfil, backend, CPU, memoria, GPU, versión del driver, si el driver está sincronizado y la edición.

### sync-driver

`-Name` (obligatorio), `-ShutdownIfRunning` (apaga la VM, sincroniza y la vuelve a encender). Úsalo después de actualizar el driver de NVIDIA.

### connect

| Parámetro | |
|---|---|
| `-Name` | Obligatorio. |
| `-Resolution` | Por ejemplo `2560x1440`. |
| `-Fps` | De 10 a 480. |
| `-BitrateKbps` | Bitrate de Moonlight. |
| `-Codec` | `auto`, `H.264`, `HEVC` o `AV1`. |
| `-App` | App de Sunshine que se abre (por defecto `Desktop`). |
| `-Pair` | Vuelve a emparejar aunque ya esté emparejado. |

Los valores que pases aquí valen solo para esta conexión; los predeterminados vienen de `streaming.client` del perfil.

### client-install

Sin parámetros. No hace nada si Moonlight ya está instalado.

### components-update

`-Name` (uno o más componentes: `sunshine`, `vdd`, `nefcon`, `vbcable`; todos por defecto). Admite `-WhatIf`. Consulta [Streaming](/gpuvm/es/streaming/#actualizar-componentes).

### remove

`-Name` (obligatorio), `-DeleteDisk` (borra también la carpeta y el disco de la VM; no se puede deshacer).

### repair

`-Name` (obligatorio), `-Profile` (por defecto `balanced`), `-Override`. Reconstruye `gpuvm.json` de una VM creada con GpuVM cuyo estado se perdió. La VM debe estar apagada. Si el invitado todavía no arrancó, recupera también la contraseña de Sunshine desde su disco.

### profiles

`-Name`, `-Override`. Sin nombre lista los perfiles; con nombre muestra el perfil con la herencia y el override aplicados.

### lab-new

| Parámetro | Por defecto |
|---|---|
| `-Title` | obligatorio |
| `-Hypothesis` | obligatorio |
| `-VM` | |
| `-BaselineProfile` | `balanced` |
| `-BaselineOverride` | |
| `-CandidateProfile` | |
| `-CandidateOverride` | |

### lab-add

`-Lab`, `-Variant` (`baseline` o `candidate`), `-Metric`, `-Value` (todos obligatorios), `-Unit`, `-LowerIsBetter`, `-Notes`.

### lab

`-Lab` (opcional).

### lab-close

`-Lab`, `-Status` (`adopted`, `rejected` o `inconclusive`), `-Conclusion` (todos obligatorios).

## Ejemplos

```powershell
./gpuvm.ps1 check -Profile max-performance          # revisa el equipo
./gpuvm.ps1 new -Name win11 -IsoPath D:\Win11.iso -Profile max-performance -Start
./gpuvm.ps1 client-install                           # instala Moonlight en el host (una vez)
./gpuvm.ps1 connect -Name win11                      # ver la VM con la GPU (enciende y empareja si hace falta)
./gpuvm.ps1 list                                     # VMs y si su driver coincide con el del host
./gpuvm.ps1 sync-driver -Name win11                  # después de actualizar el driver de NVIDIA (VM apagada)
./gpuvm.ps1 set -Name win11 -Profile balanced        # cambiar de perfil (VM apagada)
./gpuvm.ps1 remove -Name win11                       # agrega -DeleteDisk para borrar también el disco
```

## Módulo

```powershell
Import-Module ./src/GpuVM/GpuVM.psd1
```

Además de los cmdlets anteriores, el módulo exporta estos, que usa sobre todo la app:

| Cmdlet | Qué hace |
|---|---|
| `Get-GpuVMOverview` | Todas las VMs de Hyper-V con su estado y uso en vivo (CPU, memoria, GPU), creadas o no con GpuVM. |
| `Get-GpuVMHostInfo` | Hilos, memoria y nombre de la GPU del host. |
| `Get-GpuVMIsoList` | ISOs de Windows en Descargas y Escritorio. |
| `Invoke-GpuVMPower` | `-Action` `Start`, `Shutdown`, `TurnOff`, `Restart`, `Pause` o `Resume` sobre cualquier VM. |
| `Set-GpuVMGuestCredential` | Guarda la cuenta del invitado (DPAPI) para que GpuVM corrija cosas dentro de la VM por PowerShell Direct. |
| `Set-GpuVMStreamingClient` | Cambia la resolución, los FPS, el bitrate o el codec con los que Moonlight abre la VM. No requiere apagarla. |
| `Update-GpuVMSettings` | Aplica procesador, memoria o GPU aunque la VM esté encendida: valida, la apaga, aplica y la vuelve a encender; si no puede encenderla, restaura la configuración anterior. |
