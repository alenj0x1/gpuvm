import { MiniCube, type MiniMachine } from "./MiniCube";
import { Tips } from "./Tips";
import type { VmOverview } from "./types";

const SAMPLE: MiniMachine = { cores: 8, memoryGB: 16, gpuPercent: 60, diskGB: 256, apps: 2 };

export function miniOf(vm: VmOverview): MiniMachine {
  return {
    cores: vm.options?.cpu ?? vm.processorCount,
    memoryGB: vm.options?.memoryGB ?? vm.memoryStartupGB,
    gpuPercent: vm.hasGpu ? vm.options?.gpuPercent ?? 0 : 0,
    diskGB: vm.options?.diskGB ?? 0,
    apps: 0,
  };
}

/** Home while its data loads: a constellation of the machines themselves (their cubes, with their pieces) around the
 *  first one, joined to it by lines where light travels (the host's GPU feeding them), and a tip underneath. Without
 *  the list yet, faint machines wait in their places. */
export function HomeLoading({ vms }: { vms?: VmOverview[] | null }) {
  const list = (vms ?? []).slice(0, 9);
  const center = list[0] ?? null;
  const around = list.length > 1 ? list.slice(1) : Array.from({ length: 5 }, () => null);
  const spots = around.map((_, i) => {
    const a = -Math.PI / 2 + (i / around.length) * Math.PI * 2 + 0.4;
    return { x: 50 + Math.cos(a) * 38, y: 50 + Math.sin(a) * 35 };
  });
  return (
    <div className="main home home-loading" aria-busy="true">
      <div className="home-loading-field">
        <svg className="home-loading-links" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
          {spots.map((p, i) => (
            <g key={i} style={{ animationDelay: `${0.2 + i * 0.12}s` }}>
              <line className="rail" x1={50} y1={50} x2={p.x} y2={p.y} />
              <line className="flow" pathLength={100} x1={50} y1={50} x2={p.x} y2={p.y} style={{ animationDelay: `${i * 0.37}s` }} />
            </g>
          ))}
        </svg>
        <div className="home-loading-core">
          <MiniCube machine={center ? miniOf(center) : SAMPLE} ghost={!center || center.state !== "Running"} />
        </div>
        {around.map((vm, i) => (
          <div key={vm?.name ?? i} className="home-loading-machine"
            style={{ left: `${spots[i].x}%`, top: `${spots[i].y}%`, animationDelay: `${0.15 + i * 0.12}s, ${i * 0.6}s` }}>
            <MiniCube machine={vm ? miniOf(vm) : SAMPLE} ghost={!vm || vm.state !== "Running"} />
          </div>
        ))}
      </div>
      <Tips className="home-loading-tips" />
    </div>
  );
}
