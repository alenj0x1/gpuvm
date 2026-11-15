import { useEffect, useState } from "react";
import { MachineCube, type CubeMachine } from "./MachineCube";
import { IconAppWindow, IconBrandWindows, IconDeviceDesktop, IconExternalLink, IconPalette, IconServer, IconHandStop, IconLayoutBottombarCollapse, IconMoon, IconPlayerPlay, IconPlayerStop, IconPlugConnected, IconPlugConnectedX, IconPower, IconSun } from "@tabler/icons-react";
import { service, type ServiceStatus } from "./api";
import { ACCENTS, savePrefs, usePrefs, type ClosePref, type ServicePref, type ThemePref, type VmsOnQuitPref } from "./prefs";
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

type PrefSection = "look" | "window" | "machines" | "service";
const PREF_SECTIONS: { id: PrefSection; label: string; icon: React.ReactNode }[] = [
  { id: "look", label: "Apariencia", icon: <IconPalette size={17} /> },
  { id: "window", label: "Ventana", icon: <IconAppWindow size={17} /> },
  { id: "machines", label: "Máquinas", icon: <IconDeviceDesktop size={17} /> },
  { id: "service", label: "Servicio", icon: <IconServer size={17} /> },
];

/** A machine to show the theme and accent on, the same cube as every machine's page. */
const PREVIEW: CubeMachine = { power: "on", cores: 8, memoryGB: 16, gpuPercent: 60, diskGB: 256, usage: { cpu: 35, gpu: 55, mem: 45, disk: 10 }, apps: ["steam", "discord", "chrome"], removed: 0 };

/** Settings: the sections on the left, their options in the middle and, beside them, a live preview of how the app
 *  looks with the chosen theme and accent. */
export function Preferences() {
  const prefs = usePrefs();
  const monitors = useMonitors();
  const sections = PREF_SECTIONS.filter((x) => x.id !== "machines" || monitors.length > 1);
  // The list on the left switches which section is shown: everything fits on screen, so scrolling to it did nothing.
  const [active, setActive] = useState<PrefSection>("look");
  const shown = sections.some((x) => x.id === active) ? active : sections[0].id;
  const section = (id: PrefSection, children: React.ReactNode) => {
    if (id !== shown) return null;
    const x = PREF_SECTIONS.find((y) => y.id === id)!;
    return (
      <section className="card pref-section" key={id}>
        <div className="pref-head"><span className="opt-icon">{x.icon}</span><h2>{x.label}</h2></div>
        <div className="pref-list">{children}</div>
      </section>
    );
  };

  return (
    <div className="main prefs">
      <nav className="pref-nav" role="tablist" aria-label="Secciones de Ajustes">
        {sections.map((x) => (
          <button key={x.id} type="button" role="tab" aria-selected={x.id === shown} className={`pref-nav-item${x.id === shown ? " on" : ""}`} onClick={() => setActive(x.id)}>{x.icon}{x.label}</button>
        ))}
      </nav>
      <div className="pref-sections">
        {section("look", (
          <>
            <div className="pref-row">
              <div className="pref-text"><strong>Tema</strong><span>Sigue al de Windows o queda fijo.</span></div>
              <Segmented<ThemePref> value={prefs.theme} onChange={(theme) => savePrefs({ theme })} options={[
                { value: "system", label: <><IconDeviceDesktop size={15} />Sistema</> },
                { value: "light", label: <><IconSun size={15} />Claro</> },
                { value: "dark", label: <><IconMoon size={15} />Oscuro</> },
              ]} />
            </div>
            <div className="pref-row">
              <div className="pref-text"><strong>Color de énfasis</strong><span>Botones, selección, barras de uso y el holograma de las máquinas.</span></div>
              <div className="swatches" role="radiogroup" aria-label="Color de énfasis">
                {ACCENTS.map((a) => (
                  <button type="button" key={a.id} role="radio" aria-checked={prefs.accent === a.id} title={a.name} aria-label={a.name}
                    className={`swatch${prefs.accent === a.id ? " on" : ""}`} onClick={() => savePrefs({ accent: a.id })}>
                    {/* Half as it looks in light, half in dark, split by a wavy diagonal. */}
                    <svg viewBox="0 0 32 32" aria-hidden="true">
                      <rect width="32" height="32" fill={a.dark} />
                      <path d="M0 0H32C28 4 25 3 22 7S16 12 12 15 6 21 3 25 0 30 0 32Z" fill={a.light} />
                    </svg>
                  </button>
                ))}
              </div>
            </div>
          </>
        ))}
        {section("window", (
          <>
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
          </>
        ))}
        {monitors.length > 1 && section("machines", (
          <div className="pref-row">
            <div className="pref-text"><strong>Abrir las máquinas en</strong><span>Cada máquina puede tener el suyo en sus opciones.</span></div>
            <div className="pref-side pref-stack">
              <MonitorPicker monitors={monitors} value={prefs.monitor} onChange={(monitor) => savePrefs({ monitor })} />
            </div>
          </div>
        ))}
        {section("service", <ServicePrefs />)}
      </div>
      {/* Always in view: the theme and accent applied to a machine and to the app's own controls. */}
      <aside className="card pref-preview" aria-label="Vista previa">
        <div className="pref-preview-cube"><MachineCube machine={PREVIEW} name="vista previa" /></div>
        <div className="pref-preview-ui">
          <div className="pref-preview-name"><span className="state-pill"><span className="dot Running" />Encendida</span><span className="pref-preview-meta">GPU 55 %</span></div>
          <div className="pref-preview-bars">
            <span className="res-cpu">Procesador</span><div className="bar"><span style={{ width: "35%" }} /></div>
            <span className="res-mem">Memoria</span><div className="bar"><span style={{ width: "45%" }} /></div>
          </div>
          <div className="pref-preview-actions"><button type="button" className="btn ghost" tabIndex={-1}>Ver máquina</button><button type="button" className="primary" tabIndex={-1}><IconExternalLink size={16} />Abrir</button></div>
        </div>
      </aside>
    </div>
  );
}
