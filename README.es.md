[English](README.md) | Español

<p align="center">
  <img src="docs/src/assets/logo.svg" width="72" alt="Logo de GpuVM">
</p>

<h1 align="center">GpuVM</h1>

<p align="center">
  Máquinas virtuales Windows 10/11 que usan tu propia GPU: se crean, se encienden y se abren en un clic.
</p>

<p align="center">
  <a href="https://github.com/alenj0x1/gpuvm/releases"><img src="https://img.shields.io/github/v/release/alenj0x1/gpuvm?include_prereleases&label=versi%C3%B3n" alt="Versión"></a>
  <a href="https://alenj0x1.github.io/gpuvm/es/"><img src="https://img.shields.io/badge/docs-alenj0x1.github.io%2Fgpuvm-2f5bd3" alt="Documentación"></a>
  <a href="CHANGELOG.es.md"><img src="https://img.shields.io/badge/cambios-0.2.0-6b6e75" alt="Registro de cambios"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/licencia-MIT-2f9e6a" alt="Licencia MIT"></a>
</p>

<p align="center">
  <img src=".github/assets/app-light.png" width="49%" alt="GpuVM en modo claro">
  <img src=".github/assets/app-dark.png" width="49%" alt="GpuVM en modo oscuro">
</p>

## Qué hace

- **Tu GPU dentro de la VM.** El GPU partitioning de Hyper-V (GPU-P) comparte la GPU del equipo con la VM, que usa el mismo driver que el host. Sin passthrough ni segunda GPU.
- **Se abre en un clic.** «Encender y abrir» enciende la VM, espera a Windows, corrige la sesión y la pantalla, empareja Moonlight y abre la imagen dibujada y codificada por la GPU (Sunshine + NVENC), con sonido.
- **Se corrige sola.** Vuelve a copiar el driver de la GPU si cambió el del equipo, devuelve la sesión de Windows a la pantalla de la GPU y ajusta la resolución a la de Moonlight.
- **Crea máquinas sin pasar por el instalador.** Eliges un ISO oficial de Windows y un perfil: la imagen se aplica directo al disco y se configura sola.
- **Estadísticas y opciones.** Uso en vivo de CPU, memoria y GPU; procesadores, memoria, parte de la GPU y calidad de la imagen de cada VM.
- **Biblioteca.** Tus propios perfiles (procesadores, memoria, GPU, disco, ISO, apps, cómo abre Moonlight), los discos que quedaron de VMs eliminadas para volver a crearlas, y las ISOs que usaste.
- **Apps en un paso.** Steam, Epic Games, Discord, Chrome, Brave, Proton VPN y Firefox, instaladas dentro de la VM solo si las firma su empresa.
- **Juegos en pantalla completa exclusiva.** Una opción de captura por VM los muestra en vez de una pantalla negra; pega texto del PC en la VM con un botón.
- **Mantiene aparte al equipo.** Moonlight corre sin permisos de administrador, y el portapapeles solo va del PC a la VM, nunca al revés.
- **Laboratorios.** Cada idea de rendimiento se mide (base contra candidata) antes de volverse un valor por defecto.

<p align="center">
  <img src=".github/assets/create-light.png" width="49%" alt="Crear una máquina">
  <img src=".github/assets/empty-light.png" width="49%" alt="Primera máquina">
</p>

## Requisitos

- Windows 10/11 Pro, Enterprise, Education o Pro for Workstations, con Hyper-V activo.
- Una GPU que permita particionarse (probado con una NVIDIA GeForce RTX 4060).
- [PowerShell 7](https://learn.microsoft.com/es-es/powershell/scripting/install/installing-powershell-on-windows) (MSI o Microsoft Store).
- Un ISO oficial de Windows 10 u 11.

Activa Hyper-V una vez, como administrador, y reinicia:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```

## Instalación

Descarga `GpuVM_x.y.z_x64-setup.exe` desde [Releases](https://github.com/alenj0x1/gpuvm/releases) y ejecútalo. GpuVM se instala para todos los usuarios en Program Files y pide permisos de administrador al abrirse, porque Hyper-V los exige. Los datos que cambian (laboratorios, descargas) van a `%ProgramData%\GpuVM`.

## Primeros pasos

1. Abre GpuVM y elige **Crear máquina**: nombre, ISO de Windows, perfil y contraseña de Windows.
2. Espera a que esté lista; Windows termina de configurarse solo en unos minutos.
3. Presiona **Abrir**. Moonlight se abre con la VM.

## Documentación

Guía completa, referencia de la CLI, arquitectura y solución de problemas: **[alenj0x1.github.io/gpuvm/es](https://alenj0x1.github.io/gpuvm/es/)** (español e inglés).

## Cómo funciona

| Parte | Qué hace |
|---|---|
| `app/` | App de escritorio (Tauri 2 + React). Habla con PowerShell a través de `src/bridge.ps1`. |
| `src/GpuVM/` | Módulo de PowerShell 7: creación, perfiles, sincronización del driver, streaming, laboratorios. Backends intercambiables (`Backends/`). |
| `guest/` | Scripts que corren dentro de la VM: primer inicio, optimizaciones, streaming, resolución de la pantalla. |
| `profiles/` | Perfiles JSON con herencia (`balanced`, `max-performance`). |
| `streaming/components.json` | Componentes de terceros fijados por versión y SHA-256. |
| `labs/` | Las mediciones detrás de cada decisión. |

## Desarrollo

```powershell
npm --prefix app install
npm --prefix app run dev          # interfaz con datos de ejemplo en el navegador (?mock=empty, ?mock=noadmin)
npm --prefix app run tauri build  # instalador en app/src-tauri/target/release/bundle/nsis/
Invoke-Pester ./tests             # pruebas del módulo, sin administrador
npm --prefix docs run dev         # sitio de documentación
python scripts/release.py 0.4.0   # versión nueva: changelog, versiones, commit y etiqueta (--dry-run, --next)
```

Los cambios van en **Unreleased** de `CHANGELOG.md` y **Sin publicar** de `CHANGELOG.es.md` hasta que se publican.

La CLI tiene las mismas funciones: `./gpuvm.ps1 check`, `new`, `connect`, `list`, `sync-driver`, `set`, `remove`, `lab-*` (ver la documentación).

## Componentes de terceros

GpuVM descarga e instala dentro de la VM, verificados por SHA-256:

- [Sunshine](https://github.com/LizardByte/Sunshine) (GPL-3.0): servidor de streaming.
- [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver): monitor virtual dibujado por la GPU.
- [nefcon](https://github.com/nefarius/nefcon): instalador de drivers.
- [usbip-win2](https://github.com/vadimgrn/usbip-win2) (BSD-2-Clause): cliente USB/IP con drivers firmados por Microsoft; conecta el altavoz USB propio de GpuVM dentro de la VM.

En el equipo usa [Moonlight](https://moonlight-stream.org) (GPL-3.0), instalado con winget.

## Registro de cambios

Ver [CHANGELOG.es.md](CHANGELOG.es.md).

## Licencia

[MIT](LICENSE). Los componentes de terceros mantienen sus propias licencias.
