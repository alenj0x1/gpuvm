import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  IconAdjustments, IconAlertTriangle, IconAppWindow, IconApps, IconArrowsMaximize, IconBolt, IconCheck, IconChevronRight, IconClipboardText, IconClock, IconCpu, IconDeviceDesktop, IconDeviceFloppy, IconDeviceGamepad2, IconDots, IconDownload, IconExternalLink, IconFolders, IconGauge, IconKey, IconLayoutBoard, IconLayoutGrid, IconLink, IconList, IconLoader2, IconNetwork, IconPalette, IconPlayerPause, IconPlayerPlay, IconPlayerTrackNext, IconPlugConnected, IconPlugOff, IconPointFilled, IconPointer, IconPower, IconRectangle, IconRefresh, IconRefreshAlert, IconScreenShare, IconSearch, IconShieldCheck, IconSparkles, IconTemplate, IconTopologyStar3, IconTrash, IconWaveSine, IconWorld,
} from "@tabler/icons-react";
import type { AppInfo, CleanupLevelId, DiskBudget, SharedDiskInfo, DisplayMode, HostInfo, MouseMode, Sample, StreamSettings, VmOverview } from "./types";
import { usePrefs } from "./prefs";
import { AppLogo, FpsPicker, MonitorPicker, resolveMonitor, useMonitors, CODECS, RESOLUTIONS, USES, streamUseOf, useCleanupLevels } from "./pickers";
import { MachineIcon, patternClick, patternVariant, setPatternVariant } from "./machineIcon";
import { Scene, nextSceneStyle, sceneStyle } from "./Scene";
import { CLEANUP_LOOK, CleanupFlow, LEVEL_LOOK } from "./CleanupFlow";
import { Sparkline, series } from "./Chart";
import { CheckMark, Dropdown, Segmented, Slider, formatUptime, stateLabel, useScrollFade } from "./ui";
import { api, openConsole } from "./api";

export interface JobInfo {
  cmd: string;
  message: string;
  log: string[];
}

interface Props {
  vm: VmOverview;
  host: HostInfo | null;
  samples: Sample[];
  /** Long job or power action in progress for this VM. */
  busy: JobInfo | null;
  startJob: (vm: string, cmd: string, args: Record<string, unknown>, after?: () => void) => void;
  run: (vm: string, label: string, task: () => Promise<unknown>) => Promise<boolean>;
  onRemoved: () => void;
}

const TRANSITION: Record<string, string> = { Starting: "Encendiendo", Stopping: "Apagando", Saving: "Guardando", Pausing: "Pausando", Resuming: "Reanudando" };

type VmTab = "machine" | "display" | "windows";
const TAB_LABEL: Record<VmTab, string> = { machine: "Máquina", display: "Imagen y control", windows: "Windows" };

export function VmView({ vm, host, samples, busy, startJob, run, onRemoved }: Props) {
  const [variant, setVariant] = useState(() => patternVariant(vm.name));
  const running = vm.state === "Running";
  const off = vm.state === "Off";
  const tabs: VmTab[] = [];
  if (vm.managed && vm.options) tabs.push("machine");
  if (vm.managed && vm.options && vm.streaming) tabs.push("display");
  if (vm.managed && vm.guestCredential) tabs.push("windows");
  // Every section is on the same page; the bar above them marks the one in view and takes you to the others.
  const mainRef = useRef<HTMLDivElement>(null);
  const sectionRefs = useRef<Partial<Record<VmTab, HTMLElement | null>>>({});
  const [active, setActive] = useState<VmTab | undefined>(tabs[0]);
  const tabKey = tabs.join(",");
  useEffect(() => {
    const main = mainRef.current;
    if (!main) return;
    const spy = () => {
      const list = tabKey.split(",").filter(Boolean) as VmTab[];
      const nav = main.querySelector<HTMLElement>(".section-nav");
      const line = main.getBoundingClientRect().top + (nav?.offsetHeight ?? 0) + 48;
      let current = list[0];
      for (const t of list) {
        const el = sectionRefs.current[t];
        if (el && el.getBoundingClientRect().top <= line) current = t;
      }
      // At the very bottom the last section is the one in view, however short it is.
      if (main.scrollHeight > main.clientHeight + 4 && main.scrollTop + main.clientHeight >= main.scrollHeight - 4) current = list[list.length - 1];
      setActive(current);
    };
    spy();
    main.addEventListener("scroll", spy, { passive: true });
    return () => main.removeEventListener("scroll", spy);
  }, [tabKey, vm.name]);
  const goTo = (t: VmTab) => {
    const main = mainRef.current, el = sectionRefs.current[t];
    if (!main || !el) return;
    const nav = main.querySelector<HTMLElement>(".section-nav")?.offsetHeight ?? 0;
    const top = main.scrollTop + el.getBoundingClientRect().top - main.getBoundingClientRect().top - nav - 12;
    main.scrollTo({ top: Math.max(0, top), behavior: "smooth" });
  };

  return (
    <div className="main" ref={mainRef}>
      <Header vm={vm} busy={busy} variant={variant} startJob={startJob} run={run} onRemoved={onRemoved}
        onPattern={() => {
          // The third quick click switches every pattern's palette; the two before it are undone.
          const v = patternClick() ? Math.max(0, variant - 2) : variant + 1;
          setPatternVariant(vm.name, v);
          setVariant(v);
          window.dispatchEvent(new Event("gpuvm-pattern"));
        }} />

      {vm.managed && !vm.guestCredential && <GuestPassword vm={vm} run={run} />}
      {vm.managed && vm.driverInSync === false && (
        <div className="notice">
          <IconRefreshAlert size={20} />
          <div className="grow">El driver de NVIDIA de la VM es distinto al de tu PC. Se actualiza solo la próxima vez que la enciendas desde aquí.</div>
          {!busy && (
            <button className="btn" onClick={() => startJob(vm.name, "Sync-GpuVMDriver", { Name: vm.name, Confirm: false, ShutdownIfRunning: true })}>
              <IconDownload size={16} />{off ? "Actualizar ahora" : "Apagar y actualizar"}
            </button>
          )}
        </div>
      )}

      <div className="card stats">
        <Stat icon={<IconCpu size={15} />} label="Procesador" value={`${vm.processorCount} hilos`}
          sub={running ? `${vm.cpuPercent} % en uso` : "Sin uso"} spark={running ? series(samples, (s) => s.cpu) : []} color="var(--chart-cpu)" />
        <Stat icon={<IconTopologyStar3 size={15} />} label="Memoria" value={`${vm.memoryStartupGB} GB`}
          sub={running ? `${vm.memoryDemandGB} GB en uso` : "Fija al encender"}
          spark={running ? series(samples, (s) => (s.mem / Math.max(vm.memoryAssignedGB, 0.1)) * 100) : []} color="var(--chart-mem)" />
        <Stat icon={<IconBolt size={15} />} label="GPU"
          value={vm.hasGpu ? (running ? `${vm.gpuPercent} %` : `${vm.options?.gpuPercent ?? 100} % asignada`) : "Sin GPU"}
          sub={vm.gpuName ?? "Solo gráficos básicos"} spark={running && vm.hasGpu ? series(samples, (s) => s.gpu) : []} color="var(--chart-gpu)" />
        <Stat icon={<IconClock size={15} />} label="Tiempo encendida" value={running ? formatUptime(vm.uptimeSeconds) : "—"}
          sub={running ? (vm.address ?? "Esperando red") : "Sin red"} />
      </div>

      {tabs.length > 1 && (
        <nav className="section-nav" role="tablist">
          {tabs.map((t) => (
            <button key={t} type="button" role="tab" aria-selected={t === active} className={t === active ? "on" : ""} onClick={() => goTo(t)}>{TAB_LABEL[t]}</button>
          ))}
        </nav>
      )}
      {tabs.includes("machine") && (
        <section className="vm-section" ref={(el) => { sectionRefs.current.machine = el; }}>
          <Options part="machine" vm={vm} host={host} busy={busy} startJob={startJob} run={run} />
          <SharedDisks vm={vm} busy={busy} startJob={startJob} />
        </section>
      )}
      {tabs.includes("display") && (
        <section className="vm-section" ref={(el) => { sectionRefs.current.display = el; }}>
          <Options part="display" vm={vm} host={host} busy={busy} startJob={startJob} run={run} />
        </section>
      )}
      {tabs.includes("windows") && (
        <section className="vm-section" ref={(el) => { sectionRefs.current.windows = el; }}>
          {vm.options && <Cleanup vm={vm} busy={busy} startJob={startJob} />}
          <Apps vm={vm} busy={busy} startJob={startJob} />
        </section>
      )}
    </div>
  );
}

/** Shared disks: attach one to this machine or take it away, also while it runs. Hidden until a disk exists. */
export function SharedDisks({ vm, busy, startJob }: Pick<Props, "vm" | "busy" | "startJob">) {
  const [disks, setDisks] = useState<SharedDiskInfo[]>([]);
  const load = () => api.sharedDisks().then(setDisks).catch(() => {});
  useEffect(() => { load(); }, [vm.name, vm.state, busy?.cmd]);
  if (!disks.length) return null;
  const working = busy?.cmd === "Connect-GpuVMSharedDisk" || busy?.cmd === "Disconnect-GpuVMSharedDisk";
  const gb = (n: number) => `${n.toLocaleString("es", { maximumFractionDigits: 1 })} GB`;
  return (
    <div className="card">
      <div className="opt-rows">
        {disks.map((d) => {
          const here = d.vm === vm.name;
          // Another running machine has it: it has to be taken away there first.
          const elsewhere = !!d.vm && !here;
          const state = here ? "Conectado" : elsewhere ? `En ${d.vm}` : "Libre";
          return (
            <div className="opt-row disk-row" key={d.name}>
              <span className="opt-icon">{d.purpose === "games" ? <IconDeviceGamepad2 size={17} /> : <IconFolders size={17} />}</span>
              <div className="opt-text">
                <span className="opt-title">{d.name}
                  <span className={`disk-state${here ? " here" : elsewhere ? " away" : ""}`}><i />{state}</span>
                </span>
                {/* What a shared disk is, said plainly: its name alone ("juegos") doesn't tell. */}
                <span className="opt-desc">{d.purpose === "games"
                  ? `Disco compartido de ${gb(d.sizeGB)} para juegos. Se instalan una sola vez y se conecta a la máquina que los necesite.`
                  : `Disco compartido de ${gb(d.sizeGB)}. Tus archivos, en la máquina que lo conecte.`}</span>
                <div className="disk-use" title={`Ocupa ${gb(d.fileGB)} en tu PC`}>
                  <div className="disk-use-bar"><span style={{ width: `${Math.min(100, (d.fileGB / Math.max(d.sizeGB, 1)) * 100)}%` }} /></div>
                  <span>{gb(d.fileGB)} de {gb(d.sizeGB)}</span>
                </div>
              </div>
              <div className="opt-ctl">
                {here ? (
                  <button className="btn" disabled={!!busy} onClick={() => startJob(vm.name, "Disconnect-GpuVMSharedDisk", { Name: d.name }, load)}>
                    {working ? <IconLoader2 size={16} className="spin" /> : <IconPlugOff size={16} />}{working ? busy!.message : "Desconectar"}
                  </button>
                ) : (
                  <button className="btn" disabled={!!busy || (elsewhere && d.vmRunning)} onClick={() => startJob(vm.name, "Connect-GpuVMSharedDisk", { Name: d.name, VMName: vm.name }, load)}
                    title={elsewhere && d.vmRunning ? `Desconéctalo en ${d.vm} o apágala para traerlo` : undefined}>
                    <IconPlugConnected size={16} />{elsewhere ? `Traer desde ${d.vm}` : "Conectar"}
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// What each cleanup level is about, in a few words; what it does comes from the module, item by item.

/** Windows cleanup: the levels as cards (each includes the ones before it), what the chosen one does, and Aplicar
 *  only when a different level is chosen. */
export function Cleanup({ vm, busy, startJob }: Pick<Props, "vm" | "busy" | "startJob">) {
  const levels = useCleanupLevels();
  const current = vm.options?.cleanup ?? "none";
  const [chosen, setChosen] = useState<CleanupLevelId>(current);
  useEffect(() => setChosen(current), [vm.name, current]);
  if (!levels.length) return null;
  const applying = busy?.cmd === "Set-GpuVMCleanup";
  const rank = Math.max(0, levels.findIndex((l) => l.id === chosen));
  const items = levels.slice(0, rank + 1).flatMap((l) => l.items);
  const all = levels.flatMap((l) => l.items);
  const removedIds = new Set(items.map((i) => i.id));
  return (
    <div className="card">
      <div className="opt-rows">
        <OptionRow icon={<IconSparkles size={17} />} title="Limpieza de Windows" desc="Cada nivel incluye lo de los anteriores.">
          {(chosen !== current || applying) && (
            <button className="btn" disabled={!!busy} onClick={() => startJob(vm.name, "Set-GpuVMCleanup", { Name: vm.name, Level: chosen })}>
              {applying ? <IconLoader2 size={16} className="spin" /> : <IconSparkles size={16} />}
              {applying ? busy!.message : vm.state === "Off" ? "Encender y aplicar" : "Aplicar"}
            </button>
          )}
        </OptionRow>
      </div>
      <div className="cleanup-body">
        <div className="level-list" role="radiogroup" aria-label="Nivel de limpieza">
          {levels.map((l) => (
            <button key={l.id} type="button" role="radio" aria-checked={l.id === chosen} className={`level-row${l.id === chosen ? " on" : ""}`}
              onClick={() => setChosen(l.id)}>
              <span className="level-icon">{LEVEL_LOOK[l.id]?.icon ?? <IconSparkles size={18} />}</span>
              <span className="level-text"><span className="level-name">{l.name}</span><span className="level-tagline">{LEVEL_LOOK[l.id]?.tagline ?? ""}</span></span>
              {l.id === current && <span className="level-applied"><IconCheck size={12} />Aplicado</span>}
            </button>
          ))}
        </div>
        <CleanupFlow items={all.map((i) => i.id)} removed={removedIds} />
        {/* Everything Windows comes with that a level can take away: what the chosen level removes has a check, what
            stays has a dot, so even Normal shows what is there. */}
        <ul className="cleanup-items">
          {all.map((i) => {
            const drop = removedIds.has(i.id);
            const look = CLEANUP_LOOK[i.id];
            return <li key={i.id} className={drop ? "drop" : "keep"} title={i.description}>
              {drop ? <IconCheck size={14} /> : <IconPointFilled size={14} />}
              <span><span className="ci-name">{look?.name ?? i.description}</span>{look && <span className="ci-line">{look.line}</span>}</span>
            </li>;
          })}
        </ul>
      </div>
      <p className="levels-safe"><IconShieldCheck size={14} />Microsoft Defender, Windows Update, SmartScreen y el firewall nunca se tocan.</p>
    </div>
  );
}

const APP_JOBS = ["Install-GpuVMApp", "Uninstall-GpuVMApp"];
type AppsView = "tiles" | "list";
const APPS_VIEW_KEY = "gpuvm.appsView";
const fold = (s: string) => s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

/** Apps of a machine: the installed ones on top (each with its menu), then the catalog as tiles to pick several
 *  and install them together, or as a list with each app's own action. The chosen view is remembered. */
export function Apps({ vm, busy, startJob }: Pick<Props, "vm" | "busy" | "startJob">) {
  const [catalog, setCatalog] = useState<AppInfo[]>([]);
  const [chosen, setChosen] = useState<string[]>([]);
  const [installed, setInstalled] = useState<string[]>([]);
  const [uninstalling, setUninstalling] = useState<AppInfo | null>(null);
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState("all");
  const [view, setView] = useState<AppsView>(() => { try { return (localStorage.getItem(APPS_VIEW_KEY) as AppsView) || "tiles"; } catch { return "tiles"; } });
  const [menu, setMenu] = useState<{ app: AppInfo; x: number; y: number } | null>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  // The catalog keeps a set height and scrolls inside, fading where it continues, so the page doesn't grow with it.
  const [listRef, listFade] = useScrollFade<HTMLDivElement>();
  useEffect(() => { try { localStorage.setItem(APPS_VIEW_KEY, view); } catch { /* no storage */ } }, [view]);
  useEffect(() => { api.apps().then(setCatalog).catch(() => {}); }, []);
  // Checked again when the machine turns on and after every job (an install, a template, a cleanup) ends.
  const idle = !busy;
  useEffect(() => {
    if (!idle) return;
    let live = true;
    api.installedApps(vm.name).then((list) => {
      if (!live) return;
      const ids = list.map((a) => a.id);
      setInstalled(ids);
      setChosen((c) => c.filter((id) => !ids.includes(id)));
    }).catch(() => {});
    return () => { live = false; };
  }, [vm.name, vm.state, idle]);
  useEffect(() => {
    if (!menu) return;
    const close = (e: PointerEvent) => { if (!menuRef.current?.contains(e.target as Node)) setMenu(null); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setMenu(null); };
    const away = () => setMenu(null);
    window.addEventListener("pointerdown", close, true);
    window.addEventListener("keydown", key);
    window.addEventListener("scroll", away, true);
    return () => { window.removeEventListener("pointerdown", close, true); window.removeEventListener("keydown", key); window.removeEventListener("scroll", away, true); };
  }, [menu]);
  if (!catalog.length) return null;

  const working = !!busy && APP_JOBS.includes(busy.cmd);
  const install = (ids: string[], after?: () => void) => startJob(vm.name, "Install-GpuVMApp", { Name: vm.name, App: ids }, after);
  const reinstall = (app: AppInfo) => startJob(vm.name, "Install-GpuVMApp", { Name: vm.name, App: [app.id], Reinstall: true });
  const openMenu = (app: AppInfo, target: HTMLElement) => {
    const box = target.getBoundingClientRect();
    const y = box.bottom + 6 + 96 > window.innerHeight ? box.top - 96 - 6 : box.bottom + 6;
    setMenu({ app, x: Math.min(box.right - 200, window.innerWidth - 208), y });
  };
  const categories = [...new Map(catalog.map((a) => [a.category, a.categoryName ?? a.category])).entries()];
  const q = fold(query.trim());
  // The catalog shows every app of the category, the installed ones too (marked, not installable again).
  const available = catalog
    .filter((a) => (q ? fold(`${a.name} ${a.categoryName ?? ""}`).includes(q) : category === "all" || a.category === category));
  const mine = catalog.filter((a) => installed.includes(a.id));
  const mineShown = q ? mine.filter((a) => fold(`${a.name} ${a.categoryName ?? ""}`).includes(q)) : mine;
  const toggle = (id: string) => setChosen((c) => (c.includes(id) ? c.filter((x) => x !== id) : [...c, id]));

  return (
    <div className="card apps-card">
      <div className="opt-rows">
        <OptionRow icon={<IconApps size={17} />} title="Apps" desc="Desde su fuente oficial, verificadas antes de instalarse.">
          <Segmented<AppsView> value={view} onChange={setView} options={[
            { value: "tiles", label: <><IconLayoutGrid size={15} />Mosaico</> },
            { value: "list", label: <><IconList size={15} />Lista</> },
          ]} />
        </OptionRow>
      </div>

      <div className="apps-layout">
        {/* Left: the catalog, by category; it renews with a short animation whenever the category or view changes. */}
        <div className="apps-catalog">
          <Segmented value={category} onChange={setCategory} options={[{ value: "all", label: "Todas" }, ...categories.map(([id, name]) => ({ value: id, label: name }))]} />
          {available.length === 0 ? (
            <p className="app-none">{`Ninguna app se llama «${query.trim()}»`}</p>
          ) : view === "tiles" ? (
            <div key={`${category}-${q}`} ref={listRef} className={`app-tiles app-scroll appear ${listFade}`} role="group" aria-label="Apps para instalar">
              {available.map((a, n) => {
                const on = chosen.includes(a.id);
                const has = installed.includes(a.id);
                return (
                  <button key={a.id} type="button" role="checkbox" aria-checked={on} className={`app-tile${on ? " on" : ""}${has ? " has" : ""}`} disabled={!!busy || has}
                    onClick={() => toggle(a.id)} style={{ "--n": n } as React.CSSProperties}>
                    {on && <span className="app-tile-check"><IconCheck size={12} stroke={2.4} /></span>}
                    <span className="app-tile-logo"><AppLogo id={a.id} /></span>
                    <span className="app-tile-name">{a.name}</span>
                    {has ? <span className="app-installed"><IconCheck size={12} />Instalada</span> : <span className="app-tile-cat">{a.categoryName}</span>}
                  </button>
                );
              })}
            </div>
          ) : (
            <div key={`${category}-${q}`} ref={listRef} className={`app-rows app-scroll appear ${listFade}`}>
              {available.map((a, n) => (
                <div key={a.id} className="app-row" style={{ "--n": n } as React.CSSProperties}>
                  <span className="app-row-logo"><AppLogo id={a.id} /></span>
                  <span className="app-row-text"><strong>{a.name}</strong><span>{a.categoryName}</span></span>
                  {installed.includes(a.id) ? <span className="app-installed"><IconCheck size={14} />Instalada</span> : (
                    <button type="button" className="btn" disabled={!!busy} onClick={() => install([a.id])}>
                      <IconDownload size={15} />{vm.state === "Off" ? "Encender e instalar" : "Instalar"}
                    </button>
                  )}
                </div>
              ))}
            </div>
          )}
          {/* The tiles' selection: what is chosen and the one button that installs it. */}
          {view === "tiles" && (chosen.length > 0 || working) && (
            <div className="apps-selection">
              <span>{working ? busy!.message : `${chosen.length} ${chosen.length === 1 ? "app elegida" : "apps elegidas"}`}</span>
              {!working && <button type="button" className="btn ghost" onClick={() => setChosen([])}>Quitar</button>}
              <button type="button" className="primary compact" disabled={!!busy} onClick={() => install(chosen, () => setChosen([]))}>
                {working ? <IconLoader2 size={16} className="spin" /> : <IconDownload size={16} />}
                {vm.state === "Off" ? "Encender e instalar" : "Instalar"}
              </button>
            </div>
          )}
        </div>

        {/* Right: the search (it looks through both sides) and what this machine already has. */}
        <div className="apps-mine">
          <label className="search-box">
            <IconSearch size={16} />
            <input className="text-input" placeholder="Buscar" value={query} onChange={(e) => setQuery(e.target.value)} />
          </label>
          <span className="apps-mine-title">En esta máquina</span>
          {mineShown.length ? (
            <div className="apps-mine-list">
              {mineShown.map((a) => (
                <div key={a.id} className="app-row mine" onContextMenu={(e) => { e.preventDefault(); if (!busy) openMenu(a, e.currentTarget); }}>
                  <span className="app-row-logo"><AppLogo id={a.id} /></span>
                  <span className="app-row-text"><strong>{a.name}</strong><span>{a.categoryName}</span></span>
                  <button type="button" className="icon-btn" aria-label={`Opciones de ${a.name}`} disabled={!!busy}
                    onClick={(e) => (menu?.app.id === a.id ? setMenu(null) : openMenu(a, e.currentTarget))}><IconDots size={15} /></button>
                </div>
              ))}
            </div>
          ) : (
            <div className="empty-small">
              <span className="empty-small-icon">{q ? <IconSearch size={18} /> : <IconApps size={18} />}</span>
              <strong>{q ? "Ninguna con ese nombre" : "Sin apps instaladas"}</strong>
            </div>
          )}
        </div>
      </div>

      {menu && createPortal(
        <div ref={menuRef} className="menu floating" role="menu" style={{ left: Math.max(8, menu.x), top: menu.y }}>
          <button role="menuitem" onClick={() => { setMenu(null); reinstall(menu.app); }}><IconRefresh size={16} />Reinstalar</button>
          <button role="menuitem" className="danger" onClick={() => { setMenu(null); setUninstalling(menu.app); }}><IconTrash size={16} />Desinstalar</button>
        </div>,
        document.body,
      )}
      {uninstalling && (
        <ConfirmUninstall vm={vm} app={uninstalling} onClose={() => setUninstalling(null)}
          onConfirm={() => { setUninstalling(null); startJob(vm.name, "Uninstall-GpuVMApp", { Name: vm.name, App: [uninstalling.id], Confirm: false }); }} />
      )}
    </div>
  );
}

function ConfirmUninstall({ vm, app, onClose, onConfirm }: { vm: VmOverview; app: AppInfo; onClose: () => void; onConfirm: () => void }) {
  const cancelRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cancelRef.current?.focus();
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);
  // In a portal: inside the card, the overlay would be laid out within it.
  return createPortal(
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog narrow" role="dialog" aria-modal="true" aria-label={`Desinstalar ${app.name}`}>
        <div className="dialog-head"><span className="choice-icon dialog-logo"><AppLogo id={app.id} /></span><h2>Desinstalar {app.name}</h2></div>
        <p className="dialog-text">
          {app.interactiveUninstall
            ? `Su desinstalador se abre en la ventana de ${vm.name}. Termínalo ahí.`
            : `Se quita de ${vm.name} con su propio desinstalador, junto con lo que guarda en su carpeta.`}
          {vm.state === "Off" && " La máquina se enciende para hacerlo."}
        </p>
        <div className="dialog-foot">
          <button ref={cancelRef} className="btn ghost" onClick={onClose}>Cancelar</button>
          <button className="btn danger-fill" onClick={onConfirm}><IconTrash size={16} />Desinstalar</button>
        </div>
      </div>
    </div>,
    document.body,
  );
}

function Stat({ icon, label, value, sub, spark, color }: { icon: React.ReactNode; label: string; value: string; sub: string; spark?: number[]; color?: string }) {
  return (
    <div className="stat">
      <span className="label">{icon}{label}</span>
      <span className="value">{value}</span>
      <span className="sub" title={sub}>{sub}</span>
      {/* The line's room is kept even without data, so the strip never changes height. */}
      <div className="spark-room">{spark && color && <Sparkline values={spark} color={color} />}</div>
    </div>
  );
}

interface HeaderProps extends Omit<Props, "samples" | "host"> {
  variant: number;
  onPattern: () => void;
}

function Header({ vm, busy, variant, startJob, run, onRemoved, onPattern }: HeaderProps) {
  const [menu, setMenu] = useState(false);
  const [confirmOff, setConfirmOff] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const [templating, setTemplating] = useState(false);
  const [pasting, setPasting] = useState<"busy" | "done" | null>(null);
  const [banner, setBanner] = useState(() => sceneStyle(vm.name));
  useEffect(() => setBanner(sceneStyle(vm.name)), [vm.name]);
  const menuRef = useRef<HTMLDivElement>(null);
  const running = vm.state === "Running";
  const paused = vm.state === "Paused";
  const off = vm.state === "Off";
  const transition = TRANSITION[vm.state];
  const working = busy?.message ?? (transition ? `${transition}…` : null);

  useEffect(() => {
    if (!menu) { setConfirmOff(false); return; }
    const close = (e: MouseEvent) => { if (!menuRef.current?.contains(e.target as Node)) setMenu(false); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setMenu(false); };
    window.addEventListener("mousedown", close);
    window.addEventListener("keydown", key);
    return () => { window.removeEventListener("mousedown", close); window.removeEventListener("keydown", key); };
  }, [menu]);

  const power = (action: string, label: string) => {
    setMenu(false);
    run(vm.name, label, () => api.power(vm.name, action));
  };
  const job = (cmd: string, args: Record<string, unknown>) => { setMenu(false); startJob(vm.name, cmd, args); };

  let primary: { label: string; icon: React.ReactNode; onClick: () => void; disabled?: boolean; title?: string };
  // Off and doesn't fit in the free memory as configured: said before the click, with a way out.
  const short = off && !vm.fits;
  if (paused) primary = { label: "Reanudar", icon: <IconPlayerPlay size={17} />, onClick: () => power("Resume", "Reanudando") };
  else if (short && vm.managed && vm.streaming && vm.fitGB >= 4 && vm.fitGB < vm.memoryStartupGB) {
    // Opens with what does fit; it is saved, like changing it in Options.
    primary = { label: `Abrir con ${vm.fitGB} GB`, icon: <IconPlayerPlay size={17} />, onClick: () => job("Connect-GpuVM", { Name: vm.name, MemoryGB: vm.fitGB }),
      title: `Usa ${vm.fitGB} GB de memoria en vez de ${vm.memoryStartupGB} GB; puedes volver a subirla en Opciones` };
  } else if (short) {
    primary = { label: "Falta memoria", icon: <IconAlertTriangle size={17} />, onClick: () => {}, disabled: true, title: "Cierra programas en este equipo para encenderla" };
  } else if (vm.managed && vm.streaming) {
    primary = running
      ? { label: "Abrir", icon: <IconExternalLink size={17} />, onClick: () => job("Connect-GpuVM", { Name: vm.name }) }
      : { label: "Encender y abrir", icon: <IconPlayerPlay size={17} />, onClick: () => job("Connect-GpuVM", { Name: vm.name }) };
  } else {
    primary = running
      ? { label: "Ver consola", icon: <IconDeviceDesktop size={17} />, onClick: () => openConsole(vm.name) }
      : { label: "Encender", icon: <IconPlayerPlay size={17} />, onClick: () => power("Start", "Encendiendo") };
  }
  const consoleIsPrimary = !vm.streaming && running;
  const locked = !!working;

  return (
    <div className="card head scene-head">
      <div className="scene-wrap"><Scene name={vm.name} variant={variant} style={banner} state={vm.state}
        activity={{ cpu: vm.cpuPercent, gpu: vm.gpuPercent, mem: (vm.memoryDemandGB / Math.max(vm.memoryAssignedGB, 0.1)) * 100 }} /></div>
      <div className="head-info">
      <button type="button" className="pattern-btn" title="Otro ícono" aria-label="Otro ícono" onClick={onPattern}>
        <MachineIcon name={vm.name} variant={variant} size={48} radius={12} />
      </button>
      <div style={{ minWidth: 0 }}>
        <h1>{vm.name}</h1>
        <div className="meta">
          <span className="state-pill"><span className={`dot ${vm.state}`} />{stateLabel[vm.state] ?? vm.state}</span>
          {[vm.edition, vm.gpuName && vm.hasGpu ? vm.gpuName.replace("NVIDIA GeForce ", "") : null, vm.profile].filter(Boolean).map((t) => (
            <span key={t as string}>· {t}</span>
          ))}
          {short && <span className="warn-text">· Le faltan {vm.missingGB.toLocaleString("es")} GB de memoria libre</span>}
        </div>
      </div>
      </div>
      <div className="actions" ref={menuRef}>
        {running && vm.managed && vm.guestCredential && (
          <button className="icon-btn" aria-label="Pegar en la VM" title="Pegar en la VM lo copiado en este equipo" disabled={pasting === "busy"}
            onClick={async () => {
              setPasting("busy");
              const ok = await run(vm.name, "Pegando", () => api.pasteToVm(vm.name));
              setPasting(ok ? "done" : null);
              if (ok) setTimeout(() => setPasting(null), 2000);
            }}>
            {pasting === "busy" ? <IconLoader2 size={18} className="spin" /> : pasting === "done" ? <IconCheck size={18} /> : <IconClipboardText size={18} />}
          </button>
        )}
        <button className="icon-btn" aria-label="Más opciones" aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu((m) => !m)}><IconDots size={18} /></button>
        {working ? (
          <span className="primary busy" role="status" title={working}><IconLoader2 size={17} className="spin" /><span className="ellipsis">{working}</span></span>
        ) : (
          <button className="primary" onClick={primary.onClick} disabled={primary.disabled} title={primary.title}>{primary.icon}<span className="ellipsis">{primary.label}</span></button>
        )}
        {menu && (
          <div className="menu" role="menu">
            {!locked && off && vm.streaming && (
              <button role="menuitem" onClick={() => power("Start", "Encendiendo")}><IconPower size={16} />Encender sin abrir</button>
            )}
            {!locked && !off && (
              <>
                <button role="menuitem" onClick={() => job("Invoke-GpuVMPower", { Name: vm.name, Action: "Shutdown" })}><IconPower size={16} />Apagar</button>
                <button role="menuitem" className={confirmOff ? "danger" : ""}
                  onClick={() => confirmOff ? power("TurnOff", "Forzando el apagado") : setConfirmOff(true)}>
                  <IconPlugOff size={16} />{confirmOff ? "Forzar: se pierde lo no guardado" : "Forzar apagado"}
                </button>
                <button role="menuitem" onClick={() => power("Restart", "Reiniciando")}><IconRefresh size={16} />Reiniciar</button>
                {paused
                  ? <button role="menuitem" onClick={() => power("Resume", "Reanudando")}><IconPlayerPlay size={16} />Reanudar</button>
                  : <button role="menuitem" onClick={() => power("Pause", "Pausando")}><IconPlayerPause size={16} />Pausar</button>}
              </>
            )}
            {locked && vm.state !== "Off" && (
              <button role="menuitem" className={confirmOff ? "danger" : ""}
                onClick={() => confirmOff ? power("TurnOff", "Forzando el apagado") : setConfirmOff(true)}>
                <IconPlugOff size={16} />{confirmOff ? "Forzar: se pierde lo no guardado" : "Forzar apagado"}
              </button>
            )}
            {!consoleIsPrimary && (
              <button role="menuitem" onClick={() => { setMenu(false); openConsole(vm.name); }}><IconDeviceDesktop size={16} />Ver consola de Hyper-V</button>
            )}
            {!locked && vm.managed && vm.streaming && (
              <button role="menuitem" onClick={() => job("Connect-GpuVM", { Name: vm.name, Pair: true })}><IconLink size={16} />Volver a emparejar Moonlight</button>
            )}
            <hr />
            {!locked && vm.managed && (
              <button role="menuitem" onClick={() => job("Sync-GpuVMDriver", { Name: vm.name, Confirm: false, ShutdownIfRunning: true })}>
                <IconDownload size={16} />{off ? "Actualizar driver de la GPU" : "Apagar y actualizar driver"}
              </button>
            )}
            {!locked && vm.managed && (
              <button role="menuitem" onClick={() => { setMenu(false); setTemplating(true); }}>
                <IconTemplate size={16} />{off ? "Crear plantilla" : "Apagar y crear plantilla"}
              </button>
            )}
            <button role="menuitem" onClick={() => { setMenu(false); onPattern(); }}><IconPalette size={16} />Otro ícono</button>
            <button role="menuitem" onClick={() => { setMenu(false); setBanner(nextSceneStyle(vm.name)); }}><IconLayoutBoard size={16} />Otro banner</button>
            {!locked && vm.managed && (
              <>
                <hr />
                <button role="menuitem" className="danger" onClick={() => { setMenu(false); setConfirm(true); }}><IconTrash size={16} />Eliminar máquina</button>
              </>
            )}
          </div>
        )}
      </div>
      {confirm && <ConfirmRemove vm={vm} run={run} onClose={() => setConfirm(false)} onRemoved={onRemoved} />}
      {templating && (
        <NewTemplate vm={vm} onClose={() => setTemplating(false)}
          onCreate={(name, from) => { setTemplating(false); startJob(from, "New-GpuVMTemplate", { Name: name, VMName: from, ShutdownIfRunning: true, Confirm: false }); }} />
      )}
    </div>
  );
}

/** Names the template; the copy itself runs as a job on the machine (its button shows the progress). */
/** Save a machine's Windows as a template. From a machine's menu it is that machine; from the Library, `vms` lists the
 *  machines to pick from. */
export function NewTemplate({ vm: fixed, vms, onClose, onCreate }: {
  vm?: VmOverview; vms?: VmOverview[]; onClose: () => void; onCreate: (name: string, vm: string) => void;
}) {
  const [picked, setPicked] = useState<string>(fixed?.name ?? vms?.[0]?.name ?? "");
  const vm = fixed ?? vms?.find((v) => v.name === picked) ?? null;
  const [name, setName] = useState(`${fixed?.name ?? vms?.[0]?.name ?? "maquina"}-base`);
  const [named, setNamed] = useState(false);
  useEffect(() => { if (!named && vm) setName(`${vm.name}-base`); }, [vm?.name]);
  const [existing, setExisting] = useState<string[]>([]);
  useEffect(() => { api.templates().then((t) => setExisting(t.map((x) => x.name))).catch(() => {}); }, []);
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);
  const trimmed = name.trim();
  const nameError = !trimmed ? "" : !/^[\w-]{1,40}$/.test(trimmed) ? "Usa letras, números o guiones, sin espacios"
    : existing.some((x) => x.toLowerCase() === trimmed.toLowerCase()) ? "Ya hay una plantilla con ese nombre" : "";
  const complete = !!trimmed && !nameError && !!vm;
  const running = !!vm && vm.state !== "Off";
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog narrow" role="dialog" aria-modal="true" aria-label="Crear plantilla">
        <div className="dialog-head"><MachineIcon name={`plantilla-${trimmed || vm?.name || "nueva"}`} size={40} radius={10} /><h2>Crear plantilla</h2></div>
        <form className="dialog-form" onSubmit={(e) => { e.preventDefault(); if (complete && vm) onCreate(trimmed, vm.name); }}>
          <div className="dialog-body">
            {!fixed && (
              <div className="field">
                <div className="field-top"><span>Máquina</span></div>
                {vms && vms.length ? (
                  <Dropdown label="Máquina" value={picked} onChange={setPicked}
                    options={vms.map((v) => ({ value: v.name, label: v.name, detail: [v.edition, stateLabel[v.state] ?? v.state].filter(Boolean).join(" · "), icon: <MachineIcon name={v.name} size={22} radius={6} /> }))} />
                ) : <span className="hint">Primero crea una máquina: la plantilla guarda su Windows.</span>}
              </div>
            )}
            {vm && <p className="dialog-text">Guarda el Windows de {vm.name}, con sus apps y ajustes, para crear otras máquinas en segundos. {vm.name} sigue igual.</p>}
            <div className="field">
              <label className="field-top" htmlFor="tpl-name"><span>Nombre</span></label>
              <input id="tpl-name" className="text-input" value={name} autoFocus onChange={(e) => { setName(e.target.value); setNamed(true); }} />
              {nameError && <span className="error-text">{nameError}</span>}
            </div>
          </div>
          <div className="dialog-foot">
            <button type="button" className="btn ghost" onClick={onClose}>Cancelar</button>
            <button type="submit" className="primary compact" disabled={!complete}><IconTemplate size={16} />{running ? "Apagar y crear" : "Crear plantilla"}</button>
          </div>
        </form>
      </div>
    </div>
  );
}

function ConfirmRemove({ vm, run, onClose, onRemoved }: { vm: VmOverview; run: Props["run"]; onClose: () => void; onRemoved: () => void }) {
  const [deleteDisk, setDeleteDisk] = useState(false);
  const cancelRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cancelRef.current?.focus();
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog narrow" role="dialog" aria-modal="true" aria-label={`Eliminar ${vm.name}`}>
        <div className="dialog-head"><MachineIcon name={vm.name} size={40} radius={10} /><h2>Eliminar {vm.name}</h2></div>
        <p className="dialog-text">La máquina se quita de Hyper-V. Esto no se puede deshacer.</p>
        <div className="choice-list" role="radiogroup">
          <button role="radio" aria-checked={!deleteDisk} className={`choice ${!deleteDisk ? "on" : ""}`} onClick={() => setDeleteDisk(false)}>
            <span className="check">{!deleteDisk && <CheckMark />}</span>
            <span className="grow"><span className="title">Conservar el disco</span><span className="desc">Puedes volver a usar el archivo .vhdx después.</span></span>
          </button>
          <button role="radio" aria-checked={deleteDisk} className={`choice ${deleteDisk ? "on" : ""}`} onClick={() => setDeleteDisk(true)}>
            <span className="check">{deleteDisk && <CheckMark />}</span>
            <span className="grow"><span className="title">Borrar también el disco</span><span className="desc">Libera el espacio de la carpeta de la VM.</span></span>
          </button>
        </div>
        <div className="dialog-foot">
          <button ref={cancelRef} className="btn ghost" onClick={onClose}>Cancelar</button>
          <button className="btn danger-fill" onClick={async () => {
            onClose();
            if (await run(vm.name, "Eliminando", () => api.remove(vm.name, deleteDisk))) onRemoved();
          }}><IconTrash size={16} />Eliminar</button>
        </div>
      </div>
    </div>
  );
}

function GuestPassword({ vm, run }: { vm: VmOverview; run: Props["run"] }) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  return (
    <div className="notice info">
      <IconKey size={20} />
      <div className="grow">
        Guarda la contraseña de Windows de esta máquina para que GpuVM corrija problemas dentro de ella sin preguntarte.
        <span className="notice-sub">Usuario: gpuvm</span>
      </div>
      <form className="notice-form" onSubmit={async (e) => {
        e.preventDefault();
        if (!password) { setError("Escribe la contraseña"); return; }
        setError("");
        setSaving(true);
        await run(vm.name, "Guardando", () => api.saveGuestPassword(vm.name, "gpuvm", password));
        setSaving(false);
      }}>
        <div className="field-stack">
          <input type="password" aria-label="Contraseña de Windows" placeholder="Contraseña de Windows" value={password}
            onChange={(e) => { setPassword(e.target.value); setError(""); }} />
          {error && <span className="error-text">{error}</span>}
        </div>
        <button className="btn" type="submit" disabled={saving}>
          {saving ? <IconLoader2 size={16} className="spin" /> : <IconDeviceFloppy size={16} />}{saving ? "Guardando" : "Guardar"}
        </button>
      </form>
    </div>
  );
}

/** The drive as it would be with this disk at sizeGB and every VM disk full: this machine, what the other machines'
 * disks can still take, and what would be left. Changes as the slider moves. */
export function DiskRoom({ budget, sizeGB }: { budget: DiskBudget; sizeGB: number }) {
  const used = budget.usedGB ?? 0;
  const ownPromised = Math.max(0, sizeGB - used);
  // What the drive has now, split: this VM's file, its unwritten part, the others' unwritten parts, what is left.
  const total = used + budget.freeGB;
  const left = Math.max(0, budget.freeGB - budget.promisedGB - ownPromised);
  const pct = (gb: number) => `${Math.max(0, Math.min(100, (gb / Math.max(1, total)) * 100))}%`;
  const others = budget.others.map((o) => o.vm).join(", ");
  const gb = (n: number) => `${Math.round(n).toLocaleString("es")} GB`;
  return (
    <div className="disk-room">
      <div className="disk-bar" role="img" aria-label={`En ${budget.drive} quedarían ${gb(left)} libres con todos los discos llenos`}>
        <span className="seg own" style={{ width: pct(used) }} />
        <span className="seg own-room" style={{ width: pct(ownPromised) }} />
        <span className="seg others" style={{ width: pct(budget.promisedGB) }} />
      </div>
      <ul className="disk-legend">
        <li><i className="own" />Esta máquina, {gb(used)} usados de {gb(sizeGB)}</li>
        {budget.promisedGB > 0 && <li><i className="others" />Reservado para {others || "otras máquinas"}, {gb(budget.promisedGB)}</li>}
        <li><i className="free" />Libre en {budget.drive} con todo lleno, {gb(left)}</li>
      </ul>
    </div>
  );
}

/** One option: icon, name and a short line that explains it, with its control at the right (or below, `wide`). */
function OptionRow({ icon, title, value, desc, wide, section, sub, below, children }: {
  icon: React.ReactNode; title: string; value?: string; desc: string; wide?: boolean; below?: React.ReactNode; children?: React.ReactNode;
  /** Heads a group whose rows it changes (Tipo de uso); `sub` rows belong to the group above. */
  section?: boolean; sub?: boolean;
}) {
  return (
    <div className={`opt-row${wide ? " wide" : ""}${section ? " section" : ""}${sub ? " sub" : ""}`}>
      <span className="opt-icon">{icon}</span>
      <div className="opt-text">
        <span className="opt-title">{title}{value && <strong>{value}</strong>}</span>
        <span className="opt-desc">{desc}</span>
      </div>
      {children && <div className="opt-ctl">{children}</div>}
      {below && <div className="opt-below">{below}</div>}
    </div>
  );
}

/** The machine's settings, in two parts: "machine" (resources and network) and "display" (use, picture, connection). */
function Options({ part, vm, host, busy, startJob, run }: Pick<Props, "vm" | "host" | "busy" | "startJob" | "run"> & { part: "machine" | "display" }) {
  const initial = {
    cpu: vm.options!.cpu, memoryGB: vm.options!.memoryGB, gpuPercent: vm.options!.gpuPercent, diskGB: vm.options!.diskGB,
    resolution: vm.client?.resolution ?? "1920x1080", fps: vm.client?.fps ?? 60,
    displayMode: (vm.client?.displayMode === "windowed" ? "windowed" : "fullscreen") as DisplayMode,
    // Unset = Moonlight's own defaults.
    vsync: vm.client?.vsync ?? true,
    framePacing: vm.client?.framePacing ?? false,
    mouse: (vm.client?.mouse ?? "capture") as MouseMode,
    codec: vm.client?.codec ?? "auto",
    bitrateKbps: vm.client?.bitrateKbps ?? 0,
    captureMode: vm.options!.captureMode ?? "wgc",
    networkIsolation: vm.options!.networkIsolation ?? true,
    // "default": the monitor chosen in Preferences.
    monitor: vm.client?.monitor ?? "default",
  };
  const [draft, setDraft] = useState(initial);
  const [saved, setSaved] = useState(false);
  const key = JSON.stringify(initial);
  useEffect(() => setDraft(JSON.parse(key)), [key]);
  useEffect(() => { if (!saved) return; const t = setTimeout(() => setSaved(false), 2500); return () => clearTimeout(t); }, [saved]);

  const hostCpu = host?.logicalProcessors ?? 12;
  const hostMem = Math.round(host?.memoryGB ?? 16);
  const maxCpu = Math.max(2, hostCpu - 1);
  const maxMem = Math.max(4, hostMem - 4);
  // A disk only grows, and never past what the drive can hold once every VM disk on it is full (the module checks
  // the same limit). Without the budget (older module), the old rule.
  const budget = vm.options!.diskBudget ?? null;
  const maxDisk = budget ? Math.max(initial.diskGB, Math.floor(budget.maxGB / 8) * 8)
    : Math.max(initial.diskGB, Math.min(1024, initial.diskGB + (vm.options!.diskType === "Fixed" ? vm.options!.diskFreeGB - 10 : 1024)));
  const vmDirty = draft.cpu !== initial.cpu || draft.memoryGB !== initial.memoryGB || draft.gpuPercent !== initial.gpuPercent || draft.diskGB !== initial.diskGB;
  const streamKeys = ["vsync", "framePacing", "mouse", "codec", "bitrateKbps"] as const;
  const streamChanges: StreamSettings = Object.fromEntries(streamKeys.filter((k) => draft[k] !== initial[k]).map((k) => [k, draft[k]]));
  const clientDirty = draft.resolution !== initial.resolution || draft.fps !== initial.fps || draft.displayMode !== initial.displayMode
    || Object.keys(streamChanges).length > 0;
  const use = streamUseOf(draft);
  // "Personalizado" picked by hand stays chosen until a use is picked; a change by hand also lands there.
  const [customUse, setCustomUse] = useState(false);
  const shownUse = customUse ? null : use;
  const [advanced, setAdvanced] = useState(false);
  const captureDirty = draft.captureMode !== initial.captureMode;
  const networkDirty = draft.networkIsolation !== initial.networkIsolation;
  const monitorDirty = draft.monitor !== initial.monitor;
  const monitors = useMonitors();
  const prefs = usePrefs();
  const off = vm.state === "Off";

  const save = async () => {
    if (clientDirty && !(await run(vm.name, "Guardando", () => api.setClient(vm.name, draft.resolution, draft.fps, draft.displayMode !== initial.displayMode ? draft.displayMode : undefined, streamChanges)))) return;
    if (captureDirty && !(await run(vm.name, "Cambiando la captura", () => api.setCapture(vm.name, draft.captureMode)))) return;
    if (networkDirty && !(await run(vm.name, "Cambiando la red", () => api.setNetworkIsolation(vm.name, draft.networkIsolation)))) return;
    if (monitorDirty && !(await run(vm.name, "Guardando", () => api.setMonitor(vm.name, draft.monitor)))) return;
    if (!vmDirty) { setSaved(true); return; }
    const override = {
      vm: { cpu: { count: draft.cpu }, memoryGB: draft.memoryGB, disk: { sizeGB: draft.diskGB } },
      gpu: { allocationPercent: draft.gpuPercent },
    };
    if (off) { if (await run(vm.name, "Aplicando", () => api.applyOptions(vm.name, override))) setSaved(true); }
    else startJob(vm.name, "Update-GpuVMSettings", { Name: vm.name, Override: override });
  };

  return (
    <div className="card">
      <div className="opt-rows">
        {part === "machine" && (
          <>
        <OptionRow icon={<IconCpu size={17} />} title="Procesador" value={`${draft.cpu} hilos`} desc={`Quedan ${hostCpu - draft.cpu} hilos para tu PC`}>
          <Slider label="Hilos" value={Math.min(draft.cpu, maxCpu)} min={2} max={maxCpu} onChange={(cpu) => setDraft({ ...draft, cpu })} />
        </OptionRow>
        <OptionRow icon={<IconTopologyStar3 size={17} />} title="Memoria" value={`${draft.memoryGB} GB`} desc={`Quedan ${hostMem - draft.memoryGB} GB para tu PC, se reserva entera al encender`}>
          <Slider label="Memoria" value={Math.min(draft.memoryGB, maxMem)} min={4} max={maxMem} onChange={(memoryGB) => setDraft({ ...draft, memoryGB })} />
        </OptionRow>
        <OptionRow icon={<IconBolt size={17} />} title="GPU para la VM" value={`${draft.gpuPercent} %`} desc={draft.gpuPercent === 100 ? "Puede usar toda la GPU, tu PC la comparte" : `Hasta el ${draft.gpuPercent} % de la GPU`}>
          <Slider label="GPU" value={draft.gpuPercent} min={10} max={100} step={10} onChange={(gpuPercent) => setDraft({ ...draft, gpuPercent })} />
        </OptionRow>
        <OptionRow icon={<IconDeviceFloppy size={17} />} title="Disco" value={`${draft.diskGB} GB`}
          desc={vm.options!.diskType === "Differencing" ? "Sobre una plantilla, mide lo mismo que ella"
            : maxDisk > initial.diskGB ? "Se puede ampliar, no reducir" : "Sin espacio libre en el equipo para ampliarlo"}
          below={budget && vm.options!.diskType !== "Differencing" ? <DiskRoom budget={budget} sizeGB={draft.diskGB} /> : undefined}>
          {vm.options!.diskType !== "Differencing" && maxDisk > initial.diskGB
            && <Slider label="Disco" value={draft.diskGB} min={initial.diskGB} max={maxDisk} step={8} onChange={(diskGB) => setDraft({ ...draft, diskGB })} />}
        </OptionRow>
        <OptionRow icon={<IconWorld size={17} />} title="Red" desc={draft.networkIsolation
          ? "La VM no llega a este equipo ni a tu red local. Si se infecta, no puede salir de ahí."
          : "La VM llega a este equipo y a los demás de tu red. Úsalo solo si necesitas, por ejemplo, un NAS."}>
          <Segmented value={draft.networkIsolation} onChange={(networkIsolation) => setDraft({ ...draft, networkIsolation })} options={[
            { value: true, label: <><IconWorld size={15} />Solo internet</> },
            { value: false, label: <><IconNetwork size={15} />Internet y red local</> },
          ]} />
        </OptionRow>
          </>
        )}
        {part === "display" && (
          <>
        {vm.streaming && (
          <OptionRow icon={<IconDeviceGamepad2 size={17} />} title="Tipo de uso" section
            desc={shownUse ? USES.find((u) => u.id === shownUse)!.description : "Ajustado a mano. Elige un tipo para volver a sus valores."}>
            <Segmented value={shownUse ?? "custom"} onChange={(id) => {
              if (id === "custom") { setCustomUse(true); return; }
              setCustomUse(false);
              setDraft({ ...draft, ...USES.find((u) => u.id === id)!.client });
            }} options={[...USES.map((u) => ({ value: u.id as string, label: <><u.icon size={15} />{u.label}</> })),
              { value: "custom", label: <><IconAdjustments size={15} />Personalizado</> }]} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow sub icon={<IconGauge size={17} />} title="Cuadros por segundo"
            desc={draft.fps === 0 ? "Siempre al ritmo del monitor donde se abre" : `${draft.fps} FPS fijos`}>
            <FpsPicker value={draft.fps} monitor={resolveMonitor(monitors, draft.monitor, prefs.monitor)} onChange={(fps) => setDraft({ ...draft, fps })} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow sub icon={<IconRectangle size={17} />} title="Sincronización vertical" desc={draft.vsync
            ? "Cada cuadro llega entero al monitor. Al ritmo del monitor no agrega espera."
            : "Cada cuadro sale apenas llega, aunque el monitor esté a mitad de dibujar el anterior."}>
            <Segmented value={draft.vsync} onChange={(vsync) => setDraft({ ...draft, vsync, framePacing: vsync && draft.framePacing })} options={[
              { value: true, label: <><IconRectangle size={15} />Imagen entera</> },
              { value: false, label: <><IconBolt size={15} />Más rápida</> },
            ]} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow sub icon={<IconWaveSine size={17} />} title="Ritmo de cuadros" desc={!draft.vsync
            ? "Solo con la imagen entera."
            : draft.framePacing ? "Reparte los cuadros a ritmo constante, ideal a 60 FPS." : "Muestra cada cuadro apenas está listo."}>
            <div className={`segment-row${draft.vsync ? "" : " disabled"}`}>
              <Segmented value={draft.framePacing} onChange={(framePacing) => draft.vsync && setDraft({ ...draft, framePacing })} options={[
                { value: true, label: <><IconWaveSine size={15} />Parejo</> },
                { value: false, label: <><IconPlayerTrackNext size={15} />Al instante</> },
              ]} />
            </div>
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow sub icon={<IconPointer size={17} />} title="Mouse" desc={draft.mouse === "capture"
            ? "La VM toma el mouse, como necesitan los juegos para girar la cámara. Ctrl+Alt+Shift+Z lo libera sin cerrar."
            : "El puntero entra y sale de la ventana como en escritorio remoto. No sirve en la mayoría de juegos."}>
            <Segmented value={draft.mouse} onChange={(mouse) => setDraft({ ...draft, mouse })} options={[
              { value: "capture", label: <><IconDeviceGamepad2 size={15} />Para juegos</> },
              { value: "absolute", label: <><IconPointer size={15} />Libre</> },
            ]} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow icon={<IconDeviceDesktop size={17} />} title="Resolución" desc="Tamaño de la imagen de la máquina">
            <Segmented value={draft.resolution} onChange={(resolution) => setDraft({ ...draft, resolution })}
              options={RESOLUTIONS.map((r) => ({ value: r, label: r.split("x")[1] + "p" }))} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow icon={<IconArrowsMaximize size={17} />} title="Ventana"
            desc={draft.displayMode === "fullscreen" ? "Ocupa todo el monitor" : "Se abre en una ventana que puedes mover"}>
            <Segmented value={draft.displayMode} onChange={(displayMode) => setDraft({ ...draft, displayMode })} options={[
              { value: "fullscreen", label: <><IconArrowsMaximize size={15} />Pantalla completa</> },
              { value: "windowed", label: <><IconAppWindow size={15} />Ventana</> },
            ]} />
          </OptionRow>
        )}
        {vm.streaming && monitors.length > 1 && (
          <OptionRow icon={<IconScreenShare size={17} />} title="Abrir en" desc="Monitor donde se abre la máquina">
            <MonitorPicker monitors={monitors} value={draft.monitor} inherited={prefs.monitor} onChange={(monitor) => setDraft({ ...draft, monitor })} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow icon={<IconScreenShare size={17} />} title="Captura" desc={draft.captureMode === "wgc"
            ? "La imagen aparece apenas te conectas y se ven los juegos en pantalla completa exclusiva. Los avisos de administrador de Windows se responden desde GpuVM."
            : "Los avisos de administrador se ven en Moonlight, pero la imagen puede tardar en aparecer al conectar y los juegos en pantalla completa exclusiva se ven en negro."}>
            <Segmented value={draft.captureMode} onChange={(captureMode) => setDraft({ ...draft, captureMode })} options={[
              { value: "wgc", label: <><IconBolt size={15} />Rápida</> },
              { value: "ddx", label: <><IconScreenShare size={15} />Clásica</> },
            ]} />
          </OptionRow>
        )}
        {vm.streaming && (
          <button type="button" className="disclosure opt-disclosure" aria-expanded={advanced} onClick={() => setAdvanced(!advanced)}>
            <IconChevronRight size={15} />Avanzado
          </button>
        )}
        {vm.streaming && advanced && (
          <>
            <OptionRow icon={<IconAppWindow size={17} />} title="Códec"
              desc={draft.codec === "auto" ? "Moonlight elige el mejor que tu equipo puede mostrar." : "Si la imagen no aparece, vuelve a Automático."}>
              <Segmented value={draft.codec} onChange={(codec) => setDraft({ ...draft, codec })} options={CODECS} />
            </OptionRow>
            <OptionRow icon={<IconSparkles size={17} />} title="Calidad de imagen" value={draft.bitrateKbps ? `${draft.bitrateKbps / 1000} Mbps` : "Automática"}
              desc="Más calidad usa más red. Al mínimo, Moonlight la ajusta a la resolución y los FPS.">
              <Slider label="Calidad de imagen" value={draft.bitrateKbps / 1000} min={0} max={150} step={5} format={(v) => (v ? String(v) : "Auto")}
                onChange={(mbps) => setDraft({ ...draft, bitrateKbps: mbps * 1000 })} />
            </OptionRow>
          </>
        )}
          </>
        )}
      </div>
      {(vmDirty || clientDirty || captureDirty || networkDirty || monitorDirty || saved) && (
        <div className="options-foot">
          {saved && !vmDirty && !clientDirty && !captureDirty && !networkDirty && !monitorDirty ? (
            <span className="saved"><IconCheck size={16} />Guardado</span>
          ) : (
            <>
              <button className="btn ghost" onClick={() => setDraft(initial)}>Descartar</button>
              <button className="primary compact" disabled={!!busy} onClick={save}>
                <IconDeviceFloppy size={16} />{vmDirty && !off ? "Apagar y aplicar" : "Guardar"}
              </button>
            </>
          )}
        </div>
      )}
    </div>
  );
}
