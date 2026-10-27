# Registro de cambios

Aquí se documentan los cambios importantes de GpuVM. El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el proyecto usa [versionado semántico](https://semver.org/lang/es/).

[English](CHANGELOG.md)

## [0.1.0] - 2026-10-27

Primera versión pública.

### Agregado
- **App de escritorio** (Tauri 2 + React): todas las VMs de Hyper-V en una lista, «Encender y abrir» en un clic, estadísticas en vivo de CPU, memoria y GPU, opciones (procesadores, memoria, parte de la GPU, resolución y FPS de Moonlight), asistente para crear máquinas y acciones de energía. Temas claro y oscuro con barra de título y borde de ventana propios que siguen el tema.
- **Preferencias**: tema (sistema, claro u oscuro, también desde la barra de título) y qué hace cerrar la ventana (salir por completo o quedarse en la bandeja del sistema). Abrir GpuVM otra vez muestra la ventana que ya está abierta.
- **VMs Windows con la GPU del equipo** mediante GPU partitioning de Hyper-V (GPU-P): la imagen de Windows se aplica directo a un VHDX, el driver del host se copia al invitado y la instalación es desatendida (cuenta local, inicio de sesión automático, sin OOBE).
- **Streaming**: Sunshine dentro de la VM captura una pantalla virtual dibujada por la GPU y codifica con NVENC; Moonlight en el host la abre. El emparejamiento es automático (el PIN se entrega a Sunshine por su API).
- **Audio silencioso** con VB-CABLE (firmado WHQL), con el crédito a VB-Audio que pide su licencia.
- **Autorreparación al «Encender y abrir»**: sincroniza el driver de la GPU si el del host cambió, espera a Windows y a Sunshine, devuelve la sesión de Windows a la pantalla de la GPU, elige la pantalla virtual en Sunshine y ajusta su resolución a la de Moonlight.
- **Perfiles** en JSON con herencia (`balanced`, `max-performance`) y ajustes por VM.
- **Laboratorios** para medir cada mejora (base contra candidata) antes de adoptarla, con siete laboratorios abiertos.
- **CLI** `gpuvm.ps1` y módulo de PowerShell `GpuVM` con las mismas funciones.
- Instalador NSIS (para todo el equipo, en Program Files) con el módulo, los perfiles y los scripts del invitado incluidos.

### Seguridad
- La app, que corre como administrador, solo ejecuta scripts de Program Files, y PowerShell 7 solo desde Program Files (MSI o carpeta del paquete de Microsoft Store).
- Los datos que cambian (laboratorios, descargas) viven en `%ProgramData%\GpuVM`, solo para administradores.
- Los instaladores de terceros están fijados por SHA-256 y se vuelven a verificar justo antes de copiarlos a la VM.
- Las credenciales de streaming y del invitado se cifran con DPAPI.

[0.1.0]: https://github.com/alenj0x1/gpuvm/releases/tag/v0.1.0
