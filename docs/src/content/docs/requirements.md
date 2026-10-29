---
title: Requirements
description: What your PC needs to run GpuVM.
---

GpuVM checks this for you before creating a VM: `./gpuvm.ps1 check -Profile <profile>` lists each item as Ok, Warn or Fail, and `New-GpuVM` runs the same checks first.

## Host

- **Windows 10 or 11** Pro, Enterprise, Education or Pro for Workstations.
- **Hardware virtualization** turned on in the BIOS/UEFI (Intel VT-x or AMD-V).
- **Hyper-V** enabled. See [Install](/gpuvm/docs/install/#enable-hyper-v).
- **A GPU that supports GPU partitioning** with its current driver. The bundled profiles pick the GPU whose name matches `NVIDIA` (`gpu.match` in the [profile](/gpuvm/docs/profiles/)), and Sunshine encodes with NVENC.
- **PowerShell 7** ([aka.ms/powershell](https://aka.ms/powershell)). The app looks for it in `Program Files\PowerShell\7` (MSI install) or in the Microsoft Store package folder.
- **Administrator rights.** Hyper-V only lets administrators create and control VMs. The installed app asks for elevation when it opens; the CLI needs PowerShell 7 as administrator to create and modify VMs.
- **Moonlight** on the host to see the VM. See [Install](/gpuvm/docs/install/#install-moonlight).

## Resources for the VM

- **Free memory:** Hyper-V memory is fixed, so it has to be *free* when the VM starts, not just installed. Both bundled profiles use 8 GB.
- **Disk space** on the drive of the VM folder (`C:\GpuVM` by default): about 40 GB for a dynamic disk (`balanced`), or the disk size plus 10 GB for a fixed disk (`max-performance`: 96 + 10 GB).
- **Network:** the Hyper-V `Default Switch`. If it doesn't exist the VM is created without network, and streaming needs network.

## Windows image

An official Windows 10 or 11 ISO:

- [Windows 11](https://www.microsoft.com/software-download/windows11)
- [Windows 10](https://www.microsoft.com/software-download/windows10)

The create wizard lists the ISOs in your Downloads and Desktop folders and lets you browse for another one.
