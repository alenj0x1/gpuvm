import { useEffect, useRef, useState } from "react";
import {
  IconCpu, IconDeviceDesktop, IconDots, IconExternalLink, IconKey, IconLoader2, IconPlayerPause, IconPlayerPlay,
  IconPower, IconRefresh, IconRefreshAlert, IconTrash, IconPlugOff, IconClock, IconTopologyStar3, IconPalette,
  IconBolt, IconDeviceFloppy, IconLink, IconDownload, IconCheck, IconChartLine,
} from "@tabler/icons-react";
import type { HostInfo, Sample, VmOverview } from "./types";
import { Bauhaus, machineColor, patternVariant, setPatternVariant, tintVars } from "./bauhaus";
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

const RESOLUTIONS = ["1280x720", "1920x1080", "2560x1440", "3840x2160"];
const FPS = [30, 60, 120, 144];
const TRANSITION: Record<string, string> = { Starting: "Encendiendo", Stopping: "Apagando", Saving: "Guardando", Pausing: "Pausando", Resuming: "Reanudando" };

export function VmView({ vm, host, samples, busy, startJob, run, onRemoved }: Props) {
  const [variant, setVariant] = useState(() => patternVariant(vm.name));
  const color = machineColor(vm.name, variant);
  const running = vm.state === "Running";
  const off = vm.state === "Off";

  return (
    <div className="main" style={tintVars(color) as React.CSSProperties}>
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

  let primary: { label: string; icon: React.ReactNode; onClick: () => void };
  if (paused) primary = { label: "Reanudar", icon: <IconPlayerPlay size={17} />, onClick: () => power("Resume", "Reanudando") };
  else if (vm.managed && vm.streaming) {
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
      <Bauhaus name={vm.name} variant={variant} size={56} radius={14} />
      <div style={{ minWidth: 0 }}>
        <h1>{vm.name}</h1>
        <div className="meta">
          <span className="state-pill"><span className={`dot ${vm.state}`} />{stateLabel[vm.state] ?? vm.state}</span>
          {[vm.edition, vm.gpuName && vm.hasGpu ? vm.gpuName.replace("NVIDIA GeForce ", "") : null, vm.profile].filter(Boolean).map((t) => (
            <span key={t as string}>· {t}</span>
          ))}
        </div>
      </div>
      <div className="actions" ref={menuRef}>
        <button className="icon-btn" aria-label="Más opciones" aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu((m) => !m)}><IconDots size={18} /></button>
        {working ? (
          <span className="primary busy" role="status" title={working}><IconLoader2 size={17} className="spin" /><span className="ellipsis">{working}</span></span>
        ) : (
          <button className="primary" onClick={primary.onClick}>{primary.icon}<span className="ellipsis">{primary.label}</span></button>
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
  const initial = { cpu: vm.options!.cpu, memoryGB: vm.options!.memoryGB, gpuPercent: vm.options!.gpuPercent, resolution: vm.client?.resolution ?? "1920x1080", fps: vm.client?.fps ?? 60 };
  const [draft, setDraft] = useState(initial);
  const [saved, setSaved] = useState(false);
  const key = JSON.stringify(initial);
  useEffect(() => setDraft(JSON.parse(key)), [key]);
  useEffect(() => { if (!saved) return; const t = setTimeout(() => setSaved(false), 2500); return () => clearTimeout(t); }, [saved]);

  const maxCpu = Math.max(2, (host?.logicalProcessors ?? 12) - 1);
  const maxMem = Math.max(4, (host?.memoryGB ?? 16) - 4);
  const vmDirty = draft.cpu !== initial.cpu || draft.memoryGB !== initial.memoryGB || draft.gpuPercent !== initial.gpuPercent;
  const clientDirty = draft.resolution !== initial.resolution || draft.fps !== initial.fps;
  const off = vm.state === "Off";

  const save = async () => {
    if (clientDirty && !(await run(vm.name, "Guardando", () => api.setClient(vm.name, draft.resolution, draft.fps)))) return;
    if (!vmDirty) { setSaved(true); return; }
    const override = { vm: { cpu: { count: draft.cpu }, memoryGB: draft.memoryGB }, gpu: { allocationPercent: draft.gpuPercent } };
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
        {vm.streaming && (
          <div className="field">
            <div className="field-top"><span>Moonlight</span></div>
            <div className="segment-row">
              <Segmented value={draft.resolution} onChange={(resolution) => setDraft({ ...draft, resolution })}
                options={RESOLUTIONS.map((r) => ({ value: r, label: r.split("x")[1] + "p" }))} />
              <Segmented value={draft.fps} onChange={(fps) => setDraft({ ...draft, fps })} options={FPS.map((f) => ({ value: f, label: `${f} FPS` }))} />
            </div>
          </div>
        )}
      </div>
      {(vmDirty || clientDirty || saved) && (
        <div className="options-foot">
          {saved && !vmDirty && !clientDirty ? (
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
