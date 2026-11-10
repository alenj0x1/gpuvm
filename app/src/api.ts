import type { AppInfo, InstalledApp, BaseInfo, CleanupLevel, HomeInfo, SharedDiskInfo, TemplateInfo, DiskInfo, DisplayMode, HostInfo, IsoFile, JobEvent, ProfileInfo, ProfileSettings, StreamSettings, VmOverview, AdminPrompt } from "./types";
import * as mock from "./mock";

// Outside Tauri (browser) the UI runs on sample data so it can be designed.
export const inTauri = "__TAURI_INTERNALS__" in window;

async function ps<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T[]> {
  if (!inTauri) return mock.ps(cmd, args) as Promise<T[]>;
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T[]>("ps", { cmd, args });
}

export const api = {
  overview: () => ps<VmOverview>("Get-GpuVMOverview"),
  adminPrompts: () => adminPromptsNow(),
  answerAdminPrompt: (name: string, answer: "Allow" | "Deny", id: number) =>
    ps("Resolve-GpuVMAdminPrompt", { Name: name, Answer: answer, PromptId: id }),
  home: () => ps<HomeInfo>("Get-GpuVMHome").then((r) => r[0]),
  isos: () => ps<IsoFile>("Get-GpuVMIsoList"),
  hostInfo: () => ps<HostInfo>("Get-GpuVMHostInfo"),
  profiles: () => ps<ProfileInfo>("Get-GpuVMProfile"),
  power: (name: string, action: string) => ps("Invoke-GpuVMPower", { Name: name, Action: action }),
  saveGuestPassword: (name: string, user: string, password: string) =>
    ps("Set-GpuVMGuestCredential", { Name: name, Credential: { user, password } }),
  applyOptions: (name: string, override: Record<string, unknown>) => ps("Set-GpuVM", { Name: name, Override: override }),
  // DisplayMode only goes when it changed, so a mode the app doesn't show (borderless) is kept.
  // The stream settings (V-Sync, pacing, mouse, codec, bitrate) also go only when they changed.
  setClient: (name: string, resolution: string, fps: number, displayMode?: DisplayMode, stream: StreamSettings = {}) =>
    ps("Set-GpuVMStreamingClient", {
      Name: name, Resolution: resolution, Fps: fps, ...(displayMode ? { DisplayMode: displayMode } : {}),
      ...(stream.vsync !== undefined ? { VSync: stream.vsync } : {}),
      ...(stream.framePacing !== undefined ? { FramePacing: stream.framePacing } : {}),
      ...(stream.mouse ? { Mouse: stream.mouse } : {}),
      ...(stream.codec ? { Codec: stream.codec } : {}),
      ...(stream.bitrateKbps !== undefined ? { BitrateKbps: stream.bitrateKbps } : {}),
    }),
  remove: (name: string, deleteDisk: boolean) => ps("Remove-GpuVM", { Name: name, DeleteDisk: deleteDisk, Confirm: false }),
  apps: () => ps<AppInfo>("Get-GpuVMApp"),
  installedApps: (name: string) => ps<InstalledApp>("Get-GpuVMInstalledApp", { Name: name }),
  cleanupLevels: () => ps<CleanupLevel>("Get-GpuVMCleanup"),
  pasteToVm: (name: string) => ps("Send-GpuVMClipboard", { Name: name }),
  setCapture: (name: string, mode: "ddx" | "wgc") => ps("Set-GpuVMCapture", { Name: name, Mode: mode }),
  setNetworkIsolation: (name: string, enabled: boolean) => ps("Set-GpuVMNetworkIsolation", { Name: name, Enabled: enabled }),
  saveProfile: (name: string, description: string, extendsName: string, settings: Partial<ProfileSettings>, previous?: string) =>
    ps<ProfileInfo>("Save-GpuVMProfile", { Name: name, Description: description, Extends: extendsName, Settings: settings, ...(previous ? { Previous: previous } : {}) }),
  removeProfile: (name: string) => ps("Remove-GpuVMProfile", { Name: name }),
  disks: () => ps<DiskInfo>("Get-GpuVMDisk"),
  templates: () => ps<TemplateInfo>("Get-GpuVMTemplate"),
  removeTemplate: (name: string) => ps("Remove-GpuVMTemplate", { Name: name, Confirm: false }),
  sharedDisks: () => ps<SharedDiskInfo>("Get-GpuVMSharedDisk"),
  newSharedDisk: (name: string, sizeGB: number, purpose: string) => ps<SharedDiskInfo>("New-GpuVMSharedDisk", { Name: name, SizeGB: sizeGB, Purpose: purpose }),
  removeSharedDisk: (name: string) => ps("Remove-GpuVMSharedDisk", { Name: name, Confirm: false }),
  removeDisk: (name: string) => ps("Remove-GpuVMDisk", { Name: name, Confirm: false }),
  bases: () => ps<BaseInfo>("Get-GpuVMBase"),
  removeBase: (key: string) => ps("Remove-GpuVMBase", { Key: key, Confirm: false }),
  addIso: (path: string) => ps("Add-GpuVMIso", { Path: path }),
  removeIso: (path: string) => ps("Remove-GpuVMIso", { Path: path }),
};

export async function startJob(jobId: string, cmd: string, args: Record<string, unknown>) {
  if (!inTauri) return mock.job(jobId, cmd, args);
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("job", { jobId, cmd, args });
}

export async function onJob(handler: (e: JobEvent) => void): Promise<() => void> {
  if (!inTauri) return mock.onJob(handler);
  const { listen } = await import("@tauri-apps/api/event");
  return listen<JobEvent>("job", (e) => handler(e.payload));
}

// Administrator prompts (PromptCard): the list the app's poller last saw, and the person's answer.
export async function adminPromptsNow(): Promise<AdminPrompt[]> {
  if (!inTauri) return mock.adminPrompts();
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<AdminPrompt[]>("admin_prompts");
}

export async function adminPromptAnswered(id: number) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("admin_prompt_answered", { id });
}

export async function openConsole(name: string) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("open_console", { name });
}

/** Installs and starts the GpuVM service again (UAC prompt). */
export async function repairService() {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("repair_service");
}

export interface ServiceStatus { state: "running" | "starting" | "stopping" | "stopped" | "missing"; withWindows: boolean }

/** The GpuVM service: its state, start and stop (no UAC), and whether it starts with Windows (UAC). */
export const service = {
  status: async (): Promise<ServiceStatus> => {
    if (!inTauri) return { state: "running", withWindows: false };
    const { invoke } = await import("@tauri-apps/api/core");
    return invoke<ServiceStatus>("service_status");
  },
  start: async () => {
    if (!inTauri) return;
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("start_service");
  },
  stop: async () => {
    if (!inTauri) return;
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("stop_service");
  },
  setStartup: async (withWindows: boolean) => {
    if (!inTauri) return;
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("set_service_startup", { withWindows });
  },
};

/** Development builds only: they start the module themselves and need administrator. */
export async function relaunchAsAdmin() {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("relaunch_as_admin");
}

export async function pickIso(): Promise<string | null> {
  if (!inTauri) return "D:\\ISOs\\Win11_24H2_Spanish_x64.iso";
  const { open } = await import("@tauri-apps/plugin-dialog");
  const file = await open({ multiple: false, filters: [{ name: "Imagen de Windows", extensions: ["iso"] }] });
  return typeof file === "string" ? file : null;
}

export async function pickFolder(): Promise<string | null> {
  if (!inTauri) return "D:\\SteamLibrary";
  const { open } = await import("@tauri-apps/plugin-dialog");
  const folder = await open({ directory: true, multiple: false });
  return typeof folder === "string" ? folder : null;
}
