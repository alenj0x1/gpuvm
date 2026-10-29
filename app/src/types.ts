export type VmState = "Running" | "Off" | "Paused" | "Saved" | "Starting" | "Stopping" | string;

export interface ClientSettings {
  app: string;
  resolution: string;
  fps: number;
  bitrateKbps: number;
  codec: string;
  displayMode?: DisplayMode;
}

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
  address: string | null;
  client: ClientSettings | null;
  options: { cpu: number; memoryGB: number; gpuPercent: number; diskGB: number; diskType: string; diskFreeGB: number; captureMode: "ddx" | "wgc"; networkIsolation: boolean; cleanup: CleanupLevelId } | null;
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
}

export interface Sample {
  cpu: number;
  gpu: number;
  mem: number;
}
