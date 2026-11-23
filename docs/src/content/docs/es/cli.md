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
| `components-update` | `Update-GpuVMComponent` | Busca versiones nuevas de los componentes de streaming. |
| `remove` | `Remove-GpuVM` | Quita la VM de Hyper-V. |
| `rename` | `Rename-GpuVM` | Cambia el nombre de la VM con su carpeta y su disco. |
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

Revisa la edición de Windows, los permisos de administrador, la virtualización, Hyper-V, las GPU particionables, la selección de GPU en Windows 10, el switch de red, el perfil contra tu hardware, la memoria libre, la GPU, el espacio en disco y los componentes de streaming.

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

`-Name` (obligatorio), `-Profile`, `-Override`. La VM debe estar apagada. Sin `-Profile` parte de la configuración actual de la VM; con `-Profile` conserva el disco, la carpeta y las preferencias de imagen.

### list

`-Name` (por defecto `*`). Muestra nombre, estado, perfil, backend, CPU, memoria, GPU, versión del driver, si el driver está sincronizado y la edición.

### sync-driver

`-Name` (obligatorio), `-ShutdownIfRunning` (apaga la VM, sincroniza y la vuelve a encender). Úsalo después de actualizar el driver de NVIDIA.

### components-update

`-Name` (uno o más componentes: `sunshine`, `vdd`, `nefcon`, `usbip`, `vigembus`; todos por defecto, salvo los retenidos). Admite `-WhatIf`. Consulta [Streaming](/docs/es/streaming/#actualizar-componentes).

### remove

`-Name` (obligatorio), `-DeleteDisk` (borra también la carpeta y el disco de la VM; no se puede deshacer).

### rename

`-Name` y `-NewName` (obligatorios). La VM debe estar apagada. Le cambia el nombre en Hyper-V, en su carpeta y en su disco, y conserva su configuración, el emparejamiento con el visor y los discos compartidos. El nombre nuevo sigue las mismas reglas que en `new`; si un paso falla, se deshace lo que ya se había renombrado.

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
./gpuvm.ps1 list                                     # VMs y si su driver coincide con el del host
./gpuvm.ps1 sync-driver -Name win11                  # después de actualizar el driver de NVIDIA (VM apagada)
./gpuvm.ps1 set -Name win11 -Profile balanced        # cambiar de perfil (VM apagada)
./gpuvm.ps1 rename -Name win11 -NewName juegos       # cambiar el nombre (VM apagada)
./gpuvm.ps1 remove -Name win11                       # agrega -DeleteDisk para borrar también el disco
```

## Módulo

```powershell
Import-Module ./src/GpuVM/GpuVM.psd1
```

Además de los cmdlets anteriores, el módulo exporta estos, que usa sobre todo la app:

| Cmdlet | Qué hace |
|---|---|
| `Get-GpuVMOverview` | Todas las VMs de Hyper-V con su estado y uso en vivo (CPU, memoria, GPU), creadas o no con GpuVM. En las máquinas de GpuVM, `options.diskBudget` dice hasta dónde puede crecer su disco, contando el espacio prometido a las demás máquinas de esa unidad. |
| `Get-GpuVMHostInfo` | Hilos, memoria y nombre de la GPU del host, y en `disk` el espacio que tiene el disco de una máquina nueva en la unidad de GpuVM con todos los discos de las máquinas llenos, dejando 20 GB para Windows. |
| `Get-GpuVMIsoList` | ISOs de Windows en Descargas y Escritorio. |
| `Invoke-GpuVMPower` | `-Action` `Start`, `Shutdown`, `TurnOff`, `Restart`, `Pause` o `Resume` sobre cualquier VM. |
| `Set-GpuVMGuestCredential` | Guarda la cuenta del invitado (DPAPI) para que GpuVM corrija cosas dentro de la VM por PowerShell Direct. |
| `Set-GpuVMStreamingClient` | Cambia cómo se abre la imagen de la VM. No requiere apagarla. Consulta [más abajo](#set-gpuvmstreamingclient). |
| `Connect-GpuVM` | `-Name`, `-Pair`, `-Monitor`, `-MemoryGB`. Deja una máquina lista para el visor de GpuVM (driver, encendido, Windows, sesión, pantalla, emparejamiento) y devuelve los argumentos del stream (`viewerLaunch`); la app abre el visor por su cuenta. Consulta [Streaming](/docs/es/streaming/#desde-powershell). |
| `Get-GpuVMAdminPrompt` | Los avisos de administrador de Windows abiertos en las máquinas de GpuVM encendidas: `name`, `id`, `app`, `publisher`. Solo lee el intercambio de datos de Hyper-V (unos 100 ms, sin PowerShell Direct); la app lo consulta cada segundo. |
| `Resolve-GpuVMAdminPrompt` | `-Name`, `-Answer` `Allow` o `Deny`, `-PromptId` (el `id` de `Get-GpuVMAdminPrompt`). Presiona Sí o No en la VM, solo si ese aviso sigue siendo el que está abierto; si no, falla sin presionar nada. Necesita la contraseña del invitado. Consulta [Avisos de administrador](/docs/es/streaming/#avisos-de-administrador). |
| `Update-GpuVMSettings` | Aplica procesador, memoria o GPU aunque la VM esté encendida: valida, la apaga, aplica y la vuelve a encender; si no puede encenderla, restaura la configuración anterior. |
| `Get-GpuVMHome` | Lo que muestra el Inicio de la app: la última máquina abierta, qué máquinas caben en memoria y lo que necesita atención. |
| `Stop-GpuVMAll` | Apaga de forma ordenada todas las máquinas de GpuVM encendidas, a la vez. |
| `Send-GpuVMClipboard` | Pone texto en el portapapeles de la VM (solo del PC a la VM). |
| `Set-GpuVMNetworkIsolation` | Activa (la predeterminada) o desactiva el aislamiento de red de la VM. |
| `Get-GpuVMCleanup` / `Set-GpuVMCleanup` | Los niveles de limpieza de Windows / aplica uno a una VM. |
| `Get-GpuVMMonitor` | Los monitores de este equipo, de izquierda a derecha (`id`, nombre, tamaño, frecuencia y cuál es el principal), para elegir dónde se abre una VM. |
| `Get-GpuVMApp` / `Install-GpuVMApp` | El catálogo de apps / instala apps en una VM (la enciende si hace falta). Las que ya están instaladas quedan como están; `-Reinstall` primero las desinstala y luego las instala de nuevo. |
| `Get-GpuVMInstalledApp` | `-Name`. Las apps del catálogo instaladas en una VM: se revisan dentro de Windows mientras está encendida; apagada, las últimas que se vieron. |
| `Uninstall-GpuVMApp` | `-Name`, `-App`. Desinstala apps con el desinstalador de cada una, en silencio (enciende la VM si hace falta). El de Battle.net no tiene modo silencioso: se abre en el escritorio de la VM para terminarlo ahí. |
| `Add-GpuVMIso` / `Remove-GpuVMIso` | Recuerda un ISO en la biblioteca / lo olvida (el archivo queda). |
| `Get-GpuVMDisk` / `Restore-GpuVM` / `Remove-GpuVMDisk` | Los discos de la carpeta de GpuVM / vuelve a crear una VM con un disco conservado / borra un disco libre. |
| `Get-GpuVMBase` / `Remove-GpuVMBase` | Los Windows preparados (uno por ISO y edición) / borra uno; la próxima VM con ese Windows lo vuelve a preparar. |
| `Save-GpuVMProfile` / `Remove-GpuVMProfile` | Crea o actualiza un perfil propio / lo borra. |
| `New-GpuVMTemplate` / `Get-GpuVMTemplate` / `Remove-GpuVMTemplate` | Guarda una VM apagada como plantilla / lista las plantillas (con `stale`, `updating` y `layers`) / borra una sobre la que no hay VMs. |
| `Update-GpuVMTemplate` | `-Name` o `-Stale` (todas las que lo necesiten), `-Force`. Pone una plantilla al día con el Sunshine de este GpuVM (y el agente, si es de agentes) como una capa de solo lectura encima: una copia temporal recibe la instalación una vez, se apaga limpio y su disco pasa a ser la capa más nueva, así las copias no lo instalan una por una. Las copias anteriores conservan su capa. La app ejecuta `-Stale` al abrir y cada hora. |
| `New-GpuVMSharedDisk` / `Get-GpuVMSharedDisk` / `Connect-GpuVMSharedDisk` / `Disconnect-GpuVMSharedDisk` / `Import-GpuVMSharedDisk` / `Remove-GpuVMSharedDisk` | Discos compartidos: crear, listar, conectar, desconectar, copiar a uno una carpeta de este equipo, borrar. |
| `Get-GpuVMRestorePoint` / `New-GpuVMRestorePoint` / `Restore-GpuVMRestorePoint` / `Remove-GpuVMRestorePoint` | Puntos de restauración de una VM apagada: listar, guardar, volver (`-SaveCurrent` guarda antes cómo está ahora como un punto nuevo), borrar. |
| `Export-GpuVM` / `Get-GpuVMImportInfo` / `Import-GpuVM` | Guarda una VM apagada en un solo archivo `.gpuvm`, sin su contraseña de Windows / lee qué contiene un archivo / crea una VM desde él, con su propia identidad de streaming. |
| `Set-GpuVMDisposable` / `Remove-GpuVMDisposable` | Conserva una máquina desechable como una normal / borra las máquinas desechables apagadas. |
| `Send-GpuVMFile` / `Get-GpuVMExplorerSelection` | Copia archivos y carpetas de este equipo, o de otra VM encendida, al `Desktop\Received` de una VM / lo seleccionado en el Explorador de archivos de una VM. |
| `Set-GpuVMUse` / `Install-GpuVMAgent` / `Uninstall-GpuVMAgent` | Convierte una VM en máquina de agentes o la devuelve a una persona / instala o quita el agente de GpuVM dentro de ella. Los demás cmdlets `*-GpuVMAgent*` atienden a la sección [Agentes](/docs/es/agents/) y al servidor MCP. |

Desde la app, `Remove-GpuVM`, `Remove-GpuVMDisk`, `Remove-GpuVMBase`, `Remove-GpuVMSharedDisk` y `Remove-GpuVMTemplate` además piden confirmación en UAC ([Arquitectura](/docs/es/architecture/#puente-entre-la-app-y-powershell)).

### Set-GpuVMStreamingClient

| Parámetro | |
|---|---|
| `-Name` | Obligatorio. |
| `-Resolution` | Por ejemplo `2560x1440`. |
| `-Fps` | De 10 a 480, o `0` para la frecuencia del monitor del equipo, que se lee cada vez que se abre la VM. |
| `-BitrateKbps` | De 0 a 500000; `0` deja que el visor lo elija según la resolución y los FPS. |
| `-Codec` | `auto`, `H.264`, `HEVC` o `AV1`. |
| `-DisplayMode` | `fullscreen`, `windowed` (una ventana del tamaño de la resolución que se puede redimensionar) o `borderless`. |
| `-VSync` | `$true` o `$false`. Sin indicarlo, queda como está. |
| `-FramePacing` | `$true` o `$false`. Se apaga siempre que la sincronización vertical está apagada. |
| `-Mouse` | `capture` (la VM toma el mouse, para juegos) o `absolute` (el puntero se mueve libre, como en escritorio remoto). |
| `-Monitor` | El monitor donde se abre la VM: un `id` de `Get-GpuVMMonitor`, `primary`, o `default` para seguir lo elegido en Ajustes de la app. |

```powershell
Set-GpuVMStreamingClient -Name win11 -Fps 0 -VSync $true -FramePacing $false -Mouse capture   # el uso «Juegos»
```
