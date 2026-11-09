---
title: Problemas y límites conocidos
description: Pantalla negra en Moonlight, avisos de administrador, mandos, sincronización del driver, anti-cheat, selección de GPU en Windows 10 y otros límites conocidos de GPU-P.
---

## Pantalla negra en Moonlight

Las causas habituales, en orden:

1. **Sunshine está capturando la pantalla de Hyper-V** en lugar de la virtual. **Encender y abrir** (o `./gpuvm.ps1 connect`) apunta Sunshine a la pantalla virtual cada vez. Si avisa que Sunshine no ve la pantalla virtual, revisa `C:\GpuVM\setup.log` dentro de la VM.
2. **El driver de la VM no coincide con el del host** (después de actualizar el driver de NVIDIA). Al abrirla desde la app se sincroniza solo si la VM está apagada; o ejecuta `./gpuvm.ps1 sync-driver -Name <vm>` con la VM apagada.
3. **Escritorio remoto se llevó la sesión** de la pantalla de la GPU. Cierra Escritorio remoto y vuelve a usar **Encender y abrir**: con la contraseña del invitado guardada, GpuVM devuelve la sesión a la consola.

Si la imagen tarda en aparecer al conectar, revisa que **Opciones → Captura** esté en **Rápida**: la captura **Clásica** puede quedar en negro hasta que algo cambie en pantalla.

Para ver la pantalla de la VM sin la GPU, abre la consola de Hyper-V (**Ver consola de Hyper-V** en el menú **⋯**, o `vmconnect.exe localhost <vm>`). Mientras la pantalla virtual funciona, la de Hyper-V está desactivada; Escritorio remoto sigue disponible como respaldo.

Problema abierto ([laboratorio 002](/gpuvm/docs/es/labs/#lo-que-encontraron-los-laboratorios-hasta-ahora)): Sunshine puede decir "Display device configuration API is temporarily unavailable" y no cambiar la resolución.

## Un programa en pantalla completa se ve en negro

El escritorio se ve bien, pero un juego o programa en **pantalla completa exclusiva** se ve en negro (puede aparecer cuando pierde el foco). Pasa con la captura **Clásica**, que no ve la pantalla completa exclusiva en una pantalla virtual. En **Opciones → Captura** elige **Rápida** (la predeterminada en las máquinas nuevas) y guarda. Consulta [Modos de captura](/gpuvm/docs/es/streaming/#modos-de-captura).

## Un programa espera permiso de administrador

Con la captura **Rápida**, los avisos de administrador de Windows no se dibujan en Moonlight; GpuVM los muestra en una tarjeta encima de todo, con **Permitir** y **Rechazar** ([Avisos de administrador](/gpuvm/docs/es/using-the-app/#avisos-de-administrador)). Si no aparece la tarjeta:

- GpuVM tiene que estar abierto (en la ventana o en la bandeja): la tarjeta sale de la app.
- GpuVM necesita la contraseña de Windows de la VM; sin ella, la VM muestra un aviso que la pide.
- El vigilante se instala la primera vez que la VM se abre desde GpuVM; ábrela una vez con **Abrir**.
- Para ver los avisos en Moonlight, cambia a **Clásica** en **Opciones → Captura**.

## Las ventanas se abren donde no las veo

Las VMs con GPU-P tienen una salida oculta extra de 1024×768; si quedaba como pantalla principal, las ventanas nuevas (Steam, instaladores) se abrían ahí en vez de en la pantalla transmitida. **Encender y abrir** lo corrige solo: deja la pantalla virtual como la única y principal. Necesita la contraseña del invitado; si todavía falta una ventana, vuelve a abrir la VM desde la app.

## Alt+F4 cerró el stream

Ya no: en pantalla completa, Alt+F4, Alt+Tab y la tecla Windows van a la VM. Para salir del stream, presiona **Ctrl+Alt+Shift+Q**. Las VMs creadas antes de este cambio también lo reciben la próxima vez que se abren.

## El mando no funciona

GpuVM instala el controlador de mandos (ViGEmBus) la primera vez que abre la VM, con la contraseña del invitado guardada; después Sunshine se reinicia para usarlo. Si un control no responde, vuelve a abrir la VM desde GpuVM y revisa que Moonlight vea el control en este equipo.

## Sincronizar el driver

El invitado tiene que usar **la misma versión de driver que el host**. Después de actualizar el driver de NVIDIA:

- En la app aparece un aviso en la VM; se actualiza solo la próxima vez que la enciendas desde la app, o en el momento con **Actualizar ahora** / **Apagar y actualizar**.
- Desde la CLI: `./gpuvm.ps1 sync-driver -Name <vm>` (VM apagada), o agrega `-ShutdownIfRunning`.
- `./gpuvm.ps1 list` muestra si el driver de cada VM está sincronizado.

## El primer inicio tarda

El primer inicio instala Windows y el streaming, y después reinicia una vez. **Encender y abrir** espera a Windows y a Sunshine, y lo indica en el botón. Si Sunshine nunca responde, el error remite a `C:\GpuVM\setup.log` dentro de la VM. Si la VM nunca obtiene una dirección IP, mira su pantalla con la consola de Hyper-V y confirma que exista el `Default Switch`. Si la VM está apagada, guardada o en pausa, abrirla lo dice al instante en vez de esperar una dirección.

## La app dice que el servicio de GpuVM está detenido o falta

La app corre sin permisos de administrador y le pide al servicio **GpuVM** el trabajo de Hyper-V. Con el servicio en **Manual**, inícialo con **Iniciar servicio**, o cámbialo a **Con GpuVM** en [Preferencias](/gpuvm/docs/es/using-the-app/#preferencias). Si falta (por ejemplo, tras una actualización fallida), **Reparar** lo vuelve a registrar después de un aviso de UAC; reinstalar GpuVM hace lo mismo.

## No hay audio

El sonido de la VM sale del altavoz USB de GpuVM, **Altavoces (GpuVM Audio)** ([Streaming](/gpuvm/docs/es/streaming/#audio)). **Encender y abrir** lo instala, lo reconecta y apunta Sunshine a él (`virtual_sink`) cuando falta, siempre que la contraseña de Windows de la VM esté guardada en GpuVM. Dentro de la VM, el estado del servidor está en `C:\ProgramData\GpuVM\Audio\status.json`. Sin la contraseña, al abrir la VM aparece un aviso. Si el perfil tiene `"audio": "none"`, no se instala ningún dispositivo de audio.

## Falla el emparejamiento

Usa **Volver a emparejar Moonlight** en el menú **⋯**, o `./gpuvm.ps1 connect -Name <vm> -Pair`. Si Moonlight no está instalado, instálalo ([Instalación](/gpuvm/docs/es/install/#instalar-moonlight)).

## La VM no enciende por falta de memoria

La memoria fija de Hyper-V tiene que estar libre al encender la VM. Cierra programas o baja la memoria de la VM en **Opciones** (o con `-Override @{ vm = @{ memoryGB = 6 } }`).

## Límites conocidos de GPU-P

- **Pantalla:** la consola de Hyper-V no muestra la GPU; se ve con el streaming.
- **Audio:** la VM no tiene tarjeta de sonido; el altavoz USB propio de GpuVM se la da, comprobado en una VM real a través de Moonlight ([laboratorio 012](/gpuvm/docs/es/labs/)).
- **Driver:** el invitado tiene que usar la misma versión que el host (ver arriba).
- **Selección de GPU en Windows 10:** no se puede elegir cuál GPU recibe la VM. Si la integrada también es particionable, puede tocarle la equivocada. `check` lo advierte; desactiva la integrada en el Administrador de dispositivos antes de encender la VM ([laboratorio 001](/gpuvm/docs/es/labs/)).
- **Sin puntos de control ni estado guardado:** la VM se apaga directamente.
- **Anti-cheat:** algunos sistemas anti-cheat bloquean las máquinas virtuales.
