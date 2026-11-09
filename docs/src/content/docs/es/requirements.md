---
title: Requisitos
description: Lo que necesita tu PC para usar GpuVM.
---

GpuVM revisa esto por ti antes de crear una VM: `./gpuvm.ps1 check -Profile <perfil>` muestra cada punto como Ok, Warn o Fail, y `New-GpuVM` hace las mismas revisiones antes de empezar.

## Host

- **Windows 10 u 11** Pro, Enterprise, Education o Pro for Workstations.
- **Virtualización por hardware** activada en el BIOS/UEFI (Intel VT-x o AMD-V).
- **Hyper-V** activo. Consulta [Instalación](/gpuvm/docs/es/install/#activar-hyper-v).
- **Una GPU que admita GPU partitioning** con su driver actual. Los perfiles incluidos eligen la GPU cuyo nombre contiene `NVIDIA` (`gpu.match` en el [perfil](/gpuvm/docs/es/profiles/)), y Sunshine codifica con NVENC.
- **Una cuenta de administrador.** Hyper-V solo deja crear y controlar máquinas a un administrador. La app se abre sin permisos: el servicio **GpuVM** hace el trabajo de Hyper-V con los permisos de administrador de tu cuenta, y borrar una máquina o un disco pide confirmarlo en un aviso de UAC.
- **PowerShell 7** solo para la CLI ([aka.ms/powershell](https://aka.ms/powershell)), como administrador para crear y modificar VMs. La app trae el suyo.
- **Moonlight** en el host para ver la VM. Consulta [Instalación](/gpuvm/docs/es/install/#instalar-moonlight).

## Recursos para la VM

- **Memoria libre:** la memoria de Hyper-V es fija, así que tiene que estar *libre* al encender la VM, no solo instalada. Los dos perfiles incluidos usan 8 GB.
- **Espacio en disco** en la unidad de la carpeta de las VMs (`C:\GpuVM` por defecto): unos 40 GB con disco dinámico, más unos 13 GB una vez por ISO y edición para el Windows preparado; un disco fijo (perfiles personalizados) necesita su tamaño completo más 10 GB.
- **Red:** el `Default Switch` de Hyper-V. Si no existe, la VM se crea sin red, y el streaming necesita red.

## Imagen de Windows

Un ISO oficial de Windows 10 u 11:

- [Windows 11](https://www.microsoft.com/software-download/windows11)
- [Windows 10](https://www.microsoft.com/software-download/windows10)

El asistente para crear máquinas muestra los ISOs de tus carpetas Descargas y Escritorio, y te deja buscar otro.
