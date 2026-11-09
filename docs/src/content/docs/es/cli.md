---
title: Referencia de la CLI
description: Los comandos de gpuvm.ps1 y los cmdlets del módulo de PowerShell GpuVM.
---

`gpuvm.ps1`, en la raíz del repositorio, es un atajo para el módulo `GpuVM`. Ejecútalo desde PowerShell 7 **como administrador** para crear y modificar VMs. (La app no lo necesita: trae su propio PowerShell 7 y el servicio GpuVM ejecuta el módulo por ella.)

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
| `-MemoryGB` | De 4 a 256. Abre con esa memoria cuando la VM no cabe como está configurada (se guarda, como al cambiarla en Opciones). |

Los valores que pases aquí valen solo para esta conexión; los predeterminados vienen de `streaming.client` de la VM (se cambian con `Set-GpuVMStreamingClient`), donde unos FPS de `0` significan la frecuencia del monitor del equipo. `connect` termina cuando Moonlight muestra el primer cuadro; si la VM ya está abierta en Moonlight (y no se pasa `-Pair`), trae esa ventana al frente. Si la VM está apagada, guardada o en pausa mientras espera su dirección, falla al instante.

### client-install

Sin parámetros. No hace nada si Moonlight ya está instalado.

### components-update

`-Name` (uno o más componentes: `sunshine`, `vdd`, `nefcon`, `usbip`, `vigembus`; todos por defecto, salvo los retenidos). Admite `-WhatIf`. Consulta [Streaming](/gpuvm/docs/es/streaming/#actualizar-componentes).

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
| `Set-GpuVMStreamingClient` | Cambia cómo abre Moonlight la VM. No requiere apagarla. Consulta [más abajo](#set-gpuvmstreamingclient). |
| `Set-GpuVMCapture` | `-Name`, `-Mode` `wgc` (la predeterminada: Windows.Graphics.Capture, la imagen aparece apenas te conectas y captura la pantalla completa exclusiva) o `ddx` (desktop duplication: muestra los avisos de administrador de Windows en el stream). Se aplica en el momento si la VM está encendida (reinicia Sunshine); si no, la próxima vez que se abra. Consulta [Modos de captura](/gpuvm/docs/es/streaming/#modos-de-captura). |
| `Get-GpuVMAdminPrompt` | Los avisos de administrador de Windows abiertos en las máquinas de GpuVM encendidas que capturan con `wgc`: `name`, `id`, `app`, `publisher`. Solo lee el intercambio de datos de Hyper-V (unos 100 ms, sin PowerShell Direct); la app lo consulta cada 2 s. |
| `Resolve-GpuVMAdminPrompt` | `-Name`, `-Answer` `Allow` o `Deny`, `-PromptId` (el `id` de `Get-GpuVMAdminPrompt`). Presiona Sí o No en la VM, solo si ese aviso sigue siendo el que está abierto; si no, falla sin presionar nada. Necesita la contraseña del invitado. Consulta [Avisos de administrador](/gpuvm/docs/es/streaming/#avisos-de-administrador). |
| `Update-GpuVMSettings` | Aplica procesador, memoria o GPU aunque la VM esté encendida: valida, la apaga, aplica y la vuelve a encender; si no puede encenderla, restaura la configuración anterior. |
| `Get-GpuVMHome` | Lo que muestra el Inicio de la app: la última máquina abierta, qué máquinas caben en memoria y lo que necesita atención. |
| `Stop-GpuVMAll` | Apaga de forma ordenada todas las máquinas de GpuVM encendidas, a la vez. |
| `Send-GpuVMClipboard` | Pone texto en el portapapeles de la VM (solo del PC a la VM). |
| `Set-GpuVMNetworkIsolation` | Activa (la predeterminada) o desactiva el aislamiento de red de la VM. |
| `Get-GpuVMCleanup` / `Set-GpuVMCleanup` | Los niveles de limpieza de Windows / aplica uno a una VM. |
| `Get-GpuVMApp` / `Install-GpuVMApp` | El catálogo de apps / instala apps en una VM (la enciende si hace falta). |
| `Add-GpuVMIso` / `Remove-GpuVMIso` | Recuerda un ISO en la biblioteca / lo olvida (el archivo queda). |
| `Get-GpuVMDisk` / `Restore-GpuVM` / `Remove-GpuVMDisk` | Los discos de la carpeta de GpuVM / vuelve a crear una VM con un disco conservado / borra un disco libre. |
| `Save-GpuVMProfile` / `Remove-GpuVMProfile` | Crea o actualiza un perfil propio / lo borra. |
| `New-GpuVMTemplate` / `Get-GpuVMTemplate` / `Remove-GpuVMTemplate` | Guarda una VM apagada como plantilla / lista las plantillas / borra una sobre la que no hay VMs. |
| `New-GpuVMSharedDisk` / `Get-GpuVMSharedDisk` / `Connect-GpuVMSharedDisk` / `Disconnect-GpuVMSharedDisk` / `Import-GpuVMSharedDisk` / `Remove-GpuVMSharedDisk` | Discos compartidos: crear, listar, conectar, desconectar, copiar a uno una carpeta de este equipo, borrar. |

Desde la app, `Remove-GpuVM`, `Remove-GpuVMDisk`, `Remove-GpuVMSharedDisk` y `Remove-GpuVMTemplate` además piden confirmación en UAC ([Arquitectura](/gpuvm/docs/es/architecture/#puente-entre-la-app-y-powershell)).

### Set-GpuVMStreamingClient

| Parámetro | |
|---|---|
| `-Name` | Obligatorio. |
| `-Resolution` | Por ejemplo `2560x1440`. |
| `-Fps` | De 10 a 480, o `0` para la frecuencia del monitor del equipo, que se lee cada vez que se abre la VM. |
| `-BitrateKbps` | De 0 a 500000; `0` deja que Moonlight lo elija según la resolución y los FPS. |
| `-Codec` | `auto`, `H.264`, `HEVC` o `AV1`. |
| `-DisplayMode` | `fullscreen`, `windowed` (una ventana del tamaño de la resolución que se puede redimensionar) o `borderless`. |
| `-VSync` | `$true` o `$false`. Sin indicarlo, queda como está. |
| `-FramePacing` | `$true` o `$false`. Se apaga siempre que la sincronización vertical está apagada. |
| `-Mouse` | `capture` (la VM toma el mouse, para juegos) o `absolute` (el puntero se mueve libre, como en escritorio remoto). |

```powershell
Set-GpuVMStreamingClient -Name win11 -Fps 0 -VSync $true -FramePacing $false -Mouse capture   # el uso «Juegos»
```
