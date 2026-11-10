import { useEffect, useState } from "react";
import { IconAppWindow, IconBrandWindows, IconDeviceDesktop, IconHandStop, IconLayoutBottombarCollapse, IconMoon, IconPlayerPlay, IconPlayerStop, IconPlugConnected, IconPlugConnectedX, IconPower, IconSun } from "@tabler/icons-react";
import { service, type ServiceStatus } from "./api";
import { savePrefs, usePrefs, type ClosePref, type ServicePref, type ThemePref, type VmsOnQuitPref } from "./prefs";
import { Segmented, humanError } from "./ui";
import { MonitorPicker, useMonitors } from "./pickers";

const SERVICE_TEXT: Record<ServicePref, string> = {
  app: "Se enciende al abrir GpuVM y se apaga al salir, cuando termina lo que estaba haciendo.",
  windows: "Se enciende con Windows y queda listo antes de abrir GpuVM.",
  manual: "Solo se enciende y se apaga desde aquí.",
};

const STATE_TEXT: Record<ServiceStatus["state"], string> = {
  running: "En marcha",
  starting: "Iniciando…",
  stopping: "Deteniéndose…",
  stopped: "Detenido",
  missing: "No instalado",
};

const DOT: Record<ServiceStatus["state"], string> = { running: "Running", starting: "Paused", stopping: "Paused", stopped: "Off", missing: "Off" };

/** "Servicio de GpuVM": when the service runs, and (manual) starting or stopping it. */
function ServicePrefs() {
  const prefs = usePrefs();
  const [status, setStatus] = useState<ServiceStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    const read = () => service.status().then((s) => { if (alive) setStatus(s); }).catch(() => {});
    read();
    const timer = setInterval(read, 2000);
    return () => { alive = false; clearInterval(timer); };
  }, []);

  // Windows is the reference for "with Windows": the preference follows it if it was changed elsewhere.
  useEffect(() => {
    if (!status || status.state === "missing") return;
    if (status.withWindows && prefs.service !== "windows") savePrefs({ service: "windows" });
    if (!status.withWindows && prefs.service === "windows") savePrefs({ service: "app" });
  }, [status?.withWindows]); // eslint-disable-line react-hooks/exhaustive-deps

  const choose = async (mode: ServicePref) => {
    setError(null);
    // Starting with Windows or not changes the service's settings: Windows asks for administrator once.
    if ((mode === "windows") !== (prefs.service === "windows")) {
      setBusy(true);
      try { await service.setStartup(mode === "windows"); }
      catch (e) { setError(humanError(e)); setBusy(false); return; }
      setBusy(false);
    }
    savePrefs({ service: mode });
  };

  const toggle = async () => {
    setError(null);
    setBusy(true);
    try { await (status?.state === "running" ? service.stop() : service.start()); setStatus(await service.status()); }
    catch (e) { setError(humanError(e)); }
    setBusy(false);
  };

  const running = status?.state === "running";
  return (
    <>
      <div className="pref-row">
        <div className="pref-text"><strong>Servicio de GpuVM</strong><span>{SERVICE_TEXT[prefs.service]}</span></div>
        <Segmented<ServicePref> value={prefs.service} onChange={(mode) => { if (!busy) choose(mode); }} options={[
          { value: "app", label: <><IconAppWindow size={15} />Con GpuVM</> },
          { value: "windows", label: <><IconBrandWindows size={15} />Con Windows</> },
          { value: "manual", label: <><IconHandStop size={15} />Manual</> },
        ]} />
      </div>
      <div className="pref-row">
        <div className="pref-text">
          <strong>Estado</strong>
          {error ? <span className="error-text">{error}</span> : <span>El servicio hace el trabajo de Hyper-V para GpuVM.</span>}
        </div>
        <div className="pref-side">
          {status && <span className="pref-state"><span className={`dot ${DOT[status.state]}`} />{STATE_TEXT[status.state]}</span>}
          {prefs.service === "manual" && status && (status.state === "running" || status.state === "stopped") && (
            <button className="btn" onClick={toggle} disabled={busy}>
              {running ? <><IconPlugConnectedX size={16} />Detener</> : <><IconPlugConnected size={16} />Iniciar</>}
            </button>
          )}
        </div>
      </div>
    </>
  );
}

export function Preferences() {
  const prefs = usePrefs();
  const monitors = useMonitors();
  return (
    <div className="main">
      <div className="card">
        <h2 className="section-title">Preferencias</h2>
        <div className="pref-list">
          <div className="pref-row">
            <div className="pref-text"><strong>Tema</strong></div>
            <Segmented<ThemePref> value={prefs.theme} onChange={(theme) => savePrefs({ theme })} options={[
              { value: "system", label: <><IconDeviceDesktop size={15} />Sistema</> },
              { value: "light", label: <><IconSun size={15} />Claro</> },
              { value: "dark", label: <><IconMoon size={15} />Oscuro</> },
            ]} />
          </div>
          <div className="pref-row">
            <div className="pref-text"><strong>Al cerrar la ventana</strong><span>En la bandeja, GpuVM sigue abierta junto al reloj y los trabajos en curso continúan.</span></div>
            <Segmented<ClosePref> value={prefs.close} onChange={(close) => savePrefs({ close })} options={[
              { value: "quit", label: <><IconPower size={15} />Salir por completo</> },
              { value: "tray", label: <><IconLayoutBottombarCollapse size={15} />Quedarse en la bandeja</> },
            ]} />
          </div>
          <div className="pref-row">
            <div className="pref-text"><strong>Al salir de GpuVM</strong><span>Apagarlas cierra Windows en cada máquina y libera su memoria.</span></div>
            <Segmented<VmsOnQuitPref> value={prefs.vmsOnQuit} onChange={(vmsOnQuit) => savePrefs({ vmsOnQuit })} options={[
              { value: "keep", label: <><IconPlayerPlay size={15} />Dejarlas encendidas</> },
              { value: "stop", label: <><IconPlayerStop size={15} />Apagarlas</> },
            ]} />
          </div>
          {monitors.length > 1 && (
            <div className="pref-row">
              <div className="pref-text"><strong>Abrir las máquinas en</strong><span>Cada máquina puede tener el suyo en sus opciones.</span></div>
              <div className="pref-side pref-stack">
                <MonitorPicker monitors={monitors} value={prefs.monitor} onChange={(monitor) => savePrefs({ monitor })} />
              </div>
            </div>
          )}
          <ServicePrefs />
        </div>
      </div>
    </div>
  );
}
