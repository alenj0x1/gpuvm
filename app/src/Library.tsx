import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import {
  IconAdjustmentsHorizontal, IconCopyPlus, IconDatabase, IconDeviceFloppy, IconDisc, IconFolderDown, IconLoader2, IconPencil, IconPlus,
  IconRestore, IconStack2, IconTemplate, IconTrash, IconX,
} from "@tabler/icons-react";
import type { AppInfo, DiskInfo, HostInfo, IsoFile, ProfileInfo, ProfileSettings, SharedDiskInfo, TemplateInfo } from "./types";
import { api, pickFolder, pickIso } from "./api";
import { PatternButton } from "./bauhaus";
import { AppPicker, CleanupPicker, FPS, IsoPicker, useCleanupLevels, RESOLUTIONS, isoDetail, profileLabel, profileSummary } from "./pickers";
import { Segmented, Slider, humanError, portalRoot, useScrollFade } from "./ui";

export type LibraryTab = "perfiles" | "plantillas" | "discos" | "compartidos" | "isos";

// What each tab loaded last, so switching tabs shows it at once while it refreshes.
const cache: { profiles?: ProfileInfo[]; apps?: AppInfo[]; disks?: DiskInfo[]; isos?: IsoFile[]; templates?: TemplateInfo[]; shared?: SharedDiskInfo[] } = {};

/** Loading rows with the shape of the real ones (pattern, name, detail). */
function RowSkeletons({ count = 3 }: { count?: number }) {
  return (
    <>
      {Array.from({ length: count }, (_, i) => (
        <div className="row row-skeleton" key={i} aria-hidden="true">
          <span className="skeleton icon" />
          <div className="row-text">
            <span className="skeleton" style={{ width: "28%", height: 14 }} />
            <span className="skeleton" style={{ width: "62%", height: 12 }} />
          </div>
        </div>
      ))}
    </>
  );
}

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

export function Library({ tab, onTab, host, startJob, busy, progress, notify, onOpenVm, onCreateFromTemplate }: Props) {
  // Each tab puts its own action (new profile, add ISO…) next to the tabs, so the card needs no title.
  const tabs = (
    <Segmented<LibraryTab> value={tab} onChange={onTab} options={[
      { value: "perfiles", label: <><IconAdjustmentsHorizontal size={15} />Perfiles</> },
      { value: "plantillas", label: <><IconTemplate size={15} />Plantillas</> },
      { value: "discos", label: <><IconDatabase size={15} />Discos</> },
      { value: "compartidos", label: <><IconStack2 size={15} />Compartidos</> },
      { value: "isos", label: <><IconDisc size={15} />ISOs</> },
    ]} />
  );
  return (
    <div className="main">
      {tab === "perfiles" && <Profiles tabs={tabs} host={host} notify={notify} />}
      {tab === "discos" && <Disks tabs={tabs} startJob={startJob} busy={busy} notify={notify} onOpenVm={onOpenVm} />}
      {tab === "plantillas" && <Templates tabs={tabs} notify={notify} onOpenVm={onOpenVm} onCreate={onCreateFromTemplate} />}
      {tab === "compartidos" && <SharedDisks tabs={tabs} startJob={startJob} progress={progress} notify={notify} onOpenVm={onOpenVm} />}
      {tab === "isos" && <Isos tabs={tabs} notify={notify} />}
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
    name: from.BuiltIn ? "" : `${from.Name}-copia`, description: "", extends: from.BuiltIn ? from.Name : (from.Extends ?? "max-performance"),
    settings: { ...from.Settings! },
  });
  const remove = async (name: string) => {
    try { await api.removeProfile(name); setConfirm(null); load(); }
    catch (e) { notify("error", humanError(e)); }
  };
  const fallback = profiles?.find((p) => p.Name === "max-performance");

  return (
    <>
    <div className="library-head">
      {tabs}
      <button className="btn" disabled={!fallback?.Settings} onClick={() => fallback && startNew(fallback)}><IconPlus size={16} />Nuevo perfil</button>
    </div>
    <div className="card">
      <div className="rows">
        {profiles === null && <RowSkeletons />}
        {profiles?.map((p) => (
          <div className="row" key={p.Name}>
            <PatternButton name={`perfil-${p.Name}`} size={36} radius={10} />
            <div className="row-text">
              <strong>{profileLabel(p.Name)}{p.BuiltIn && <span className="tag">Incluido</span>}</strong>
              <span>{p.Settings ? profileSummary(p.Settings, apps) : p.Description}</span>
            </div>
            <div className="row-actions">
              {p.Settings && (
                <button className="btn ghost" onClick={() => startNew(p)} title="Crear un perfil a partir de este">
                  <IconCopyPlus size={16} />Duplicar
                </button>
              )}
              {!p.BuiltIn && p.Settings && (
                <button className="btn ghost" onClick={() => setEditing({ previous: p.Name, name: p.Name, description: p.Description ?? "", extends: p.Extends ?? "max-performance", settings: { ...p.Settings! } })}>
                  <IconPencil size={16} />Editar
                </button>
              )}
              {!p.BuiltIn && (
                <button className={`btn ${confirm === p.Name ? "danger-fill" : "ghost danger"}`} onClick={() => confirm === p.Name ? remove(p.Name) : setConfirm(p.Name)}>
                  <IconTrash size={16} />{confirm === p.Name ? "Confirmar" : "Eliminar"}
                </button>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
    {editing && (
      <ProfileEditor initial={editing} host={host} apps={apps} existing={profiles ?? []}
        onCancel={() => setEditing(null)}
        onSaved={(name) => { setEditing(null); load(); notify("ok", `Perfil ${name} guardado.`); }} notify={notify} />
    )}
    </>
  );
}

// Same dialog as "Create machine": over the list, Esc closes, clicking outside closes only when nothing changed.
function ProfileEditor({ initial, host, apps, existing, onCancel, onSaved, notify }: {
  initial: Editing; host: HostInfo | null; apps: AppInfo[]; existing: ProfileInfo[];
  onCancel: () => void; onSaved: (name: string) => void; notify: Props["notify"];
}) {
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
  useEffect(() => { api.isos().then(setIsos).catch(() => setIsos([])); }, []);

  const maxCpu = Math.max(2, (host?.logicalProcessors ?? 12) - 1);
  const maxMem = Math.max(4, Math.floor(host?.memoryGB ?? 16) - 4);
  const bases = existing.filter((p) => p.BuiltIn);

  // Checked as you type; "Guardar perfil" stays disabled until the name is valid.
  const trimmed = draft.name.trim();
  const nameError = !trimmed ? "" : !/^[\w-]{1,40}$/.test(trimmed) ? "Usa letras, números o guiones, sin espacios"
    : existing.some((p) => p.Name === trimmed && p.Name !== draft.previous) ? "Ya hay un perfil con ese nombre" : "";
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
    <div className="dialog" role="dialog" aria-modal="true" aria-label={draft.previous ? `Editar ${draft.previous}` : "Nuevo perfil"}>
      <div className="dialog-head">
        <PatternButton name={`perfil-${draft.name || "nuevo"}`} size={44} radius={12} onChange={() => repaint((n) => n + 1)} />
        <h2>{draft.previous ? `Editar ${draft.previous}` : "Nuevo perfil"}</h2>
        <button type="button" className="icon-btn" aria-label="Cerrar" onClick={onCancel}><IconX size={18} /></button>
      </div>
      <form className="dialog-form" onSubmit={save}>
        <div ref={bodyRef} className={`dialog-body ${bodyFade}`}>
          <div className="two">
            <div className="field">
              <label className="field-top" htmlFor="p-name"><span>Nombre</span></label>
              <input id="p-name" className="text-input" value={draft.name} autoFocus placeholder="juegos" onChange={(e) => { setDraft({ ...draft, name: e.target.value }); setError(null); }} />
              {nameError && <span className="error-text">{nameError}</span>}
            </div>
            <div className="field">
              <label className="field-top" htmlFor="p-desc"><span>Descripción</span></label>
              <input id="p-desc" className="text-input" value={draft.description} onChange={(e) => setDraft({ ...draft, description: e.target.value })} />
            </div>
          </div>

          <div className="field">
            <div className="field-top"><span>Basado en</span></div>
            <div className="segment-row">
              <Segmented value={draft.extends} onChange={(v) => setDraft({ ...draft, extends: v })}
                options={bases.map((b) => ({ value: b.Name, label: profileLabel(b.Name) }))} />
            </div>
          </div>

          <div className="options">
            <div className="field">
              <div className="field-top"><span>Procesador</span><strong>{s.cpu} hilos</strong></div>
              <Slider label="Hilos" value={Math.min(s.cpu, maxCpu)} min={2} max={maxCpu} onChange={(cpu) => set({ cpu })} />
            </div>
            <div className="field">
              <div className="field-top"><span>Memoria</span><strong>{s.memoryGB} GB</strong></div>
              <Slider label="Memoria" value={Math.min(s.memoryGB, maxMem)} min={4} max={maxMem} onChange={(memoryGB) => set({ memoryGB })} />
            </div>
            <div className="field">
              <div className="field-top"><span>GPU para la VM</span><strong>{s.gpuPercent} %</strong></div>
              <Slider label="GPU" value={s.gpuPercent} min={10} max={100} step={10} onChange={(gpuPercent) => set({ gpuPercent })} />
            </div>
            <div className="field">
              <div className="field-top"><span>Disco</span><strong>{s.diskGB} GB</strong></div>
              <Slider label="Disco" value={s.diskGB} min={64} max={1024} step={16} onChange={(diskGB) => set({ diskGB })} />
            </div>
            <div className="field">
              <div className="field-top"><span>Tipo de disco</span></div>
              <div className="segment-row">
                <Segmented value={s.diskType} onChange={(diskType) => set({ diskType })} options={[
                  { value: "Fixed", label: "Fijo" }, { value: "Dynamic", label: "Dinámico" },
                ]} />
              </div>
            </div>
            <div className="field">
              <div className="field-top"><span>Moonlight</span></div>
              <div className="segment-row">
                <Segmented value={s.resolution ?? "1920x1080"} onChange={(resolution) => set({ resolution })}
                  options={RESOLUTIONS.map((r) => ({ value: r, label: r.split("x")[1] + "p" }))} />
                <Segmented value={s.fps ?? 60} onChange={(fps) => set({ fps })} options={FPS.map((f) => ({ value: f, label: `${f} FPS` }))} />
                <Segmented value={s.displayMode === "windowed" ? "windowed" : "fullscreen"} onChange={(displayMode) => set({ displayMode })} options={[
                  { value: "fullscreen", label: "Pantalla completa" }, { value: "windowed", label: "Ventana" },
                ]} />
              </div>
            </div>
          </div>

          {cleanupLevels.length > 0 && (
            <div className="field">
              <div className="field-top"><span>Windows</span></div>
              <CleanupPicker levels={cleanupLevels} value={s.cleanup ?? "none"} onChange={(cleanup) => set({ cleanup })} />
            </div>
          )}

          <div className="field">
            <div className="field-top"><span>Apps que se instalan</span></div>
            <AppPicker apps={apps} value={s.apps} onChange={(v) => set({ apps: v })} scroll={false} />
          </div>

          <div className="field">
            <div className="field-top"><span>Imagen de Windows</span></div>
            <IsoPicker isos={isos} value={s.iso} onChange={(iso) => set({ iso })} onBrowse={browse} allowNone />
          </div>
        </div>
        {error && <div className="notice error-notice"><span className="grow">{error}</span></div>}

        <div className="dialog-foot">
          <button type="button" className="btn ghost" onClick={onCancel}>Cancelar</button>
          <button type="submit" className="primary compact" disabled={saving || !complete}>
            {saving ? <IconLoader2 size={16} className="spin" /> : <IconDeviceFloppy size={16} />}Guardar perfil
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
  const load = useCallback(() => api.disks().then((d) => { cache.disks = d; setDisks(d); }).catch((e) => { setDisks([]); notify("error", humanError(e)); }), [notify]);
  useEffect(() => { load(); }, [load]);

  const remove = async (name: string) => {
    try { await api.removeDisk(name); setConfirm(null); load(); notify("ok", `Disco ${name} borrado.`); }
    catch (e) { notify("error", humanError(e)); }
  };
  const free = disks?.[0]?.hostFreeGB;

  return (
    <>
    <div className="library-head">
      {tabs}
      {free !== undefined && <span className="muted-note">{free} GB libres en el equipo</span>}
    </div>
    <div className="card">
      <div className="rows">
        {disks === null && <RowSkeletons />}
        {disks?.length === 0 && <p className="muted-note">Aún no hay discos de GpuVM.</p>}
        {disks?.map((d) => {
          const working = busy(d.name);
          return (
            <div className="row" key={d.path}>
              <PatternButton name={d.name} size={36} radius={10} />
              <div className="row-text">
                <strong>{d.name}<span className={`tag ${d.vm ? "" : "free"}`}>{!d.vm ? "Libre" : d.vm === d.name ? "En uso" : `En uso por ${d.vm}`}</span></strong>
                <span>
                  {d.sizeGB} GB {d.type === "Fixed" ? "fijo" : "dinámico"}
                  {d.type !== "Fixed" && ` · ocupa ${d.fileGB} GB`}
                  {d.edition && ` · ${d.edition}`}
                </span>
              </div>
              <div className="row-actions">
                {d.vm && <button className="btn ghost" onClick={() => onOpenVm(d.vm!)}>Ver máquina</button>}
                {d.restorable && (
                  <button className="btn" disabled={working} onClick={() => startJob(d.name, "Restore-GpuVM", { Name: d.name, Confirm: false }, () => { load(); onOpenVm(d.name); })}>
                    {working ? <IconLoader2 size={16} className="spin" /> : <IconRestore size={16} />}Crear máquina con este disco
                  </button>
                )}
                {!d.vm && (
                  <button className={`btn ${confirm === d.name ? "danger-fill" : "ghost danger"}`} disabled={working}
                    onClick={() => confirm === d.name ? remove(d.name) : setConfirm(d.name)}>
                    <IconTrash size={16} />{confirm === d.name ? `Borrar ${d.sizeGB} GB` : "Eliminar"}
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
    </>
  );
}

/* ---------- Templates ---------- */

function Templates({ tabs, notify, onOpenVm, onCreate }: { tabs: React.ReactNode; notify: Props["notify"]; onOpenVm: Props["onOpenVm"]; onCreate: (name: string) => void }) {
  const [templates, setTemplates] = useState<TemplateInfo[] | null>(cache.templates ?? null);
  const [confirm, setConfirm] = useState<string | null>(null);
  const cleanupLevels = useCleanupLevels();
  const load = useCallback(() => api.templates().then((t) => { cache.templates = t; setTemplates(t); }).catch((e) => { setTemplates([]); notify("error", humanError(e)); }), [notify]);
  useEffect(() => { load(); }, [load]);
  const remove = async (name: string) => {
    try { await api.removeTemplate(name); setConfirm(null); load(); notify("ok", `Plantilla ${name} eliminada.`); }
    catch (e) { notify("error", humanError(e)); }
  };

  return (
    <>
    <div className="library-head">{tabs}</div>
    <div className="card">
      <div className="rows">
        {templates === null && <RowSkeletons />}
        {templates?.length === 0 && <p className="muted-note">Crea una plantilla desde el menú «…» de una máquina: guarda su Windows con sus apps para crear otras en segundos.</p>}
        {templates?.map((t) => {
          const level = t.cleanup !== "none" ? cleanupLevels.find((l) => l.id === t.cleanup)?.name : null;
          return (
            <div className="row" key={t.name}>
              <PatternButton name={`plantilla-${t.name}`} size={36} radius={10} />
              <div className="row-text">
                <strong>{t.name}{t.usedBy.length > 0 && <span className="tag">{t.usedBy.length === 1 ? `Base de ${t.usedBy[0]}` : `Base de ${t.usedBy.length} máquinas`}</span>}</strong>
                <span>{[`Desde ${t.fromVM}`, t.edition, `ocupa ${t.fileGB} GB`, level && `Windows: ${level.toLowerCase()}`].filter(Boolean).join(" · ")}</span>
              </div>
              <div className="row-actions">
                {t.usedBy.length === 1 && <button className="btn ghost" onClick={() => onOpenVm(t.usedBy[0])}>Ver máquina</button>}
                <button className="btn" onClick={() => onCreate(t.name)}><IconPlus size={16} />Crear máquina</button>
                {t.usedBy.length === 0 && (
                  <button className={`btn ${confirm === t.name ? "danger-fill" : "ghost danger"}`} onClick={() => confirm === t.name ? remove(t.name) : setConfirm(t.name)}>
                    <IconTrash size={16} />{confirm === t.name ? `Borrar ${t.fileGB} GB` : "Eliminar"}
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
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
    try { await api.removeSharedDisk(name); setConfirm(null); load(); notify("ok", `Disco ${name} eliminado.`); }
    catch (e) { notify("error", humanError(e)); }
  };
  const importFolder = async (name: string) => {
    const folder = await pickFolder();
    if (!folder) return;
    startJob(`compartido:${name}`, "Import-GpuVMSharedDisk", { Name: name, Path: folder }, () => { load(); notify("ok", `Carpeta copiada al disco ${name}.`); });
  };

  return (
    <>
    <div className="library-head">
      {tabs}
      <button className="btn" onClick={() => setCreating(true)}><IconPlus size={16} />Nuevo disco</button>
    </div>
    <div className="card">
      <div className="rows">
        {disks === null && <RowSkeletons />}
        {disks?.length === 0 && <p className="muted-note">Un disco compartido guarda tus juegos o archivos aparte y pasa de una máquina a otra sin descargar todo de nuevo.</p>}
        {disks?.map((d) => {
          const working = progress(`compartido:${d.name}`);
          return (
            <div className="row" key={d.name}>
              <PatternButton name={`compartido-${d.name}`} size={36} radius={10} />
              <div className="row-text">
                <strong>{d.name}<span className={`tag ${d.vm ? "" : "free"}`}>{d.vm ? `En ${d.vm}` : "Libre"}</span></strong>
                <span>{PURPOSE_LABEL[d.purpose]} · {d.sizeGB} GB · ocupa {d.fileGB} GB</span>
              </div>
              <div className="row-actions">
                {d.vm && <button className="btn ghost" onClick={() => onOpenVm(d.vm!)}>Ver máquina</button>}
                <button className="btn" disabled={!!working} onClick={() => importFolder(d.name)} title="Copiar una carpeta de este equipo al disco">
                  {working ? <IconLoader2 size={16} className="spin" /> : <IconFolderDown size={16} />}{working ?? "Importar carpeta"}
                </button>
                {!d.vm && !working && (
                  <button className={`btn ${confirm === d.name ? "danger-fill" : "ghost danger"}`} onClick={() => confirm === d.name ? remove(d.name) : setConfirm(d.name)}>
                    <IconTrash size={16} />{confirm === d.name ? `Borrar ${d.fileGB} GB` : "Eliminar"}
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
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
  const nameError = !trimmed ? "" : !/^[\w-]{1,40}$/.test(trimmed) ? "Usa letras, números o guiones, sin espacios"
    : existing.some((d) => d.name.toLowerCase() === trimmed.toLowerCase()) ? "Ya hay un disco con ese nombre" : "";
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
    try { await api.newSharedDisk(trimmed, sizeGB, purpose); notify("ok", `Disco ${trimmed} creado.`); onCreated(); }
    catch (err) { notify("error", humanError(err)); setSaving(false); }
  };

  return createPortal(
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && !trimmed && onCancel()}>
    <div className="dialog narrow" role="dialog" aria-modal="true" aria-label="Nuevo disco compartido">
      <div className="dialog-head">
        <PatternButton name={`compartido-${trimmed || "nuevo"}`} size={44} radius={12} />
        <h2>Nuevo disco compartido</h2>
        <button type="button" className="icon-btn" aria-label="Cerrar" onClick={onCancel}><IconX size={18} /></button>
      </div>
      <form className="dialog-form" onSubmit={save}>
        <div ref={bodyRef} className={`dialog-body ${bodyFade}`}>
          <div className="field">
            <label className="field-top" htmlFor="sd-name"><span>Nombre</span></label>
            <input id="sd-name" className="text-input" value={name} autoFocus onChange={(e) => setName(e.target.value)} />
            {nameError && <span className="error-text">{nameError}</span>}
          </div>
          <div className="field">
            <div className="field-top"><span>Uso</span></div>
            <div className="segment-row">
              <Segmented value={purpose} onChange={setPurpose} options={[{ value: "games", label: "Juegos" }, { value: "general", label: "General" }]} />
            </div>
            <span className="hint">{purpose === "games"
              ? "Al conectarlo, Steam lo suma a sus bibliotecas en la máquina."
              : "Aparece como un disco más en la máquina."}</span>
          </div>
          <div className="field">
            <div className="field-top"><span>Tamaño máximo</span><strong>{sizeGB} GB</strong></div>
            <Slider label="Tamaño" value={sizeGB} min={64} max={maxGB} step={64} onChange={setSizeGB} />
            <span className="hint">Solo ocupa en el equipo lo que guardes en él.</span>
          </div>
        </div>
        <div className="dialog-foot">
          <button type="button" className="btn ghost" onClick={onCancel}>Cancelar</button>
          <button type="submit" className="primary compact" disabled={saving || !complete}>
            {saving ? <IconLoader2 size={16} className="spin" /> : <IconPlus size={16} />}Crear disco
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
    <div className="library-head">
      {tabs}
      <button className="btn" onClick={() => add()}><IconPlus size={16} />Agregar ISO</button>
    </div>
    <div className="card">
      <div className="rows">
        {isos === null && <RowSkeletons />}
        {isos?.length === 0 && <p className="muted-note">No hay imágenes de Windows en descargas ni en el escritorio.</p>}
        {isos?.map((f) => (
          <div className={`row ${f.missing ? "missing" : ""}`} key={f.path}>
            <span className="row-icon"><IconDisc size={18} /></span>
            <div className="row-text">
              <strong title={f.path}>{f.name}</strong>
              <span>{isoDetail(f)}</span>
            </div>
            <div className="row-actions">
              {f.remembered
                ? <button className="btn ghost" onClick={() => remove(f.path)}><IconX size={16} />Quitar de la lista</button>
                : <button className="btn ghost" onClick={() => add(f.path)}><IconPlus size={16} />Agregar a la lista</button>}
            </div>
          </div>
        ))}
      </div>
    </div>
    </>
  );
}
