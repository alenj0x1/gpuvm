export type VmState = "Running" | "Off" | "Paused" | "Saved" | "Starting" | "Stopping" | string;

export interface ClientSettings {
  app: string;
  resolution: string;
  fps: number;
  bitrateKbps: number;
  codec: string;
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
  options: { cpu: number; memoryGB: number; gpuPercent: number } | null;
}

export interface IsoFile {
  path: string;
  name: string;
  sizeGB: number;
  modified: string;
}

export interface ProfileInfo {
  Name: string;
  Extends: string | null;
  Description: string;
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
