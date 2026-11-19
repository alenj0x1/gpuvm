export type VmState = "Running" | "Off" | "Paused" | "Saved" | "Starting" | "Stopping" | string;

export interface ClientSettings {
  app: string;
  resolution: string;
  fps: number;
  bitrateKbps: number;
  codec: string;
  displayMode?: DisplayMode;
  /** Undefined = Moonlight's own default (V-Sync on, frame pacing off, mouse captured). */
  vsync?: boolean;
  framePacing?: boolean;
  mouse?: MouseMode;
  /** The monitor Moonlight opens on: a monitor's id or "primary". Unset = the app's choice in Preferences. */
  monitor?: string;
}

/** A monitor of this PC (Get-GpuVMMonitor), in physical pixels. */
export interface HostMonitor {
  id: string;
  name: string;
  primary: boolean;
  x: number;
  y: number;
  width: number;
  height: number;
  hz: number;
}

/** capture: relative mouse for games; absolute: the pointer moves freely, as in remote desktop. */
export type MouseMode = "capture" | "absolute";

/** A Windows administrator prompt open in a VM captured with WGC (it can't be streamed; GpuVM answers it). */
export interface AdminPrompt {
  name: string;
  /** The prompt's own id: an answer only applies to this prompt. */
  id: number;
  app: string | null;
  publisher: string | null;
  /** The machine is still reading the program and publisher: the answer waits for them. */
  reading?: boolean;
}

export type StreamSettings = Partial<Pick<ClientSettings, "vsync" | "framePacing" | "mouse" | "codec" | "bitrateKbps">>;

export interface VmOverview {
  id: string;
  name: string;
  state: VmState;
  managed: boolean;
  profile: string | null;
  edition: string | null;
  generation: number;
  processorCount: number;
  cpuPercent: number;
  memoryStartupGB: number;
  memoryAssignedGB: number;
  memoryDemandGB: number;
  uptimeSeconds: number;
  hasGpu: boolean;
  gpuName: string | null;
  gpuPercent: number;
  driverInSync: boolean | null;
  /** Whether it fits in the host's free memory now (always true unless off), and the most it could start with. */
  fits: boolean;
  fitGB: number;
  missingGB: number;
  streaming: boolean;
  paired: boolean;
  guestCredential: boolean;
  /** Deleted with its disk once it has run and is off again. */
  disposable?: boolean;
  /** How many restore points it has. */
  restorePoints?: number;
  address: string | null;
  /** The guest agent: installed, connected to the broker, and which Windows user agents work as. Missing = never set up. */
  agent?: { installed: boolean; connected: boolean; version: string | null; user: "agent" | "own" } | null;
  /** Made for agents (usage type Agent): 1280x800, always recording while an agent works, isolated network. */
  forAgents?: boolean;
  /** Get-GpuVMOverview: "agent" for a machine made for agents, and who Windows signs in as there. */
  use?: string | null;
  agentUser?: "agent" | "own" | null;
  client: ClientSettings | null;
  options: { cpu: number; memoryGB: number; gpuPercent: number; diskGB: number; diskType: string; diskFreeGB: number; captureMode: "ddx" | "wgc"; networkIsolation: boolean; cleanup: CleanupLevelId; diskBudget?: DiskBudget | null } | null;
}

export type DisplayMode = "fullscreen" | "windowed" | "borderless";

export interface IsoFile {
  path: string;
  name: string;
  sizeGB: number;
  modified: string;
  remembered?: boolean;
  missing?: boolean;
  lastUsed?: string | null;
  usedBy?: string[];
}

export interface ProfileSettings {
  cpu: number;
  memoryGB: number;
  gpuPercent: number;
  diskGB: number;
  diskType: "Dynamic" | "Fixed";
  iso: string | null;
  apps: string[];
  cleanup: CleanupLevelId;
  resolution: string | null;
  fps: number | null;
  displayMode: DisplayMode;
  vsync?: boolean;
  framePacing?: boolean;
  mouse?: MouseMode;
}

export interface ProfileInfo {
  Name: string;
  Extends: string | null;
  Description: string;
  BuiltIn?: boolean;
  Settings?: ProfileSettings | null;
}

/** A VM's Windows saved as a base disk that new VMs build on. */
export interface TemplateInfo {
  name: string;
  fromVM: string;
  createdAt: string;
  edition: string | null;
  sizeGB: number;
  fileGB: number;
  cleanup: CleanupLevelId;
  usedBy: string[];
}

/** A data disk (a game library, for example) attached to one VM at a time. */
export interface SharedDiskInfo {
  name: string;
  purpose: "games" | "general";
  sizeGB: number;
  fileGB: number;
  vm: string | null;
  vmRunning: boolean;
  createdAt: string;
}

/** The home screen: the last machine opened, what fits in memory now and what needs attention. */
export interface HomeInfo {
  lastOpened: { name: string; at: string } | null;
  host: { memoryTotalGB: number; memoryFreeGB: number; diskFreeGB: number; topProcesses: { name: string; gb: number }[] };
  machines: { name: string; state: string; memoryGB: number; needGB: number; fits: boolean; fitGB: number }[];
  attention: { vm: string | null; kind: string; text: string; label: string; cmd: string | null; args: Record<string, unknown> | null }[];
}

export type CleanupLevelId = "none" | "privacy" | "apps" | "minimal";

/** A Windows cleanup level and what it adds to the ones before it. */
export interface CleanupLevel {
  id: CleanupLevelId;
  name: string;
  items: { id: string; description: string }[];
}

export interface AppInfo {
  id: string;
  name: string;
  signer: string | null;
  category: string;
  categoryName: string;
  /** Its uninstaller has no silent mode: it opens on the VM's desktop. */
  interactiveUninstall?: boolean;
}

/** A catalog app installed in a VM. */
export interface InstalledApp {
  id: string;
  name: string;
}

export interface DiskInfo {
  name: string;
  path: string;
  sizeGB: number;
  fileGB: number;
  type: string | null;
  vm: string | null;
  restorable: boolean;
  profile: string | null;
  edition: string | null;
  createdAt: string;
  hostFreeGB: number;
}

/** An ISO's edition applied once, so new VMs with it are copies instead of a new install. */
export interface BaseInfo {
  key: string;
  edition: string | null;
  language: string | null;
  createdAt: string;
  fileGB: number;
}

export interface JobEvent {
  jobId: string;
  type: "progress" | "warning" | "result";
  message?: string;
  ok?: boolean;
  error?: string;
  data?: unknown;
}

export interface HostInfo {
  logicalProcessors: number;
  memoryGB: number;
  gpuName: string | null;
  /** Room for a new machine's disk where GpuVM keeps them. */
  disk?: DiskBudget | null;
}

/** Get-GpuVMDiskBudget: what a disk on a drive can really take once every VM disk there is full. */
export interface DiskBudget {
  drive: string;
  freeGB: number;
  /** What the other VMs' dynamic disks can still grow into. */
  promisedGB: number;
  marginGB: number;
  /** What a new (or a bigger) disk can still add. */
  availableGB: number;
  /** This VM's disk: its size and what its file takes today. */
  sizeGB: number | null;
  usedGB: number | null;
  /** The most this VM's disk (or a new one) can measure. */
  maxGB: number;
  others: { vm: string; promisedGB: number }[];
}

export interface Sample {
  cpu: number;
  gpu: number;
  mem: number;
}

/** Get-GpuVMImportInfo: what a .gpuvm file holds. */
export interface ImportInfo { path: string; name: string | null; freeName: string; edition: string | null; user: string | null; installedApps: string[]; exportedAt: string | null; diskGB: number; fileGB: number; freeGB: number }

// --- Agents (docs/agents/protocol.md) ---

/** What an agent's client is doing now. "waiting": a request waits for the person's approval; "human": something only
 *  the person can do (a password, UAC, the lock screen) blocks it; "control": the person took control. */
export type AgentState = "working" | "paused" | "control" | "waiting" | "human" | "idle";

/** One thing the agent did on its machine, newest first in AgentClient.actions. */
export interface AgentAction { id: number; text: string; at: string; method: string; ok: boolean; thumb?: string | null; /** The broker kept its screenshot (Get-GpuVMAgentCapture). */ capture?: boolean }

/** A client connected over MCP (gpuvm.exe --mcp): Claude Code, another MCP client. */
export interface AgentClient {
  id: string;
  name: string;
  version: string | null;
  connectedAt: string;
  /** The machine it works on, or null while it hasn't picked one. */
  machine: string | null;
  state: AgentState;
  /** The task it said it works on (its own words), when it said one. */
  task: string | null;
  /** Why it is paused or waiting, in the app's words. */
  reason: string | null;
  steps: number;
  maxSteps: number;
  minutes: number;
  maxMinutes: number;
  actions: AgentAction[];
  /** Approvals answered from the client itself (MCP elicitation): off unless the person turned it on for this one. */
  clientApprovals: boolean;
}

export type AgentRequestKind = "deliver" | "admin" | "network" | "revert" | "delete" | "other";

/** Something the agent asked that needs the person's approval (dock + Windows notification). Deliveries don't come
 *  here: they are the pending AgentOffers (the dock shows them as "deliver" requests). */
export interface AgentRequest {
  id: string;
  client: string;
  clientName: string;
  machine: string;
  kind: AgentRequestKind;
  /** What it asks, in the app's words ("Connect to github.com"). */
  title: string;
  /** The agent's reason, in its own words. */
  reason: string | null;
  createdAt: string;
  /** Refused by itself at this time. */
  expiresAt: string;
  /** A delivery: the file waiting in the machine's Outbox. */
  file?: { name: string; sizeBytes: number } | null;
  /** "human": only the person can do it in the viewer (no buttons). */
  human?: boolean;
}

/** A file an agent offered from the machine's Outbox (Desktop\Outbox). Only metadata: it's never opened here. */
export interface AgentOffer {
  id: string;
  machine: string;
  client: string;
  clientName: string;
  name: string;
  sizeBytes: number;
  note: string | null;
  createdAt: string;
  /** copying: accepted, the broker is copying it to Downloads. */
  state: "pending" | "copying" | "accepted" | "refused" | "expired" | "failed";
  /** Where an accepted file went (Downloads\GpuVM\<machine>). */
  savedTo?: string | null;
  /** Why it failed (the copy to Downloads), when state is "failed". */
  error?: string | null;
}

/** A recording of an agent's work on a machine (in Videos\GpuVM\<machine>). */
export interface AgentRecording { machine: string; client: string; clientName: string; path: string; name: string; durationMs: number; bytes: number; at: string }

/** Get-GpuVMRestorePoint: a machine's restore points, oldest first. */
export interface RestorePoint { id: string; label: string | null; createdAt: string; sizeGB: number | null; missing: boolean; current: boolean }
export interface RestorePointList { points: RestorePoint[]; max: number; changesGB: number | null; restoredFrom: { id: string; at: string } | null }
