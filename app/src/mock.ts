import type { BaseInfo, DiskInfo, SharedDiskInfo, TemplateInfo, DisplayMode, IsoFile, JobEvent, MouseMode, ProfileInfo, ProfileSettings, RestorePointList, VmOverview } from "./types";
import catalog from "../../apps/catalog.json";
import { agentCommand, agentMachines } from "./mockAgents";
export { agentHistory, agentRecordings } from "./mockAgents";

// Sample data for designing in the browser (there is no Hyper-V outside the app).
const params = new URLSearchParams(location.search);
// ?vms=0 is the same as ?mock=empty: no machines and an empty Library.
const scenario = params.get("vms") === "0" ? "empty" : params.get("mock") ?? "default";

const vms: VmOverview[] = [
  {
    id: "efddad96", name: "win10", state: "Running", managed: true, profile: "max-performance",
    edition: "Windows 10 Pro", generation: 2, processorCount: 8, cpuPercent: 34, memoryStartupGB: 8,
    memoryAssignedGB: 8, memoryDemandGB: 5.1, uptimeSeconds: 4320, hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060",
    gpuPercent: 61, driverInSync: true, fits: true, fitGB: 6, missingGB: 0, streaming: true, paired: true, guestCredential: true, address: "172.29.111.201",
    client: { app: "Desktop", resolution: "1920x1080", fps: 0, bitrateKbps: 0, codec: "auto", vsync: true, framePacing: false, mouse: "capture" },
    options: { cpu: 8, memoryGB: 8, gpuPercent: 100, diskGB: 200, diskType: "Fixed", diskFreeGB: 232, networkIsolation: true, cleanup: "none", diskBudget: { drive: "C:", freeGB: 232, promisedGB: 86, marginGB: 20, availableGB: 126, sizeGB: 200, usedGB: 61, maxGB: 326, others: [{ vm: "estudio", promisedGB: 86 }] } },
  },
  {
    id: "a1b2c3d4", name: "win11-pruebas", state: "Off", managed: true, profile: "balanced",
    edition: "Windows 11 Pro", generation: 2, processorCount: 8, cpuPercent: 0, memoryStartupGB: 8,
    memoryAssignedGB: 0, memoryDemandGB: 0, uptimeSeconds: 0, hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060",
    gpuPercent: 0, driverInSync: false, fits: false, fitGB: 6, missingGB: 1.9, streaming: true, paired: false, guestCredential: true, restorePoints: 2, address: null,
    client: { app: "Desktop", resolution: "2560x1440", fps: 120, bitrateKbps: 40000, codec: "HEVC" },
    options: { cpu: 8, memoryGB: 8, gpuPercent: 100, diskGB: 200, diskType: "Fixed", diskFreeGB: 232, networkIsolation: true, cleanup: "none", diskBudget: { drive: "C:", freeGB: 232, promisedGB: 86, marginGB: 20, availableGB: 126, sizeGB: 200, usedGB: 61, maxGB: 326, others: [{ vm: "estudio", promisedGB: 86 }] } },
  },
  {
    // GpuVM's demo machines are all Windows: it only creates Windows 10 and 11 VMs.
    id: "99ff0011", name: "estudio", state: "Off", managed: true, profile: "balanced", edition: "Windows 11 Pro", generation: 2,
    processorCount: 6, cpuPercent: 0, memoryStartupGB: 6, memoryAssignedGB: 0, memoryDemandGB: 0, uptimeSeconds: 0,
    hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060", gpuPercent: 0, driverInSync: true, fits: true, fitGB: 6, missingGB: 0, streaming: true, paired: true,
    guestCredential: true, address: null, client: { app: "Desktop", resolution: "1920x1080", fps: 60, bitrateKbps: 0, codec: "auto" },
    options: { cpu: 6, memoryGB: 6, gpuPercent: 60, diskGB: 128, diskType: "Dynamic", diskFreeGB: 232, networkIsolation: true, cleanup: "privacy", diskBudget: { drive: "C:", freeGB: 232, promisedGB: 0, marginGB: 20, availableGB: 126, sizeGB: 128, usedGB: 42, maxGB: 254, others: [] } },
  },
  {
    id: "d15b0sa1", name: "juegos-desechable", state: "Running", managed: true, profile: "balanced", edition: "Windows 10 Pro", generation: 2,
    processorCount: 8, cpuPercent: 12, memoryStartupGB: 6, memoryAssignedGB: 6, memoryDemandGB: 3.2, uptimeSeconds: 640,
    hasGpu: true, gpuName: "NVIDIA GeForce RTX 4060", gpuPercent: 18, driverInSync: true, fits: true, fitGB: 6, missingGB: 0, streaming: true, paired: true,
    guestCredential: true, disposable: true, address: "172.29.111.214", client: { app: "Desktop", resolution: "1920x1080", fps: 60, bitrateKbps: 0, codec: "auto" },
    options: { cpu: 8, memoryGB: 6, gpuPercent: 100, diskGB: 128, diskType: "Differencing", diskFreeGB: 232, networkIsolation: true, cleanup: "none", diskBudget: null },
  },
];

// The machines agents work on (mockAgents.ts): made for agents, 1280x800, isolated, disposable, with the agent installed.
for (const name of agentMachines) {
  vms.push({ ...vms[3], id: `agent-${name}`, name, edition: "Windows 11 Pro", disposable: name === "win-agent", forAgents: true, use: "agent", agentUser: "agent", uptimeSeconds: 380,
    agent: { installed: true, connected: true, version: "0.1.0", user: "agent" },
    client: { app: "Desktop", resolution: "1280x800", fps: 60, bitrateKbps: 0, codec: "auto", vsync: true, framePacing: false, mouse: "absolute" } });
}

const restorePoints: Record<string, RestorePointList> = {
  "win11-pruebas": {
    max: 10, changesGB: 1.4, restoredFrom: null,
    points: [
      { id: "20261112-091000-a1b2", label: "Freshly installed", createdAt: "2026-11-12T09:10:00-05:00", sizeGB: 38.2, missing: false, current: false },
      { id: "20261117-213000-c3d4", label: "Before the game", createdAt: "2026-11-17T21:30:00-05:00", sizeGB: 2.1, missing: false, current: true },
    ],
  },
};

// Many machines, to see how every screen holds up: open http://localhost:1420/?vms=30 for thirty in all.
for (let i = vms.length; i < Number(params.get("vms") ?? 0); i++) {
  const from = vms[i % 3];
  // About a third on, a few starting or paused, the rest off.
  const on = i % 3 === 0;
  vms.push({ ...from, id: `extra${i}`, name: `lab-${String(i - 2).padStart(2, "0")}`, state: on ? "Running" : i % 13 === 0 ? "Starting" : i % 17 === 0 ? "Paused" : "Off", cpuPercent: on ? 20 + (i * 7) % 60 : 0,
    gpuPercent: on ? 10 + (i * 11) % 70 : 0, memoryAssignedGB: on ? 6 : 0, memoryDemandGB: on ? 3.5 : 0, uptimeSeconds: on ? 600 : 0, driverInSync: true, fits: true, missingGB: 0 });
}

// The card over Moonlight (PromptCard): open http://localhost:1420/?prompt to see it with a sample prompt.
// The website's demo of the card turns it on with showSamplePrompt().
let samplePrompt = params.has("prompt") || params.has("prompt-dock");
export const showSamplePrompt = () => { samplePrompt = true; };
export const adminPrompts = async () =>
  samplePrompt ? [{ name: "win10", id: 4242, app: "Windows Command Processor", publisher: params.get("prompt") === "unknown" ? "Desconocido" : "Microsoft Windows" }] : [];

const builtIn = (cpu: number, diskGB: number, diskType: "Dynamic" | "Fixed"): ProfileSettings =>
  ({ cpu, memoryGB: 8, gpuPercent: 100, diskGB, diskType, iso: null, apps: [], cleanup: "none", resolution: "1920x1080", fps: 0, displayMode: "fullscreen", vsync: true, framePacing: false, mouse: "capture" });

let profiles: ProfileInfo[] = [
  { Name: "balanced", Extends: "base", Description: "Good performance while leaving headroom for the host: 8 threads, 8 GB, dynamic disk.", BuiltIn: true, Settings: builtIn(8, 128, "Dynamic") },
  { Name: "base", Extends: null, Description: "Values shared by all profiles. Not used directly.", BuiltIn: true, Settings: builtIn(6, 128, "Dynamic") },
  { Name: "max-performance", Extends: "balanced", Description: "Maximum performance: 100 % CPU reservation, host SMT topology, 8 GB fixed and guest optimizations.", BuiltIn: true, Settings: builtIn(8, 96, "Fixed") },
  { Name: "juegos", Extends: "max-performance", Description: "For games with Steam.", BuiltIn: false,
    Settings: { ...builtIn(8, 250, "Fixed"), iso: "C:\\Users\\demo\\Downloads\\Win10_22H2_Spanish_Mexico_x64v1.iso", apps: ["steam", "discord"], resolution: "1920x1080", fps: 120 } },
];

let isos: IsoFile[] = [
  { path: "C:\\Users\\demo\\Downloads\\Win10_22H2_Spanish_Mexico_x64v1.iso", name: "Win10_22H2_Spanish_Mexico_x64v1.iso", sizeGB: 5.4, modified: "2026-10-26T22:32:08", remembered: true, missing: false, lastUsed: "2026-10-26T23:10:00", usedBy: ["win10"] },
  { path: "D:\\ISOs\\Win11_24H2_Spanish_x64.iso", name: "Win11_24H2_Spanish_x64.iso", sizeGB: 0, modified: "", remembered: true, missing: true, lastUsed: null, usedBy: [] },
  { path: "C:\\Users\\demo\\Desktop\\Win11_25H2_Spanish_x64.iso", name: "Win11_25H2_Spanish_x64.iso", sizeGB: 7.1, modified: "2026-10-20T10:00:00", remembered: false, missing: false, lastUsed: null, usedBy: [] },
];

let bases: BaseInfo[] = [
  { key: "3f9c2a71b8e04d15", edition: "Windows 11 Pro", language: "es-MX", createdAt: "2026-11-08T18:00:00", fileGB: 11.8 },
];
let disks: DiskInfo[] = [
  { name: "win10", path: "C:\\GpuVM\\win10\\Virtual Hard Disks\\win10.vhdx", sizeGB: 200, fileGB: 200, type: "Fixed", vm: "win10", restorable: false, profile: "max-performance", edition: "Windows 10 Pro", createdAt: "2026-10-26T22:40:00", hostFreeGB: 232 },
  { name: "win11-pruebas", path: "C:\\GpuVM\\win11-pruebas\\Virtual Hard Disks\\win11-pruebas.vhdx", sizeGB: 128, fileGB: 31.4, type: "Dynamic", vm: "win11-pruebas", restorable: false, profile: "balanced", edition: "Windows 11 Pro", createdAt: "2026-10-27T09:00:00", hostFreeGB: 232 },
  { name: "win10-viejo", path: "C:\\GpuVM\\win10-viejo\\Virtual Hard Disks\\win10-viejo.vhdx", sizeGB: 128, fileGB: 42.7, type: "Dynamic", vm: null, restorable: true, profile: "balanced", edition: "Windows 10 Pro", createdAt: "2026-10-20T18:00:00", hostFreeGB: 232 },
];

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Catalog apps already in each sample machine's Windows.
const installed: Record<string, string[]> = { win10: ["steam", "discord", "chrome", "7zip"], "win11-pruebas": ["steam"] };

export async function ps(cmd: string, args: Record<string, unknown>): Promise<unknown[]> {
  await wait(250);
  if (scenario === "noadmin") throw new Error("This command needs PowerShell 7 opened as administrator.");
  if (scenario === "noservice") throw new Error("The GpuVM service isn't installed.");
  if (scenario === "servicestopped") throw new Error("The GpuVM service is stopped.");
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
      return [{ logicalProcessors: 12, memoryGB: 15, gpuName: "NVIDIA GeForce RTX 4060", disk: { drive: "C:", freeGB: 232, promisedGB: 86, marginGB: 20, availableGB: 126, sizeGB: null, usedGB: null, maxGB: 126, others: [{ vm: "estudio", promisedGB: 86 }] } }];
    case "Get-GpuVMIsoList":
      return scenario === "empty" ? [] : isos;
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
      return Object.entries(catalog.apps).map(([id, a]: [string, { name: string; signer?: string; category: string; uninstall?: { match: string; interactive?: boolean } }]) => (
        { id, name: a.name, signer: a.signer ?? null, category: a.category, categoryName: (catalog.categories as Record<string, string>)[a.category],
          interactiveUninstall: !!a.uninstall?.interactive }));
    case "Get-GpuVMMonitor":
      return [
        { id: "mock-qms20", name: "QMS20", primary: false, x: -1920, y: 0, width: 1920, height: 1080, hz: 60 },
        { id: "mock-kg241y", name: "KG241Y S", primary: true, x: 0, y: 0, width: 1920, height: 1080, hz: 180 },
      ];
    case "Get-GpuVMInstalledApp":
      await wait(700);
      return (installed[String(args.Name)] ?? []).map((id) => ({ id, name: APP_NAMES[id] ?? id }));
    case "Get-GpuVMHome":
      return [{
        lastOpened: { name: lastOpened, at: new Date(Date.now() - 2 * 3600e3).toISOString() },
        host: { memoryTotalGB: 15.8, memoryFreeGB: 6.4, diskFreeGB: 212, topProcesses: [{ name: "Translay", gb: 2.7 }, { name: "brave", gb: 1.1 }, { name: "Code", gb: 0.8 }] },
        machines: vms.map((v) => ({ name: v.name, state: v.state, memoryGB: v.options?.memoryGB ?? 2, needGB: (v.options?.memoryGB ?? 2) + 0.3, fits: v.state !== "Off" || (v.options?.memoryGB ?? 2) + 0.3 <= 6.4, fitGB: 6 })),
        attention,
      }];
    case "Get-GpuVMTemplate":
      return scenario === "empty" ? [] : templates;
    case "Remove-GpuVMTemplate":
      templates = templates.filter((t) => t.name !== args.Name);
      return [];
    case "Get-GpuVMSharedDisk":
      return scenario === "empty" ? [] : shared;
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
    // ?mock=empty: no machines and an empty Library (only the profiles GpuVM ships with).
    case "Get-GpuVMDisk":
      return scenario === "empty" ? [] : disks;
    case "Get-GpuVMBase":
      return scenario === "empty" ? [] : bases;
    case "Remove-GpuVMBase":
      bases = bases.filter((b) => b.key !== args.Key);
      return [];
    case "Remove-GpuVMDisk":
      disks = disks.filter((d) => d.name !== args.Name);
      return [];
    case "Set-GpuVMStreamingClient": {
      const vm = vms.find((v) => v.name === args.Name)!;
      if (args.Monitor !== undefined && args.Resolution === undefined) {
        const { monitor: _, ...rest } = vm.client!;
        vm.client = args.Monitor === "default" ? rest : { ...rest, monitor: String(args.Monitor) };
        return [];
      }
      vm.client = {
        ...vm.client!, resolution: String(args.Resolution), fps: Number(args.Fps), displayMode: (args.DisplayMode as DisplayMode) ?? vm.client!.displayMode,
        ...(args.VSync !== undefined ? { vsync: Boolean(args.VSync) } : {}),
        ...(args.FramePacing !== undefined ? { framePacing: Boolean(args.FramePacing) } : {}),
        ...(args.Mouse ? { mouse: args.Mouse as MouseMode } : {}),
        ...(args.Codec ? { codec: String(args.Codec) } : {}),
        ...(args.BitrateKbps !== undefined ? { bitrateKbps: Number(args.BitrateKbps) } : {}),
      };
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
      return [];
    case "Send-GpuVMClipboard":
      await wait(600);
      return [];
    case "Rename-GpuVM":
      renameVm(String(args.Name), String(args.NewName));
      return [];
    case "Get-GpuVMImportInfo":
      return [{ path: args.Path, name: "win10", freeName: vms.some((v) => v.name === "win10") ? "win10-2" : "win10", edition: "Windows 10 Pro", user: "gpuvm",
        installedApps: ["steam", "vlc"], exportedAt: "2026-11-16T20:05:00-05:00", diskGB: 61.4, fileGB: 61.4, freeGB: 232 }];
    case "Get-GpuVMRestorePoint":
      return [restorePoints[String(args.Name)] ?? { max: 10, changesGB: null, restoredFrom: null, points: [] }];
    case "Remove-GpuVMDisposable":
      return [];
    case "Set-GpuVMDisposable": {
      const vm = vms.find((v) => v.name === args.Name);
      if (vm) vm.disposable = false;
      return [{ name: args.Name, disposable: false }];
    }
    case "Set-GpuVMGuestCredential":
      vms.find((v) => v.name === args.Name)!.guestCredential = true;
      return [];
    case "Set-GpuVMAgentUser": {
      const vm = vms.find((v) => v.name === args.Name)!;
      vm.agent = { ...(vm.agent ?? { installed: false, connected: false, version: null }), user: args.User === "own" ? "own" : "agent" };
      return [];
    }
    case "Set-GpuVMUse": {
      const vm = vms.find((v) => v.name === args.Name)!;
      vm.forAgents = args.Use === "agent";
      return [];
    }
    default:
      return agentCommand(cmd, args) ?? [];
  }
}

const listeners = new Set<(e: JobEvent) => void>();
export function onJob(handler: (e: JobEvent) => void) {
  listeners.add(handler);
  return () => listeners.delete(handler);
}

let lastOpened = "win10";

// What Rename-GpuVM keeps under the new name: the machine, its apps, shared disks, templates and last opened.
function renameVm(from: string, to: string) {
  const vm = vms.find((v) => v.name === from);
  if (!vm) throw new Error(`The VM '${from}' doesn't exist.`);
  if (vm.state !== "Off") throw new Error(`Turn off the VM '${from}' to rename it.`);
  if (vms.some((v) => v !== vm && v.name.toLowerCase() === to.toLowerCase())) throw new Error(`There's already a VM called '${to}'.`);
  vm.name = to;
  if (installed[from]) { installed[to] = installed[from]; delete installed[from]; }
  shared = shared.map((d) => d.vm === from ? { ...d, vm: to } : d);
  templates = templates.map((t) => ({ ...t, usedBy: t.usedBy.map((n) => n === from ? to : n) }));
  attention = attention.map((a) => a.vm === from ? { ...a, vm: to } : a);
  if (lastOpened === from) lastOpened = to;
}

let attention = [
  { vm: "win11-pruebas", kind: "driver", text: "Its GPU driver isn't the one on this PC (32.0.15.8180)", label: "Update driver", cmd: "Sync-GpuVMDriver", args: { Name: "win11-pruebas" } },
  { vm: "win11-pruebas", kind: "apps", text: "Still to install: Steam, Discord", label: "Start and install", cmd: "Install-GpuVMApp", args: { Name: "win11-pruebas", App: ["steam", "discord"] } },
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
  { id: "privacy", name: "Privacy", items: [
    { id: "telemetry-minimum", description: "Diagnostic data at the lowest level the edition allows (on Pro, “Required”; on Enterprise and Education, off)." },
    { id: "advertising", description: "No advertising ID or tailored experiences from your diagnostic data." },
    { id: "activity-history", description: "No activity history and no activity sent to Microsoft." },
    { id: "suggestions", description: "No suggestions, tips, Spotlight or promoted apps that install themselves." },
    { id: "web-search", description: "Start's search looks only on this PC, without Bing." },
    { id: "copilot-recall", description: "No Copilot or Recall (the screenshots Windows 11 saves)." },
  ] },
  { id: "apps", name: "No extra apps", items: [
    { id: "store-apps", description: "Removes preinstalled apps that aren't needed (news, weather, Solitaire, Clipchamp, personal Teams, new Outlook...), for new users too. They can be installed again from Microsoft Store." },
    { id: "onedrive", description: "Removes OneDrive and keeps it from installing again." },
    { id: "widgets", description: "No widgets or “News and interests” on the taskbar." },
  ] },
  { id: "minimal", name: "Minimal", items: [
    { id: "telemetry-services", description: "Turns off the services that send telemetry and error reports to Microsoft." },
    { id: "unneeded-services", description: "Turns off services a VM doesn't use: maps, location, fax, demo mode and Windows Media sharing." },
    { id: "background-apps", description: "Microsoft Store apps don't run in the background." },
  ] },
];

export async function job(jobId: string, cmd: string, args: Record<string, unknown>) {
  const emit = (e: Omit<JobEvent, "jobId">) => listeners.forEach((l) => l({ jobId, ...e }));
  const steps = cmd === "New-GpuVMTemplate" ? ["Shutting down", "Copying the disk of win10 (it may take a few minutes)", "Starting", `Template '${args.Name}' is ready (61.4 GB)`]
    : cmd === "Import-GpuVMSharedDisk" ? ["Measuring the folder", "Copying to SteamLibrary\\steamapps", "Copying 18 %", "Copying 47 %", "Copying 83 %", "Copied: 92.4 GB in SteamLibrary\\steamapps"]
    : cmd === "Connect-GpuVMSharedDisk" ? [`Connecting the disk '${args.Name}' to '${args.VMName}'`, `Disk '${args.Name}' at G: inside the VM`, "Steam library at G:\\SteamLibrary"]
    : cmd === "Disconnect-GpuVMSharedDisk" ? [`Closing the disk inside '${args.VMName ?? "win10"}'`, `Removing the disk '${args.Name}' from '${args.VMName ?? "win10"}'`]
    : cmd === "Set-GpuVMCleanup" ? ["Waiting for Windows", "Cleaning up Windows", "Cleanup applied"]
    : cmd === "Sync-GpuVMDriver" ? ["Reading the files of driver 32.0.15.8180 for NVIDIA GeForce RTX 4060", "Driver copied: 4 DriverStore folders and 31 files"]
    : cmd === "Install-GpuVMApp" ? ["Waiting for Windows", ...((args.App as string[]) ?? []).flatMap((id) => [
      ...(args.Reinstall ? [`Uninstalling ${APP_NAMES[id] ?? id}`, `${APP_NAMES[id] ?? id} uninstalled`] : []),
      `Installing ${APP_NAMES[id] ?? id}`, `${APP_NAMES[id] ?? id} installed`])]
    : cmd === "Uninstall-GpuVMApp" ? ["Waiting for Windows", ...((args.App as string[]) ?? []).flatMap((id) => [`Uninstalling ${APP_NAMES[id] ?? id}`, `${APP_NAMES[id] ?? id} uninstalled`])]
    : cmd === "Invoke-GpuVMPower" ? ["Installing updates"]
    : cmd === "Rename-GpuVM" ? [`Renaming it in Hyper-V to '${args.NewName}'`, "Moving the VM's settings to its new folder", "Renaming the disk", `The VM is now called '${args.NewName}'.`]
    : cmd === "Connect-GpuVM" && args.MemoryGB ? [`Memory: ${args.MemoryGB} GB`, "Starting", "Waiting for Windows", "Waiting for Sunshine", "Opening at 1920x1080 and 60 FPS"]
    : cmd === "New-GpuVM" && args.Template ? [`Creating the disk on top of the template '${args.Template}'`, "Giving the copy its own streaming identity", "Starting", "Waiting for Windows"]
    : cmd === "New-GpuVM"
    ? ["Edition: Windows 10 Pro (es-MX)", "Reading the files of driver 32.0.15.8180 for NVIDIA GeForce RTX 4060", "Creating a fixed 96 GB disk (it writes the whole disk; takes a few minutes)", "Copying Windows to the machine's disk", "Copying the GPU driver to the guest", `Registering the VM '${args.Name}' in Hyper-V`]
    : ["Starting", "Waiting for Windows", "Signing in to Windows", "Waiting for Sunshine", "Sunshine will capture the virtual display (Virtual Display)", "Opening at 1920x1080 and 60 FPS", "Connecting the picture"];
  for (const message of steps) {
    emit({ type: "progress", message });
    await wait(900);
  }
  if (cmd === "Set-GpuVMUse" || cmd === "Set-GpuVMAgentUser") {
    const vm = vms.find((v) => v.name === args.Name);
    if (vm && cmd === "Set-GpuVMUse") { vm.use = args.Use === "agent" ? "agent" : null; vm.forAgents = args.Use === "agent"; }
    if (vm && cmd === "Set-GpuVMAgentUser") vm.agentUser = args.User === "own" ? "own" : "agent";
    emit({ type: "result", ok: true, data: [] });
    return;
  }
  if (cmd === "Rename-GpuVM") {
    try { renameVm(String(args.Name), String(args.NewName)); }
    catch (err) { emit({ type: "result", ok: false, error: (err as Error).message }); return; }
  } else if (cmd === "New-GpuVM") {
    const agent = args.Use === "agent";
    vms.push({ ...vms[1], id: String(Date.now()), name: String(args.Name), state: "Running", paired: false, disposable: !!args.Disposable,
      ...(agent ? { forAgents: true, agent: { installed: true, connected: false, version: "0.1.0", user: args.AgentUser === "own" ? "own" : "agent" } } : {}) });
  } else {
    const vm = vms.find((v) => v.name === args.Name);
    if (vm) vm.state = cmd === "Invoke-GpuVMPower" ? "Off" : "Running";
    if (cmd === "New-GpuVMTemplate") templates = [...templates, { name: String(args.Name), fromVM: String(args.VMName), createdAt: new Date().toISOString(), edition: "Windows 10 Pro", sizeGB: 200, fileGB: 61.4, cleanup: "none", usedBy: [] }];
    if (cmd === "Connect-GpuVMSharedDisk") shared = shared.map((d) => d.name === args.Name ? { ...d, vm: String(args.VMName), vmRunning: true } : d);
    if (cmd === "Disconnect-GpuVMSharedDisk") shared = shared.map((d) => d.name === args.Name ? { ...d, vm: null, vmRunning: false } : d);
    if (vm?.options && cmd === "Set-GpuVMCleanup") vm.options.cleanup = args.Level as typeof vm.options.cleanup;
    if (vm?.options && args.MemoryGB) { vm.options.memoryGB = Number(args.MemoryGB); vm.memoryStartupGB = Number(args.MemoryGB); vm.fits = true; vm.missingGB = 0; }
    if (vm && cmd === "Sync-GpuVMDriver") vm.driverInSync = true;
    const ids = (args.App as string[] | undefined) ?? [];
    if (vm && cmd === "Install-GpuVMApp") installed[vm.name] = [...new Set([...(installed[vm.name] ?? []), ...ids])];
    if (vm && cmd === "Uninstall-GpuVMApp") installed[vm.name] = (installed[vm.name] ?? []).filter((id) => !ids.includes(id));
    // What was fixed leaves the home screen's list.
    attention = attention.filter((a) => !(a.vm === args.Name && a.cmd === cmd));
  }
  emit({ type: "result", ok: true, data: [] });
}
