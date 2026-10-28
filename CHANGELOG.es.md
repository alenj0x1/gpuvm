# Registro de cambios

Aquí se documentan los cambios importantes de GpuVM. El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el proyecto usa [versionado semántico](https://semver.org/lang/es/).

[English](CHANGELOG.md)

Los cambios que esperan la próxima versión van en **Sin publicar**, arriba (esa sección solo existe mientras haya alguno y el sitio de documentación no la muestra); `scripts/release.py` la convierte en la versión nueva.

## [0.3.0] - 2026-10-28

### Cambiado
- **Audio real sin Steam.** La salida de VB-CABLE le llegaba muda a Sunshine dentro de la VM; el sonido que parecía funcionar venía de Steam Streaming Speakers (laboratorio 011). Ahora la VM tiene el altavoz USB propio de GpuVM, **Altavoces (GpuVM Audio)**: un servidor dentro de la VM presenta un dispositivo de audio USB, usbip-win2 (drivers firmados por Microsoft) lo conecta y Windows lo maneja con su propio driver. Llega a Moonlight con más volumen que los altavoces de Steam, no necesita reinicio, vuelve solo después de cada reinicio y nunca sale de la VM (`127.0.0.1`, `LOCAL SERVICE`). Las VMs existentes pasan a él la próxima vez que se abren (laboratorio 012).
- El primer arranque ya no reinicia la VM por el audio.
- `components-update` se salta los componentes retenidos; usbip-win2 se mantiene en 0.9.8.0 hasta que un laboratorio pruebe una versión nueva.

### Seguridad
- **La VM queda aislada de tu red por defecto.** Conserva internet, pero no llega a este equipo ni a tu red local, salvo al DHCP y DNS del Default Switch y a las respuestas de las conexiones que abre Moonlight. Las reglas viven en el puerto del switch virtual de la VM y las aplica el equipo, así que una VM dañada o infectada no puede quitarlas; se renuevan antes de cada encendido porque el Default Switch cambia la dirección del equipo. Se desactiva por VM en **Opciones → Red** (por ejemplo, para llegar a un NAS). No se aplica en un switch externo, con un aviso (laboratorio 010).

## [0.2.0] - 2026-10-27

### Agregado
- **Biblioteca** (ícono de capas en la barra de título) con tres pestañas:
  - **Perfiles**: crea, edita, duplica y borra tus propios perfiles a partir de los incluidos. Cada uno guarda procesador, memoria, parte de la GPU, tamaño y tipo de disco, ISO de Windows, apps por instalar y cómo abre Moonlight (resolución, FPS, pantalla completa o ventana). «Crear máquina» llena todo con el perfil elegido.
  - **Discos**: muestra qué VM usa cada disco, vuelve a crear una VM con un disco que se conservó al eliminarla, o borra los discos libres.
  - **ISOs**: recuerda las ISOs que usaste (con las máquinas que las usaron) y las ofrece primero; puedes agregarlas o quitarlas de la lista.
- **Apps para instalar en la VM**: Steam, Epic Games, Discord, Chrome, Proton VPN y Firefox. Se eligen al crear la máquina (se instalan la primera vez que se abre) o después desde la tarjeta Apps de la VM. Cada instalador se descarga dentro de la VM y solo se ejecuta si Windows confirma que lo firma su empresa; las versiones fijas también se comprueban por SHA-256.
- **Pegar en la VM**: un botón pasa el texto copiado en este equipo al portapapeles de la VM, listo para Ctrl+V. Solo va del PC a la VM; la VM nunca lee el portapapeles de este equipo.
- **Opción de captura** por VM (Opciones → Captura): «Estándar» (por defecto) o «Pantalla completa exclusiva», que además muestra programas en pantalla completa exclusiva a cualquier resolución. En ese modo los avisos de administrador de Windows no se ven en el stream.
- **Ampliar el disco** desde Opciones; el disco C: de la VM crece solo la próxima vez que se abre.
- **Abrir en ventana**: Moonlight puede abrir la VM en pantalla completa o en una ventana del tamaño de la resolución elegida.
- **Preferencia «Al salir de GpuVM»**: dejar las máquinas encendidas o apagarlas de forma ordenada.
- Clic en el patrón de una máquina o perfil para cambiarlo; el nuevo se ve en todas partes al instante.
- Labs 008 (tiempo de arranque del stream) y 009 (captura de programas en pantalla completa exclusiva), y un medidor de latencia de punta a punta en `tools/latency`.

### Cambiado
- **Abrir una VM es mucho más rápido**: si GpuVM ya apagó la pantalla de Hyper-V, Sunshine ya no reconfigura la pantalla en cada sesión, lo que lo obligaba a volver a probar todos sus codificadores. El primer cuadro llega en unos 2 s en vez de 22–27 s (lab 008).
- La pantalla virtual queda como la única y principal de la VM, así que las ventanas nuevas siempre aparecen donde se ve el stream; si ya está así, no se toca nada.
- En pantalla completa, Alt+F4, Alt+Tab y la tecla Windows van a la VM en vez de cerrar o sacarte de Moonlight (Ctrl+Alt+Shift+Q sale del stream).
- Windows Update ya no instala drivers de GPU en la VM (reemplazarían el copiado del host).
- El procesador de la VM ya no oculta instrucciones como AVX2 (compatibilidad de migración apagada).
- Se rehicieron los labs 006 y 007: el host usa el planificador root de Hyper-V, donde la reserva y el peso de CPU no tienen efecto, y la candidata de NVENC era igual a los valores por defecto de Sunshine.
- Los mensajes de espera dicen lo que pasa (un reinicio de Sunshine ya no aparece como primer arranque).

### Corregido
- Aplicar Opciones fallaba en toda VM con TPM virtual (Hyper-V no deja cambiar la plantilla de Secure Boot una vez iniciado el TPM).
- Windows y los programas podían abrirse en una salida oculta de 1024×768 de la GPU compartida en vez de la pantalla transmitida.
- Siluetas de carga casi invisibles o apiladas sin espacio; diálogos que se desbordaban en ventanas angostas; íconos de apps desalineados.

### Seguridad
- Moonlight corre sin permisos de administrador, así que una VM comprometida que hable con él no puede alcanzar un proceso elevado en el host.
- La dirección de la VM solo se acepta si está dentro de la red de Hyper-V del host, y la API de Sunshine no sigue redirecciones.
- Cuando el host debe abrir el disco de una VM (actualizar el driver), lo monta sin letra de unidad y rechaza los enlaces puestos dentro, para que una VM no pueda redirigir escrituras a archivos del host.
- `C:\GpuVM` y `%ProgramData%\GpuVM` se revisan y restringen a Administradores y SYSTEM cada vez (los procesos de las VMs solo leen); el proceso elevado ignora módulos y ajustes del entorno del usuario, y la versión publicada no tiene respaldos de desarrollo.
- Las VMs no pueden hacerse pasar por servidor DHCP ni router en la red (protecciones DHCP y router activadas).

## [0.1.1] - 2026-10-27

### Corregido
- **Audio con Windows en otros idiomas.** La VM nunca configuraba el audio de Sunshine si Windows no estaba en inglés, porque la salida del cable tiene un nombre traducido («Altavoces (VB-Audio Virtual Cable)» en español). Ahora se busca por tipo de dispositivo, así que la imagen llega con sonido con Windows en cualquier idioma.
- **«Encender y abrir» repara el audio** de las VMs creadas antes de esta corrección: si la contraseña de Windows de la VM está guardada, hace que Sunshine capture la salida del cable cuando todavía no lo hace.
- Sunshine solo se reinicia cuando su configuración cambia de verdad.

### Agregado
- Licencia MIT.

## [0.1.0] - 2026-10-27

Primera versión.

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

[0.3.0]: https://github.com/alenj0x1/gpuvm/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/alenj0x1/gpuvm/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/alenj0x1/gpuvm/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alenj0x1/gpuvm/tree/v0.1.0
