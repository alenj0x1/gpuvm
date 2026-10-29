import type { DiskInfo, SharedDiskInfo, TemplateInfo, DisplayMode, IsoFile, JobEvent, ProfileInfo, ProfileSettings, VmOverview } from "./types";
import catalog from "../../apps/catalog.json";

// Sample data for designing in the browser (there is no Hyper-V outside the app).
const params = new URLSearchParams(location.search);
const scenario = params.get("mock") ?? "default";

const vms: VmOverview[] = [
  {
    id: "efddad96", name: "win10", state: "Running", managed: true, profile: "max-performance",
    edition: "Windows 10 Pro", generation: 2, processorCount: 8, cpuPercent: 34, memoryStartupGB: 8,
    memoryAssignedGB: 8, memoryDemandGB: 5.1, uptimeSeconds: 4320, hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060",
    gpuPercent: 61, driverInSync: true, fits: true, fitGB: 6, missingGB: 0, streaming: true, paired: true, guestCredential: true, address: "172.29.111.201",
    client: { app: "Desktop", resolution: "1920x1080", fps: 60, bitrateKbps: 0, codec: "auto" },
    options: { cpu: 8, memoryGB: 8, gpuPercent: 100, diskGB: 200, diskType: "Fixed", diskFreeGB: 232, captureMode: "ddx", networkIsolation: true, cleanup: "none" },
  },
  {
    id: "a1b2c3d4", name: "win11-pruebas", state: "Off", managed: true, profile: "balanced",
    edition: "Windows 11 Pro", generation: 2, processorCount: 8, cpuPercent: 0, memoryStartupGB: 8,
    memoryAssignedGB: 0, memoryDemandGB: 0, uptimeSeconds: 0, hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060",
    gpuPercent: 0, driverInSync: false, fits: false, fitGB: 6, missingGB: 1.9, streaming: true, paired: false, guestCredential: true, address: null,
    client: { app: "Desktop", resolution: "2560x1440", fps: 120, bitrateKbps: 40000, codec: "HEVC" },
    options: { cpu: 8, memoryGB: 8, gpuPercent: 100, diskGB: 200, diskType: "Fixed", diskFreeGB: 232, captureMode: "ddx", networkIsolation: true, cleanup: "none" },
  },
  {
    // GpuVM's demo machines are all Windows: it only creates Windows 10 and 11 VMs.
    id: "99ff0011", name: "estudio", state: "Off", managed: true, profile: "balanced", edition: "Windows 11 Pro", generation: 2,
    processorCount: 6, cpuPercent: 0, memoryStartupGB: 6, memoryAssignedGB: 0, memoryDemandGB: 0, uptimeSeconds: 0,
    hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060", gpuPercent: 0, driverInSync: true, fits: true, fitGB: 6, missingGB: 0, streaming: true, paired: true,
    guestCredential: true, address: null, client: { app: "Desktop", resolution: "1920x1080", fps: 60, bitrateKbps: 0, codec: "auto" },
    options: { cpu: 6, memoryGB: 6, gpuPercent: 60, diskGB: 128, diskType: "Dynamic", diskFreeGB: 232, captureMode: "ddx", networkIsolation: true, cleanup: "privacy" },
  },
];

const builtIn = (cpu: number, diskGB: number, diskType: "Dynamic" | "Fixed"): ProfileSettings =>
  ({ cpu, memoryGB: 8, gpuPercent: 100, diskGB, diskType, iso: null, apps: [], cleanup: "none", resolution: "1920x1080", fps: 60, displayMode: "fullscreen" });

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
      // The real catalog, so the mock shows every app and category the app ships with.
      return Object.entries(catalog.apps).map(([id, a]: [string, { name: string; signer?: string; category: string }]) => (
        { id, name: a.name, signer: a.signer ?? null, category: a.category, categoryName: (catalog.categories as Record<string, string>)[a.category] }));
    case "Get-GpuVMHome":
      return [{
        lastOpened: { name: "win10", at: new Date(Date.now() - 2 * 3600e3).toISOString() },
        host: { memoryTotalGB: 15.8, memoryFreeGB: 6.4, diskFreeGB: 212, topProcesses: [{ name: "Translay", gb: 2.7 }, { name: "brave", gb: 1.1 }, { name: "Code", gb: 0.8 }] },
        machines: vms.map((v) => ({ name: v.name, state: v.state, memoryGB: v.options?.memoryGB ?? 2, needGB: (v.options?.memoryGB ?? 2) + 0.3, fits: v.state !== "Off" || (v.options?.memoryGB ?? 2) + 0.3 <= 6.4, fitGB: 6 })),
        attention,
      }];
    case "Get-GpuVMTemplate":
      return templates;
    case "Remove-GpuVMTemplate":
      templates = templates.filter((t) => t.name !== args.Name);
      return [];
    case "Get-GpuVMSharedDisk":
      return shared;
    case "New-GpuVMSharedDisk": {
      const disk = { name: String(args.Name), purpose: args.Purpose as "games" | "general", sizeGB: Number(args.SizeGB), fileGB: 0.1, vm: null, vmRunning: false, createdAt: new Date().toISOString() };
      shared = [...shared, disk];
      return [disk];
    }
    case "Remove-GpuVMSharedDisk":
      shared = shared.filter((d) => d.name !== args.Name);
      return [];
    case "Get-GpuVMCleanup":
      return CLEANUP_LEVELS;
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

let attention = [
  { vm: "win11-pruebas", kind: "driver", text: "Su driver de la GPU no es el del equipo (32.0.15.8180)", label: "Actualizar driver", cmd: "Sync-GpuVMDriver", args: { Name: "win11-pruebas" } },
  { vm: "win11-pruebas", kind: "apps", text: "Faltan por instalar: Steam, Discord", label: "Encender e instalar", cmd: "Install-GpuVMApp", args: { Name: "win11-pruebas", App: ["steam", "discord"] } },
];
const APP_NAMES: Record<string, string> = Object.fromEntries(Object.entries(catalog.apps).map(([id, a]) => [id, (a as { name: string }).name]));

let templates: TemplateInfo[] = [
  { name: "juegos-base", fromVM: "win10", createdAt: "2026-10-28T20:00:00Z", edition: "Windows 10 Pro", sizeGB: 200, fileGB: 61.4, cleanup: "privacy", usedBy: ["win11-pruebas"] },
];
let shared: SharedDiskInfo[] = [
  { name: "juegos", purpose: "games", sizeGB: 500, fileGB: 132.6, vm: "win10", vmRunning: true, createdAt: "2026-10-28T20:00:00Z" },
];

// Same levels and texts as guest/cleanup.ps1 (Get-GpuVMCleanup), shortened to what the UI needs.
const CLEANUP_LEVELS = [
  { id: "none", name: "Normal", items: [] },
  { id: "privacy", name: "Privacidad", items: [
    { id: "telemetry-minimum", description: "Datos de diagnóstico al mínimo que permite la edición (en Pro, «Requerido»; en Enterprise y Education, apagados)." },
    { id: "advertising", description: "Sin identificador de publicidad ni experiencias personalizadas con tus datos de diagnóstico." },
    { id: "activity-history", description: "Sin historial de actividad ni envío de actividad a Microsoft." },
    { id: "suggestions", description: "Sin sugerencias, consejos, Spotlight ni apps promocionadas que se instalan solas." },
    { id: "web-search", description: "La búsqueda de Inicio busca solo en el equipo, sin Bing." },
    { id: "copilot-recall", description: "Sin Copilot ni Recall (las capturas de pantalla que guarda Windows 11)." },
  ] },
  { id: "apps", name: "Sin apps de más", items: [
    { id: "store-apps", description: "Quita apps preinstaladas que no hacen falta (noticias, clima, Solitario, Clipchamp, Teams personal, Outlook nuevo...), también para usuarios nuevos. Se pueden volver a instalar desde Microsoft Store." },
    { id: "onedrive", description: "Quita OneDrive y evita que se vuelva a instalar." },
    { id: "widgets", description: "Sin widgets ni «Noticias e intereses» en la barra de tareas." },
  ] },
  { id: "minimal", name: "Mínimo", items: [
    { id: "telemetry-services", description: "Apaga los servicios que envían telemetría y el informe de errores a Microsoft." },
    { id: "unneeded-services", description: "Apaga servicios que una VM no usa: mapas, ubicación, fax, modo demo y uso compartido de Windows Media." },
    { id: "background-apps", description: "Las apps de Microsoft Store no corren en segundo plano." },
  ] },
];

export async function job(jobId: string, cmd: string, args: Record<string, unknown>) {
  const emit = (e: Omit<JobEvent, "jobId">) => listeners.forEach((l) => l({ jobId, ...e }));
  const steps = cmd === "New-GpuVMTemplate" ? ["Apagando", "Copiando el disco de win10 (puede tardar unos minutos)", "Encendiendo", "Plantilla lista (61.4 GB)"]
    : cmd === "Import-GpuVMSharedDisk" ? ["Midiendo la carpeta", "Copiando a SteamLibrary\\steamapps", "Copiando 18 %", "Copiando 47 %", "Copiando 83 %", "Copiado: 92,4 GB en SteamLibrary\\steamapps"]
    : cmd === "Connect-GpuVMSharedDisk" ? ["Conectando el disco", "Disco en G: dentro de la VM", "Biblioteca de Steam en G:\\SteamLibrary"]
    : cmd === "Disconnect-GpuVMSharedDisk" ? ["Cerrando el disco dentro de la VM", "Quitando el disco"]
    : cmd === "Set-GpuVMCleanup" ? ["Esperando a que Windows arranque", "Limpiando Windows", "Limpieza aplicada"]
    : cmd === "Sync-GpuVMDriver" ? ["Leyendo archivos del driver 32.0.15.8180", "Driver copiado: 4 carpetas del DriverStore y 31 archivos"]
    : cmd === "Install-GpuVMApp" ? ["Esperando a que Windows arranque", ...((args.App as string[]) ?? []).flatMap((id) => [`Instalando ${APP_NAMES[id] ?? id}`, `${APP_NAMES[id] ?? id} instalado`])]
    : cmd === "Connect-GpuVM" && args.MemoryGB ? [`Memoria: ${args.MemoryGB} GB`, "Encendiendo", "Esperando a que Windows arranque", "Esperando a Sunshine", "Abriendo a 1920x1080 y 60 FPS"]
    : cmd === "New-GpuVM" && args.Template ? [`Copia diferencial de ${args.Template}`, "Identidad propia: nombre de equipo y Sunshine", "Encendiendo", "Esperando a que Windows arranque"]
    : cmd === "New-GpuVM"
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
    if (cmd === "New-GpuVMTemplate") templates = [...templates, { name: String(args.Name), fromVM: String(args.VMName), createdAt: new Date().toISOString(), edition: "Windows 10 Pro", sizeGB: 200, fileGB: 61.4, cleanup: "none", usedBy: [] }];
    if (cmd === "Connect-GpuVMSharedDisk") shared = shared.map((d) => d.name === args.Name ? { ...d, vm: String(args.VMName), vmRunning: true } : d);
    if (cmd === "Disconnect-GpuVMSharedDisk") shared = shared.map((d) => d.name === args.Name ? { ...d, vm: null, vmRunning: false } : d);
    if (vm?.options && cmd === "Set-GpuVMCleanup") vm.options.cleanup = args.Level as typeof vm.options.cleanup;
    if (vm?.options && args.MemoryGB) { vm.options.memoryGB = Number(args.MemoryGB); vm.memoryStartupGB = Number(args.MemoryGB); vm.fits = true; vm.missingGB = 0; }
    if (vm && cmd === "Sync-GpuVMDriver") vm.driverInSync = true;
    // What was fixed leaves the home screen's list.
    attention = attention.filter((a) => !(a.vm === args.Name && a.cmd === cmd));
  }
  emit({ type: "result", ok: true, data: [] });
}
