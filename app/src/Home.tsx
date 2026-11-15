import { memo, useEffect, useRef, useState } from "react";
import {
  IconApps, IconArrowRight, IconBolt, IconCpu, IconDatabase, IconDeviceGamepad2, IconDisc, IconDownload, IconExternalLink, IconKey,
  IconLayoutGrid, IconLink, IconLoader2, IconPlayerPlay, IconPlus, IconStack2, IconTemplate, IconTopologyStar3,
} from "@tabler/icons-react";
import type { HomeInfo, VmOverview } from "./types";
import type { JobInfo } from "./VmView";
import { api } from "./api";
import { MachineIcon } from "./machineIcon";
import { MachineCube, cubeOf, type CubeMachine } from "./MachineCube";
import { randomDecor, randomMachine } from "./decor/random";
import { Scene, sceneStyle } from "./Scene";
import { formatUptime, stateLabel, useFlip, useScrollFade } from "./ui";

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

const ROW_KEY = "gpuvm.home.rowHeight", PANEL_KEY = "gpuvm.home.panelWidth", LIB_KEY = "gpuvm.home.libraryWidth", ATT_KEY = "gpuvm.home.attentionWidth";
// The row's lowest height still shows a machine card whole (its banner, name and button) and the Library's counts.
const ROW_DEFAULT = 230, ROW_MIN = 214, PANEL_DEFAULT = 320, PANEL_MIN = 260, PANEL_MAX = 460;
const LIB_DEFAULT = 280, LIB_MIN = 230, LIB_MAX = 420, ATT_DEFAULT = 360, ATT_MIN = 300, ATT_MAX = 520;
const clamp = (n: number, a: number, b: number) => Math.min(b, Math.max(a, n));
const readSize = (key: string, fallback: number) => { try { return Number(localStorage.getItem(key)) || fallback; } catch { return fallback; } };
const saveSize = (key: string, n: number) => { try { localStorage.setItem(key, String(Math.round(n))); } catch { /* no storage */ } };

const gb = (n: number) => `${n.toLocaleString("es", { maximumFractionDigits: 1 })} GB`;

/** Renders `render()` again only when `sig` changes. */
const Memo = memo(({ render }: { sig: string; render: () => React.ReactNode }) => <>{render()}</>, (a, b) => a.sig === b.sig);

/** Home while it loads: the stage and the row under it, with their real shape. */
export function HomeSkeleton() {
  return (
    <div className="main home" aria-busy="true">
      <div className="skeleton home-stage" style={{ marginBottom: 16 }} />
      <div className="home-row with-attention">
        <div className="skeleton" style={{ height: 200 }} />
        <div className="skeleton" style={{ height: 200 }} />
        <div className="skeleton" style={{ height: 200 }} />
      </div>
    </div>
  );
}

/** Home: the space of machines up front, with the one in use (or the last one opened) in its cube and, beside it, how
 *  much it is using and its actions; below, the other machines, what needs attention and the Library at a glance. */
export function Home({ vms, busyFor, startJob, onOpenVm, onRoute, onCreate }: Props) {
  const [home, setHome] = useState<HomeInfo | null>(cache);
  const [library, setLibrary] = useState(libraryCache);
  const [heroApps, setHeroApps] = useState<string[]>([]);
  const rowRef = useFlip<HTMLDivElement>();
  // The stage and the row under it, and the stage's side panel, change size by dragging the line between them (as the
  // sidebar's edge does), within limits; a double click goes back to the default. Remembered.
  const mainRef = useRef<HTMLDivElement>(null);
  const [rowH, setRowH] = useState(() => readSize(ROW_KEY, ROW_DEFAULT));
  const [panelW, setPanelW] = useState(() => readSize(PANEL_KEY, PANEL_DEFAULT));
  const [libW, setLibW] = useState(() => readSize(LIB_KEY, LIB_DEFAULT));
  const [attW, setAttW] = useState(() => readSize(ATT_KEY, ATT_DEFAULT));
  const [dragging, setDragging] = useState<"row" | "panel" | "lib" | "att" | null>(null);
  const drag = (kind: "row" | "panel" | "lib" | "att") => (e: React.PointerEvent<HTMLDivElement>) => {
    const target = e.currentTarget, start = { x: e.clientX, y: e.clientY, row: rowH, panel: panelW, lib: libW, att: attW };
    target.setPointerCapture(e.pointerId);
    setDragging(kind);
    const mainH = mainRef.current?.clientHeight ?? 800;
    const move = (ev: PointerEvent) => {
      if (kind === "row") setRowH(clamp(start.row - (ev.clientY - start.y), ROW_MIN, Math.max(ROW_MIN, mainH * 0.5)));
      else if (kind === "panel") setPanelW(clamp(start.panel - (ev.clientX - start.x), PANEL_MIN, PANEL_MAX));
      // The lines in the row: left of the Library it trades width with the machines; left of the notices, with the Library.
      else if (kind === "lib") setLibW(clamp(start.lib - (ev.clientX - start.x), LIB_MIN, LIB_MAX));
      else setAttW(clamp(start.att - (ev.clientX - start.x), ATT_MIN, ATT_MAX));
    };
    const up = () => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", up);
      target.removeEventListener("pointercancel", up);
      setDragging(null);
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", up);
    target.addEventListener("pointercancel", up);
  };
  useEffect(() => { if (!dragging) { saveSize(ROW_KEY, rowH); saveSize(PANEL_KEY, panelW); saveSize(LIB_KEY, libW); saveSize(ATT_KEY, attW); } }, [dragging, rowH, panelW, libW, attW]);
  const [othersRef, othersFade] = useScrollFade<HTMLDivElement>("x");
  const [othersEl, setOthersEl] = useState<HTMLDivElement | null>(null);
  useEffect(() => {
    const el = othersEl;
    if (!el) return;
    const wheel = (e: WheelEvent) => {
      if (el.scrollWidth <= el.clientWidth || Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
      e.preventDefault();
      el.scrollBy({ left: e.deltaY, behavior: "auto" });
    };
    el.addEventListener("wheel", wheel, { passive: false });
    return () => el.removeEventListener("wheel", wheel);
  }, [othersEl]);
  // Refreshed with the machines' state (the app polls it) and after any job.
  const states = vms.map((v) => `${v.name}:${v.state}`).join(",");
  const jobs = vms.map((v) => busyFor(v.name)?.cmd ?? "").join(",");
  useEffect(() => { api.home().then((h) => { cache = h; setHome(h); }).catch(() => {}); }, [states, jobs]);
  useEffect(() => {
    Promise.all([api.profiles(), api.templates(), api.sharedDisks(), api.isos()])
      .then(([p, t, s, i]) => { libraryCache = { profiles: p.length, templates: t.length, shared: s.length, isos: i.length }; setLibrary(libraryCache); })
      .catch(() => {});
  }, [jobs]);

  // Up front: the machine that is on, or else the last one opened.
  const hero = vms.find((v) => v.state === "Running") ?? (home?.lastOpened ? vms.find((v) => v.name === home.lastOpened!.name) : null) ?? vms[0];
  useEffect(() => {
    if (!hero) return;
    let live = true;
    api.installedApps(hero.name).then((list) => { if (live) setHeroApps(list.map((a) => a.id)); }).catch(() => {});
    return () => { live = false; };
  }, [hero?.name, jobs]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!home) return <HomeSkeleton />;

  const others = vms.filter((v) => v !== hero);
  const memUsed = home.host.memoryTotalGB - home.host.memoryFreeGB;
  const fits = home.machines.filter((m) => m.state === "Off" && m.fits).map((m) => m.name);
  const short = home.machines.filter((m) => m.state === "Off" && !m.fits);
  // Named one by one while it is short; with many machines, counted, so the panel never turns into a list.
  const memoryHint = fits.length + short.length > 3
    ? [fits.length && `${fits.length === 1 ? "Cabe 1 máquina" : `Caben ${fits.length} máquinas`} más.`, short.length && `${short.length === 1 ? "1 necesita" : `${short.length} necesitan`} más memoria libre.`].filter(Boolean).join(" ")
    : (fits.length ? `Cabe ${fits.join(", ")}.` : short.length ? "" : "Todas están encendidas.")
      + short.map((m) => ` ${m.name} necesita ${gb(Math.max(0, m.needGB - home.host.memoryFreeGB))} más.`).join("");

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

  // How much the machine in front is using: processor, memory and GPU, each in its resource color.
  const running = hero?.state === "Running";
  const meters = hero ? [
    { cls: "res-cpu", icon: <IconCpu size={15} />, label: "Procesador", value: running ? `${hero.cpuPercent} %` : `${hero.options?.cpu ?? hero.processorCount} hilos`, pct: running ? hero.cpuPercent : 0 },
    { cls: "res-mem", icon: <IconTopologyStar3 size={15} />, label: "Memoria", value: running ? `${gb(hero.memoryDemandGB)} de ${gb(hero.memoryAssignedGB)}` : gb(hero.memoryStartupGB),
      pct: running ? (hero.memoryDemandGB / Math.max(hero.memoryAssignedGB, 0.1)) * 100 : 0 },
    { cls: "res-gpu", icon: <IconBolt size={15} />, label: "GPU", value: !hero.hasGpu ? "Sin GPU" : running ? `${hero.gpuPercent} %` : `${hero.options?.gpuPercent ?? 100} % asignada`, pct: running && hero.hasGpu ? hero.gpuPercent : 0 },
  ] : [];

  return (
    <div ref={mainRef} className={`main home${dragging ? ` dragging-${dragging}` : ""}`}
      style={{ "--row-h": `${rowH}px`, "--panel-w": `${panelW}px`, "--lib-w": `${libW}px`, "--att-w": `${attW}px` } as React.CSSProperties}>
      {hero && (
        <div className="card home-stage">
          <div className="home-space">
            <MachineCube key="home" machine={cubeOf(hero, heroApps)} name={hero.name} others={others.map((v) => ({ name: v.name, machine: cubeOf(v) }))} />
          </div>
          <div className="home-split home-split-panel" role="separator" aria-orientation="vertical" aria-label="Ancho del panel"
            onPointerDown={drag("panel")} onDoubleClick={() => setPanelW(PANEL_DEFAULT)}><span /></div>
          <div className="home-panel">
            <div className="home-hero-name">
              <MachineIcon name={hero.name} size={40} radius={10} />
              <div style={{ minWidth: 0 }}>
                <h1>{hero.name}</h1>
                <div className="meta">
                  <span className="state-pill"><span className={`dot ${hero.state}`} />{stateLabel[hero.state] ?? hero.state}</span>
                  {running && <span>· {formatUptime(hero.uptimeSeconds)}</span>}
                </div>
              </div>
            </div>
            <div className="home-meters">
              {meters.map((x) => (
                <div key={x.label} className="home-meter">
                  <span className={`home-meter-label ${x.cls}`}>{x.icon}{x.label}</span>
                  <strong>{x.value}</strong>
                  <div className={`home-meter-bar ${x.cls}`}><span style={{ width: `${Math.min(100, x.pct)}%` }} /></div>
                </div>
              ))}
            </div>
            <div className="home-memory">
              <span className="home-side-title">Memoria libre para máquinas</span>
              <strong>{gb(home.host.memoryFreeGB)} de {gb(home.host.memoryTotalGB)}</strong>
              <div className="bar"><span style={{ width: `${Math.min(100, (memUsed / home.host.memoryTotalGB) * 100)}%` }} /></div>
              <span className="hint">
                {memoryHint}
              </span>
            </div>
            <div className="home-panel-actions">
              <button className="btn ghost" onClick={() => onOpenVm(hero.name)}>Ver máquina</button>
              {action(hero)}
            </div>
          </div>
        </div>
      )}

      <div className="home-split home-split-row" role="separator" aria-orientation="horizontal" aria-label="Alto de la fila de abajo"
        onPointerDown={drag("row")} onDoubleClick={() => setRowH(ROW_DEFAULT)}><span /></div>

      <div ref={rowRef} className={`home-row${home.attention.length ? " with-attention" : ""}`}>
        {/* Every other machine in one row: they share its width and, when they don't fit, it scrolls sideways. */}
        <div ref={(el) => { othersRef(el); setOthersEl(el); }} className={`home-others ${othersFade}`} style={{ "--count": Math.max(1, others.length) } as React.CSSProperties}>
        {others.map((vm) => {
          // Each card is drawn again only when something it shows changes: with many machines, a refresh that
          // touches one doesn't redraw them all.
          const m = home.machines.find((x) => x.name === vm.name);
          const sig = [vm.name, vm.state, vm.memoryStartupGB, Math.round(vm.cpuPercent / 10), Math.round(vm.gpuPercent / 10), vm.managed, vm.streaming, busyFor(vm.name)?.message ?? "",
            m?.fits, m?.fitGB, m?.needGB, home.host.memoryFreeGB].join("|");
          return <Memo key={vm.id} sig={sig} render={() => (
          <div className="card home-machine">
            <button type="button" className="home-machine-scene" onClick={() => onOpenVm(vm.name)} aria-label={`Ver ${vm.name}`}>
              <Scene name={vm.name} style={sceneStyle(vm.name)} state={vm.state}
                activity={{ cpu: vm.cpuPercent, gpu: vm.gpuPercent, mem: (vm.memoryDemandGB / Math.max(vm.memoryAssignedGB, 0.1)) * 100 }} />
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
          )} />;
        })}
        </div>

        <div className="home-split home-split-col" role="separator" aria-orientation="vertical" aria-label="Ancho de la Biblioteca"
          onPointerDown={drag("lib")} onDoubleClick={() => setLibW(LIB_DEFAULT)}><span /></div>
        <div className="card home-library">
          <div className="home-card-head">
            <span className="home-side-title">Biblioteca</span>
            {/* Creating a machine lives with what it is made from, as a quiet action, not a big tile. */}
            <button type="button" className="btn ghost compact" onClick={onCreate}><IconPlus size={15} />Crear máquina</button>
          </div>
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
          <div className="home-split home-split-col" role="separator" aria-orientation="vertical" aria-label="Ancho de lo pendiente"
            onPointerDown={drag("att")} onDoubleClick={() => setAttW(ATT_DEFAULT)}><span /></div>
        )}
        {home.attention.length > 0 && (
          <div className="card home-attention">
            {home.attention.map((a, i) => {
              const busy = a.vm ? busyFor(a.vm) : null;
              // The job running is this notice's own: its progress goes under the text, the button keeps its size.
              const mine = !!busy && !!a.cmd && busy.cmd === a.cmd;
              const act = () => {
                if (a.cmd && a.vm) startJob(a.vm, a.cmd, a.args ?? {}, () => api.home().then((h) => { cache = h; setHome(h); }).catch(() => {}));
                else if (a.kind === "disk") onRoute(":biblioteca:discos");
                else if (a.vm) onOpenVm(a.vm);
              };
              return (
                <div className="home-attention-row" key={`${a.vm}-${a.kind}-${i}`}>
                  <span className="notice-icon">{ISSUE_ICONS[a.kind] ?? <IconDeviceGamepad2 size={17} />}</span>
                  <div className="home-attention-text">
                    <strong>{a.vm ?? "Equipo"}</strong>
                    <span className={mine ? "home-attention-progress" : ""}>{mine ? busy!.message : a.text}</span>
                  </div>
                  <button className="btn compact" disabled={!!busy} onClick={act}>
                    {mine && <IconLoader2 size={15} className="spin" />}{a.label}
                  </button>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}

/** A machine that doesn't exist yet: the cube with its pieces off, waiting. */
/** With no machines yet, the space shows machines made up at random: a new decoration every few seconds, arriving
 *  with a quick spin. The machine itself stays (changing its pieces would send the camera around them). */
function Showcase() {
  const [machine] = useState<CubeMachine>(randomMachine);
  const [decor, setDecor] = useState(randomDecor);
  useEffect(() => { const t = setInterval(() => setDecor(randomDecor()), 7000); return () => clearInterval(t); }, []);
  return <MachineCube machine={machine} name="" decorShown={decor} />;
}

/** Home with no machines: the same stage, with an empty machine in its cube, and beside it the invitation to create
 *  the first one and what the Library already has ready for it. */
export function EmptyHome({ gpuName, onCreate, onRoute }: { gpuName: string | null; onCreate: () => void; onRoute: (route: string) => void }) {
  const [library, setLibrary] = useState(libraryCache);
  useEffect(() => {
    Promise.all([api.profiles(), api.templates(), api.sharedDisks(), api.isos()])
      .then(([p, t, s, i]) => { libraryCache = { profiles: p.length, templates: t.length, shared: s.length, isos: i.length }; setLibrary(libraryCache); })
      .catch(() => {});
  }, []);
  const ready = [
    { icon: <IconLayoutGrid size={16} />, n: library?.profiles, one: "perfil listo", many: "perfiles listos", route: ":biblioteca:perfiles" },
    { icon: <IconTemplate size={16} />, n: library?.templates, one: "plantilla", many: "plantillas", route: ":biblioteca:plantillas" },
    { icon: <IconDisc size={16} />, n: library?.isos, one: "imagen de Windows", many: "imágenes de Windows", route: ":biblioteca:isos" },
  ].filter((x) => x.n);
  return (
    <div className="main home">
      <div className="card home-stage home-empty">
        <div className="home-space"><Showcase /></div>
        <div className="home-split home-split-panel" aria-hidden="true" />
        <div className="home-panel home-empty-panel">
          <div className="home-empty-text">
            <h1>Crea tu primera máquina</h1>
            <p>Windows 10 u 11 con {gpuName ? `tu ${gpuName.replace("NVIDIA GeForce ", "")}` : "tu GPU"}, lista para abrir con Moonlight en un clic.</p>
          </div>
          {ready.length > 0 && (
            <div className="home-library-grid home-empty-ready">
              {ready.map((x) => (
                <button key={x.route} type="button" className="home-library-item" onClick={() => onRoute(x.route)}>
                  <span className="home-library-icon">{x.icon}</span><strong>{x.n}</strong><span>{x.n === 1 ? x.one : x.many}</span>
                </button>
              ))}
            </div>
          )}
          <div className="home-panel-actions">
            <button className="primary" onClick={onCreate}><IconPlus size={17} />Crear máquina</button>
          </div>
        </div>
      </div>
    </div>
  );
}
