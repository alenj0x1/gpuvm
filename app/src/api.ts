import type { AppInfo, InstalledApp, BaseInfo, CleanupLevel, HomeInfo, SharedDiskInfo, TemplateInfo, DiskInfo, DisplayMode, HostInfo, IsoFile, JobEvent, ProfileInfo, ProfileSettings, StreamSettings, VmOverview, AdminPrompt, HostMonitor, RestorePointList, ImportInfo } from "./types";
import * as mock from "./mock";
import { t } from "./i18n";

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
  monitors: () => ps<HostMonitor>("Get-GpuVMMonitor"),
  /** What is selected in a machine's File Explorer (what "Enviar a" sends to another machine). */
  explorerSelection: (name: string) => ps<{ name: string; paths: string[]; names: string[] }>("Get-GpuVMExplorerSelection", { Name: name }).then((r) => r[0]),
  /** A monitor's id, "primary", or "default" to follow Preferences. */
  setMonitor: (name: string, monitor: string) => ps("Set-GpuVMStreamingClient", { Name: name, Monitor: monitor }),
  /** The machine must be off; the app runs it as a job (startJob) so its steps show on the button. */
  rename: (name: string, newName: string) => ps("Rename-GpuVM", { Name: name, NewName: newName, Confirm: false }),
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
  // Creating, going back to and deleting a point, exporting and importing run as jobs (startJob) so their steps show on the button.
  restorePoints: (name: string) => ps<RestorePointList>("Get-GpuVMRestorePoint", { Name: name }).then((r) => r[0]),
  /** Deletes the disposable machines that ran and are off, and their leftovers; returns the names deleted. */
  sweepDisposable: () => ps<string>("Remove-GpuVMDisposable", { Confirm: false }),
  importInfo: (path: string) => ps<ImportInfo>("Get-GpuVMImportInfo", { Path: path }).then((r) => r[0]),
  keepDisposable: (name: string) => ps("Set-GpuVMDisposable", { Name: name, Keep: true }),
};

/** Agents (docs/agents/protocol.md): the clients connected over MCP, their requests and the files they offer. The
 *  broker decides everything; the app only shows it and passes on the person's answers. */
// The broker's own shapes (times in ms, the client is a "connection"); agentStore.ts turns them into the app's types.
type Raw = Record<string, unknown>;
export const agents = {
  /** The agent sessions: who, on which machine, doing what, how far into the budget, its last steps. */
  clients: () => ps<Raw>("Get-GpuVMAgentClient"),
  requests: () => ps<Raw>("Get-GpuVMAgentRequest"),
  offers: (machine?: string) => ps<Raw>("Get-GpuVMAgentOffer", machine ? { Name: machine } : {}),
  settings: () => ps<{ clients?: Record<string, { clientApprovals?: boolean }> }>("Get-GpuVMAgentSettings").then((r) => r[0] ?? null),
  broker: () => ps<{ listening: boolean; error?: string | null }>("Get-GpuVMAgentBroker").then((r) => r[0] ?? null),
  /** Recordings of agents' work (agent.rs keeps them while the app runs). */
  recordings: async (): Promise<Record<string, unknown>[]> => {
    if (!inTauri) return mock.agentRecordings();
    const { invoke } = await import("@tauri-apps/api/core");
    return invoke<Record<string, unknown>[]>("agent_recordings");
  },
  /** Opens a recording (only files GpuVM saved this run, capture.rs). */
  openRecording: async (path: string) => {
    if (!inTauri) return;
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("capture_open", { path });
  },
  /** An action's screenshot, kept by the broker for the last 10 steps. */
  capture: (connection: string, action: number) => ps<{ format: string; data: string }>("Get-GpuVMAgentCapture", { Connection: connection, Action: action }).then((r) => r[0] ?? null),
  /** "control": the person took control over the picture (the viewer saw their input). */
  pause: (connection: string, reason: "person" | "control" = "person") =>
    ps("Suspend-GpuVMAgent", { Connection: connection, Reason: reason, Message: reason === "control" ? "You took control" : "Paused by you" }),
  /** Only that machine goes back to the session (one it holds besides may still be the person's). */
  resume: (connection: string, machine: string) => ps("Resume-GpuVMAgent", connection ? { Name: machine, Connection: connection } : { Name: machine }),
  /** The guest repaints its whole desktop (agent 0.3.8, no input, nothing moved): with ddx a still desktop sends no
   *  frame and the picture stayed black after connecting. From the app's pipe, no session. */
  refreshScreen: (name: string) =>
    // A burst (every 250 ms for 10 s): a single repaint got lost while Sunshine/ddx restarted capture (agent-broker,
    // lab: picture on opening 9/10, median 0.84 s).
    ps("Invoke-GpuVMAgent", { Name: name, Method: "screen.refresh", Params: { repeatMs: 10000 }, TimeoutSec: 15 }),
  /** The kill switch: one session, or every one with "*". */
  stop: (connection: string) => ps("Stop-GpuVMAgentClient", connection === "*" ? { All: true } : { Connection: connection }),
  /** Per client (by its name, so it stays for its next sessions): low-risk approvals from the client itself. */
  setClientApprovals: (clientName: string, on: boolean) => ps("Set-GpuVMAgentClient", { Name: clientName, ClientApprovals: on }),
  /** Settings › Agents, only when the person moves it: the service keeps it (never written at startup). */
  /** Each machine's agent: name, state (ready | no-display | starting | off | no-agent), lastError. */
  machines: () => ps<Record<string, unknown>>("Get-GpuVMAgent"),
  setApprovalTimeout: (seconds: number) => ps("Set-GpuVMAgentSettings", { ApprovalTimeoutSec: seconds }),
  /** Finished sessions, newest first (the service keeps the last ~1000). */
  history: (limit = 200) => (inTauri
    ? ps<{ sessions?: Record<string, unknown>[] }>("Get-GpuVMAgentHistory", { Limit: limit }).then((r) => r[0]?.sessions ?? [])
    : Promise.resolve(mock.agentHistory())),
  /** The limit of new sessions in minutes, 0 = none; the action count is never limited from the app. */
  setSessionLimit: (minutes: number) => ps("Set-GpuVMAgentSettings", { MaxMinutes: minutes, MaxSteps: 0 }),
  /** forTask: allowed again for the rest of this task (never forever). */
  answer: (id: string, allow: boolean, forTask = false) => ps("Resolve-GpuVMAgentRequest", { Id: id, Allow: allow, ...(forTask ? { ForTask: true } : {}) }),
  resolveOffer: (id: string, accept: boolean) => ps("Resolve-GpuVMAgentOffer", { Id: id, Accept: accept }),
  setUser: (machine: string, user: "agent" | "own") => ps("Set-GpuVMAgentUser", { Name: machine, User: user }),
  setUse: (machine: string, use: "agent" | null) => ps("Set-GpuVMUse", { Name: machine, Use: use ?? "none" }),
};

/** What is wrong with a new machine name, as New-GpuVM and Rename-GpuVM check it, or "" when it can be used.
 * `current` is the machine being renamed: its own name, even in another case, is not taken. */
export function vmNameError(name: string, vms: { name: string }[], current?: string): string {
  if (!name) return t("Enter a name");
  if (!/^[\w-]{1,40}$/.test(name)) return name.length > 40 ? t("Up to 40 characters") : t("Use letters, numbers or hyphens, no spaces");
  const taken = vms.some((v) => v.name.toLowerCase() === name.toLowerCase() && v.name.toLowerCase() !== current?.toLowerCase());
  return taken ? t("There's already a machine with that name") : "";
}

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
  const file = await open({ multiple: false, filters: [{ name: t("Windows image"), extensions: ["iso"] }] });
  return typeof file === "string" ? file : null;
}

/** Where to save a machine exported to one file (Windows' own save dialog, so the person picks the place). */
export async function pickExportFile(name: string): Promise<string | null> {
  if (!inTauri) return `C:\\Users\\Usuario\\Documents\\${name}.gpuvm`;
  const { save } = await import("@tauri-apps/plugin-dialog");
  const file = await save({ defaultPath: `${name}.gpuvm`, filters: [{ name: t("GpuVM machine"), extensions: ["gpuvm"] }] });
  return typeof file === "string" ? file : null;
}

/** A machine file to import. */
export async function pickMachineFile(): Promise<string | null> {
  if (!inTauri) return "C:\\Users\\Usuario\\Documents\\win10.gpuvm";
  const { open } = await import("@tauri-apps/plugin-dialog");
  const file = await open({ multiple: false, filters: [{ name: t("GpuVM machine"), extensions: ["gpuvm"] }] });
  return typeof file === "string" ? file : null;
}

export async function pickFolder(): Promise<string | null> {
  if (!inTauri) return "D:\\SteamLibrary";
  const { open } = await import("@tauri-apps/plugin-dialog");
  const folder = await open({ directory: true, multiple: false });
  return typeof folder === "string" ? folder : null;
}
