import { useEffect, useState } from "react";
import { MachineCube, type CubeMachine } from "./MachineCube";
import { IconAppWindow, IconCamera, IconFolder, IconFolderOpen, IconHistory, IconHistoryOff, IconBrandWindows, IconDeviceDesktop, IconExternalLink, IconPalette, IconServer, IconHandStop, IconLayoutBottombarCollapse, IconMoon, IconPlayerPlay, IconPlayerStop, IconPlugConnected, IconPlugConnectedX, IconPower, IconShieldLock, IconShieldOff, IconSun } from "@tabler/icons-react";
import { inTauri, service, type ServiceStatus } from "./api";
import { ACCENTS, savePrefs, usePrefs, type ClosePref, type ServicePref, type ThemePref, type ViewerHomePref, type VmsOnQuitPref } from "./prefs";
import { Segmented, Slider, humanError } from "./ui";
import { t, type LangPref } from "./i18n";
import { MonitorPicker, useMonitors } from "./pickers";

// Functions, so each text is read in the language of the moment.
const serviceText = (): Record<ServicePref, string> => ({
  app: t("Se enciende al abrir GpuVM y se apaga al salir, cuando termina lo que estaba haciendo."),
  windows: t("Se enciende con Windows y queda listo antes de abrir GpuVM."),
  manual: t("Solo se enciende y se apaga desde aquí."),
});

const stateText = (): Record<ServiceStatus["state"], string> => ({
  running: t("En marcha"),
  starting: t("Iniciando…"),
  stopping: t("Deteniéndose…"),
  stopped: t("Detenido"),
  missing: t("No instalado"),
});

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
        <div className="pref-text"><strong>{t("Servicio de GpuVM")}</strong><span>{serviceText()[prefs.service]}</span></div>
        <Segmented<ServicePref> value={prefs.service} onChange={(mode) => { if (!busy) choose(mode); }} options={[
          { value: "app", label: <><IconAppWindow size={15} />{t("Con GpuVM")}</> },
          { value: "windows", label: <><IconBrandWindows size={15} />{t("Con Windows")}</> },
          { value: "manual", label: <><IconHandStop size={15} />{t("Manual")}</> },
        ]} />
      </div>
      <div className="pref-row">
        <div className="pref-text">
          <strong>{t("Estado")}</strong>
          {error ? <span className="error-text">{error}</span> : <span>{t("El servicio hace el trabajo de Hyper-V para GpuVM.")}</span>}
        </div>
        <div className="pref-side">
          {status && <span className="pref-state"><span className={`dot ${DOT[status.state]}`} />{stateText()[status.state]}</span>}
          {prefs.service === "manual" && status && (status.state === "running" || status.state === "stopped") && (
            <button className="btn" onClick={toggle} disabled={busy}>
              {running ? <><IconPlugConnectedX size={16} />{t("Detener")}</> : <><IconPlugConnected size={16} />{t("Iniciar")}</>}
            </button>
          )}
        </div>
      </div>
    </>
  );
}

/** The limits offered for the animations' frames a second, from lightest to none (0: as many as the monitor shows). */
const ANIM_FPS = [15, 30, 60, 120, 0];
/** The option a stored limit is shown at: its own, or the nearest one (no limit stays last). */
const animFpsIndex = (fps: number) => (fps > 0 ? ANIM_FPS.slice(0, -1).reduce((best, f, i) => (Math.abs(f - fps) < Math.abs(ANIM_FPS[best] - fps) ? i : best), 0) : ANIM_FPS.length - 1);

type PrefSection = "look" | "window" | "machines" | "captures" | "service";
const prefSections = (): { id: PrefSection; label: string; icon: React.ReactNode }[] => [
  { id: "look", label: t("Apariencia"), icon: <IconPalette size={17} /> },
  { id: "window", label: t("Ventana"), icon: <IconAppWindow size={17} /> },
  { id: "machines", label: t("Máquinas"), icon: <IconDeviceDesktop size={17} /> },
  { id: "captures", label: t("Capturas"), icon: <IconCamera size={17} /> },
  { id: "service", label: t("Servicio"), icon: <IconServer size={17} /> },
];

/** "Capturas": the last 30 s kept in memory (off by default), and where screenshots and videos go. */
function CapturePrefs() {
  const prefs = usePrefs();
  const [folders, setFolders] = useState<{ shots: string | null; videos: string | null; hevc?: boolean }>({ shots: null, videos: null });
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!inTauri) { setFolders({ shots: "C:\\Users\\…\\Pictures\\GpuVM", videos: "C:\\Users\\…\\Videos\\GpuVM", hevc: false }); return; }
    import("@tauri-apps/api/core").then(({ invoke }) => invoke<{ shots: string | null; videos: string | null; hevc: boolean }>("capture_folders")).then(setFolders).catch(() => {});
  }, [prefs.shotsDir, prefs.videosDir]);

  const choose = async (video: boolean) => {
    setError(null);
    if (!inTauri) return;
    const { open } = await import("@tauri-apps/plugin-dialog");
    const dir = await open({ directory: true, defaultPath: (video ? folders.videos : folders.shots) ?? undefined });
    if (typeof dir === "string") savePrefs(video ? { videosDir: dir } : { shotsDir: dir });
  };
  const show = async (video: boolean) => {
    setError(null);
    if (!inTauri) return;
    const { invoke } = await import("@tauri-apps/api/core");
    invoke("capture_open_folder", { video }).catch((e) => setError(humanError(e)));
  };
  const folderRow = (video: boolean) => {
    const custom = video ? prefs.videosDir : prefs.shotsDir;
    const path = video ? folders.videos : folders.shots;
    return (
      <div className="pref-row">
        <div className="pref-text">
          <strong>{video ? t("Carpeta de videos") : t("Carpeta de capturas")}</strong>
          <span className="pref-path" title={path ?? ""}>{path ? t("{path}, una carpeta por máquina", { path }) : "—"}</span>
        </div>
        <div className="pref-side">
          {custom && <button type="button" className="btn ghost" onClick={() => savePrefs(video ? { videosDir: "" } : { shotsDir: "" })}>{t("Restablecer")}</button>}
          <button type="button" className="btn ghost" onClick={() => show(video)}><IconFolderOpen size={16} />{t("Abrir")}</button>
          <button type="button" className="btn" onClick={() => choose(video)}><IconFolder size={16} />{t("Elegir carpeta")}</button>
        </div>
      </div>
    );
  };

  return (
    <>
      <div className="pref-row">
        <div className="pref-text">
          <strong>{t("Guardar los últimos 30 s")}</strong>
          <span>{t("El visor guarda en memoria los últimos 30 segundos de la imagen, listos para guardarse como clip con Ctrl+Alt+Shift+B o desde el panel. Ocupa unos 130 MB a 35 Mb/s.")}</span>
        </div>
        <Segmented<boolean> value={prefs.replay} onChange={(replay) => savePrefs({ replay })} options={[
          { value: false, label: <><IconHistoryOff size={15} />{t("Desactivado")}</> },
          { value: true, label: <><IconHistory size={15} />{t("Activado")}</> },
        ]} />
      </div>
      {folderRow(false)}
      {folderRow(true)}
      {folders.hevc === false && (
        <div className="pref-row">
          <div className="pref-text">
            <strong>{t("Videos en HEVC")}</strong>
            <span>{t("Las grabaciones de máquinas que transmiten en HEVC no se abren en Películas y TV sin la extensión HEVC de Microsoft. El navegador y VLC ya las reproducen.")}</span>
          </div>
          <div className="pref-side">
            <button type="button" className="btn" onClick={() => import("@tauri-apps/api/core").then(({ invoke }) => invoke("capture_get_hevc")).catch((e) => setError(humanError(e)))}>
              <IconExternalLink size={16} />{t("Ver en Microsoft Store")}
            </button>
          </div>
        </div>
      )}
      <div className="pref-row">
        <div className="pref-text">
          <strong>{t("Atajos")}</strong>
          {error ? <span className="error-text">{error}</span> : <span>{t("Ctrl+Alt+Shift+P captura la imagen y Ctrl+Alt+Shift+R empieza o detiene la grabación.")}</span>}
        </div>
      </div>
    </>
  );
}

/** A machine to show the theme and accent on, the same cube as every machine's page. */
const PREVIEW: CubeMachine = { power: "on", cores: 8, memoryGB: 16, gpuPercent: 60, diskGB: 256, usage: { cpu: 35, gpu: 55, mem: 45, disk: 10 }, apps: ["steam", "discord", "chrome"], removed: 0 };

/** Settings: the sections on the left, their options in the middle and, beside them, a live preview of how the app
 *  looks with the chosen theme and accent. */
export function Preferences() {
  const prefs = usePrefs();
  const monitors = useMonitors();
  const all = prefSections();
  const sections = all.filter((x) => x.id !== "machines" || monitors.length > 1);
  // The list on the left switches which section is shown: everything fits on screen, so scrolling to it did nothing.
  const [active, setActive] = useState<PrefSection>("look");
  const shown = sections.some((x) => x.id === active) ? active : sections[0].id;
  const section = (id: PrefSection, children: React.ReactNode) => {
    if (id !== shown) return null;
    const x = all.find((y) => y.id === id)!;
    return (
      <section className="card pref-section" key={id}>
        <div className="pref-head"><span className="opt-icon">{x.icon}</span><h2>{x.label}</h2></div>
        <div className="pref-list">{children}</div>
      </section>
    );
  };

  return (
    <div className="main prefs">
      <nav className="pref-nav" role="tablist" aria-label={t("Secciones de Ajustes")}>
        {sections.map((x) => (
          <button key={x.id} type="button" role="tab" aria-selected={x.id === shown} className={`pref-nav-item${x.id === shown ? " on" : ""}`} onClick={() => setActive(x.id)}>{x.icon}{x.label}</button>
        ))}
      </nav>
      <div className="pref-sections">
        {section("look", (
          <>
            <div className="pref-row">
              <div className="pref-text"><strong>{t("Tema")}</strong><span>{t("Sigue al de Windows o queda fijo.")}</span></div>
              <Segmented<ThemePref> value={prefs.theme} onChange={(theme) => savePrefs({ theme })} options={[
                { value: "system", label: <><IconDeviceDesktop size={15} />{t("Sistema")}</> },
                { value: "light", label: <><IconSun size={15} />{t("Claro")}</> },
                { value: "dark", label: <><IconMoon size={15} />{t("Oscuro")}</> },
              ]} />
            </div>
            <div className="pref-row">
              <div className="pref-text"><strong>{t("Idioma")}</strong><span>{t("Sigue al de Windows o queda fijo.")}</span></div>
              {/* Each language is named in itself, so it can be found whatever language the app is in. */}
              <Segmented<LangPref> value={prefs.lang} onChange={(lang) => savePrefs({ lang })} options={[
                { value: "system", label: <><IconDeviceDesktop size={15} />Windows</> },
                { value: "es", label: "Español" }, // i18n-ignore: each language is named in itself
                { value: "en", label: "English" },
              ]} />
            </div>
            <div className="pref-row">
              <div className="pref-text"><strong>{t("Color de énfasis")}</strong><span>{t("Botones, selección, barras de uso y el holograma de las máquinas.")}</span></div>
              <div className="swatches" role="radiogroup" aria-label={t("Color de énfasis")}>
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
            <div className="pref-row">
              <div className="pref-text"><strong>{t("Fluidez de las animaciones")}</strong><span>{t("Cuadros por segundo de hologramas y escenas. Menos dejan más GPU libre para las máquinas.")}</span></div>
              <div className="pref-side pref-slider">
                <Slider label={t("Fluidez de las animaciones")} min={0} max={ANIM_FPS.length - 1} marks={ANIM_FPS.map((_, i) => i)}
                  value={animFpsIndex(prefs.animFps)} format={(i) => (ANIM_FPS[i] ? String(ANIM_FPS[i]) : t("Máx"))}
                  onChange={(i) => savePrefs({ animFps: ANIM_FPS[i] })} />
              </div>
            </div>
            <div className="pref-row">
              <div className="pref-text"><strong>{t("Calidad de las animaciones")}</strong><span>{t("La resolución con que se dibujan. Más baja se ve menos nítida y usa menos GPU.")}</span></div>
              <div className="pref-side pref-slider">
                <Slider label={t("Calidad de las animaciones")} min={25} max={100} step={25} marks={[25, 50, 75, 100]}
                  value={prefs.animQuality} format={(v) => `${v} %`} onChange={(animQuality) => savePrefs({ animQuality })} />
              </div>
            </div>
          </>
        ))}
        {section("window", (
          <>
            <div className="pref-row">
              <div className="pref-text"><strong>{t("Al cerrar la ventana")}</strong><span>{t("En la bandeja, GpuVM sigue abierta junto al reloj y los trabajos en curso continúan.")}</span></div>
              <Segmented<ClosePref> value={prefs.close} onChange={(close) => savePrefs({ close })} options={[
                { value: "quit", label: <><IconPower size={15} />{t("Salir por completo")}</> },
                { value: "tray", label: <><IconLayoutBottombarCollapse size={15} />{t("Quedarse en la bandeja")}</> },
              ]} />
            </div>
            <div className="pref-row">
              <div className="pref-text"><strong>{t("Al volver a Inicio desde una máquina")}</strong><span>{t("Conectada, vuelves a su imagen al instante. Mientras tanto usa un poco de la GPU de este equipo.")}</span></div>
              <Segmented<ViewerHomePref> value={prefs.viewerHome} onChange={(viewerHome) => savePrefs({ viewerHome })} options={[
                { value: "keep", label: <><IconPlugConnected size={15} />{t("Mantenerla conectada")}</> },
                { value: "disconnect", label: <><IconPlugConnectedX size={15} />{t("Desconectarla")}</> },
              ]} />
            </div>
            <div className="pref-row">
              <div className="pref-text"><strong>{t("Al salir de GpuVM")}</strong><span>{t("Apagarlas cierra Windows en cada máquina y libera su memoria.")}</span></div>
              <Segmented<VmsOnQuitPref> value={prefs.vmsOnQuit} onChange={(vmsOnQuit) => savePrefs({ vmsOnQuit })} options={[
                { value: "keep", label: <><IconPlayerPlay size={15} />{t("Dejarlas encendidas")}</> },
                { value: "stop", label: <><IconPlayerStop size={15} />{t("Apagarlas")}</> },
              ]} />
            </div>
            {prefs.vmsOnQuit === "keep" && (
              <div className="pref-row">
                <div className="pref-text"><strong>{t("Avisos de administrador después de salir")}</strong><span>{t("GpuVM se queda junto al reloj, sin ventanas, mientras alguna máquina siga encendida y te muestra cuando pida permiso de administrador.")}</span></div>
                <Segmented<boolean> value={prefs.noticesAfterQuit} onChange={(noticesAfterQuit) => savePrefs({ noticesAfterQuit })} options={[
                  { value: true, label: <><IconShieldLock size={15} />{t("Mostrarlos")}</> },
                  { value: false, label: <><IconShieldOff size={15} />{t("No mostrarlos")}</> },
                ]} />
              </div>
            )}
          </>
        ))}
        {monitors.length > 1 && section("machines", (
          <div className="pref-row">
            <div className="pref-text"><strong>{t("Abrir las máquinas en")}</strong><span>{t("Cada máquina puede tener el suyo en sus opciones.")}</span></div>
            <div className="pref-side pref-stack">
              <MonitorPicker monitors={monitors} value={prefs.monitor} onChange={(monitor) => savePrefs({ monitor })} />
            </div>
          </div>
        ))}
        {section("captures", <CapturePrefs />)}
        {section("service", <ServicePrefs />)}
      </div>
      {/* Always in view: the theme and accent applied to a machine and to the app's own controls. */}
      <aside className="card pref-preview" aria-label={t("Vista previa")}>
        <div className="pref-preview-cube"><MachineCube machine={PREVIEW} name={t("vista previa")} /></div>
        <div className="pref-preview-ui">
          <div className="pref-preview-name"><span className="state-pill"><span className="dot Running" />{t("Encendida")}</span><span className="pref-preview-meta">GPU 55 %</span></div>
          <div className="pref-preview-bars">
            <span className="res-cpu">{t("Procesador")}</span><div className="bar"><span style={{ width: "35%" }} /></div>
            <span className="res-mem">{t("Memoria")}</span><div className="bar"><span style={{ width: "45%" }} /></div>
          </div>
          <div className="pref-preview-actions"><button type="button" className="btn ghost" tabIndex={-1}>{t("Ver máquina")}</button><button type="button" className="primary" tabIndex={-1}><IconExternalLink size={16} />{t("Abrir")}</button></div>
        </div>
      </aside>
    </div>
  );
}
