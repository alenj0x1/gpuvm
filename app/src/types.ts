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
  monitor?: string;
}

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

export type MouseMode = "capture" | "absolute";

export interface AdminPrompt {
  name: string;
  id: number;
  app: string | null;
  publisher: string | null;
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
  fits: boolean;
  fitGB: number;
  missingGB: number;
  streaming: boolean;
  paired: boolean;
  guestCredential: boolean;
  disposable?: boolean;
  restorePoints?: number;
  address: string | null;
  agent?: { installed: boolean; connected: boolean; version: string | null; user: "agent" | "own" } | null;
  forAgents?: boolean;
  use?: string | null;
  agentUser?: "agent" | "own" | null;
  client: ClientSettings | null;
  options: { cpu: number; memoryGB: number; gpuPercent: number; diskGB: number; diskType: string; diskFreeGB: number; networkIsolation: boolean; cleanup: CleanupLevelId; diskBudget?: DiskBudget | null } | null;
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

export interface TemplateInfo {
  name: string;
  fromVM: string;
  createdAt: string;
  edition: string | null;
  sizeGB: number;
  fileGB: number;
  cleanup: CleanupLevelId;
  usedBy: string[];
  stale?: boolean;
  updating?: boolean;
}

export interface SharedDiskInfo {
  name: string;
  purpose: "games" | "general";
  sizeGB: number;
  fileGB: number;
  vm: string | null;
  vmRunning: boolean;
  createdAt: string;
}

export interface HomeInfo {
  lastOpened: { name: string; at: string } | null;
  host: { memoryTotalGB: number; memoryFreeGB: number; diskFreeGB: number; topProcesses: { name: string; gb: number }[] };
  machines: { name: string; state: string; memoryGB: number; needGB: number; fits: boolean; fitGB: number }[];
  attention: { vm: string | null; kind: string; text: string; label: string; cmd: string | null; args: Record<string, unknown> | null }[];
}

export type CleanupLevelId = "none" | "privacy" | "apps" | "minimal";

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
  interactiveUninstall?: boolean;
}

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
  disk?: DiskBudget | null;
}

export interface DiskBudget {
  drive: string;
  freeGB: number;
  promisedGB: number;
  marginGB: number;
  availableGB: number;
  sizeGB: number | null;
  usedGB: number | null;
  maxGB: number;
  others: { vm: string; promisedGB: number }[];
}

export interface Sample {
  cpu: number;
  gpu: number;
  mem: number;
}

export interface ImportInfo { path: string; name: string | null; freeName: string; edition: string | null; user: string | null; installedApps: string[]; exportedAt: string | null; diskGB: number; fileGB: number; freeGB: number }

export type AgentState = "working" | "paused" | "control" | "waiting" | "human" | "idle";

export interface AgentAction { id: number; text: string; at: string; method: string; ok: boolean; thumb?: string | null; capture?: boolean }

export interface AgentClient {
  id: string;
  name: string;
  version: string | null;
  connectedAt: string;
  machine: string | null;
  state: AgentState;
  task: string | null;
  reason: string | null;
  steps: number;
  maxSteps: number;
  minutes: number;
  maxMinutes: number;
  actions: AgentAction[];
  clientApprovals: boolean;
}

export type AgentRequestKind = "deliver" | "admin" | "network" | "revert" | "delete" | "send" | "take" | "other";

export interface AgentRequest {
  id: string;
  client: string;
  clientName: string;
  machine: string;
  kind: AgentRequestKind;
  title: string;
  reason: string | null;
  createdAt: string;
  expiresAt: string;
  file?: { name: string; sizeBytes: number } | null;
  send?: { paths: string[]; bytes: number; files: number } | null;
  human?: boolean;
}

/** Only metadata: the file is never opened here. */
export interface AgentOffer {
  id: string;
  machine: string;
  client: string;
  clientName: string;
  name: string;
  sizeBytes: number;
  note: string | null;
  createdAt: string;
  state: "pending" | "copying" | "accepted" | "refused" | "expired" | "failed";
  savedTo?: string | null;
  error?: string | null;
}

export interface AgentHistoryEntry { id: string; client: string; version: string; task: string | null; machines: string[]; start: number; end: number;
  steps: number; runs: number; approvals: number; offers: number; controls: number; ended: "done" | "stopped" | "limit" }

export interface AgentRecording { machine: string; client: string; clientName: string; path: string; name: string; durationMs: number; bytes: number; at: string }

export interface RestorePoint { id: string; label: string | null; createdAt: string; sizeGB: number | null; missing: boolean; current: boolean }
export interface RestorePointList { points: RestorePoint[]; max: number; changesGB: number | null; restoredFrom: { id: string; at: string } | null }
