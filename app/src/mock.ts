import type { JobEvent, VmOverview } from "./types";

// Sample data for designing in the browser (there is no Hyper-V outside the app).
const params = new URLSearchParams(location.search);
const scenario = params.get("mock") ?? "default";

const vms: VmOverview[] = [
  {
    id: "efddad96", name: "win10", state: "Running", managed: true, profile: "max-performance",
    edition: "Windows 10 Pro", generation: 2, processorCount: 8, cpuPercent: 34, memoryStartupGB: 8,
    memoryAssignedGB: 8, memoryDemandGB: 5.1, uptimeSeconds: 4320, hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060",
    gpuPercent: 61, driverInSync: true, streaming: true, paired: true, guestCredential: false, address: "172.29.111.201",
    client: { app: "Desktop", resolution: "1920x1080", fps: 60, bitrateKbps: 0, codec: "auto" },
    options: { cpu: 8, memoryGB: 8, gpuPercent: 100 },
  },
  {
    id: "a1b2c3d4", name: "win11-pruebas", state: "Off", managed: true, profile: "balanced",
    edition: "Windows 11 Pro", generation: 2, processorCount: 8, cpuPercent: 0, memoryStartupGB: 8,
    memoryAssignedGB: 0, memoryDemandGB: 0, uptimeSeconds: 0, hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060",
    gpuPercent: 0, driverInSync: false, streaming: true, paired: false, guestCredential: true, address: null,
    client: { app: "Desktop", resolution: "2560x1440", fps: 120, bitrateKbps: 40000, codec: "HEVC" },
    options: { cpu: 8, memoryGB: 8, gpuPercent: 100 },
  },
  {
    id: "99ff0011", name: "ubuntu-server", state: "Off", managed: false, profile: null, edition: null, generation: 2,
    processorCount: 2, cpuPercent: 0, memoryStartupGB: 2, memoryAssignedGB: 0, memoryDemandGB: 0, uptimeSeconds: 0,
    hasGpu: false, gpuName: null, gpuPercent: 0, driverInSync: null, streaming: false, paired: false,
    guestCredential: false, address: null, client: null, options: null,
  },
];

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function ps(cmd: string, args: Record<string, unknown>): Promise<unknown[]> {
  await wait(250);
  if (scenario === "noadmin") throw new Error("Este comando necesita PowerShell 7 abierto como administrador.");
  switch (cmd) {
    case "Get-GpuVMOverview":
      if (scenario === "empty") return [];
      return vms.map((vm) => vm.state !== "Running" ? vm : {
        ...vm,
        cpuPercent: Math.round(20 + Math.random() * 40),
        gpuPercent: Math.round(40 + Math.random() * 45),
        memoryDemandGB: Math.round((4.5 + Math.random()) * 10) / 10,
        uptimeSeconds: vm.uptimeSeconds + Math.round(performance.now() / 1000),
      });
    case "Get-GpuVMHostInfo":
      return [{ logicalProcessors: 12, memoryGB: 15, gpuName: "NVIDIA GeForce RTX 4060" }];
    case "Get-GpuVMIsoList":
      return [{ path: "C:\\Users\\demo\\Downloads\\Win10_22H2_Spanish_Mexico_x64v1.iso", name: "Win10_22H2_Spanish_Mexico_x64v1.iso", sizeGB: 5.4, modified: "2026-10-26T22:32:08" }];
    case "Get-GpuVMProfile":
      return [
        { Name: "balanced", Extends: "base", Description: "Buen rendimiento dejando holgura al host: 8 hilos, 8 GB, disco dinámico." },
        { Name: "base", Extends: null, Description: "Valores comunes a todos los perfiles." },
        { Name: "max-performance", Extends: "balanced", Description: "CPU reservada al 100 %, 8 GB fijos, disco fijo y optimizaciones del invitado." },
      ];
    case "Invoke-GpuVMPower": {
      const vm = vms.find((v) => v.name === args.Name)!;
      const action = args.Action as string;
      vm.state = action === "Start" || action === "Resume" || action === "Restart" ? "Running" : action === "Pause" ? "Paused" : "Off";
      return [{ name: vm.name, state: vm.state }];
    }
    case "Set-GpuVMGuestCredential":
      vms.find((v) => v.name === args.Name)!.guestCredential = true;
      return [];
    default:
      return [];
  }
}

const listeners = new Set<(e: JobEvent) => void>();
export function onJob(handler: (e: JobEvent) => void) {
  listeners.add(handler);
  return () => listeners.delete(handler);
}

export async function job(jobId: string, cmd: string, args: Record<string, unknown>) {
  const emit = (e: Omit<JobEvent, "jobId">) => listeners.forEach((l) => l({ jobId, ...e }));
  const steps = cmd === "New-GpuVM"
    ? ["Edición: Windows 10 Pro (es-MX)", "Leyendo archivos del driver", "Creando disco Fixed de 96 GB", "Aplicando la imagen de Windows", "Copiando el driver de la GPU al invitado", "Registrando la VM en Hyper-V"]
    : ["Encendiendo", "Esperando a que Windows arranque", "Esperando a Sunshine", "Sunshine capturará la pantalla virtual", "Abriendo Desktop a 1920x1080 y 60 FPS"];
  for (const message of steps) {
    emit({ type: "progress", message });
    await wait(900);
  }
  if (cmd === "New-GpuVM") {
    vms.push({ ...vms[1], id: String(Date.now()), name: String(args.Name), state: "Running", paired: false });
  } else {
    const vm = vms.find((v) => v.name === args.Name);
    if (vm) vm.state = "Running";
  }
  emit({ type: "result", ok: true, data: [] });
}
