import type { AppInfo, CleanupLevel, DiskInfo, DisplayMode, HostInfo, IsoFile, JobEvent, ProfileInfo, ProfileSettings, VmOverview } from "./types";
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
  isos: () => ps<IsoFile>("Get-GpuVMIsoList"),
  hostInfo: () => ps<HostInfo>("Get-GpuVMHostInfo"),
  profiles: () => ps<ProfileInfo>("Get-GpuVMProfile"),
  power: (name: string, action: string) => ps("Invoke-GpuVMPower", { Name: name, Action: action }),
  saveGuestPassword: (name: string, user: string, password: string) =>
    ps("Set-GpuVMGuestCredential", { Name: name, Credential: { user, password } }),
  applyOptions: (name: string, override: Record<string, unknown>) => ps("Set-GpuVM", { Name: name, Override: override }),
  // DisplayMode only goes when it changed, so a mode the app doesn't show (borderless) is kept.
  setClient: (name: string, resolution: string, fps: number, displayMode?: DisplayMode) =>
    ps("Set-GpuVMStreamingClient", { Name: name, Resolution: resolution, Fps: fps, ...(displayMode ? { DisplayMode: displayMode } : {}) }),
  remove: (name: string, deleteDisk: boolean) => ps("Remove-GpuVM", { Name: name, DeleteDisk: deleteDisk, Confirm: false }),
  apps: () => ps<AppInfo>("Get-GpuVMApp"),
  cleanupLevels: () => ps<CleanupLevel>("Get-GpuVMCleanup"),
  pasteToVm: (name: string) => ps("Send-GpuVMClipboard", { Name: name }),
  setCapture: (name: string, mode: "ddx" | "wgc") => ps("Set-GpuVMCapture", { Name: name, Mode: mode }),
  setNetworkIsolation: (name: string, enabled: boolean) => ps("Set-GpuVMNetworkIsolation", { Name: name, Enabled: enabled }),
  saveProfile: (name: string, description: string, extendsName: string, settings: Partial<ProfileSettings>, previous?: string) =>
    ps<ProfileInfo>("Save-GpuVMProfile", { Name: name, Description: description, Extends: extendsName, Settings: settings, ...(previous ? { Previous: previous } : {}) }),
  removeProfile: (name: string) => ps("Remove-GpuVMProfile", { Name: name }),
  disks: () => ps<DiskInfo>("Get-GpuVMDisk"),
  removeDisk: (name: string) => ps("Remove-GpuVMDisk", { Name: name, Confirm: false }),
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

export async function openConsole(name: string) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("open_console", { name });
}

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
