import { MiniCube } from "./MiniCube";
import { CLEANUP_REMOVED, MachineCube } from "./MachineCube";
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  IconAdjustmentsHorizontal, IconCopyPlus, IconDatabase, IconDeviceFloppy, IconDisc, IconFlask, IconFolderDown, IconLoader2, IconPencil, IconPlus,
  IconRestore, IconStack2, IconTemplate, IconTrash, IconX,
} from "@tabler/icons-react";
import type { VmOverview, AppInfo, BaseInfo, DiskInfo, HostInfo, IsoFile, ProfileInfo, ProfileSettings, SharedDiskInfo, TemplateInfo } from "./types";
import { api, pickFolder, pickIso } from "./api";
import { PatternButton } from "./machineIcon";
import { usePrefs } from "./prefs";
import { AppPicker, CleanupPicker, FpsPicker, IsoPicker, resolveMonitor, useMonitors, useCleanupLevels, RESOLUTIONS, USES, isoDetail, profileLabel, streamUseOf } from "./pickers";
import { Segmented, Slider, humanError, portalRoot, scrollToSection, useFlip, useScrollFade } from "./ui";
import { ResourceChips } from "./resources";
import { NewTemplate } from "./VmView";
import { locale, t, tn } from "./i18n";

export type LibraryTab = "perfiles" | "plantillas" | "discos" | "compartidos" | "isos";

// What each tab loaded last, so switching tabs shows it at once while it refreshes.
const cache: { bases?: BaseInfo[]; profiles?: ProfileInfo[]; apps?: AppInfo[]; disks?: DiskInfo[]; isos?: IsoFile[]; templates?: TemplateInfo[]; shared?: SharedDiskInfo[] } = {};

interface Props {
  tab: LibraryTab;
  onTab: (tab: LibraryTab) => void;
  host: HostInfo | null;
  /** Long jobs (restoring a disk) run like the VM ones, with their progress in the sidebar. */
  startJob: (vm: string, cmd: string, args: Record<string, unknown>, after?: () => void) => void;
  busy: (vm: string) => boolean;
  /** The running job's progress message for a key (a template or shared disk), if any. */
  progress: (key: string) => string | null;
  notify: (kind: "ok" | "error", text: string) => void;
  onOpenVm: (name: string) => void;
  onCreateFromTemplate: (template: string) => void;
}

// Labels are getters so they are read in the language shown.
const SECTIONS: { tab: LibraryTab; readonly label: string; icon: React.ReactNode; readonly desc: string }[] = [
  { tab: "perfiles", get label() { return t("Perfiles"); }, icon: <IconAdjustmentsHorizontal size={17} />, get desc() { return t("Recetas de máquina: recursos, apps y limpieza listos para usar."); } },
  { tab: "plantillas", get label() { return t("Plantillas"); }, icon: <IconTemplate size={17} />, get desc() { return t("Un Windows ya instalado, con sus apps, para crear máquinas en segundos."); } },
  { tab: "compartidos", get label() { return t("Discos compartidos"); }, icon: <IconStack2 size={17} />, get desc() { return t("Se conectan a la máquina que los necesite: tus juegos o archivos, una sola vez."); } },
  { tab: "discos", get label() { return t("Discos de máquinas"); }, icon: <IconDatabase size={17} />, get desc() { return t("El disco de cada máquina y los que quedaron sin máquina."); } },
  { tab: "isos", get label() { return t("ISOs"); }, icon: <IconDisc size={17} />, get desc() { return t("Las imágenes de Windows para crear máquinas desde cero."); } },
];

/** A section's head: its icon, name and what it is for, with the section's own action at the right. */
function SectionHead({ tab }: { tab: LibraryTab }) {
  const x = SECTIONS.find((s) => s.tab === tab)!;
  return (
    <div className="lib-section-head">
      <span className="opt-icon">{x.icon}</span>
      <div className="opt-text"><span className="opt-title">{x.label}</span><span className="opt-desc">{x.desc}</span></div>
    </div>
  );
}

/** The Library on one page: every section one after the other, and a bar on top that marks the one in view and
 *  takes you to the others (the route still names a section, so links from Inicio land on it). */

// The profiles GpuVM ships with describe themselves in the app's language (their JSON keeps an English note).
const BUILT_IN_DESC: Record<string, () => string> = {
  balanced: () => t("Buen rendimiento dejando holgura a tu PC: 8 hilos, 8 GB y disco dinámico."),
  "max-performance": () => t("Máximo rendimiento: procesador reservado al 100 %, la topología de tu PC, 8 GB fijos y Windows optimizado."),
};
export function Library({ tab, onTab, host, startJob, busy, progress, notify, onOpenVm, onCreateFromTemplate }: Props) {
  const mainRef = useRef<HTMLDivElement>(null);
  const refs = useRef<Partial<Record<LibraryTab, HTMLElement | null>>>({});
  const [active, setActive] = useState<LibraryTab>(tab);
  // A tab clicked here already scrolls; the route it changes must not scroll again (it cut the glide short).
  const clicked = useRef<LibraryTab | null>(null);
  const goTo = (t: LibraryTab, smooth = true) => {
    // The first section goes back to the very top, with the space overview above it in view.
    const main = mainRef.current, el = t === SECTIONS[0].tab ? main?.querySelector<HTMLElement>(".section-nav + *") : refs.current[t];
    if (main && el) scrollToSection(main, el, smooth);
  };
  // Arriving with a section in the route (from Inicio) scrolls to it.
  // The first section opens at the very top, with the storage overview above it in view.
  useEffect(() => {
    if (clicked.current === tab) { clicked.current = null; return; }
    const id = setTimeout(() => { if (tab === SECTIONS[0].tab) mainRef.current?.scrollTo({ top: 0 }); else goTo(tab, false); }, 60);
    return () => clearTimeout(id);
  }, [tab]);
  useEffect(() => {
    const main = mainRef.current;
    if (!main) return;
    const spy = () => {
      const nav = main.querySelector<HTMLElement>(".section-nav")?.offsetHeight ?? 0;
      const line = main.getBoundingClientRect().top + nav + 48;
      let current = SECTIONS[0].tab;
      for (const x of SECTIONS) { const el = refs.current[x.tab]; if (el && el.getBoundingClientRect().top <= line) current = x.tab; }
      if (main.scrollHeight > main.clientHeight + 4 && main.scrollTop + main.clientHeight >= main.scrollHeight - 4) current = SECTIONS[SECTIONS.length - 1].tab;
      setActive(current);
    };
    spy();
    main.addEventListener("scroll", spy, { passive: true });
    return () => main.removeEventListener("scroll", spy);
  }, []);
  const section = (t: LibraryTab, node: React.ReactNode) => <section className="vm-section lib-section" ref={(el) => { refs.current[t] = el; }}>{node}</section>;
  return (
    <div className="main" ref={mainRef}>
      <nav className="section-nav" role="tablist">
        {SECTIONS.map((x) => (
          <button key={x.tab} type="button" role="tab" aria-selected={x.tab === active} className={x.tab === active ? "on" : ""}
            onClick={() => { clicked.current = x.tab; goTo(x.tab); onTab(x.tab); }}>{x.label}</button>
        ))}
      </nav>
      <StorageOverview hostFreeGB={host?.disk?.freeGB ?? null} />
      {section("perfiles", <Profiles tabs={<SectionHead tab="perfiles" />} host={host} notify={notify} />)}
      {section("plantillas", <Templates tabs={<SectionHead tab="plantillas" />} notify={notify} onOpenVm={onOpenVm} onCreate={onCreateFromTemplate} startJob={startJob} />)}
      {section("compartidos", <SharedDisks tabs={<SectionHead tab="compartidos" />} startJob={startJob} progress={progress} notify={notify} onOpenVm={onOpenVm} />)}
      {section("discos", <Disks tabs={<SectionHead tab="discos" />} startJob={startJob} busy={busy} notify={notify} onOpenVm={onOpenVm} />)}
      {section("isos", <Isos tabs={<SectionHead tab="isos" />} notify={notify} />)}
    </div>
  );
}

/** A grid of Library cards whose cards glide to their new places when the window changes size or one comes or goes. */
function FlipGrid({ children }: { children: React.ReactNode }) {
  const ref = useFlip<HTMLDivElement>();
  return <div ref={ref} className="profile-grid">{children}</div>;
}

/* ---------- Storage ---------- */

/** Where the drive's space goes: machine disks, templates, shared disks and ISOs, each with its color, and what is
 *  left free. */
type Storage = { parts: { gb: number; cls: string }[]; free: number };
// What it last showed, so coming back to the Library shows it at once while it refreshes.
let storageCache: Storage | null = null;
const STORAGE_PARTS = ["st-machines", "st-templates", "st-shared", "st-isos"];
const partLabel = (cls: string) => cls === "st-machines" ? t("Discos de máquinas") : cls === "st-templates" ? t("Plantillas") : cls === "st-shared" ? t("Discos compartidos") : t("ISOs");

function StorageOverview({ hostFreeGB }: { hostFreeGB: number | null }) {
  const [data, setData] = useState<Storage | null>(storageCache);
  useEffect(() => {
    Promise.all([api.disks(), api.templates(), api.sharedDisks(), api.isos()]).then(([d, t, sd, i]) => {
      const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0);
      setData(storageCache = {
        free: d[0]?.hostFreeGB ?? hostFreeGB ?? 0,
        parts: [
          { gb: sum(d.map((x) => x.fileGB)), cls: "st-machines" },
          { gb: sum(t.map((x) => x.fileGB)), cls: "st-templates" },
          { gb: sum(sd.map((x) => x.fileGB)), cls: "st-shared" },
          { gb: sum(i.filter((x) => !x.missing && x.remembered !== false).map((x) => x.sizeGB)), cls: "st-isos" },
        ],
      });
    }).catch(() => {});
  }, []);
  const fmt = (n: number) => `${Math.round(n).toLocaleString(locale())} GB`;
  // While it loads: the same panel, with its bar and legend waiting, never a bare strip.
  if (!data) {
    return (
      <div className="card storage loading" aria-busy="true">
        <div className="storage-top"><span className="storage-title">{t("Espacio de GpuVM en el disco")}</span><span className="storage-free skeleton-text" /></div>
        <div className="storage-bar" />
        <div className="storage-legend">{STORAGE_PARTS.map((cls) => <span key={cls}><i className={cls} />{partLabel(cls)}<strong className="skeleton-text" /></span>)}</div>
      </div>
    );
  }
  const total = data.free + data.parts.reduce((a, b) => a + b.gb, 0) || 1;
  return (
    <div className="card storage">
      <div className="storage-top"><span className="storage-title">{t("Espacio de GpuVM en el disco")}</span><span className="storage-free">{t("{gb} libres", { gb: fmt(data.free) })}</span></div>
      <div className="storage-bar">
        {data.parts.filter((x) => x.gb > 0).map((x) => <span key={x.cls} className={x.cls} style={{ width: `${(x.gb / total) * 100}%` }} title={`${partLabel(x.cls)}: ${fmt(x.gb)}`} />)}
      </div>
      <div className="storage-legend">
        {data.parts.map((x) => <span key={x.cls}><i className={x.cls} />{partLabel(x.cls)}<strong>{fmt(x.gb)}</strong></span>)}
      </div>
    </div>
  );
}

/* ---------- Profiles ---------- */

type Editing = { previous?: string; name: string; description: string; extends: string; settings: ProfileSettings };

function Profiles({ tabs, host, notify }: { tabs: React.ReactNode; host: HostInfo | null; notify: Props["notify"] }) {
  const [profiles, setProfiles] = useState<ProfileInfo[] | null>(cache.profiles ?? null);
  const [apps, setApps] = useState<AppInfo[]>(cache.apps ?? []);
  const [editing, setEditing] = useState<Editing | null>(null);
  const [confirm, setConfirm] = useState<string | null>(null);

  const load = useCallback(() => api.profiles().then((p) => { cache.profiles = p.filter((x) => x.Name !== "base"); setProfiles(cache.profiles); }).catch((e) => notify("error", humanError(e))), [notify]);
  useEffect(() => { load(); api.apps().then((a) => { cache.apps = a; setApps(a); }).catch(() => {}); }, [load]);

  const startNew = (from: ProfileInfo) => setEditing({
    name: from.BuiltIn ? "" : `${from.Name}-${t("copia")}`, description: "", extends: from.BuiltIn ? from.Name : (from.Extends ?? "max-performance"),
    settings: { ...from.Settings! },
  });
  const remove = async (name: string) => {
    try { await api.removeProfile(name); setConfirm(null); load(); }
    catch (e) { notify("error", humanError(e)); }
  };
  const fallback = profiles?.find((p) => p.Name === "max-performance");

  return (
    <>
    <div className="library-head">{tabs}</div>
    {/* One card per profile, with its cube built from what it gives; the grid grows with however many there are. */}
    <FlipGrid>
      {profiles === null && [0, 1, 2].map((i) => <div key={i} className="card skeleton profile-skeleton" />)}
      {profiles?.map((p) => (
        <div className="card profile-card" key={p.Name}>
          {p.Settings && <MiniCube className="profile-cube" machine={{ cores: p.Settings.cpu, memoryGB: p.Settings.memoryGB, gpuPercent: p.Settings.gpuPercent, diskGB: p.Settings.diskGB, apps: p.Settings.apps?.length ?? 0 }} />}
          <div className="profile-text">
            <strong>{profileLabel(p.Name)}{p.BuiltIn && <span className="tag">{t("Incluido")}</span>}</strong>
            {(BUILT_IN_DESC[p.Name] && p.BuiltIn ? BUILT_IN_DESC[p.Name]() : p.Description) && <span className="profile-desc">{BUILT_IN_DESC[p.Name] && p.BuiltIn ? BUILT_IN_DESC[p.Name]() : p.Description}</span>}
            {p.Settings && <ResourceChips s={p.Settings} apps={apps} />}
          </div>
          <div className="profile-actions">
            {p.Settings && (
              <button className="btn ghost compact" onClick={() => startNew(p)} title={t("Crear un perfil a partir de este")}>
                <IconCopyPlus size={15} />{t("Duplicar")}
              </button>
            )}
            {!p.BuiltIn && p.Settings && (
              <button className="btn ghost compact" onClick={() => setEditing({ previous: p.Name, name: p.Name, description: p.Description ?? "", extends: p.Extends ?? "max-performance", settings: { ...p.Settings! } })}>
                <IconPencil size={15} />{t("Editar")}
              </button>
            )}
            {!p.BuiltIn && (confirm === p.Name
              ? <button className="btn compact danger-fill profile-delete" onClick={() => remove(p.Name)}><IconTrash size={15} />{t("Confirmar")}</button>
              : <button className="icon-btn profile-delete" aria-label={t("Eliminar {name}", { name: profileLabel(p.Name) })} title={t("Eliminar")} onClick={() => setConfirm(p.Name)}><IconTrash size={16} /></button>)}
          </div>
        </div>
      ))}
      {/* The last card makes a new one: an empty cube waiting for its pieces. */}
      {profiles && (
        <div className="card profile-card profile-new">
          <MiniCube className="profile-cube" ghost machine={{ cores: 8, memoryGB: 16, gpuPercent: 60, diskGB: 256, apps: 2 }} />
          <div className="profile-new-text">
            <strong>{t("Crea tu propio perfil")}</strong>
            <span className="profile-desc">{t("Elige procesador, memoria, GPU, disco, apps y limpieza una vez, y úsalo para crear máquinas.")}</span>
            <button type="button" className="btn" disabled={!fallback?.Settings} onClick={() => fallback && startNew(fallback)}><IconPlus size={16} />{t("Nuevo perfil")}</button>
          </div>
        </div>
      )}
    </FlipGrid>
    {editing && (
      <ProfileEditor initial={editing} host={host} apps={apps} existing={profiles ?? []}
        onCancel={() => setEditing(null)}
        onSaved={(name) => { setEditing(null); load(); notify("ok", t("Perfil {name} guardado.", { name })); }} notify={notify} />
    )}
    </>
  );
}

// Same dialog as "Create machine": over the list, Esc closes, clicking outside closes only when nothing changed.
function ProfileEditor({ initial, host, apps, existing, onCancel, onSaved, notify }: {
  initial: Editing; host: HostInfo | null; apps: AppInfo[]; existing: ProfileInfo[];
  onCancel: () => void; onSaved: (name: string) => void; notify: Props["notify"];
}) {
  const monitors = useMonitors();
  const prefs = usePrefs();
  const [draft, setDraft] = useState(initial);
  const [isos, setIsos] = useState<IsoFile[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [, repaint] = useState(0);
  const dirty = JSON.stringify(draft) !== JSON.stringify(initial);
  const s = draft.settings;
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onCancel(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onCancel]);
  const cleanupLevels = useCleanupLevels();
  const [bodyRef, bodyFade] = useScrollFade<HTMLDivElement>();
  const set = (patch: Partial<ProfileSettings>) => setDraft({ ...draft, settings: { ...s, ...patch } });
  const profileUse = streamUseOf({ fps: s.fps ?? 60, vsync: s.vsync ?? true, framePacing: s.framePacing ?? false, mouse: s.mouse ?? "capture" });
  useEffect(() => { api.isos().then(setIsos).catch(() => setIsos([])); }, []);

  const maxCpu = Math.max(2, (host?.logicalProcessors ?? 12) - 1);
  const maxMem = Math.max(4, Math.floor(host?.memoryGB ?? 16) - 4);
  const diskMax = host?.disk ? Math.max(64, Math.floor(host.disk.availableGB / 16) * 16) : 1024;
  const bases = existing.filter((p) => p.BuiltIn);
  const diskLeft = host?.disk?.availableGB.toLocaleString(locale()) ?? "";

  // Checked as you type; "Guardar perfil" stays disabled until the name is valid.
  const trimmed = draft.name.trim();
  const nameError = !trimmed ? "" : !/^[\w-]{1,40}$/.test(trimmed) ? t("Usa letras, números o guiones, sin espacios")
    : existing.some((p) => p.Name === trimmed && p.Name !== draft.previous) ? t("Ya hay un perfil con ese nombre") : "";
  const complete = !!trimmed && !nameError;

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    const name = draft.name.trim();
    if (!complete) return;
    setSaving(true);
    try {
      await api.saveProfile(name, draft.description.trim(), draft.extends, s, draft.previous);
      onSaved(name);
    } catch (err) { setError(humanError(err)); notify("error", humanError(err)); }
    finally { setSaving(false); }
  };

  const browse = async () => {
    const file = await pickIso();
    if (!file) return;
    await api.addIso(file).catch(() => {});
    setIsos(await api.isos().catch(() => isos));
    set({ iso: file });
  };

  // Rendered at app level, like "Create machine": inside the scrolling content its fade mask would clip it.
  return createPortal(
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && !dirty && onCancel()}>
    <div className="dialog wide profile-dialog" role="dialog" aria-modal="true" aria-label={draft.previous ? t("Editar {name}", { name: draft.previous }) : t("Nuevo perfil")}>
      <div className="dialog-head">
        <PatternButton name={`perfil-${draft.name || "nuevo"}`} size={44} radius={12} onChange={() => repaint((n) => n + 1)} />
        <h2>{draft.previous ? t("Editar {name}", { name: draft.previous }) : t("Nuevo perfil")}</h2>
        <button type="button" className="icon-btn" aria-label={t("Cerrar")} onClick={onCancel}><IconX size={18} /></button>
      </div>
      <form className="dialog-form" onSubmit={save}>
        <div className="profile-editor">
        <div ref={bodyRef} className={`dialog-body ${bodyFade}`}>
          <div className="two">
            <div className="field">
              <label className="field-top" htmlFor="p-name"><span>{t("Nombre")}</span></label>
              <input id="p-name" className="text-input" value={draft.name} autoFocus placeholder={t("juegos")} onChange={(e) => { setDraft({ ...draft, name: e.target.value }); setError(null); }} />
              {nameError && <span className="error-text">{nameError}</span>}
            </div>
            <div className="field">
              <label className="field-top" htmlFor="p-desc"><span>{t("Descripción")}</span></label>
              <input id="p-desc" className="text-input" value={draft.description} onChange={(e) => setDraft({ ...draft, description: e.target.value })} />
            </div>
          </div>

          <div className="field">
            <div className="field-top"><span>{t("Basado en")}</span></div>
            <div className="segment-row">
              <Segmented value={draft.extends} onChange={(v) => setDraft({ ...draft, extends: v })}
                options={bases.map((b) => ({ value: b.Name, label: profileLabel(b.Name) }))} />
            </div>
          </div>

          <div className="options">
            <div className="field">
              <div className="field-top"><span>{t("Procesador")}</span><strong>{tn(s.cpu, "{n} hilo", "{n} hilos")}</strong></div>
              <Slider label={t("Hilos")} value={Math.min(s.cpu, maxCpu)} min={2} max={maxCpu} onChange={(cpu) => set({ cpu })} />
            </div>
            <div className="field">
              <div className="field-top"><span>{t("Memoria")}</span><strong>{s.memoryGB} GB</strong></div>
              <Slider label={t("Memoria")} value={Math.min(s.memoryGB, maxMem)} min={4} max={maxMem} onChange={(memoryGB) => set({ memoryGB })} />
            </div>
            <div className="field">
              <div className="field-top"><span>{t("GPU para la VM")}</span><strong>{s.gpuPercent} %</strong></div>
              <Slider label="GPU" value={s.gpuPercent} min={10} max={100} step={10} onChange={(gpuPercent) => set({ gpuPercent })} />
            </div>
            <div className="field">
              <div className="field-top"><span>{t("Disco")}</span><strong>{s.diskGB} GB</strong></div>
              {/* A new machine's disk can't be bigger than the room left once every VM disk is full. */}
              <Slider label={t("Disco")} value={Math.min(s.diskGB, diskMax)} min={64} max={diskMax} step={16} onChange={(diskGB) => set({ diskGB })} />
              {host?.disk && <span className="hint">{t("Para una máquina nueva quedan {gb} GB en {drive}, contando lo reservado para las demás", { gb: diskLeft, drive: host.disk.drive })}</span>}
            </div>
            <div className="field">
              <div className="field-top"><span>{t("Tipo de disco")}</span></div>
              <div className="segment-row">
                <Segmented value={s.diskType} onChange={(diskType) => set({ diskType })} options={[
                  { value: "Fixed", label: t("Fijo") }, { value: "Dynamic", label: t("Dinámico") },
                ]} />
              </div>
            </div>
            <div className="field">
              <div className="field-top"><span>{t("Cuadros por segundo")}</span></div>
              <FpsPicker value={s.fps ?? 60} monitor={resolveMonitor(monitors, "default", prefs.monitor)} onChange={(fps) => set({ fps })} />
            </div>
            <div className="field">
              <div className="field-top"><span>{t("Imagen")}</span></div>
              <div className="segment-row">
                <Segmented value={s.resolution ?? "1920x1080"} onChange={(resolution) => set({ resolution })}
                  options={RESOLUTIONS.map((r) => ({ value: r, label: r.split("x")[1] + "p" }))} />
                <Segmented value={s.displayMode === "windowed" ? "windowed" : "fullscreen"} onChange={(displayMode) => set({ displayMode })} options={[
                  { value: "fullscreen", label: t("Pantalla completa") }, { value: "windowed", label: t("Ventana") },
                ]} />
              </div>
            </div>
          </div>

          <div className="field">
            <div className="field-top"><span>{t("Tipo de uso")}</span></div>
            <div className="segment-row">
              <Segmented value={profileUse ?? ""} onChange={(id) => set({ ...USES.find((u) => u.id === id)!.client })}
                options={USES.map((u) => ({ value: u.id, label: <><u.icon size={15} />{u.label}</> }))} />
            </div>
            <span className="hint">{profileUse ? USES.find((u) => u.id === profileUse)!.description : t("Personalizado. Los ajustes del visor se cambiaron a mano.")}</span>
          </div>

          {cleanupLevels.length > 0 && (
            <div className="field">
              <div className="field-top"><span>Windows</span></div>
              <CleanupPicker levels={cleanupLevels} value={s.cleanup ?? "none"} onChange={(cleanup) => set({ cleanup })} />
            </div>
          )}

          <div className="field">
            <div className="field-top"><span>{t("Apps que se instalan")}</span></div>
            <AppPicker apps={apps} value={s.apps} onChange={(v) => set({ apps: v })} scroll={false} />
          </div>

          <div className="field">
            <div className="field-top"><span>{t("Imagen de Windows")}</span></div>
            <IsoPicker isos={isos} value={s.iso} onChange={(iso) => set({ iso })} onBrowse={browse} allowNone />
          </div>
        </div>
        {/* The machine this profile makes, built as it is edited, as when creating a machine. */}
        <aside className="profile-editor-cube">
          <MachineCube name={draft.name} machine={{
            power: "on", cores: s.cpu, memoryGB: s.memoryGB, gpuPercent: s.gpuPercent, diskGB: s.diskGB,
            usage: { cpu: 12, gpu: 18, mem: 30, disk: 8 }, apps: s.apps ?? [], removed: CLEANUP_REMOVED[s.cleanup ?? "none"] ?? 0,
          }} />
        </aside>
        </div>
        {error && <div className="notice error-notice"><span className="grow">{error}</span></div>}

        <div className="dialog-foot">
          <button type="button" className="btn ghost" onClick={onCancel}>{t("Cancelar")}</button>
          <button type="submit" className="primary compact" disabled={saving || !complete}>
            {saving ? <IconLoader2 size={16} className="spin" /> : <IconDeviceFloppy size={16} />}{t("Guardar perfil")}
          </button>
        </div>
      </form>
    </div>
    </div>,
    portalRoot());
}

/* ---------- Disks ---------- */

function Disks({ tabs, startJob, busy, notify, onOpenVm }: Pick<Props, "startJob" | "busy" | "notify" | "onOpenVm"> & { tabs: React.ReactNode }) {
  const [disks, setDisks] = useState<DiskInfo[] | null>(cache.disks ?? null);
  const [confirm, setConfirm] = useState<string | null>(null);
  const [bases, setBases] = useState<BaseInfo[]>(cache.bases ?? []);
  const load = useCallback(() => {
    api.disks().then((d) => { cache.disks = d; setDisks(d); }).catch((e) => { setDisks([]); notify("error", humanError(e)); });
    api.bases().then((b) => { cache.bases = b; setBases(b); }).catch(() => setBases([]));
  }, [notify]);
  useEffect(() => { load(); }, [load]);

  const remove = async (name: string) => {
    try { await api.removeDisk(name); setConfirm(null); load(); notify("ok", t("Disco {name} borrado.", { name })); }
    catch (e) { notify("error", humanError(e)); }
  };
  const removeBase = async (b: BaseInfo) => {
    try { await api.removeBase(b.key); setConfirm(null); load(); notify("ok", t("Se liberaron {gb} GB.", { gb: b.fileGB })); }
    catch (e) { notify("error", humanError(e)); }
  };

  return (
    <>
    <div className="library-head">{tabs}</div>
    <FlipGrid>
      {disks === null && [0, 1, 2].map((i) => <div key={i} className="card skeleton profile-skeleton" />)}
      {disks?.length === 0 && bases.length === 0 && (
        <div className="card profile-card profile-new">
          <MiniCube className="profile-cube" kind="disk" ghost />
          <div className="profile-new-text">
            <strong>{t("Sin discos de máquinas")}</strong>
            <span className="profile-desc">{t("Aquí aparece el disco de cada máquina que crees, y los que queden sin máquina para volver a usarlos.")}</span>
          </div>
        </div>
      )}
      {disks?.map((d) => {
        const working = busy(d.name);
        return (
          <div className="card profile-card" key={d.path}>
            <MiniCube className="profile-cube" kind="disk" fill={d.sizeGB ? d.fileGB / d.sizeGB : 0} />
            <div className="profile-text">
              <strong>{d.name}<span className={`tag ${d.vm ? "" : "free"}`}>{!d.vm ? t("Libre") : d.vm === d.name ? t("En uso") : t("En uso por {vm}", { vm: d.vm })}</span></strong>
              <span className="profile-desc">
                {[d.type === "Fixed" ? t("{gb} GB fijo", { gb: d.sizeGB }) : t("{gb} GB dinámico", { gb: d.sizeGB }), d.type !== "Fixed" && t("ocupa {gb} GB", { gb: d.fileGB }), d.edition].filter(Boolean).join(" · ")}
              </span>
            </div>
            <div className="profile-actions">
              {d.vm && <button className="btn ghost compact" onClick={() => onOpenVm(d.vm!)}>{t("Ver máquina")}</button>}
              {d.restorable && (
                <button className="btn compact" disabled={working} onClick={() => startJob(d.name, "Restore-GpuVM", { Name: d.name, Confirm: false }, () => { load(); onOpenVm(d.name); })}
                  title={t("Crear una máquina con este disco")}>
                  {working ? <IconLoader2 size={15} className="spin" /> : <IconRestore size={15} />}{t("Crear máquina")}
                </button>
              )}
              {!d.vm && (confirm === d.name
                ? <button className="btn compact danger-fill profile-delete" disabled={working} onClick={() => remove(d.name)}><IconTrash size={15} />{t("Borrar {gb} GB", { gb: d.sizeGB })}</button>
                : <button className="icon-btn profile-delete" aria-label={t("Eliminar {name}", { name: d.name })} title={t("Eliminar")} disabled={working} onClick={() => setConfirm(d.name)}><IconTrash size={16} /></button>)}
            </div>
          </div>
        );
      })}
      {bases.map((b) => {
        const id = `base:${b.key}`;
        return (
          <div className="card profile-card" key={id}>
            <MiniCube className="profile-cube" kind="windows" />
            <div className="profile-text">
              <strong>{b.edition ?? "Windows"}<span className="tag">{t("Windows preparado")}</span></strong>
              <span className="profile-desc">{t("Ocupa {gb} GB. Las máquinas nuevas con este Windows se crean copiándolo.", { gb: b.fileGB })}</span>
            </div>
            <div className="profile-actions">
              {confirm === id
                ? <button className="btn compact danger-fill profile-delete" onClick={() => removeBase(b)}><IconTrash size={15} />{t("Borrar {gb} GB", { gb: b.fileGB })}</button>
                : <button className="icon-btn profile-delete" aria-label={t("Eliminar {name}", { name: b.edition ?? "Windows" })} title={t("Eliminar")} onClick={() => setConfirm(id)}><IconTrash size={16} /></button>}
            </div>
          </div>
        );
      })}
    </FlipGrid>
    </>
  );
}

/* ---------- Templates ---------- */

function Templates({ tabs, notify, onOpenVm, onCreate, startJob }: { tabs: React.ReactNode; notify: Props["notify"]; onOpenVm: Props["onOpenVm"]; onCreate: (name: string) => void; startJob: Props["startJob"] }) {
  const [templates, setTemplates] = useState<TemplateInfo[] | null>(cache.templates ?? null);
  // "Nueva plantilla": pick the machine whose Windows it saves.
  const [newFrom, setNewFrom] = useState<VmOverview[] | null>(null);
  const openNew = () => api.overview().then((list) => setNewFrom(list.filter((v) => v.managed))).catch((e) => notify("error", humanError(e)));
  const [confirm, setConfirm] = useState<string | null>(null);
  const cleanupLevels = useCleanupLevels();
  const load = useCallback(() => api.templates().then((t) => { cache.templates = t; setTemplates(t); }).catch((e) => { setTemplates([]); notify("error", humanError(e)); }), [notify]);
  useEffect(() => { load(); }, [load]);
  // A throwaway copy in one click: named like the module would ("<template>-desechable", -2…), started, and opened.
  const openDisposable = async (template: string) => {
    try {
      const taken = new Set((await api.overview()).map((v) => v.name.toLowerCase()));
      const base = `${template.slice(0, 29)}-desechable`;
      let name = base;
      for (let i = 2; taken.has(name.toLowerCase()); i++) name = `${base.slice(0, 40 - `-${i}`.length)}-${i}`;
      startJob(name, "New-GpuVM", { Name: name, Template: template, Disposable: true, Confirm: false }, () => {
        onOpenVm(name);
        startJob(name, "Connect-GpuVM", { Name: name });
      });
    } catch (e) { notify("error", humanError(e)); }
  };
  const remove = async (name: string) => {
    try { await api.removeTemplate(name); setConfirm(null); load(); notify("ok", t("Plantilla {name} eliminada.", { name })); }
    catch (e) { notify("error", humanError(e)); }
  };

  return (
    <>
    <div className="library-head">{tabs}</div>
    {newFrom && (
      <NewTemplate vms={newFrom} onClose={() => setNewFrom(null)}
        onCreate={(name, from) => { setNewFrom(null); startJob(from, "New-GpuVMTemplate", { Name: name, VMName: from, ShutdownIfRunning: true, Confirm: false }, load); }} />
    )}
    <FlipGrid>
      {templates === null && [0, 1].map((i) => <div key={i} className="card skeleton profile-skeleton" />)}
      {templates?.map((tpl) => {
        const level = tpl.cleanup !== "none" ? cleanupLevels.find((l) => l.id === tpl.cleanup)?.name : null;
        return (
          <div className="card profile-card" key={tpl.name}>
            <MiniCube className="profile-cube" kind="template" machine={{ cores: 0, memoryGB: 0, gpuPercent: 0, diskGB: 0, apps: 3 }} />
            <div className="profile-text">
              <strong>{tpl.name}{tpl.usedBy.length > 0 && <span className="tag">{tpl.usedBy.length === 1 ? t("Base de {vm}", { vm: tpl.usedBy[0] }) : tn(tpl.usedBy.length, "Base de {n} máquina", "Base de {n} máquinas")}</span>}</strong>
              <span className="profile-desc">{[t("Desde {vm}", { vm: tpl.fromVM }), tpl.edition, t("ocupa {gb} GB", { gb: tpl.fileGB }), level && `Windows: ${level.toLowerCase()}`].filter(Boolean).join(" · ")}</span>
            </div>
            <div className="profile-actions">
              <button className="btn compact" onClick={() => onCreate(tpl.name)}><IconPlus size={15} />{t("Crear máquina")}</button>
              <button className="btn ghost compact fold-label" onClick={() => openDisposable(tpl.name)} aria-label={t("Abrir desechable")} title={t("Una copia que se borra sola al apagarla")}><IconFlask size={15} /><span>{t("Abrir desechable")}</span></button>
              {tpl.usedBy.length === 1 && <button className="btn ghost compact" onClick={() => onOpenVm(tpl.usedBy[0])}>{t("Ver máquina")}</button>}
              {tpl.usedBy.length === 0 && (confirm === tpl.name
                ? <button className="btn compact danger-fill profile-delete" onClick={() => remove(tpl.name)}><IconTrash size={15} />{t("Borrar {gb} GB", { gb: tpl.fileGB })}</button>
                : <button className="icon-btn profile-delete" aria-label={t("Eliminar {name}", { name: tpl.name })} title={t("Eliminar")} onClick={() => setConfirm(tpl.name)}><IconTrash size={16} /></button>)}
            </div>
          </div>
        );
      })}
      {templates && (
        <div className="card profile-card profile-new">
          <MiniCube className="profile-cube" kind="template" ghost machine={{ cores: 0, memoryGB: 0, gpuPercent: 0, diskGB: 0, apps: 3 }} />
          <div className="profile-new-text">
            <strong>{t("Guarda un Windows listo")}</strong>
            <span className="profile-desc">{t("Copia el Windows de una máquina, con sus apps, para crear otras en segundos.")}</span>
            <button type="button" className="btn" onClick={openNew}><IconPlus size={16} />{t("Nueva plantilla")}</button>
          </div>
        </div>
      )}
    </FlipGrid>
    </>
  );
}

/* ---------- Shared disks ---------- */

const PURPOSE_LABEL = { games: "Juegos", general: "General" } as const;

function SharedDisks({ tabs, startJob, progress, notify, onOpenVm }: Pick<Props, "startJob" | "progress" | "notify" | "onOpenVm"> & { tabs: React.ReactNode }) {
  const [disks, setDisks] = useState<SharedDiskInfo[] | null>(cache.shared ?? null);
  const [creating, setCreating] = useState(false);
  const [confirm, setConfirm] = useState<string | null>(null);
  const load = useCallback(() => api.sharedDisks().then((d) => { cache.shared = d; setDisks(d); }).catch((e) => { setDisks([]); notify("error", humanError(e)); }), [notify]);
  useEffect(() => { load(); }, [load]);
  const remove = async (name: string) => {
    try { await api.removeSharedDisk(name); setConfirm(null); load(); notify("ok", t("Disco {name} eliminado.", { name })); }
    catch (e) { notify("error", humanError(e)); }
  };
  const importFolder = async (name: string) => {
    const folder = await pickFolder();
    if (!folder) return;
    startJob(`compartido:${name}`, "Import-GpuVMSharedDisk", { Name: name, Path: folder }, () => { load(); notify("ok", t("Carpeta copiada al disco {name}.", { name })); });
  };

  return (
    <>
    <div className="library-head">{tabs}</div>
    <FlipGrid>
      {disks === null && [0, 1].map((i) => <div key={i} className="card skeleton profile-skeleton" />)}
      {disks?.map((d) => {
        const working = progress(`compartido:${d.name}`);
        return (
          <div className="card profile-card" key={d.name}>
            <MiniCube className="profile-cube" kind="disk" fill={d.sizeGB ? d.fileGB / d.sizeGB : 0} />
            <div className="profile-text">
              <strong>{d.name}<span className={`tag ${d.vm ? "" : "free"}`}>{d.vm ? t("En {space}", { space: d.vm }) : t("Libre")}</span></strong>
              <span className="profile-desc">{t(PURPOSE_LABEL[d.purpose])} · {t("{used} de {total} GB", { used: d.fileGB, total: d.sizeGB })}</span>
            </div>
            <div className="profile-actions">
              <button className="btn compact" disabled={!!working} onClick={() => importFolder(d.name)} title={t("Copiar una carpeta de este equipo al disco")}>
                {working ? <IconLoader2 size={15} className="spin" /> : <IconFolderDown size={15} />}{working ?? t("Importar carpeta")}
              </button>
              {d.vm && <button className="btn ghost compact" onClick={() => onOpenVm(d.vm!)}>{t("Ver máquina")}</button>}
              {!d.vm && !working && (confirm === d.name
                ? <button className="btn compact danger-fill profile-delete" onClick={() => remove(d.name)}><IconTrash size={15} />{t("Borrar {gb} GB", { gb: d.fileGB })}</button>
                : <button className="icon-btn profile-delete" aria-label={t("Eliminar {name}", { name: d.name })} title={t("Eliminar")} onClick={() => setConfirm(d.name)}><IconTrash size={16} /></button>)}
            </div>
          </div>
        );
      })}
      {disks && (
        <div className="card profile-card profile-new">
          <MiniCube className="profile-cube" kind="disk" ghost />
          <div className="profile-new-text">
            <strong>{t("Crea un disco compartido")}</strong>
            <span className="profile-desc">{t("Tus juegos o archivos aparte, para pasarlos de una máquina a otra sin descargarlos de nuevo.")}</span>
            <button type="button" className="btn" onClick={() => setCreating(true)}><IconPlus size={16} />{t("Nuevo disco")}</button>
          </div>
        </div>
      )}
    </FlipGrid>
    {creating && <NewSharedDisk existing={disks ?? []} notify={notify} onCancel={() => setCreating(false)} onCreated={() => { setCreating(false); load(); }} />}
    </>
  );
}

function NewSharedDisk({ existing, notify, onCancel, onCreated }: {
  existing: SharedDiskInfo[]; notify: Props["notify"]; onCancel: () => void; onCreated: () => void;
}) {
  const [name, setName] = useState(existing.some((d) => d.name === "juegos") ? "" : "juegos");
  const [purpose, setPurpose] = useState<"games" | "general">("games");
  // Dynamic: it only takes what its files use, so the size is a ceiling, not space taken now.
  const maxGB = 2048;
  const [sizeGB, setSizeGB] = useState(512);
  const [saving, setSaving] = useState(false);
  const [bodyRef, bodyFade] = useScrollFade<HTMLDivElement>();
  const trimmed = name.trim();
  const nameError = !trimmed ? "" : !/^[\w-]{1,40}$/.test(trimmed) ? t("Usa letras, números o guiones, sin espacios")
    : existing.some((d) => d.name.toLowerCase() === trimmed.toLowerCase()) ? t("Ya hay un disco con ese nombre") : "";
  const complete = !!trimmed && !nameError;
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onCancel(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onCancel]);
  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!complete) return;
    setSaving(true);
    try { await api.newSharedDisk(trimmed, sizeGB, purpose); notify("ok", t("Disco {name} creado.", { name: trimmed })); onCreated(); }
    catch (err) { notify("error", humanError(err)); setSaving(false); }
  };

  return createPortal(
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && !trimmed && onCancel()}>
    <div className="dialog narrow" role="dialog" aria-modal="true" aria-label={t("Nuevo disco compartido")}>
      <div className="dialog-head">
        <PatternButton name={`compartido-${trimmed || "nuevo"}`} size={44} radius={12} />
        <h2>{t("Nuevo disco compartido")}</h2>
        <button type="button" className="icon-btn" aria-label={t("Cerrar")} onClick={onCancel}><IconX size={18} /></button>
      </div>
      <form className="dialog-form" onSubmit={save}>
        <div ref={bodyRef} className={`dialog-body ${bodyFade}`}>
          <div className="field">
            <label className="field-top" htmlFor="sd-name"><span>{t("Nombre")}</span></label>
            <input id="sd-name" className="text-input" value={name} autoFocus onChange={(e) => setName(e.target.value)} />
            {nameError && <span className="error-text">{nameError}</span>}
          </div>
          <div className="field">
            <div className="field-top"><span>{t("Uso")}</span></div>
            <div className="segment-row">
              <Segmented value={purpose} onChange={setPurpose} options={[{ value: "games", label: t("Juegos") }, { value: "general", label: t("General") }]} />
            </div>
            <span className="hint">{purpose === "games"
              ? t("Al conectarlo, Steam lo suma a sus bibliotecas en la máquina.")
              : t("Aparece como un disco más en la máquina.")}</span>
          </div>
          <div className="field">
            <div className="field-top"><span>{t("Tamaño máximo")}</span><strong>{sizeGB} GB</strong></div>
            <Slider label={t("Tamaño")} value={sizeGB} min={64} max={maxGB} step={64} onChange={setSizeGB} />
            <span className="hint">{t("Solo ocupa en el equipo lo que guardes en él.")}</span>
          </div>
        </div>
        <div className="dialog-foot">
          <button type="button" className="btn ghost" onClick={onCancel}>{t("Cancelar")}</button>
          <button type="submit" className="primary compact" disabled={saving || !complete}>
            {saving ? <IconLoader2 size={16} className="spin" /> : <IconPlus size={16} />}{t("Crear disco")}
          </button>
        </div>
      </form>
    </div>
    </div>,
    portalRoot());
}

/* ---------- ISOs ---------- */

function Isos({ tabs, notify }: { tabs: React.ReactNode; notify: Props["notify"] }) {
  const [isos, setIsos] = useState<IsoFile[] | null>(cache.isos ?? null);
  const load = useCallback(() => api.isos().then((f) => { cache.isos = f; setIsos(f); }).catch((e) => { setIsos([]); notify("error", humanError(e)); }), [notify]);
  useEffect(() => { load(); }, [load]);

  const add = async (path?: string) => {
    const file = path ?? await pickIso();
    if (!file) return;
    try { await api.addIso(file); load(); } catch (e) { notify("error", humanError(e)); }
  };
  const remove = async (path: string) => {
    try { await api.removeIso(path); load(); } catch (e) { notify("error", humanError(e)); }
  };

  return (
    <>
    <div className="library-head">{tabs}</div>
    <FlipGrid>
      {isos === null && [0, 1].map((i) => <div key={i} className="card skeleton profile-skeleton" />)}
      {isos?.map((f) => (
        <div className={`card profile-card${f.missing ? " missing" : ""}`} key={f.path}>
          <MiniCube className="profile-cube" kind="iso" ghost={!!f.missing || !f.remembered} />
          <div className="profile-text">
            <strong className="profile-name-cut" title={f.path}>{f.name}</strong>
            <span className="profile-desc">{isoDetail(f)}</span>
          </div>
          <div className="profile-actions">
            {f.remembered
              ? <button className="btn ghost compact" onClick={() => remove(f.path)}><IconX size={15} />{t("Quitar de la lista")}</button>
              : <button className="btn compact" onClick={() => add(f.path)}><IconPlus size={15} />{t("Agregar a la lista")}</button>}
          </div>
        </div>
      ))}
      {isos && (
        <div className="card profile-card profile-new">
          <MiniCube className="profile-cube" kind="iso" ghost />
          <div className="profile-new-text">
            <strong>{t("Agrega una imagen de Windows")}</strong>
            <span className="profile-desc">{t("Un archivo ISO de Windows 10 u 11 para crear máquinas desde cero.")}</span>
            <button type="button" className="btn" onClick={() => add()}><IconPlus size={16} />{t("Agregar ISO")}</button>
          </div>
        </div>
      )}
    </FlipGrid>
    </>
  );
}
