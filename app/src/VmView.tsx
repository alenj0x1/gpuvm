import { useEffect, useRef, useState } from "react";
import {
  IconAlertTriangle, IconPlugConnected, IconStack2, IconTemplate,
  IconSparkles,
  IconCpu, IconDeviceDesktop, IconDots, IconExternalLink, IconKey, IconLoader2, IconPlayerPause, IconPlayerPlay,
  IconPower, IconRefresh, IconRefreshAlert, IconTrash, IconPlugOff, IconClock, IconTopologyStar3, IconPalette,
  IconBolt, IconDeviceFloppy, IconLink, IconDownload, IconCheck, IconChartLine, IconArrowsMaximize, IconAppWindow, IconApps, IconClipboardText, IconScreenShare, IconMaximize,
  IconWorld, IconNetwork,
} from "@tabler/icons-react";
import type { AppInfo, CleanupLevelId, SharedDiskInfo, DisplayMode, HostInfo, Sample, VmOverview } from "./types";
import { AppPicker, CleanupPicker, FPS, RESOLUTIONS, useCleanupLevels } from "./pickers";
import { Bauhaus, patternVariant, setPatternVariant } from "./bauhaus";
import { MAX_SAMPLES, UsageChart } from "./Chart";
import { CheckMark, Segmented, Slider, formatUptime, stateLabel } from "./ui";
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

export function VmView({ vm, host, samples, busy, startJob, run, onRemoved }: Props) {
  const [variant, setVariant] = useState(() => patternVariant(vm.name));
  const running = vm.state === "Running";
  const off = vm.state === "Off";

  return (
    <div className="main">
      <Header vm={vm} busy={busy} variant={variant} startJob={startJob} run={run} onRemoved={onRemoved}
        onPattern={() => {
          const v = variant + 1;
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

      <div className="stats">
        <Stat icon={<IconCpu size={15} />} label="Procesador" value={`${vm.processorCount} hilos`}
          sub={running ? `${vm.cpuPercent} % en uso` : "Sin uso"} pct={running ? vm.cpuPercent : 0} />
        <Stat icon={<IconTopologyStar3 size={15} />} label="Memoria" value={`${vm.memoryStartupGB} GB`}
          sub={running ? `${vm.memoryDemandGB} GB en uso` : "Fija al encender"} pct={running ? (vm.memoryDemandGB / Math.max(vm.memoryAssignedGB, 0.1)) * 100 : 0} />
        <Stat icon={<IconBolt size={15} />} label="GPU"
          value={vm.hasGpu ? (running ? `${vm.gpuPercent} %` : `${vm.options?.gpuPercent ?? 100} % asignada`) : "Sin GPU"}
          sub={vm.gpuName ?? "Solo gráficos básicos"} pct={running ? vm.gpuPercent : 0} />
        <Stat icon={<IconClock size={15} />} label="Tiempo encendida" value={running ? formatUptime(vm.uptimeSeconds) : "—"}
          sub={running ? (vm.address ?? "Esperando red") : "Sin red"} />
      </div>

      <div className="card chart-card">
        <div className="chart-head">
          <span className="chart-title">Uso</span>
          <span className="legend"><i style={{ background: "var(--chart-cpu)" }} />CPU</span>
          {vm.hasGpu && <span className="legend"><i style={{ background: "var(--chart-gpu)" }} />GPU</span>}
          <span style={{ marginLeft: "auto" }}>Últimos {Math.round((MAX_SAMPLES * 2) / 60)} min</span>
        </div>
        {running && samples.length > 1 ? <UsageChart samples={samples} /> : (
          <div className="chart-empty">
            <IconChartLine size={20} />
            <span>{running ? "Reuniendo datos…" : "Enciende la máquina para ver su uso"}</span>
          </div>
        )}
      </div>

      {vm.managed && vm.options && <Options vm={vm} host={host} busy={busy} startJob={startJob} run={run} />}
      {vm.managed && vm.options && <SharedDisks vm={vm} busy={busy} startJob={startJob} />}
      {vm.managed && vm.guestCredential && vm.options && <Cleanup vm={vm} busy={busy} startJob={startJob} />}
      {vm.managed && vm.guestCredential && <Apps vm={vm} busy={busy} startJob={startJob} />}
    </div>
  );
}

/** Shared disks: attach one to this machine or take it away, also while it runs. Hidden until a disk exists. */
function SharedDisks({ vm, busy, startJob }: Pick<Props, "vm" | "busy" | "startJob">) {
  const [disks, setDisks] = useState<SharedDiskInfo[]>([]);
  const load = () => api.sharedDisks().then(setDisks).catch(() => {});
  useEffect(() => { load(); }, [vm.name, vm.state, busy?.cmd]);
  if (!disks.length) return null;
  const working = busy?.cmd === "Connect-GpuVMSharedDisk" || busy?.cmd === "Disconnect-GpuVMSharedDisk";
  return (
    <div className="card">
      <div className="card-head"><h2 className="section-title">Discos compartidos</h2></div>
      <div className="rows">
        {disks.map((d) => {
          const here = d.vm === vm.name;
          // Another running machine has it: it has to be taken away there first.
          const elsewhere = !!d.vm && !here;
          return (
            <div className="row" key={d.name}>
              <span className="row-icon"><IconStack2 size={18} /></span>
              <div className="row-text">
                <strong>{d.name}{here && <span className="tag">Conectado</span>}</strong>
                <span>{[d.purpose === "games" ? "Juegos" : "General", `${d.sizeGB} GB`, `ocupa ${d.fileGB} GB`, elsewhere && `En ${d.vm}`].filter(Boolean).join(" · ")}</span>
              </div>
              <div className="row-actions">
                {here ? (
                  <button className="btn ghost" disabled={!!busy} onClick={() => startJob(vm.name, "Disconnect-GpuVMSharedDisk", { Name: d.name }, load)}>
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

function Cleanup({ vm, busy, startJob }: Pick<Props, "vm" | "busy" | "startJob">) {
  const levels = useCleanupLevels();
  const current = vm.options?.cleanup ?? "none";
  const [chosen, setChosen] = useState<CleanupLevelId>(current);
  useEffect(() => setChosen(current), [vm.name, current]);
  if (!levels.length) return null;
  const applying = busy?.cmd === "Set-GpuVMCleanup";
  return (
    <div className="card">
      <div className="card-head">
        <h2 className="section-title">Windows</h2>
        {(chosen !== current || applying) && (
          <button className="btn" disabled={!!busy} onClick={() => startJob(vm.name, "Set-GpuVMCleanup", { Name: vm.name, Level: chosen })}>
            {applying ? <IconLoader2 size={16} className="spin" /> : <IconSparkles size={16} />}
            {applying ? busy!.message : vm.state === "Off" ? "Encender y aplicar" : "Aplicar"}
          </button>
        )}
      </div>
      <CleanupPicker levels={levels} value={chosen} onChange={setChosen} />
    </div>
  );
}

function Apps({ vm, busy, startJob }: Pick<Props, "vm" | "busy" | "startJob">) {
  const [catalog, setCatalog] = useState<AppInfo[]>([]);
  const [chosen, setChosen] = useState<string[]>([]);
  useEffect(() => { api.apps().then(setCatalog).catch(() => {}); }, []);
  if (!catalog.length) return null;
  const installing = busy?.cmd === "Install-GpuVMApp";
  return (
    <div className="card">
      <div className="card-head">
        <h2 className="section-title">Apps</h2>
        {chosen.length > 0 && (
          <button className="btn" disabled={!!busy} onClick={() => startJob(vm.name, "Install-GpuVMApp", { Name: vm.name, App: chosen }, () => setChosen([]))}>
            {installing ? <IconLoader2 size={16} className="spin" /> : <IconApps size={16} />}
            {installing ? busy!.message : vm.state === "Off" ? "Encender e instalar" : "Instalar"}
          </button>
        )}
      </div>
      <AppPicker apps={catalog} value={chosen} onChange={setChosen} />
    </div>
  );
}

function Stat({ icon, label, value, sub, pct }: { icon: React.ReactNode; label: string; value: string; sub: string; pct?: number }) {
  return (
    <div className="stat">
      <span className="label">{icon}{label}</span>
      <span className="value">{value}</span>
      <span className="sub" title={sub}>{sub}</span>
      {pct !== undefined && <div className="bar"><span style={{ width: `${Math.min(100, Math.max(0, pct))}%` }} /></div>}
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
    <div className="card head">
      <button type="button" className="pattern-btn" title="Otro patrón" aria-label="Otro patrón" onClick={onPattern}>
        <Bauhaus name={vm.name} variant={variant} size={56} radius={14} />
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
                <button role="menuitem" onClick={() => power("Shutdown", "Apagando")}><IconPower size={16} />Apagar</button>
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
            <button role="menuitem" onClick={() => { setMenu(false); onPattern(); }}><IconPalette size={16} />Otro patrón</button>
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
          onCreate={(name) => { setTemplating(false); startJob(vm.name, "New-GpuVMTemplate", { Name: name, VMName: vm.name, ShutdownIfRunning: true, Confirm: false }); }} />
      )}
    </div>
  );
}

/** Names the template; the copy itself runs as a job on the machine (its button shows the progress). */
function NewTemplate({ vm, onClose, onCreate }: { vm: VmOverview; onClose: () => void; onCreate: (name: string) => void }) {
  const [name, setName] = useState(`${vm.name}-base`);
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
  const complete = !!trimmed && !nameError;
  const running = vm.state !== "Off";
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog narrow" role="dialog" aria-modal="true" aria-label={`Crear plantilla de ${vm.name}`}>
        <div className="dialog-head"><Bauhaus name={`plantilla-${trimmed || vm.name}`} size={40} radius={10} /><h2>Crear plantilla</h2></div>
        <form className="dialog-form" onSubmit={(e) => { e.preventDefault(); if (complete) onCreate(trimmed); }}>
          <div className="dialog-body">
            <p className="dialog-text">Guarda el Windows de {vm.name}, con sus apps y ajustes, para crear otras máquinas en segundos. {vm.name} sigue igual.</p>
            <div className="field">
              <label className="field-top" htmlFor="tpl-name"><span>Nombre</span></label>
              <input id="tpl-name" className="text-input" value={name} autoFocus onChange={(e) => setName(e.target.value)} />
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
        <div className="dialog-head"><Bauhaus name={vm.name} size={40} radius={10} /><h2>Eliminar {vm.name}</h2></div>
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

function Options({ vm, host, busy, startJob, run }: Pick<Props, "vm" | "host" | "busy" | "startJob" | "run">) {
  const initial = {
    cpu: vm.options!.cpu, memoryGB: vm.options!.memoryGB, gpuPercent: vm.options!.gpuPercent, diskGB: vm.options!.diskGB,
    resolution: vm.client?.resolution ?? "1920x1080", fps: vm.client?.fps ?? 60,
    displayMode: (vm.client?.displayMode === "windowed" ? "windowed" : "fullscreen") as DisplayMode,
    captureMode: vm.options!.captureMode ?? "ddx",
    networkIsolation: vm.options!.networkIsolation ?? true,
  };
  const [draft, setDraft] = useState(initial);
  const [saved, setSaved] = useState(false);
  const key = JSON.stringify(initial);
  useEffect(() => setDraft(JSON.parse(key)), [key]);
  useEffect(() => { if (!saved) return; const t = setTimeout(() => setSaved(false), 2500); return () => clearTimeout(t); }, [saved]);

  const maxCpu = Math.max(2, (host?.logicalProcessors ?? 12) - 1);
  const maxMem = Math.max(4, (host?.memoryGB ?? 16) - 4);
  // A disk only grows; a fixed one needs that much free space on the host (keeping 10 GB for it).
  const maxDisk = Math.max(initial.diskGB, Math.min(1024, initial.diskGB + (vm.options!.diskType === "Fixed" ? vm.options!.diskFreeGB - 10 : 1024)));
  const vmDirty = draft.cpu !== initial.cpu || draft.memoryGB !== initial.memoryGB || draft.gpuPercent !== initial.gpuPercent || draft.diskGB !== initial.diskGB;
  const clientDirty = draft.resolution !== initial.resolution || draft.fps !== initial.fps || draft.displayMode !== initial.displayMode;
  const captureDirty = draft.captureMode !== initial.captureMode;
  const networkDirty = draft.networkIsolation !== initial.networkIsolation;
  const off = vm.state === "Off";

  const save = async () => {
    if (clientDirty && !(await run(vm.name, "Guardando", () => api.setClient(vm.name, draft.resolution, draft.fps, draft.displayMode !== initial.displayMode ? draft.displayMode : undefined)))) return;
    if (captureDirty && !(await run(vm.name, "Cambiando la captura", () => api.setCapture(vm.name, draft.captureMode)))) return;
    if (networkDirty && !(await run(vm.name, "Cambiando la red", () => api.setNetworkIsolation(vm.name, draft.networkIsolation)))) return;
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
      <h2 className="section-title">Opciones</h2>
      <div className="options">
        <div className="field">
          <div className="field-top"><span>Procesador</span><strong>{draft.cpu} hilos</strong></div>
          <Slider label="Hilos" value={Math.min(draft.cpu, maxCpu)} min={2} max={maxCpu} onChange={(cpu) => setDraft({ ...draft, cpu })} />
        </div>
        <div className="field">
          <div className="field-top"><span>Memoria</span><strong>{draft.memoryGB} GB</strong></div>
          <Slider label="Memoria" value={Math.min(draft.memoryGB, maxMem)} min={4} max={maxMem} onChange={(memoryGB) => setDraft({ ...draft, memoryGB })} />
        </div>
        <div className="field">
          <div className="field-top"><span>GPU para la VM</span><strong>{draft.gpuPercent} %</strong></div>
          <Slider label="GPU" value={draft.gpuPercent} min={10} max={100} step={10} onChange={(gpuPercent) => setDraft({ ...draft, gpuPercent })} />
        </div>
        <div className="field">
          <div className="field-top"><span>Disco</span><strong>{draft.diskGB} GB</strong></div>
          {vm.options!.diskType === "Differencing" ? <span className="hint">Sobre una plantilla: mide lo mismo que ella</span> : maxDisk > initial.diskGB
            ? <Slider label="Disco" value={draft.diskGB} min={initial.diskGB} max={maxDisk} step={8} onChange={(diskGB) => setDraft({ ...draft, diskGB })} />
            : <span className="hint">Sin espacio libre en el equipo para ampliarlo</span>}
        </div>
        {vm.streaming && (
          <div className="field wide">
            <div className="field-top"><span>Moonlight</span></div>
            <div className="segment-row">
              <Segmented value={draft.resolution} onChange={(resolution) => setDraft({ ...draft, resolution })}
                options={RESOLUTIONS.map((r) => ({ value: r, label: r.split("x")[1] + "p" }))} />
              <Segmented value={draft.fps} onChange={(fps) => setDraft({ ...draft, fps })} options={FPS.map((f) => ({ value: f, label: `${f} FPS` }))} />
              <Segmented value={draft.displayMode} onChange={(displayMode) => setDraft({ ...draft, displayMode })} options={[
                { value: "fullscreen", label: <><IconArrowsMaximize size={15} />Pantalla completa</> },
                { value: "windowed", label: <><IconAppWindow size={15} />Ventana</> },
              ]} />
            </div>
          </div>
        )}
        {vm.streaming && (
          <div className="field">
            <div className="field-top"><span>Captura</span></div>
            <div className="segment-row">
              <Segmented value={draft.captureMode} onChange={(captureMode) => setDraft({ ...draft, captureMode })} options={[
                { value: "ddx", label: <><IconScreenShare size={15} />Estándar</> },
                { value: "wgc", label: <><IconMaximize size={15} />Pantalla completa exclusiva</> },
              ]} />
            </div>
            <span className="hint">{draft.captureMode === "wgc"
              ? "Muestra programas en pantalla completa exclusiva. Los avisos de administrador de Windows no se ven en el stream."
              : "Muestra todo, incluidos los avisos de administrador. Los programas en pantalla completa exclusiva se ven en negro."}</span>
          </div>
        )}
        <div className="field">
          <div className="field-top"><span>Red</span></div>
          <div className="segment-row">
            <Segmented value={draft.networkIsolation} onChange={(networkIsolation) => setDraft({ ...draft, networkIsolation })} options={[
              { value: true, label: <><IconWorld size={15} />Solo internet</> },
              { value: false, label: <><IconNetwork size={15} />Internet y red local</> },
            ]} />
          </div>
          <span className="hint">{draft.networkIsolation
            ? "La VM no llega a este equipo ni a tu red local; si se infecta, no puede salir de ahí."
            : "La VM llega a este equipo y a los demás de tu red. Úsalo solo si necesitas, por ejemplo, un NAS."}</span>
        </div>
      </div>
      {(vmDirty || clientDirty || captureDirty || networkDirty || saved) && (
        <div className="options-foot">
          {saved && !vmDirty && !clientDirty && !captureDirty && !networkDirty ? (
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
