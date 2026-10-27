import type { HostInfo, IsoFile, JobEvent, ProfileInfo, VmOverview } from "./types";
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
  setClient: (name: string, resolution: string, fps: number) =>
    ps("Set-GpuVMStreamingClient", { Name: name, Resolution: resolution, Fps: fps }),
  remove: (name: string, deleteDisk: boolean) => ps("Remove-GpuVM", { Name: name, DeleteDisk: deleteDisk, Confirm: false }),
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
