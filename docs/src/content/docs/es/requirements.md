---
title: Requisitos
description: Lo que necesita tu PC para usar GpuVM.
---

GpuVM revisa esto por ti antes de crear una VM: `./gpuvm.ps1 check -Profile <perfil>` muestra cada punto como Ok, Warn o Fail, y `New-GpuVM` hace las mismas revisiones antes de empezar.

## Host

- **Windows 10 u 11 de 64 bits, cualquier edición**: Home, Pro, Enterprise, Education o Pro for Workstations.
- **Virtualización por hardware** activada en el BIOS/UEFI (Intel VT-x o AMD-V).
- **Hyper-V o la Plataforma de máquina virtual.** Donde Windows tiene Hyper-V activo (Pro, Enterprise, Education), GpuVM ejecuta sus máquinas en Hyper-V. En cualquier otra edición, Home incluida, las ejecuta con el Host Compute Service de Windows, que solo necesita la característica opcional **Plataforma de máquina virtual** (la misma que usa WSL 2); si está desactivada, la app la activa por ti y pide reiniciar. Consulta [Instalación](/docs/es/install/#hyper-v-o-plataforma-de-máquina-virtual).
- **Una GPU con driver WDDM 2.5 o posterior** que se pueda compartir con VMs (GPU partitioning), con su driver actual. Los perfiles incluidos eligen la GPU cuyo nombre contiene `NVIDIA` (`gpu.match` en el [perfil](/docs/es/profiles/)), y Sunshine codifica con NVENC.
- **Una cuenta de administrador.** Windows solo deja crear y controlar máquinas virtuales a un administrador. La app se abre sin permisos: el servicio **GpuVM** maneja las máquinas con los permisos de administrador de tu cuenta, y borrar una máquina o un disco pide confirmarlo en un aviso de UAC.
- **PowerShell 7** solo para la CLI ([aka.ms/powershell](https://aka.ms/powershell)), como administrador para crear y modificar VMs. La app trae el suyo.

## Recursos para la VM

- **Memoria libre:** la memoria de una VM es fija, así que tiene que estar *libre* al encender la VM, no solo instalada. Los dos perfiles incluidos usan 8 GB.
- **Espacio en disco** en la unidad de la carpeta de las VMs (`C:\GpuVM` por defecto): unos 40 GB con disco dinámico, más unos 13 GB una vez por ISO y edición para el Windows preparado; un disco fijo (perfiles personalizados) necesita su tamaño completo más 10 GB. Un disco dinámico crece hasta su tamaño a medida que la máquina escribe, así que GpuVM cuenta ese espacio como prometido: un disco nuevo o más grande solo recibe lo que queda con todos los discos de las máquinas de la unidad llenos, dejando 20 GB para Windows.
- **Red:** en Hyper-V, el `Default Switch`; si no existe, la VM se crea sin red, y el streaming necesita red. Las máquinas sin Hyper-V usan redes que crea el propio GpuVM (consulta [Aislamiento de red](/docs/es/architecture/#aislamiento-de-red)).

## Imagen de Windows

Un ISO oficial de Windows 10 u 11:

- [Windows 11](https://www.microsoft.com/software-download/windows11)
- [Windows 10](https://www.microsoft.com/software-download/windows10)

El asistente para crear máquinas muestra los ISOs de tus carpetas Descargas y Escritorio, y te deja buscar otro.
