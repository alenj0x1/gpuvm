---
title: Requirements
description: What your PC needs to run GpuVM.
---

GpuVM checks this for you before creating a VM: `./gpuvm.ps1 check -Profile <profile>` lists each item as Ok, Warn or Fail, and `New-GpuVM` runs the same checks first.

## Host

- **Windows 10 or 11, 64-bit, any edition**: Home, Pro, Enterprise, Education or Pro for Workstations.
- **Hardware virtualization** turned on in the BIOS/UEFI (Intel VT-x or AMD-V).
- **Hyper-V or Virtual Machine Platform.** Where Windows has Hyper-V turned on (Pro, Enterprise, Education), GpuVM runs its machines on Hyper-V. On any other edition, Home included, it runs them through Windows' Host Compute Service, which only needs the optional feature **Virtual Machine Platform** (the same one WSL 2 uses); if it is off, the app turns it on for you and asks for a restart. See [Install](/docs/install/#hyper-v-or-virtual-machine-platform).
- **A GPU with a WDDM 2.5 or later driver** that can be shared with VMs (GPU partitioning), with its current driver. The bundled profiles pick the GPU whose name matches `NVIDIA` (`gpu.match` in the [profile](/docs/profiles/)), and Sunshine encodes with NVENC.
- **An administrator account.** Windows only lets administrators create and control virtual machines. The app opens without elevation: the **GpuVM** service runs the machines with your account's administrator rights, and deleting a machine or a disk asks for a UAC confirmation.
- **PowerShell 7** only for the CLI ([aka.ms/powershell](https://aka.ms/powershell)), as administrator to create and modify VMs. The app carries its own.

## Resources for the VM

- **Free memory:** a VM's memory is fixed, so it has to be *free* when the VM starts, not just installed. Both bundled profiles use 8 GB.
- **Disk space** on the drive of the VM folder (`C:\GpuVM` by default): about 40 GB for a dynamic disk, plus about 13 GB once per ISO and edition for the prepared Windows; a fixed disk (custom profiles) needs its full size plus 10 GB. A dynamic disk grows up to its size as the machine writes, so GpuVM counts that room as promised: a new or bigger disk only gets what is left once every machine's disk on the drive is full, keeping 20 GB for Windows.
- **Network:** on Hyper-V, the `Default Switch`; if it doesn't exist the VM is created without network, and streaming needs network. Machines without Hyper-V use networks GpuVM creates itself (see [Network isolation](/docs/architecture/#network-isolation)).

## Windows image

An official Windows 10 or 11 ISO:

- [Windows 11](https://www.microsoft.com/software-download/windows11)
- [Windows 10](https://www.microsoft.com/software-download/windows10)

The create wizard lists the ISOs in your Downloads and Desktop folders and lets you browse for another one.
