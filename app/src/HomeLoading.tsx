import { MiniCube, type MiniMachine } from "./MiniCube";
import type { VmOverview } from "./types";

const SAMPLE: MiniMachine = { cores: 8, memoryGB: 16, gpuPercent: 60, diskGB: 256, apps: 2 };

function miniOf(vm: VmOverview): MiniMachine {
  return {
    cores: vm.options?.cpu ?? vm.processorCount,
    memoryGB: vm.options?.memoryGB ?? vm.memoryStartupGB,
    gpuPercent: vm.hasGpu ? vm.options?.gpuPercent ?? 0 : 0,
    diskGB: vm.options?.diskGB ?? 0,
    apps: 0,
  };
}

/** Home while its data loads: a constellation of the machines themselves (their cubes, with their pieces) around the
 *  first one, each coming in and floating on an orbit, until Home arrives and takes their place. Without the list yet,
 *  faint machines wait in their places. */
export function HomeLoading({ vms }: { vms?: VmOverview[] | null }) {
  const list = (vms ?? []).slice(0, 9);
  const center = list[0] ?? null;
  const around = list.length > 1 ? list.slice(1) : Array.from({ length: 5 }, () => null);
  return (
    <div className="main home home-loading" aria-busy="true">
      <div className="home-loading-field">
        <svg className="home-loading-orbit" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
          <ellipse cx={50} cy={50} rx={38} ry={35} />
        </svg>
        <div className="home-loading-core">
          <MiniCube machine={center ? miniOf(center) : SAMPLE} ghost={!center || center.state !== "Running"} />
        </div>
        {around.map((vm, i) => {
          const a = -Math.PI / 2 + (i / around.length) * Math.PI * 2 + 0.4;
          return (
            <div key={vm?.name ?? i} className="home-loading-machine"
              style={{ left: `${50 + Math.cos(a) * 38}%`, top: `${50 + Math.sin(a) * 35}%`, animationDelay: `${0.15 + i * 0.12}s, ${i * 0.6}s` }}>
              <MiniCube machine={vm ? miniOf(vm) : SAMPLE} ghost={!vm || vm.state !== "Running"} />
            </div>
          );
        })}
      </div>
    </div>
  );
}
