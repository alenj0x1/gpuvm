import { useEffect, useState } from "react";
import {
  IconApps, IconArrowRight, IconDatabase, IconDeviceGamepad2, IconDisc, IconDownload, IconExternalLink, IconKey, IconLayoutGrid,
  IconLink, IconLoader2, IconPlayerPlay, IconPlus, IconStack2, IconTemplate,
} from "@tabler/icons-react";
import type { HomeInfo, VmOverview } from "./types";
import type { JobInfo } from "./VmView";
import { api } from "./api";
import { MachineIcon } from "./machineIcon";
import { Scene, sceneStyle } from "./Scene";
import { formatUptime, stateLabel } from "./ui";

interface Props {
  vms: VmOverview[];
  busyFor: (vm: string) => JobInfo | null;
  startJob: (vm: string, cmd: string, args: Record<string, unknown>, after?: () => void) => void;
  onOpenVm: (name: string) => void;
  onRoute: (route: string) => void;
  onCreate: () => void;
}

// What the home screen last showed, so coming back shows it at once while it refreshes.
let cache: HomeInfo | null = null;
let libraryCache: { profiles: number; templates: number; shared: number; isos: number } | null = null;

const ISSUE_ICONS: Record<string, React.ReactNode> = {
  driver: <IconDownload size={17} />,
  password: <IconKey size={17} />,
  pairing: <IconLink size={17} />,
  apps: <IconApps size={17} />,
  disk: <IconDatabase size={17} />,
};

const gb = (n: number) => `${n.toLocaleString("es", { maximumFractionDigits: 1 })} GB`;
const usage = (vm: VmOverview) => ({ cpu: vm.cpuPercent, gpu: vm.gpuPercent, mem: (vm.memoryDemandGB / Math.max(vm.memoryAssignedGB, 0.1)) * 100 });

/** Home: the machine in use (or the last one opened) up front, every other machine below, and on the side what fits
 *  in memory, the Library at a glance and what needs attention. */
export function Home({ vms, busyFor, startJob, onOpenVm, onRoute, onCreate }: Props) {
  const [home, setHome] = useState<HomeInfo | null>(cache);
  const [library, setLibrary] = useState(libraryCache);
  // Refreshed with the machines' state (the app polls it) and after any job.
  const states = vms.map((v) => `${v.name}:${v.state}`).join(",");
  const jobs = vms.map((v) => busyFor(v.name)?.cmd ?? "").join(",");
  useEffect(() => { api.home().then((h) => { cache = h; setHome(h); }).catch(() => {}); }, [states, jobs]);
  useEffect(() => {
    Promise.all([api.profiles(), api.templates(), api.sharedDisks(), api.isos()])
      .then(([p, t, s, i]) => { libraryCache = { profiles: p.length, templates: t.length, shared: s.length, isos: i.length }; setLibrary(libraryCache); })
      .catch(() => {});
  }, [jobs]);

  if (!home) {
    return (
      <div className="main">
        <div className="skeleton" style={{ height: 200 }} />
        <div className="skeleton" style={{ height: 160 }} />
      </div>
    );
  }

  // Up front: the machine that is on, or else the last one opened.
  const hero = vms.find((v) => v.state === "Running") ?? (home.lastOpened ? vms.find((v) => v.name === home.lastOpened!.name) : null) ?? vms[0];
  const others = vms.filter((v) => v !== hero);
  const fits = home.machines.filter((m) => m.state === "Off" && m.fits).map((m) => m.name);
  const short = home.machines.filter((m) => m.state === "Off" && !m.fits);
  const memUsed = home.host.memoryTotalGB - home.host.memoryFreeGB;

  const action = (vm: VmOverview, compact = false) => {
    const busy = busyFor(vm.name);
    if (busy) return <span className={`primary busy${compact ? " compact" : ""}`} role="status"><IconLoader2 size={16} className="spin" /><span className="ellipsis">{busy.message}</span></span>;
    const m = home.machines.find((x) => x.name === vm.name);
    const off = vm.state === "Off";
    if (off && m && !m.fits) {
      return m.fitGB >= 4 && m.fitGB < m.memoryGB && vm.managed && vm.streaming
        ? <button className="btn" onClick={() => startJob(vm.name, "Connect-GpuVM", { Name: vm.name, MemoryGB: m.fitGB })}><IconPlayerPlay size={15} />Abrir con {m.fitGB} GB</button>
        : <span className="home-short">Faltan {gb(Math.max(0, m.needGB - home.host.memoryFreeGB))}</span>;
    }
    if (!vm.managed || !vm.streaming) return <button className="btn ghost" onClick={() => onOpenVm(vm.name)}>Ver<IconArrowRight size={15} /></button>;
    return (
      <button className={compact ? "btn" : "primary"} onClick={() => startJob(vm.name, "Connect-GpuVM", { Name: vm.name })}>
        {vm.state === "Running" ? <IconExternalLink size={16} /> : <IconPlayerPlay size={16} />}
        <span className="ellipsis">{vm.state === "Running" ? "Abrir" : compact ? "Encender" : "Encender y abrir"}</span>
      </button>
    );
  };

  return (
    <div className="main home">
      <div className="home-grid">
        <div className="home-main">
          {hero && (
            <div className="card home-hero">
              <button type="button" className="home-hero-scene" onClick={() => onOpenVm(hero.name)} aria-label={`Ver ${hero.name}`}>
                <Scene name={hero.name} style={sceneStyle(hero.name)} state={hero.state} activity={usage(hero)} />
              </button>
              <div className="home-hero-info">
                <div className="home-hero-name">
                  <MachineIcon name={hero.name} size={40} radius={10} />
                  <div style={{ minWidth: 0 }}>
                    <h1>{hero.name}</h1>
                    <div className="meta">
                      <span className="state-pill"><span className={`dot ${hero.state}`} />{stateLabel[hero.state] ?? hero.state}</span>
                      {hero.state === "Running" && hero.hasGpu && <span>· GPU {hero.gpuPercent} %</span>}
                      {hero.state === "Running" && <span>· {formatUptime(hero.uptimeSeconds)}</span>}
                    </div>
                  </div>
                </div>
                <div className="home-hero-actions">
                  {action(hero)}
                  <button className="btn ghost" onClick={() => onOpenVm(hero.name)}>Ver máquina<IconArrowRight size={15} /></button>
                </div>
              </div>
            </div>
          )}

          <div className="home-machines">
            {others.map((vm) => (
              <div key={vm.id} className="card home-machine">
                <button type="button" className="home-machine-scene" onClick={() => onOpenVm(vm.name)} aria-label={`Ver ${vm.name}`}>
                  <Scene name={vm.name} style={sceneStyle(vm.name)} state={vm.state} activity={usage(vm)} />
                </button>
                <div className="home-machine-row">
                  <MachineIcon name={vm.name} size={30} radius={8} />
                  <button type="button" className="home-machine-text" onClick={() => onOpenVm(vm.name)}>
                    <strong>{vm.name}</strong>
                    <span><span className={`dot ${vm.state}`} />{stateLabel[vm.state] ?? vm.state} · {gb(vm.memoryStartupGB)}</span>
                  </button>
                  {action(vm, true)}
                </div>
              </div>
            ))}
            <button type="button" className="card home-machine home-create" onClick={onCreate}>
              <IconPlus size={18} />Crear máquina
            </button>
          </div>
        </div>

        <aside className="home-side">
          <div className="card home-memory">
            <span className="home-side-title">Memoria libre para máquinas</span>
            <strong>{gb(home.host.memoryFreeGB)} de {gb(home.host.memoryTotalGB)}</strong>
            <div className="bar"><span style={{ width: `${Math.min(100, (memUsed / home.host.memoryTotalGB) * 100)}%` }} /></div>
            <span className="hint">
              {fits.length ? `Cabe ${fits.join(", ")}.` : short.length ? "" : "Todas están encendidas."}
              {short.map((m) => ` ${m.name} necesita ${gb(Math.max(0, m.needGB - home.host.memoryFreeGB))} más.`).join("")}
            </span>
            {home.host.topProcesses.length > 0 && (
              <span className="hint">Lo que más usa: {home.host.topProcesses.map((p) => `${p.name} ${gb(p.gb)}`).join(" · ")}</span>
            )}
          </div>

          <div className="card home-library">
            <span className="home-side-title">Biblioteca</span>
            <div className="home-library-grid">
              {[
                { icon: <IconLayoutGrid size={16} />, n: library?.profiles, label: "Perfiles", route: ":biblioteca:perfiles" },
                { icon: <IconTemplate size={16} />, n: library?.templates, label: "Plantillas", route: ":biblioteca:plantillas" },
                { icon: <IconStack2 size={16} />, n: library?.shared, label: "Discos compartidos", route: ":biblioteca:compartidos" },
                { icon: <IconDisc size={16} />, n: library?.isos, label: "ISOs", route: ":biblioteca:isos" },
              ].map((x) => (
                <button key={x.label} type="button" className="home-library-item" onClick={() => onRoute(x.route)}>
                  <span className="home-library-icon">{x.icon}</span>
                  <strong>{x.n ?? "—"}</strong>
                  <span>{x.label}</span>
                </button>
              ))}
            </div>
          </div>

          {home.attention.length > 0 && (
            <div className="card home-attention">
              {home.attention.map((a, i) => {
                const busy = a.vm ? busyFor(a.vm) : null;
                const act = () => {
                  if (a.cmd && a.vm) startJob(a.vm, a.cmd, a.args ?? {}, () => api.home().then((h) => { cache = h; setHome(h); }).catch(() => {}));
                  else if (a.kind === "disk") onRoute(":biblioteca:discos");
                  else if (a.vm) onOpenVm(a.vm);
                };
                return (
                  <div className="home-attention-row" key={`${a.vm}-${a.kind}-${i}`}>
                    <span className="opt-icon">{ISSUE_ICONS[a.kind] ?? <IconDeviceGamepad2 size={17} />}</span>
                    <div className="opt-text">
                      <span className="opt-title">{a.vm ?? "Equipo"}</span>
                      <span className="opt-desc">{a.text}</span>
                      <button className="btn" disabled={!!busy} onClick={act}>
                        {busy ? <IconLoader2 size={16} className="spin" /> : null}{busy ? busy.message : a.label}
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </aside>
      </div>
    </div>
  );
}
