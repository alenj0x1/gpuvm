import { useEffect, useState } from "react";
import {
  IconAlertTriangle, IconApps, IconArrowRight, IconCheck, IconDeviceGamepad2, IconDownload, IconExternalLink, IconKey,
  IconLink, IconLoader2, IconPlayerPlay, IconDatabase,
} from "@tabler/icons-react";
import type { HomeInfo, VmOverview } from "./types";
import type { JobInfo } from "./VmView";
import { api } from "./api";
import { Bauhaus } from "./bauhaus";
import { stateLabel } from "./ui";

interface Props {
  vms: VmOverview[];
  busyFor: (vm: string) => JobInfo | null;
  startJob: (vm: string, cmd: string, args: Record<string, unknown>, after?: () => void) => void;
  onOpenVm: (name: string) => void;
  onRoute: (route: string) => void;
}

// What the home screen last showed, so coming back shows it at once while it refreshes.
let cache: HomeInfo | null = null;

const ISSUE_ICONS: Record<string, React.ReactNode> = {
  driver: <IconDownload size={18} />,
  password: <IconKey size={18} />,
  pairing: <IconLink size={18} />,
  apps: <IconApps size={18} />,
  disk: <IconDatabase size={18} />,
};

function ago(iso: string) {
  const minutes = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
  if (minutes < 1) return "hace un momento";
  if (minutes < 60) return `hace ${minutes} min`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `hace ${hours} h`;
  const days = Math.round(hours / 24);
  return days === 1 ? "ayer" : `hace ${days} días`;
}

const gb = (n: number) => `${n.toLocaleString("es", { maximumFractionDigits: 1 })} GB`;

/** Home: continue with the last machine, what fits in memory right now, and what needs attention. */
export function Home({ vms, busyFor, startJob, onOpenVm, onRoute }: Props) {
  const [home, setHome] = useState<HomeInfo | null>(cache);
  // Refreshed with the machines' state (the app polls it) and after any job.
  const states = vms.map((v) => `${v.name}:${v.state}`).join(",");
  const jobs = vms.map((v) => busyFor(v.name)?.cmd ?? "").join(",");
  useEffect(() => { api.home().then((h) => { cache = h; setHome(h); }).catch(() => {}); }, [states, jobs]);

  if (!home) {
    return (
      <div className="main">
        <div className="skeleton" style={{ height: 120 }} />
        <div className="skeleton" style={{ height: 220 }} />
      </div>
    );
  }

  const last = home.lastOpened ? vms.find((v) => v.name === home.lastOpened!.name) : null;
  const lastBusy = last ? busyFor(last.name) : null;
  const memUsed = home.host.memoryTotalGB - home.host.memoryFreeGB;

  return (
    <div className="main home">
      {last && (
        <div className="card head home-continue">
          <button type="button" className="pattern-btn" onClick={() => onOpenVm(last.name)} aria-label={`Ver ${last.name}`}>
            <Bauhaus name={last.name} size={56} radius={14} />
          </button>
          <div className="grow">
            <h1>{last.name}</h1>
            <div className="meta">
              <span className="state-pill"><span className={`dot ${last.state}`} />{stateLabel[last.state] ?? last.state}</span>
              <span>· Abierta {ago(home.lastOpened!.at)}</span>
            </div>
          </div>
          <div className="actions">
            <button className="btn ghost" onClick={() => onOpenVm(last.name)}>Ver máquina<IconArrowRight size={16} /></button>
            {lastBusy ? (
              <span className="primary busy" role="status"><IconLoader2 size={17} className="spin" /><span className="ellipsis">{lastBusy.message}</span></span>
            ) : (
              <button className="primary" onClick={() => startJob(last.name, "Connect-GpuVM", { Name: last.name })}>
                {last.state === "Running" ? <IconExternalLink size={17} /> : <IconPlayerPlay size={17} />}
                <span className="ellipsis">{last.state === "Running" ? "Abrir" : "Encender y abrir"}</span>
              </button>
            )}
          </div>
        </div>
      )}

      <div className="card">
        <div className="home-memory">
          <div className="field-top"><span>Memoria</span><strong>{gb(home.host.memoryFreeGB)} libres de {gb(home.host.memoryTotalGB)}</strong></div>
          <div className="bar"><span style={{ width: `${Math.min(100, (memUsed / home.host.memoryTotalGB) * 100)}%` }} /></div>
          {home.host.topProcesses.length > 0 && (
            <span className="hint">Lo que más usa: {home.host.topProcesses.map((p) => `${p.name} ${gb(p.gb)}`).join(" · ")}</span>
          )}
        </div>
        <div className="rows">
          {home.machines.map((m) => {
            const running = m.state !== "Off";
            const missing = Math.max(0, m.needGB - home.host.memoryFreeGB);
            const vm = vms.find((v) => v.name === m.name);
            const busy = busyFor(m.name);
            // Opens with the memory that does fit, as on the machine's own page.
            const smaller = !running && !m.fits && !!vm?.managed && !!vm.streaming && m.fitGB >= 4 && m.fitGB < m.memoryGB;
            return (
              <div className="row row-link" key={m.name} role="link" tabIndex={0} onClick={() => onOpenVm(m.name)}
                onKeyDown={(e) => { if (e.key === "Enter") onOpenVm(m.name); }}>
                <Bauhaus name={m.name} size={32} radius={9} />
                <div className="row-text">
                  <strong>{m.name}</strong>
                  <span>{gb(m.memoryGB)} de memoria</span>
                </div>
                <span className={`fit ${running ? "on" : m.fits ? "ok" : "no"}`}>
                  {busy ? <><IconLoader2 size={15} className="spin" />{busy.message}</>
                    : running ? <><span className={`dot ${m.state}`} />{stateLabel[m.state] ?? m.state}</>
                    : m.fits ? <><IconCheck size={15} />Puede encender</>
                    : <><IconAlertTriangle size={15} />Faltan {gb(missing)}</>}
                </span>
                {smaller && !busy && (
                  <button className="btn" onClick={(e) => { e.stopPropagation(); startJob(m.name, "Connect-GpuVM", { Name: m.name, MemoryGB: m.fitGB }); }}
                    title={`Usa ${m.fitGB} GB de memoria en vez de ${gb(m.memoryGB)}; puedes volver a subirla en Opciones`}>
                    <IconPlayerPlay size={16} />Abrir con {m.fitGB} GB
                  </button>
                )}
              </div>
            );
          })}
        </div>
      </div>

      {home.attention.length > 0 && (
        <div className="card">
          <div className="rows">
            {home.attention.map((a, i) => {
              const busy = a.vm ? busyFor(a.vm) : null;
              const act = () => {
                if (a.cmd && a.vm) startJob(a.vm, a.cmd, a.args ?? {}, () => api.home().then((h) => { cache = h; setHome(h); }).catch(() => {}));
                else if (a.kind === "disk") onRoute(":biblioteca:discos");
                else if (a.vm) onOpenVm(a.vm);
              };
              return (
                <div className="row" key={`${a.vm}-${a.kind}-${i}`}>
                  <span className="row-icon">{ISSUE_ICONS[a.kind] ?? <IconDeviceGamepad2 size={18} />}</span>
                  <div className="row-text">
                    <strong>{a.vm ?? "Equipo"}</strong>
                    <span>{a.text}</span>
                  </div>
                  <div className="row-actions">
                    <button className="btn" disabled={!!busy} onClick={act}>
                      {busy ? <IconLoader2 size={16} className="spin" /> : null}{busy ? busy.message : a.label}
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
