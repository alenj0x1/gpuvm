import { useCallback, useEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { IconAlertTriangle, IconHome, IconLoader2, IconPlugConnected, IconPlus, IconRefresh, IconSettings, IconShieldLock, IconStack2 } from "@tabler/icons-react";
import { Preferences } from "./Preferences";
import { Library, type LibraryTab } from "./Library";
import { EmptyHome, Home, HomeSkeleton } from "./Home";
// The app's own icon (the installer and the window use it), never a machine figure.
import { Logo } from "./Logo";
import { TripleSpark } from "./Chart";
import type { HostInfo, JobEvent, Sample, VmOverview } from "./types";
import { readPrefs } from "./prefs";
import { api, onJob, relaunchAsAdmin, repairService, service, startJob as runJob } from "./api";
import { MachineIcon, renamePatternVariant } from "./machineIcon";
import { renameSceneStyle } from "./Scene";
import { renameDecor } from "./decor/store";
import { machinesIn, moveToSpace, renameInSpaces, reorderSpaces, showSpace, useShownSpace, useSpaces } from "./spaces";
import { ambientInfo } from "./ambient";
import { carriesMachine, carriesSpace, dragging, dragMachine, dragSpace, flashMachine, glide, onDragFinish } from "./dragMachine";
import { MAX_SAMPLES } from "./Chart";
import { VmView, type JobInfo } from "./VmView";
import { CreateDialog } from "./CreateDialog";
import { TitleBar } from "./TitleBar";
import { Toasts, humanError, stateLabel, useToasts, useScrollFade } from "./ui";

const NEW_VM = "__new__";
// Route of the preferences screen in the URL hash, shaped so it doesn't look like a VM name.
const PREFS = ":preferencias";
const LIBRARY = ":biblioteca";
// The home screen, where the app opens.
const HOME = ":inicio";
const libraryTab = (route: string): LibraryTab | null => {
  if (!route.startsWith(LIBRARY)) return null;
  const tab = route.slice(LIBRARY.length + 1);
  return tab === "plantillas" || tab === "discos" || tab === "compartidos" || tab === "isos" ? tab : "perfiles";
};

interface RunningJob extends JobInfo {
  vm: string;
  name: string;
  after?: () => void;
  failed?: () => void;
}

/** `embedded`: the app runs inside another page (the website), so its route stays in memory and off the page's URL. */
export function App({ embedded = false }: { embedded?: boolean } = {}) {
  // The machine list fades only where it keeps going: never over "Crear máquina" when everything fits.
  const [sideRef, sideFade] = useScrollFade<HTMLElement>();
  const [vms, setVms] = useState<VmOverview[] | null>(null);
  const [host, setHost] = useState<HostInfo | null>(null);
  // "stopped": the GpuVM service is stopped and set to start by hand; "missing": it isn't installed (installed app);
  // "admin": development build without administrator.
  const [blocked, setBlocked] = useState<"stopped" | "missing" | "admin" | null>(null);
  const [repair, setRepair] = useState<{ busy: boolean; error: string | null }>({ busy: false, error: null });
  const [readError, setReadError] = useState<string | null>(null);
  const [selected, setSelected] = useState(() => embedded ? HOME : decodeURIComponent(location.hash.slice(1)));
  const [collapsed, setCollapsed] = useState(() => { try { return localStorage.getItem("gpuvm.collapsed") === "1"; } catch { return false; } });
  const [creating, setCreating] = useState(false);
  // Template preselected when "Crear máquina" is opened from a template in the library.
  const [createTemplate, setCreateTemplate] = useState<string | null>(null);
  // The space a new machine goes into (the one Home shows, or the one it was created from).
  const [createSpace, setCreateSpace] = useState<string | null>(null);
  const spaces = useSpaces();
  const shownSpaceId = useShownSpace();
  // While a machine or a space is dragged in the sidebar, the others make room for it as it passes: the order shown is
  // a preview, kept until the drop (which saves it) or the drag is cancelled (which glides everything back).
  const [preview, setPreview] = useState<{ name: string; space: string; before: string | null } | null>(null);
  const [spaceOrder, setSpaceOrder] = useState<string[] | null>(null);
  const previewRef = useRef(preview); previewRef.current = preview;
  const spaceOrderRef = useRef(spaceOrder); spaceOrderRef.current = spaceOrder;
  useEffect(() => onDragFinish(() => {
    if (previewRef.current || spaceOrderRef.current) glide(() => { setPreview(null); setSpaceOrder(null); });
  }), []);
  const [createError, setCreateError] = useState<string | null>(null);
  const [jobs, setJobs] = useState<Record<string, RunningJob>>({});
  // Short actions (start, shut down, save…) in progress per VM, to show their state instantly.
  const [pending, setPending] = useState<Record<string, string>>({});
  const history = useRef<Record<string, Sample[]>>({});
  // The machine just renamed, until the refreshed list shows it under its new name.
  const renamed = useRef<{ from: string; to: string } | null>(null);
  const lastJson = useRef("");
  const { toasts, push, dismiss } = useToasts();
  const creatingRef = useRef(creating);
  creatingRef.current = creating;
  const jobsRef = useRef(jobs);
  jobsRef.current = jobs;

  const refresh = useCallback(async () => {
    try {
      const list = await api.overview();
      for (const vm of list) {
        const prev = history.current[vm.name] ?? [];
        history.current[vm.name] = vm.state === "Running"
          ? [...prev, { cpu: vm.cpuPercent, gpu: vm.gpuPercent, mem: vm.memoryDemandGB }].slice(-MAX_SAMPLES)
          : [];
      }
      const json = JSON.stringify(list);
      if (json !== lastJson.current) { lastJson.current = json; setVms(list); }
      setBlocked(null);
      setReadError(null);
    } catch (e) {
      const msg = humanError(e);
      if (msg.includes("servicio de GpuVM está detenido")) setBlocked("stopped");
      else if (msg.includes("servicio de GpuVM no está instalado")) setBlocked("missing");
      else if (msg.includes("administrador")) setBlocked("admin");
      else setReadError(msg);
      setVms((v) => v ?? []);
    }
  }, []);

  // Chained polling: the next query goes out when the previous one finished; slower with no running VMs
  // or with the window hidden.
  const vmsRef = useRef(vms);
  vmsRef.current = vms;
  useEffect(() => {
    let alive = true;
    let timer: ReturnType<typeof setTimeout>;
    const loop = async () => {
      if (!document.hidden) await refresh();
      if (!alive) return;
      const anyRunning = vmsRef.current?.some((v) => v.state !== "Off");
      timer = setTimeout(loop, document.hidden ? 10000 : anyRunning ? 2000 : 6000);
    };
    loop();
    const wake = () => { if (!document.hidden) { clearTimeout(timer); loop(); } };
    document.addEventListener("visibilitychange", wake);
    return () => { alive = false; clearTimeout(timer); document.removeEventListener("visibilitychange", wake); };
  }, [refresh]);

  useEffect(() => { api.hostInfo().then((h) => setHost(h[0] ?? null)).catch(() => {}); }, []);
  useEffect(() => { if (!embedded) window.history.replaceState(null, "", selected ? `#${encodeURIComponent(selected)}` : " "); }, [selected, embedded]);
  useEffect(() => {
    if (embedded) return;
    const onHash = () => setSelected(decodeURIComponent(location.hash.slice(1)));
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, [embedded]);
  useEffect(() => { try { localStorage.setItem("gpuvm.collapsed", collapsed ? "1" : "0"); } catch { /* no storage */ } }, [collapsed]);
  // The sidebar's width: dragged from its edge between 200 and 360 px; dragging it narrower than 150 px folds it.
  const [sideWidth, setSideWidth] = useState(() => { try { return Math.min(360, Math.max(200, Number(localStorage.getItem("gpuvm.sideWidth")) || 248)); } catch { return 248; } });
  const [resizing, setResizing] = useState(false);
  // Where a press on the edge started: a press that doesn't move is a click on the line (fold or unfold).
  const press = useRef<{ x: number; moved: boolean; onLine: boolean } | null>(null);
  useEffect(() => { try { localStorage.setItem("gpuvm.sideWidth", String(sideWidth)); } catch { /* no storage */ } }, [sideWidth]);
  const startResize = (e: React.PointerEvent<HTMLDivElement>) => {
    if (e.button !== 0) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    press.current = { x: e.clientX, moved: false, onLine: (e.target as HTMLElement).classList.contains("side-handle") };
  };
  const resize = (e: React.PointerEvent<HTMLDivElement>) => {
    const p = press.current;
    if (!p || !e.currentTarget.hasPointerCapture(e.pointerId)) return;
    if (!p.moved && Math.abs(e.clientX - p.x) < 4) return;
    if (!p.moved) { p.moved = true; setResizing(true); }
    const x = e.clientX;
    if (x < 150) setCollapsed(true);
    else { setCollapsed(false); setSideWidth(Math.round(Math.min(360, Math.max(200, x)))); }
  };
  useEffect(() => {
    // A machine just renamed keeps its page until the list brings it under the new name.
    if (renamed.current && vms?.some((v) => v.name === renamed.current!.to)) renamed.current = null;
    if (renamed.current?.to === selected) return;
    if (selected !== PREFS && selected !== HOME && !libraryTab(selected) && vms && vms.length && !vms.some((v) => v.name === selected)) setSelected(HOME);
  }, [vms, selected]);

  // "Otro patrón" (another pattern) is reflected instantly in the sidebar too.
  const [, repaint] = useState(0);
  useEffect(() => {
    const onPattern = () => repaint((n) => n + 1);
    window.addEventListener("gpuvm-pattern", onPattern);
    return () => window.removeEventListener("gpuvm-pattern", onPattern);
  }, []);

  // Long job progress: the button that started the job shows the latest step.
  useEffect(() => {
    let off: (() => void) | undefined;
    let cancelled = false;
    // Side effects (toasts, opening the dialog) stay outside the state updaters, which must be pure.
    onJob((e: JobEvent) => {
      const job = jobsRef.current[e.jobId];
      if (!job) return;
      if (e.type === "progress") {
        setJobs((all) => all[e.jobId] ? { ...all, [e.jobId]: { ...all[e.jobId], message: e.message!, log: [...all[e.jobId].log, e.message!] } } : all);
        return;
      }
      if (e.type === "warning") { push("warning", e.message!); return; }
      setJobs(({ [e.jobId]: _, ...rest }) => rest);
      if (!e.ok) job.failed?.();
      if (e.ok) job.after?.();
      else if (job.vm === NEW_VM) {
        setCreateError(humanError(e.error));
        // If the dialog was closed, reopen it to show what failed.
        if (!creatingRef.current) { push("error", `No se pudo crear ${job.name}.`); setCreating(true); }
      } else push("error", humanError(e.error));
      refresh();
    }).then((fn) => { if (cancelled) fn(); else off = fn; });
    return () => { cancelled = true; off?.(); };
  }, [push, refresh]);

  const startJob = useCallback((vm: string, cmd: string, args: Record<string, unknown>, after?: () => void, failed?: () => void) => {
    // A VM without a monitor of its own opens on the one chosen in Preferences.
    if (cmd === "Connect-GpuVM" && !args.Monitor && !vmsRef.current?.find((v) => v.name === vm)?.client?.monitor) {
      args = { ...args, Monitor: readPrefs().monitor };
    }
    const jobId = `${cmd}-${Date.now()}`;
    const first = cmd === "Connect-GpuVM" ? "Preparando" : cmd === "New-GpuVM" ? "Revisando el equipo" : cmd === "Invoke-GpuVMPower" ? "Apagando" : "Trabajando";
    const job = { vm, cmd, message: first, log: [first], after, failed, name: String(args.Name ?? "") };
    // Also registered in the ref so events arriving before the next render are not lost.
    jobsRef.current = { ...jobsRef.current, [jobId]: job };
    setJobs((all) => ({ ...all, [jobId]: job }));
    runJob(jobId, cmd, args).catch((e) => {
      setJobs(({ [jobId]: _, ...rest }) => rest);
      failed?.();
      push("error", humanError(e));
    });
  }, [push]);

  const run = useCallback(async (vm: string, label: string, task: () => Promise<unknown>) => {
    setPending((p) => ({ ...p, [vm]: label }));
    try { await task(); await refresh(); return true; }
    catch (e) { push("error", humanError(e)); return false; }
    finally { setPending(({ [vm]: _, ...rest }) => rest); }
  }, [push, refresh]);

  const busyFor = (vm: string): JobInfo | null => {
    const job = Object.values(jobs).find((j) => j.vm === vm);
    if (job) return job;
    return pending[vm] ? { cmd: "", message: `${pending[vm]}…`, log: [] } : null;
  };
  const createJob = Object.values(jobs).find((j) => j.vm === NEW_VM) ?? null;
  const current = vms?.find((v) => v.name === selected)
    ?? (renamed.current?.to === selected ? vms?.find((v) => v.name === renamed.current!.from) : undefined) ?? null;
  const onRenamed = (from: string, to: string) => {
    renamed.current = { from, to };
    history.current[to] = history.current[from] ?? [];
    delete history.current[from];
    renameSceneStyle(from, to);
    renamePatternVariant(from, to);
    renameDecor(from, to);
    renameInSpaces(from, to);
    setSelected(to);
  };

  if (blocked === "stopped" || blocked === "missing") {
    const stopped = blocked === "stopped";
    const fix = async () => {
      setRepair({ busy: true, error: null });
      try { await (stopped ? service.start() : repairService()); setRepair({ busy: false, error: null }); refresh(); }
      catch (e) { setRepair({ busy: false, error: humanError(e) }); }
    };
    return (
      <div className="app single">
        <TitleBar />
        <div className="empty">
          <Logo className="empty-logo" size={96} />
          <h2>{stopped ? "El servicio de GpuVM está detenido" : "Falta el servicio de GpuVM"}</h2>
          <p>{stopped ? "Es la parte de GpuVM que controla Hyper-V. En Ajustes está en modo manual." : "Es la parte de GpuVM que controla Hyper-V. Repararlo pide permiso de administrador una vez."}</p>
          <button className="primary" onClick={fix} disabled={repair.busy}>
            {stopped ? <><IconPlugConnected size={17} />{repair.busy ? "Iniciando…" : "Iniciar servicio"}</> : <><IconShieldLock size={17} />{repair.busy ? "Reparando…" : "Reparar"}</>}
          </button>
          {repair.error && <span className="error-text">{repair.error}</span>}
        </div>
      </div>
    );
  }

  if (blocked === "admin") {
    return (
      <div className="app single">
        <TitleBar />
        <div className="empty">
          <Logo className="empty-logo" size={96} />
          <h2>GpuVM necesita permisos de administrador</h2>
          <p>Hyper-V solo deja crear y controlar máquinas a un administrador.</p>
          <button className="primary" onClick={relaunchAsAdmin}><IconShieldLock size={17} />Abrir como administrador</button>
        </div>
      </div>
    );
  }

  return (
    <div className={`app ${collapsed ? "collapsed" : ""}${resizing ? " resizing" : ""}`} style={{ "--side-w": `${collapsed ? 64 : sideWidth}px` } as React.CSSProperties}>
      <TitleBar />
      <aside className="side">
        <div className="side-head">
          <span className="side-logo"><Logo size={28} /></span>
          <strong>GpuVM</strong>
        </div>
        <nav ref={sideRef} className={`side-list ${sideFade}`}>
          {(
            <button className={`side-item side-home ${selected === HOME ? "active" : ""}`} onClick={() => setSelected(HOME)} title="Inicio">
              <span className="add-icon"><IconHome size={16} /></span><span className="name">Inicio</span>
            </button>
          )}
          <button className={`side-item side-home ${libraryTab(selected) ? "active" : ""}`} onClick={() => setSelected(LIBRARY)} title="Perfiles, discos e ISOs">
            <span className="add-icon"><IconStack2 size={16} /></span><span className="name">Biblioteca</span>
          </button>
          {/* With one space the list is just "Máquinas"; with several, each space heads its own machines and opens it in Home. */}
          {(() => {
            // The groups as shown: the spaces in their (previewed) order, each with its machines, and the dragged
            // machine where it would land.
            const order = spaceOrder ? [...spaces].sort((a, b) => spaceOrder.indexOf(a.id) - spaceOrder.indexOf(b.id)) : spaces;
            const groups = (spaces.length > 1 && vms ? order : [null]).map((sp) => {
              const space = sp ?? spaces[0];
              let list = vms ? (sp ? machinesIn(sp, vms, spaces) : machinesIn(spaces[0], vms, spaces)) : null;
              if (list && preview && vms) {
                const moving = vms.find((v) => v.name === preview.name);
                list = list.filter((v) => v.name !== preview.name);
                if (moving && preview.space === space.id) {
                  const k = preview.before ? list.findIndex((v) => v.name === preview.before) : -1;
                  list.splice(k < 0 ? list.length : k, 0, moving);
                }
              }
              return { sp, spaceId: space.id, list };
            });
            return groups.map(({ sp, spaceId, list }) => {
            const names = list?.map((v) => v.name) ?? [];
            const Icon = sp ? ambientInfo(sp.ambient).icon : null;
            return (
              <div key={sp?.id ?? "all"} className="side-group"
                onDragOver={(e) => {
                  if (carriesSpace(e) && sp && dragging.space) {
                    // A space passes over another: it goes before it or after it, by which half the pointer is on.
                    e.preventDefault(); e.dataTransfer.dropEffect = "move";
                    if (dragging.space === sp.id) return;
                    const r = e.currentTarget.getBoundingClientRect();
                    const ids = groups.map((g) => g.spaceId).filter((id) => id !== dragging.space);
                    const k = ids.indexOf(sp.id) + (e.clientY < r.top + r.height / 2 ? 0 : 1);
                    ids.splice(k, 0, dragging.space);
                    if (ids.join() !== groups.map((g) => g.spaceId).join()) glide(() => setSpaceOrder(ids));
                    return;
                  }
                  const name = dragging.machine;
                  if (!carriesMachine(e) || !name) return;
                  e.preventDefault(); e.dataTransfer.dropEffect = "move";
                  // Over another machine: it takes that machine's place (before it from below, after it from above),
                  // and the others make room. Over the space's name or its empty room: at the end of the space.
                  const row = (e.target as HTMLElement).closest<HTMLElement>("[data-vm]");
                  if (row?.dataset.vm === name) return;
                  let before: string | null;
                  if (row) {
                    const r = row.getBoundingClientRect();
                    const rest = names.filter((n) => n !== name);
                    before = e.clientY < r.top + r.height / 2 ? row.dataset.vm! : rest[rest.indexOf(row.dataset.vm!) + 1] ?? null;
                  } else {
                    if (names.includes(name)) return;
                    before = null;
                  }
                  const cur = previewRef.current;
                  if (cur && cur.name === name && cur.space === spaceId && cur.before === before) return;
                  glide(() => setPreview({ name, space: spaceId, before }), name);
                }}
                onDrop={(e) => {
                  e.preventDefault();
                  const order = spaceOrderRef.current, p = previewRef.current;
                  // Saved as shown: nothing moves on the drop, the preview just stays.
                  flushSync(() => {
                    if (order && carriesSpace(e)) reorderSpaces(order);
                    if (p && carriesMachine(e)) {
                      const shown = groups.find((g) => g.spaceId === p.space)?.list?.map((v) => v.name) ?? [];
                      moveToSpace(p.name, p.space, p.before, shown.filter((n) => n !== p.name));
                    }
                    setPreview(null); setSpaceOrder(null);
                  });
                  if (p) flashMachine(p.name);
                }}>
                {sp ? (
                  <button type="button" data-space-row={sp.id} draggable onDragStart={(e) => dragSpace(e, sp.id)}
                    className={`side-label side-space${spaceOrder && dragging.space === sp.id ? " dragged" : ""}${selected === HOME && shownSpaceId === sp.id ? " on" : ""}`} title={`Ver ${sp.name}`}
                    onClick={() => { showSpace(sp.id); setSelected(HOME); }}>
                    {Icon && <Icon size={13} />}<span className="ellipsis">{sp.name}</span>
                  </button>
                ) : <span className="side-label">Máquinas</span>}
                {vms === null && [0, 1, 2].map((i) => (
                  <div key={i} className="side-item side-skeleton" aria-hidden="true">
                    <span className="skeleton icon" />
                    <span className="name"><span className="skeleton line" /></span>
                  </div>
                ))}
                {list?.map((vm) => {
                  const busy = busyFor(vm.name);
                  return (
                    // The dot already says on or off: the row only adds what it can't, the GPU in use or a job in progress.
                    <button key={vm.id} data-vm={vm.name} draggable onDragStart={(e) => dragMachine(e, vm.name)}
                      className={`side-item ${vm.name === selected ? "active" : ""}${preview?.name === vm.name ? " dragged" : ""}`} onClick={() => setSelected(vm.name)}
                      title={busy?.message ? `${vm.name}, ${busy.message}` : `${vm.name}, ${stateLabel[vm.state] ?? vm.state}`}>
                      <span className="side-icon"><MachineIcon name={vm.name} size={28} radius={8} /><span className={`dot badge ${vm.state}`} /></span>
                      <span className="name">{vm.name}</span>
                      {busy ? <IconLoader2 size={15} className="spin side-meta" />
                        : vm.state === "Running" ? <span className="side-meta" title={`Procesador ${vm.cpuPercent} %, memoria ${vm.memoryDemandGB} GB, GPU ${vm.gpuPercent} %`}>
                          <TripleSpark samples={history.current[vm.name] ?? []} memGB={vm.memoryAssignedGB} /></span> : null}
                    </button>
                  );
                })}
              </div>
            );
          });
          })()}
          {createJob && (
            <button className="side-item" onClick={() => setCreating(true)} title="Ver avance">
              <span className="add-icon"><IconLoader2 size={16} className="spin" /></span>
              <span className="name">{createJob.name}<span className="sub">{createJob.message}</span></span>
            </button>
          )}
          <button className="side-item side-add" onClick={() => { setCreateError(null); setCreateSpace(null); setCreating(true); }} title="Crear máquina">
            <span className="add-icon"><IconPlus size={16} /></span><span className="name">Crear máquina</span>
          </button>
        </nav>
        {/* Ajustes stays at the foot of the sidebar, however long the list of machines gets. */}
        <button className={`side-item side-home side-foot ${selected === PREFS ? "active" : ""}`} onClick={() => setSelected(PREFS)} title="Ajustes">
          <span className="add-icon"><IconSettings size={16} /></span><span className="name">Ajustes</span>
        </button>
      </aside>
      {/* The sidebar's edge: drag it to resize (or fold) the sidebar; its tab, shown on hover, folds and unfolds it. */}
      <div className="side-edge" role="separator" aria-orientation="vertical" aria-label="Ancho de la barra"
        onPointerDown={startResize} onPointerMove={resize}
        onPointerUp={() => { const p = press.current; press.current = null; setResizing(false); if (p && !p.moved && p.onLine) setCollapsed((c) => !c); }}
        onPointerCancel={() => { press.current = null; setResizing(false); }}>
        {/* The line itself: drag it to resize, click it to fold or unfold. */}
        <button type="button" className="side-handle" aria-label={collapsed ? "Expandir barra" : "Contraer barra"} title={collapsed ? "Expandir barra" : "Contraer barra"}
          onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); setCollapsed((c) => !c); } }} />
      </div>

      <div className="content">
        {readError && (
          <div className="notice error-notice">
            <IconAlertTriangle size={20} />
            <div className="grow">No se pudo leer Hyper-V: {readError}</div>
            <button className="btn" onClick={refresh}><IconRefresh size={16} />Reintentar</button>
          </div>
        )}
        {vms === null ? (
          // While the machines load: the shape of Home, where the app opens.
          <HomeSkeleton />
        ) : selected === HOME && vms.length > 0 ? (
          <Home vms={vms} busyFor={busyFor} startJob={startJob} onOpenVm={setSelected} onRoute={setSelected} onCreate={(space) => { setCreateError(null); setCreateSpace(space ?? null); setCreating(true); }} />
        ) : selected === PREFS ? (
          <Preferences />
        ) : libraryTab(selected) ? (
          <Library tab={libraryTab(selected)!} onTab={(t) => setSelected(`${LIBRARY}:${t}`)} host={host} startJob={startJob}
            busy={(name) => !!busyFor(name)} progress={(key) => busyFor(key)?.message ?? null} notify={push} onOpenVm={setSelected}
            onCreateFromTemplate={(template) => { setCreateTemplate(template); setCreating(true); }} />
        ) : current ? (
          <VmView key={current.id} vm={current} vms={vms ?? []} host={host} samples={history.current[current.name] ?? []} busy={busyFor(current.name)}
            startJob={startJob} run={run} onRemoved={() => setSelected("")} onRenamed={onRenamed} />
        ) : vms.length > 0 ? (
          <Home vms={vms} busyFor={busyFor} startJob={startJob} onOpenVm={setSelected} onRoute={setSelected} onCreate={(space) => { setCreateError(null); setCreateSpace(space ?? null); setCreating(true); }} />
        ) : (
          <EmptyHome gpuName={host?.gpuName ?? null} onRoute={setSelected} onCreate={(space) => { setCreateError(null); setCreateSpace(space ?? null); setCreating(true); }} />
        )}
      </div>

      {creating && (
        <CreateDialog host={host} existing={vms ?? []} job={createJob} error={createError} template={createTemplate}
          space={createSpace ?? (selected === HOME ? shownSpaceId : current ? null : shownSpaceId)}
          onClose={() => { setCreating(false); setCreateTemplate(null); }}
          onCreate={({ name, iso, template, profile, user, password, apps, cleanup, resources, space }) => {
            setCreateError(null);
            // The new machine goes into the space picked for it, even before it exists in the list.
            if (space) moveToSpace(name, space);
            // Resources changed in the dialog go as an override of the chosen profile, like Options does.
            const hw = resources ? { vm: { cpu: { count: resources.cpu }, memoryGB: resources.memoryGB, disk: { sizeGB: resources.diskGB } }, gpu: { allocationPercent: resources.gpuPercent } } : {};
            const args = template
              ? { Name: name, Template: template, Profile: profile, ...(resources ? { Override: hw } : {}), Start: true }
              : { Name: name, IsoPath: iso, Profile: profile, Override: { ...hw, guest: { apps, cleanup } }, Credential: { user, password }, Start: true };
            startJob(NEW_VM, "New-GpuVM", args, () => {
              setCreating(false);
              setCreateTemplate(null);
              // Open the new machine once the list has it; before that, the route would fall back to Home.
              refresh().then(() => setSelected(name));
              push("ok", template ? `${name} está lista.` : `${name} está lista. Windows termina de configurarse solo en unos minutos.`);
            });
          }} />
      )}
      <Toasts toasts={toasts} dismiss={dismiss} />
    </div>
  );
}
