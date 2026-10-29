import { useCallback, useEffect, useRef, useState } from "react";
import { IconHome,
  IconAlertTriangle, IconLayoutSidebarLeftCollapse, IconLayoutSidebarLeftExpand, IconLoader2, IconPlus, IconRefresh, IconShieldLock,
} from "@tabler/icons-react";
import { Preferences } from "./Preferences";
import { Library, type LibraryTab } from "./Library";
import { Home } from "./Home";
// The app's own icon (the installer and the window use it), never a machine figure.
import appIcon from "../src-tauri/icons/128x128.png";
import type { HostInfo, JobEvent, Sample, VmOverview } from "./types";
import { api, onJob, relaunchAsAdmin, startJob as runJob } from "./api";
import { Bauhaus } from "./bauhaus";
import { MAX_SAMPLES } from "./Chart";
import { VmView, type JobInfo } from "./VmView";
import { CreateDialog } from "./CreateDialog";
import { TitleBar } from "./TitleBar";
import { Toasts, humanError, stateLabel, useToasts } from "./ui";

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
}

/** `embedded`: the app runs inside another page (the website), so its route stays in memory and off the page's URL. */
export function App({ embedded = false }: { embedded?: boolean } = {}) {
  const [vms, setVms] = useState<VmOverview[] | null>(null);
  const [host, setHost] = useState<HostInfo | null>(null);
  const [needsAdmin, setNeedsAdmin] = useState(false);
  const [readError, setReadError] = useState<string | null>(null);
  const [selected, setSelected] = useState(() => embedded ? HOME : decodeURIComponent(location.hash.slice(1)));
  const [collapsed, setCollapsed] = useState(() => { try { return localStorage.getItem("gpuvm.collapsed") === "1"; } catch { return false; } });
  const [creating, setCreating] = useState(false);
  // Template preselected when "Crear máquina" is opened from a template in the library.
  const [createTemplate, setCreateTemplate] = useState<string | null>(null);
  const [createError, setCreateError] = useState<string | null>(null);
  const [jobs, setJobs] = useState<Record<string, RunningJob>>({});
  // Short actions (start, shut down, save…) in progress per VM, to show their state instantly.
  const [pending, setPending] = useState<Record<string, string>>({});
  const history = useRef<Record<string, Sample[]>>({});
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
      setNeedsAdmin(false);
      setReadError(null);
    } catch (e) {
      const msg = humanError(e);
      if (msg.includes("administrador")) setNeedsAdmin(true);
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
  useEffect(() => {
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

  const startJob = useCallback((vm: string, cmd: string, args: Record<string, unknown>, after?: () => void) => {
    const jobId = `${cmd}-${Date.now()}`;
    const first = cmd === "Connect-GpuVM" ? "Preparando" : cmd === "New-GpuVM" ? "Revisando el equipo" : "Trabajando";
    const job = { vm, cmd, message: first, log: [first], after, name: String(args.Name ?? "") };
    // Also registered in the ref so events arriving before the next render are not lost.
    jobsRef.current = { ...jobsRef.current, [jobId]: job };
    setJobs((all) => ({ ...all, [jobId]: job }));
    runJob(jobId, cmd, args).catch((e) => {
      setJobs(({ [jobId]: _, ...rest }) => rest);
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
  const current = vms?.find((v) => v.name === selected) ?? null;

  if (needsAdmin) {
    return (
      <div className="app single">
        <TitleBar />
        <div className="empty">
          <Bauhaus name="gpuvm-admin" size={96} radius={24} />
          <h2>GpuVM necesita permisos de administrador</h2>
          <p>Hyper-V solo deja crear y controlar máquinas a un administrador.</p>
          <button className="primary" onClick={relaunchAsAdmin}><IconShieldLock size={17} />Abrir como administrador</button>
        </div>
      </div>
    );
  }

  return (
    <div className={`app ${collapsed ? "collapsed" : ""}`}>
      <TitleBar prefsOpen={selected === PREFS} onPrefs={() => setSelected(selected === PREFS ? HOME : PREFS)}
        libraryOpen={!!libraryTab(selected)} onLibrary={() => setSelected(libraryTab(selected) ? HOME : LIBRARY)} />
      <aside className="side">
        <div className="side-head">
          <span className="side-logo"><img src={appIcon} alt="" width={28} height={28} draggable={false} /></span>
          <strong>GpuVM</strong>
          <button className="icon-btn side-toggle" aria-label={collapsed ? "Expandir barra" : "Contraer barra"} onClick={() => setCollapsed((c) => !c)}>
            {collapsed ? <IconLayoutSidebarLeftExpand size={18} /> : <IconLayoutSidebarLeftCollapse size={18} />}
          </button>
        </div>
        <nav className="side-list">
          {vms && vms.length > 0 && (
            <button className={`side-item side-home ${selected === HOME ? "active" : ""}`} onClick={() => setSelected(HOME)} title="Inicio">
              <span className="add-icon"><IconHome size={16} /></span><span className="name">Inicio</span>
            </button>
          )}
          {vms === null && [0, 1, 2].map((i) => (
            <div key={i} className="side-item side-skeleton" aria-hidden="true">
              <span className="skeleton icon" />
              <span className="name"><span className="skeleton line" /><span className="skeleton line short" /></span>
            </div>
          ))}
          {vms?.map((vm) => {
            const busy = busyFor(vm.name);
            return (
              <button key={vm.id} className={`side-item ${vm.name === selected ? "active" : ""}`} onClick={() => setSelected(vm.name)} title={vm.name}>
                <span className="side-icon"><Bauhaus name={vm.name} size={28} radius={8} /><span className={`dot badge ${vm.state}`} /></span>
                <span className="name">{vm.name}<span className="sub">{busy?.message ?? stateLabel[vm.state] ?? vm.state}</span></span>
              </button>
            );
          })}
          {createJob && (
            <button className="side-item" onClick={() => setCreating(true)} title="Ver avance">
              <span className="add-icon"><IconLoader2 size={16} className="spin" /></span>
              <span className="name">{createJob.name}<span className="sub">{createJob.message}</span></span>
            </button>
          )}
          <button className="side-item side-add" onClick={() => { setCreateError(null); setCreating(true); }} title="Crear máquina">
            <span className="add-icon"><IconPlus size={16} /></span><span className="name">Crear máquina</span>
          </button>
        </nav>      </aside>

      <div className="content">
        {readError && (
          <div className="notice error-notice">
            <IconAlertTriangle size={20} />
            <div className="grow">No se pudo leer Hyper-V: {readError}</div>
            <button className="btn" onClick={refresh}><IconRefresh size={16} />Reintentar</button>
          </div>
        )}
        {vms === null ? (
          <div className="main">
            <div className="skeleton" style={{ height: 88 }} />
            <div className="stats">{[0, 1, 2, 3].map((i) => <div key={i} className="skeleton" style={{ height: 96 }} />)}</div>
            <div className="skeleton" style={{ height: 170 }} />
          </div>
        ) : selected === HOME && vms.length > 0 ? (
          <Home vms={vms} busyFor={busyFor} startJob={startJob} onOpenVm={setSelected} onRoute={setSelected} />
        ) : selected === PREFS ? (
          <Preferences />
        ) : libraryTab(selected) ? (
          <Library tab={libraryTab(selected)!} onTab={(t) => setSelected(`${LIBRARY}:${t}`)} host={host} startJob={startJob}
            busy={(name) => !!busyFor(name)} progress={(key) => busyFor(key)?.message ?? null} notify={push} onOpenVm={setSelected}
            onCreateFromTemplate={(template) => { setCreateTemplate(template); setCreating(true); }} />
        ) : current ? (
          <VmView key={current.id} vm={current} host={host} samples={history.current[current.name] ?? []} busy={busyFor(current.name)}
            startJob={startJob} run={run} onRemoved={() => setSelected("")} />
        ) : (
          <div className="main">
            <div className="empty">
              <Bauhaus name="primera-maquina" size={112} radius={28} />
              <h2>Crea tu primera máquina</h2>
              <p>Windows 10 u 11 con {host?.gpuName ? `tu ${host.gpuName.replace("NVIDIA GeForce ", "")}` : "tu GPU"}, lista para abrir con Moonlight en un clic.</p>
              <button className="primary" onClick={() => setCreating(true)}><IconPlus size={17} />Crear máquina</button>
            </div>
          </div>
        )}
      </div>

      {creating && (
        <CreateDialog existing={vms ?? []} job={createJob} error={createError} template={createTemplate}
          onClose={() => { setCreating(false); setCreateTemplate(null); }}
          onCreate={({ name, iso, template, profile, password, apps, cleanup }) => {
            setCreateError(null);
            const args = template
              ? { Name: name, Template: template, Profile: profile, Start: true }
              : { Name: name, IsoPath: iso, Profile: profile, Override: { guest: { apps, cleanup } }, Credential: { user: "gpuvm", password }, Start: true };
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
