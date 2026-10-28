import type { DiskInfo, DisplayMode, IsoFile, JobEvent, ProfileInfo, ProfileSettings, VmOverview } from "./types";

// Sample data for designing in the browser (there is no Hyper-V outside the app).
const params = new URLSearchParams(location.search);
const scenario = params.get("mock") ?? "default";

const vms: VmOverview[] = [
  {
    id: "efddad96", name: "win10", state: "Running", managed: true, profile: "max-performance",
    edition: "Windows 10 Pro", generation: 2, processorCount: 8, cpuPercent: 34, memoryStartupGB: 8,
    memoryAssignedGB: 8, memoryDemandGB: 5.1, uptimeSeconds: 4320, hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060",
    gpuPercent: 61, driverInSync: true, streaming: true, paired: true, guestCredential: true, address: "172.29.111.201",
    client: { app: "Desktop", resolution: "1920x1080", fps: 60, bitrateKbps: 0, codec: "auto" },
    options: { cpu: 8, memoryGB: 8, gpuPercent: 100, diskGB: 200, diskType: "Fixed", diskFreeGB: 232, captureMode: "ddx", networkIsolation: true },
  },
  {
    id: "a1b2c3d4", name: "win11-pruebas", state: "Off", managed: true, profile: "balanced",
    edition: "Windows 11 Pro", generation: 2, processorCount: 8, cpuPercent: 0, memoryStartupGB: 8,
    memoryAssignedGB: 0, memoryDemandGB: 0, uptimeSeconds: 0, hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060",
    gpuPercent: 0, driverInSync: false, streaming: true, paired: false, guestCredential: true, address: null,
    client: { app: "Desktop", resolution: "2560x1440", fps: 120, bitrateKbps: 40000, codec: "HEVC" },
    options: { cpu: 8, memoryGB: 8, gpuPercent: 100, diskGB: 200, diskType: "Fixed", diskFreeGB: 232, captureMode: "ddx", networkIsolation: true },
  },
  {
    id: "99ff0011", name: "ubuntu-server", state: "Off", managed: false, profile: null, edition: null, generation: 2,
    processorCount: 2, cpuPercent: 0, memoryStartupGB: 2, memoryAssignedGB: 0, memoryDemandGB: 0, uptimeSeconds: 0,
    hasGpu: false, gpuName: null, gpuPercent: 0, driverInSync: null, streaming: false, paired: false,
    guestCredential: false, address: null, client: null, options: null,
  },
];

const builtIn = (cpu: number, diskGB: number, diskType: "Dynamic" | "Fixed"): ProfileSettings =>
  ({ cpu, memoryGB: 8, gpuPercent: 100, diskGB, diskType, iso: null, apps: [], resolution: "1920x1080", fps: 60, displayMode: "fullscreen" });

let profiles: ProfileInfo[] = [
  { Name: "balanced", Extends: "base", Description: "Buen rendimiento dejando holgura al host: 8 hilos, 8 GB, disco dinámico.", BuiltIn: true, Settings: builtIn(8, 128, "Dynamic") },
  { Name: "base", Extends: null, Description: "Valores comunes a todos los perfiles.", BuiltIn: true, Settings: builtIn(6, 128, "Dynamic") },
  { Name: "max-performance", Extends: "balanced", Description: "CPU reservada al 100 %, 8 GB fijos, disco fijo y optimizaciones del invitado.", BuiltIn: true, Settings: builtIn(8, 96, "Fixed") },
  { Name: "juegos", Extends: "max-performance", Description: "Para juegos con Steam.", BuiltIn: false,
    Settings: { ...builtIn(8, 250, "Fixed"), iso: "C:\\Users\\demo\\Downloads\\Win10_22H2_Spanish_Mexico_x64v1.iso", apps: ["steam", "discord"], resolution: "1920x1080", fps: 120 } },
];

let isos: IsoFile[] = [
  { path: "C:\\Users\\demo\\Downloads\\Win10_22H2_Spanish_Mexico_x64v1.iso", name: "Win10_22H2_Spanish_Mexico_x64v1.iso", sizeGB: 5.4, modified: "2026-10-26T22:32:08", remembered: true, missing: false, lastUsed: "2026-10-26T23:10:00", usedBy: ["win10"] },
  { path: "D:\\ISOs\\Win11_24H2_Spanish_x64.iso", name: "Win11_24H2_Spanish_x64.iso", sizeGB: 0, modified: "", remembered: true, missing: true, lastUsed: null, usedBy: [] },
  { path: "C:\\Users\\demo\\Desktop\\Win11_25H2_Spanish_x64.iso", name: "Win11_25H2_Spanish_x64.iso", sizeGB: 7.1, modified: "2026-10-20T10:00:00", remembered: false, missing: false, lastUsed: null, usedBy: [] },
];

let disks: DiskInfo[] = [
  { name: "win10", path: "C:\\GpuVM\\win10\\Virtual Hard Disks\\win10.vhdx", sizeGB: 200, fileGB: 200, type: "Fixed", vm: "win10", restorable: false, profile: "max-performance", edition: "Windows 10 Pro", createdAt: "2026-10-26T22:40:00", hostFreeGB: 232 },
  { name: "win11-pruebas", path: "C:\\GpuVM\\win11-pruebas\\Virtual Hard Disks\\win11-pruebas.vhdx", sizeGB: 128, fileGB: 31.4, type: "Dynamic", vm: "win11-pruebas", restorable: false, profile: "balanced", edition: "Windows 11 Pro", createdAt: "2026-10-27T09:00:00", hostFreeGB: 232 },
  { name: "win10-viejo", path: "C:\\GpuVM\\win10-viejo\\Virtual Hard Disks\\win10-viejo.vhdx", sizeGB: 128, fileGB: 42.7, type: "Dynamic", vm: null, restorable: true, profile: "balanced", edition: "Windows 10 Pro", createdAt: "2026-10-20T18:00:00", hostFreeGB: 232 },
];

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function ps(cmd: string, args: Record<string, unknown>): Promise<unknown[]> {
  await wait(250);
  if (scenario === "noadmin") throw new Error("Este comando necesita PowerShell 7 abierto como administrador.");
  // ?mock=loading keeps every screen in its loading state, to design the skeletons.
  if (scenario === "loading") return new Promise(() => {});
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
      return isos;
    case "Add-GpuVMIso": {
      const path = String(args.Path);
      isos = [{ path, name: path.split("\\").pop()!, sizeGB: 5.8, modified: "", remembered: true, missing: false, lastUsed: null, usedBy: [] }, ...isos.filter((i) => i.path !== path)];
      return [];
    }
    case "Remove-GpuVMIso":
      isos = isos.map((i) => i.path === args.Path ? { ...i, remembered: false, usedBy: [] } : i);
      return [];
    case "Get-GpuVMProfile":
      return profiles;
    case "Save-GpuVMProfile": {
      const name = String(args.Name);
      const base = profiles.find((p) => p.Name === args.Extends)?.Settings ?? profiles[2].Settings!;
      const entry: ProfileInfo = { Name: name, Extends: String(args.Extends), Description: String(args.Description ?? ""), BuiltIn: false,
        Settings: { ...base, ...(args.Settings as Partial<ProfileSettings>) } };
      profiles = [...profiles.filter((p) => p.Name !== name && p.Name !== args.Previous), entry];
      return [entry];
    }
    case "Remove-GpuVMProfile":
      profiles = profiles.filter((p) => p.Name !== args.Name);
      return [];
    case "Get-GpuVMApp":
      return [
        { id: "steam", name: "Steam", signer: "Valve" }, { id: "epic", name: "Epic Games", signer: "Epic Games" },
        { id: "discord", name: "Discord", signer: "Discord" }, { id: "chrome", name: "Chrome", signer: "Google" },
        { id: "protonvpn", name: "Proton VPN", signer: "Proton AG" }, { id: "brave", name: "Brave", signer: "Brave Software, Inc." }, { id: "firefox", name: "Firefox", signer: "Mozilla" },
      ];
    case "Get-GpuVMDisk":
      return disks;
    case "Remove-GpuVMDisk":
      disks = disks.filter((d) => d.name !== args.Name);
      return [];
    case "Set-GpuVMStreamingClient": {
      const vm = vms.find((v) => v.name === args.Name)!;
      vm.client = { ...vm.client!, resolution: String(args.Resolution), fps: Number(args.Fps), displayMode: args.DisplayMode as DisplayMode };
      return [];
    }
    case "Invoke-GpuVMPower": {
      const vm = vms.find((v) => v.name === args.Name)!;
      const action = args.Action as string;
      vm.state = action === "Start" || action === "Resume" || action === "Restart" ? "Running" : action === "Pause" ? "Paused" : "Off";
      return [{ name: vm.name, state: vm.state }];
    }
    case "Set-GpuVMNetworkIsolation":
      vms.find((v) => v.name === args.Name)!.options!.networkIsolation = args.Enabled as boolean;
      return [];
    case "Set-GpuVMCapture":
      vms.find((v) => v.name === args.Name)!.options!.captureMode = args.Mode as "ddx" | "wgc";
      return [];
    case "Send-GpuVMClipboard":
      await wait(600);
      return [];
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
