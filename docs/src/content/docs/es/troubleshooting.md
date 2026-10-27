---
title: Problemas y límites conocidos
description: Pantalla negra en Moonlight, sincronización del driver, anti-cheat, selección de GPU en Windows 10 y otros límites conocidos de GPU-P.
---

## Pantalla negra en Moonlight

Las causas habituales, en orden:

1. **Sunshine está capturando la pantalla de Hyper-V** en lugar de la virtual. **Encender y abrir** (o `./gpuvm.ps1 connect`) apunta Sunshine a la pantalla virtual cada vez. Si avisa que Sunshine no ve la pantalla virtual, revisa `C:\GpuVM\setup.log` dentro de la VM.
2. **El driver de la VM no coincide con el del host** (después de actualizar el driver de NVIDIA). Al abrirla desde la app se sincroniza solo si la VM está apagada; o ejecuta `./gpuvm.ps1 sync-driver -Name <vm>` con la VM apagada.
3. **Escritorio remoto se llevó la sesión** de la pantalla de la GPU. Cierra Escritorio remoto y vuelve a usar **Encender y abrir**: con la contraseña del invitado guardada, GpuVM devuelve la sesión a la consola.

Para ver la pantalla de la VM sin la GPU, abre la consola de Hyper-V (**Ver consola de Hyper-V**, o `vmconnect.exe localhost <vm>`). Mientras la pantalla virtual funciona, la de Hyper-V está desactivada; Escritorio remoto sigue disponible como respaldo.

Problema abierto ([laboratorio 002](/gpuvm/es/labs/#lo-que-encontraron-los-laboratorios-hasta-ahora)): Sunshine puede decir "Display device configuration API is temporarily unavailable" y no cambiar la resolución.

## Sincronizar el driver

El invitado tiene que usar **la misma versión de driver que el host**. Después de actualizar el driver de NVIDIA:

- En la app aparece un aviso en la VM; se actualiza solo la próxima vez que la enciendas desde la app, o en el momento con **Actualizar ahora** / **Apagar y actualizar**.
- Desde la CLI: `./gpuvm.ps1 sync-driver -Name <vm>` (VM apagada), o agrega `-ShutdownIfRunning`.
- `./gpuvm.ps1 list` muestra si el driver de cada VM está sincronizado.

## El primer inicio tarda

El primer inicio instala Windows y el streaming, y después reinicia una vez. **Encender y abrir** espera a Windows y a Sunshine, y lo indica en el botón. Si Sunshine nunca responde, el error remite a `C:\GpuVM\setup.log` dentro de la VM. Si la VM nunca obtiene una dirección IP, mira su pantalla con la consola de Hyper-V y confirma que exista el `Default Switch`.

## No hay audio

El audio (`virtual_sink` en Sunshine) se configura después del primer reinicio automático de la VM. Hasta entonces, al abrir la VM aparece un aviso. Si el perfil tiene `"audio": "none"`, no se instala ningún dispositivo de audio.

## Falla el emparejamiento

Usa **Volver a emparejar Moonlight** en el menú, o `./gpuvm.ps1 connect -Name <vm> -Pair`. Si Moonlight no está instalado, instálalo ([Instalación](/gpuvm/es/install/#instalar-moonlight)).

## La VM no enciende por falta de memoria

La memoria fija de Hyper-V tiene que estar libre al encender la VM. Cierra programas o baja la memoria de la VM en **Opciones** (o con `-Override @{ vm = @{ memoryGB = 6 } }`).

## Límites conocidos de GPU-P

- **Pantalla:** la consola de Hyper-V no muestra la GPU; se ve con el streaming. Falta validar el streaming en una VM real ([laboratorio 002](/gpuvm/es/labs/)).
- **Audio:** resuelto con VB-CABLE; falta comprobarlo en una VM real ([laboratorio 003](/gpuvm/es/labs/)).
- **Driver:** el invitado tiene que usar la misma versión que el host (ver arriba).
- **Selección de GPU en Windows 10:** no se puede elegir cuál GPU recibe la VM. Si la integrada también es particionable, puede tocarle la equivocada. `check` lo advierte; desactiva la integrada en el Administrador de dispositivos antes de encender la VM ([laboratorio 001](/gpuvm/es/labs/)).
- **Sin puntos de control ni estado guardado:** la VM se apaga directamente.
- **Anti-cheat:** algunos sistemas anti-cheat bloquean las máquinas virtuales.
