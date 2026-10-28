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
  streaming: boolean;
  paired: boolean;
  guestCredential: boolean;
  address: string | null;
  client: ClientSettings | null;
  options: { cpu: number; memoryGB: number; gpuPercent: number; diskGB: number; diskType: string; diskFreeGB: number; captureMode: "ddx" | "wgc"; networkIsolation: boolean } | null;
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

export interface AppInfo {
  id: string;
  name: string;
  signer: string;
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
