import { useEffect, useMemo, useRef, useState } from "react";
import {
  IconApps, IconBolt, IconBrandWindows, IconCheck, IconCpu, IconDatabase, IconDeviceFloppy, IconDisc, IconFileImport, IconFlask, IconLayoutGrid, IconLoader2, IconPalette, IconPlus, IconSparkles, IconTag, IconTemplate, IconTopologyStar3, IconUser, IconX,
} from "@tabler/icons-react";
import type { AppInfo, CleanupLevelId, HostInfo, ImportInfo, IsoFile, ProfileInfo, ProfileSettings, TemplateInfo, VmOverview } from "./types";
import { api, pickIso, pickMachineFile, vmNameError } from "./api";
import { PatternButton } from "./machineIcon";
import { CheckMark, Segmented, Slider, humanError } from "./ui";
import { AppPicker, IsoPicker, useCleanupLevels, profileLabel } from "./pickers";
import { Chip, ResourceChips } from "./resources";
import { CleanupFlow, CleanupItems, LEVEL_LOOK } from "./CleanupFlow";
import { CLEANUP_REMOVED, MachineCube, cubeOf } from "./MachineCube";
import { Customize, useDecorEdit } from "./Customize";
import { draftSource, saveDecor, useSource, type DecorSource } from "./decor/store";
import { useSpaces } from "./spaces";
import { ambientInfo } from "./ambient";
import { Dropdown as SpaceDropdown, portalRoot } from "./ui";
import { createPortal } from "react-dom";
import { SpaceDialog } from "./SpaceDialog";
import { locale, t, tn, translateModule } from "./i18n";

export interface Resources { cpu: number; memoryGB: number; gpuPercent: number; diskGB: number }

interface Props {
  existing: VmOverview[];
  host: HostInfo | null;
  job: { message: string; log: string[] } | null;
  error: string | null;
  /** Opens with this template chosen (from the library). */
  template?: string | null;
  /** The space it goes into at first (the one Home shows). */
  space?: string | null;
  onCreate: (args: {
    name: string; iso: string | null; template: string | null; file: string | null; disposable: boolean; profile: string; user: string; password: string;
    apps: string[]; cleanup: CleanupLevelId; resources: Resources | null; space: string;
  }) => void;
  onClose: () => void;
}

const MIN_PASSWORD = 6;
const NEW_SPACE = "__new__";
// Windows local account names: up to 20 characters, none of these, and not one Windows keeps for itself.
const RESERVED_USERS = ["administrator", "administrador", "guest", "invitado", "defaultaccount", "wdagutilityaccount", "system"];
type Section = "name" | "start" | "resources" | "windows" | "apps" | "cleanup" | "custom";

/** Create a machine in one dialog: sections on the left, everything in the middle, and on the right a summary that is
 *  always in view. A profile fills it all in; anything changed afterwards can be saved as a new profile. */
export function CreateDialog({ existing, host, job, error, template: initialTemplate, space: initialSpace, onCreate, onClose }: Props) {
  const spaces = useSpaces();
  const [spaceId, setSpaceId] = useState(() => (spaces.some((x) => x.id === initialSpace) ? initialSpace! : spaces[0].id));
  const space = spaces.find((x) => x.id === spaceId) ?? spaces[0];
  // A new space is made in its own dialog over this one, so nothing set here is lost.
  const [creatingSpace, setCreatingSpace] = useState(false);
  const creatingSpaceRef = useRef(false);
  creatingSpaceRef.current = creatingSpace;
  const [name, setName] = useState(() => {
    for (let i = 1; ; i++) { const n = i === 1 ? "win-gpu" : `win-gpu-${i}`; if (!existing.some((v) => v.name === n)) return n; }
  });
  const [isos, setIsos] = useState<IsoFile[] | null>(null);
  const [iso, setIso] = useState<string | null>(null);
  const [profiles, setProfiles] = useState<ProfileInfo[]>([]);
  const [profile, setProfile] = useState("max-performance");
  const [catalog, setCatalog] = useState<AppInfo[]>([]);
  const [apps, setApps] = useState<string[]>([]);
  const cleanupLevels = useCleanupLevels();
  const [cleanup, setCleanup] = useState<CleanupLevelId>("none");
  const [res, setRes] = useState<Resources | null>(null);
  const [user, setUser] = useState("gpuvm");
  const [password, setPassword] = useState("");
  const [repeat, setRepeat] = useState("");
  // From a template: Windows, its apps, cleanup and account come from it, so only name, profile and resources are asked.
  const [templates, setTemplates] = useState<TemplateInfo[]>([]);
  const [source, setSource] = useState<"iso" | "template" | "file">(initialTemplate ? "template" : "iso");
  const [template, setTemplate] = useState<string | null>(initialTemplate ?? null);
  // From a file exported with GpuVM: Windows, apps and account come from it; only its password is asked.
  const [file, setFile] = useState<ImportInfo | null>(null);
  // A copy of the template that is deleted with its disk once it is turned off.
  const [disposable, setDisposable] = useState(false);
  const [fileError, setFileError] = useState("");
  const [reading, setReading] = useState(false);
  const [nameTouched, setNameTouched] = useState(false);
  const fromTemplate = source === "template";
  const fromFile = source === "file";
  const prebuilt = fromTemplate || fromFile;
  const [dirty, setDirty] = useState(false);
  const [, repaint] = useState(0);
  const [saving, setSaving] = useState<{ name: string; busy: boolean; error: string } | null>(null);
  const nameRef = useRef<HTMLInputElement>(null);
  const bodyRef = useRef<HTMLDivElement>(null);
  const refs = useRef<Partial<Record<Section, HTMLElement | null>>>({});
  const [active, setActive] = useState<Section>("name");
  const busy = !!job;

  const chosen = profiles.find((p) => p.Name === profile);
  const applyProfile = (p: ProfileInfo) => {
    setProfile(p.Name);
    if (!p.Settings) return;
    setRes({ cpu: p.Settings.cpu, memoryGB: p.Settings.memoryGB, gpuPercent: p.Settings.gpuPercent, diskGB: p.Settings.diskGB });
    setApps(p.Settings.apps);
    setCleanup(p.Settings.cleanup ?? "none");
    const i = p.Settings.iso;
    if (i && !isos?.find((f) => f.path === i)?.missing) setIso(i);
  };

  useEffect(() => {
    api.isos().then((list) => { setIsos(list); if (list[0]) setIso((cur) => cur ?? list[0].path); }).catch(() => setIsos([]));
    api.profiles().then((p) => {
      const list = p.filter((x) => x.Name !== "base");
      setProfiles(list);
      const first = list.find((x) => x.Name === "max-performance") ?? list[0];
      if (first) applyProfile(first);
    }).catch(() => {});
    api.apps().then(setCatalog).catch(() => {});
    api.templates().then((list) => { setTemplates(list); if (list[0]) setTemplate((cur) => cur ?? list[0].name); }).catch(() => {});
  }, []);
  useEffect(() => { if (!busy) nameRef.current?.focus(); }, [busy]);
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") { if (creatingSpaceRef.current) setCreatingSpace(false); else onClose(); } };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);

  const sections: { id: Section; label: string; icon: React.ReactNode }[] = [
    { id: "name", label: t("Nombre y espacio"), icon: <IconTag size={16} /> },
    { id: "start", label: t("Punto de partida"), icon: <IconLayoutGrid size={16} /> },
    { id: "resources", label: t("Recursos"), icon: <IconCpu size={16} /> },
    ...(prebuilt ? [] : [
      { id: "windows" as Section, label: t("Windows y cuenta"), icon: <IconBrandWindows size={16} /> },
      { id: "apps" as Section, label: t("Apps"), icon: <IconApps size={16} /> },
      { id: "cleanup" as Section, label: t("Limpieza"), icon: <IconSparkles size={16} /> },
    ]),
    { id: "custom", label: t("Personalizar"), icon: <IconPalette size={16} /> },
  ];
  // The section in view is marked on the left as the body scrolls; a click there scrolls to it.
  useEffect(() => {
    const body = bodyRef.current;
    if (!body) return;
    const spy = () => {
      const line = body.getBoundingClientRect().top + 60;
      let current: Section = "name";
      for (const s of sections) { const el = refs.current[s.id]; if (el && el.getBoundingClientRect().top <= line) current = s.id; }
      if (body.scrollHeight > body.clientHeight + 4 && body.scrollTop + body.clientHeight >= body.scrollHeight - 4) current = sections[sections.length - 1].id;
      setActive(current);
    };
    spy();
    body.addEventListener("scroll", spy, { passive: true });
    // Profiles, apps and levels arrive after opening: the content grows, so look again.
    const grow = new ResizeObserver(spy);
    if (body.firstElementChild) Array.from(body.children).forEach((c) => grow.observe(c));
    return () => { body.removeEventListener("scroll", spy); grow.disconnect(); };
  }, [busy, prebuilt]);
  const goTo = (id: Section) => {
    const body = bodyRef.current, el = refs.current[id];
    if (body && el) body.scrollTo({ top: body.scrollTop + el.getBoundingClientRect().top - body.getBoundingClientRect().top - 8, behavior: "smooth" });
  };

  const draft = useMemo(() => draftSource(""), []);
  draft.rename(name);
  const decorEdit = useDecorEdit(draft);

  const touch = () => setDirty(true);
  const [blurred, setBlurred] = useState<Record<string, boolean>>({});
  const blur = (field: string) => setBlurred((b) => ({ ...b, [field]: true }));

  // Checked as you type; "Crear máquina" stays disabled until everything is valid.
  const nameError = !name ? "" : vmNameError(name, existing);
  const userError = !user ? t("Escribe un usuario") : !/^[A-Za-z0-9._-]{1,20}$/.test(user) || user.endsWith(".") ? t("Hasta 20 letras, números, puntos o guiones")
    : RESERVED_USERS.includes(user.toLowerCase()) ? t("Windows reserva ese nombre") : "";
  const passwordError = password.length >= MIN_PASSWORD || (!blurred.password && repeat.length === 0) || !password ? "" : t("Usa al menos {n} caracteres", { n: MIN_PASSWORD });
  const repeatError = repeat && password !== repeat && (blurred.repeat || repeat.length >= password.length) ? t("Las contraseñas no coinciden") : "";
  const complete = !!name && !nameError && !!res && (fromTemplate
    ? !!template
    : fromFile ? !!file && !!password
    : !!iso && !userError && password.length >= MIN_PASSWORD && password === repeat);

  const base = chosen?.Settings;
  const changed = !!base && !!res && (res.cpu !== base.cpu || res.memoryGB !== base.memoryGB || res.gpuPercent !== base.gpuPercent || res.diskGB !== base.diskGB
    || (!prebuilt && (cleanup !== (base.cleanup ?? "none") || apps.join(",") !== (base.apps ?? []).join(","))));
  const settings: ProfileSettings | null = base && res ? { ...base, ...res, apps, cleanup, iso: iso ?? base.iso } : null;

  const submit = (e?: React.FormEvent) => {
    e?.preventDefault();
    if (!complete) return;
    const resources = changed ? res : null;
    const decor = draft.get();
    if (decor.color || decor.led || decor.stickers.length || decor.figures.length) saveDecor(name, decor);
    if (fromTemplate) onCreate({ name, iso: null, template, file: null, disposable, profile, user: "", password: "", apps: [], cleanup: "none", resources, space: space.id });
    else if (fromFile) onCreate({ name, iso: null, template: null, file: file!.path, disposable: false, profile, user: file!.user ?? user, password, apps: [], cleanup: "none", resources, space: space.id });
    else onCreate({ name, iso, template: null, file: null, disposable: false, profile, user, password, apps, cleanup, resources, space: space.id });
  };
  const saveProfile = async () => {
    if (!saving || !settings) return;
    const n = saving.name.trim();
    if (!/^[\w-]{1,40}$/.test(n)) { setSaving({ ...saving, error: t("Usa letras, números o guiones") }); return; }
    setSaving({ ...saving, busy: true, error: "" });
    try {
      await api.saveProfile(n, "", profile, settings);
      const list = (await api.profiles()).filter((x) => x.Name !== "base");
      setProfiles(list);
      setProfile(n);
      setSaving(null);
    } catch (err) { setSaving({ ...saving, busy: false, error: humanError(err) }); }
  };

  // The file is read (its manifest only) when it is picked: a file that isn't a machine says so right there.
  const pickFile = async () => {
    const path = await pickMachineFile();
    if (!path) return;
    setReading(true); setFileError("");
    try {
      const info = await api.importInfo(path);
      setFile(info);
      if (info.user) setUser(info.user);
      if (!nameTouched) setName(info.freeName);
      touch();
    } catch (err) { setFile(null); setFileError(humanError(err)); }
    finally { setReading(false); }
  };

  const browse = async () => {
    const file = await pickIso();
    if (!file) return;
    await api.addIso(file).catch(() => {});
    setIsos(await api.isos().catch(() => [...(isos ?? []), { path: file, name: file.split("\\").pop()!, sizeGB: 0, modified: "" }]));
    setIso(file);
    touch();
  };

  const maxCpu = Math.max(2, (host?.logicalProcessors ?? 12) - 1);
  const maxMem = Math.max(4, Math.round(host?.memoryGB ?? 16) - 4);
  const isoName = isos?.find((f) => f.path === iso)?.name;
  const level = cleanupLevels.find((l) => l.id === cleanup)?.name;
  const allItems = cleanupLevels.flatMap((l) => l.items);
  const dropped = new Set(cleanupLevels.slice(0, Math.max(0, cleanupLevels.findIndex((l) => l.id === cleanup)) + 1).flatMap((l) => l.items.map((i) => i.id)));
  const section = (id: Section, title: string, desc: string, children: React.ReactNode) => (
    <section className="create-section" ref={(el) => { refs.current[id] = el; }}>
      <div className="create-section-head"><strong>{title}</strong><span>{desc}</span></div>
      {children}
    </section>
  );

  return (
    // Clicking outside only closes when nothing was typed; Esc always closes.
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && (busy || !dirty) && onClose()}>
      <div className={`dialog ${busy ? "" : "create-dialog"}`} role="dialog" aria-modal="true" aria-label={t("Crear máquina")}>
        <div className="dialog-head">
          <PatternButton name={name || "nueva"} size={44} radius={12} onChange={() => repaint((n) => n + 1)} />
          <h2>{busy ? t("Creando {name}", { name }) : t("Crear máquina")}</h2>
          <button className="icon-btn" aria-label={t("Cerrar")} onClick={onClose}><IconX size={18} /></button>
        </div>

        {busy ? (
          <div className="log" role="status">
            {job!.log.map((line, i) => (
              <span key={i} className={`log-line ${i === job!.log.length - 1 ? "now" : ""}`}>
                {i === job!.log.length - 1 ? <IconLoader2 size={14} className="spin" /> : <IconCheck size={14} />}{translateModule(line)}
              </span>
            ))}
            <span className="log-hint">{t("Puedes cerrar esta ventana: el avance sigue en la barra lateral.")}</span>
          </div>
        ) : (
          <form className="dialog-form create-form" onSubmit={submit}>
            <nav className="create-nav">
              {sections.map((s) => (
                <button key={s.id} type="button" className={s.id === active ? "on" : ""} onClick={() => goTo(s.id)}>{s.icon}{s.label}</button>
              ))}
            </nav>

            <div ref={bodyRef} className="create-body">
              {section("name", t("Nombre y espacio"), t("Cómo se llama en GpuVM y en Hyper-V, y el espacio donde va a estar."), (
                <div className="create-account pair">
                  <div className="field">
                    <label className="field-top" htmlFor="vm-name"><span>{t("Nombre")}</span></label>
                    <input id="vm-name" ref={nameRef} className="text-input" aria-label={t("Nombre")} value={name} onChange={(e) => { setName(e.target.value); setNameTouched(true); touch(); }} />
                    {nameError && <span className="error-text">{nameError}</span>}
                  </div>
                  <div className="field">
                    <div className="field-top"><span>{t("Espacio")}</span></div>
                    <SpaceDropdown label={t("Espacio")} value={space.id} onChange={(v) => { if (v === NEW_SPACE) setCreatingSpace(true); else { setSpaceId(v); touch(); } }}
                      options={[...spaces.map((x) => { const I = ambientInfo(x.ambient).icon; return { value: x.id, label: x.name, detail: ambientInfo(x.ambient).name, icon: <I size={16} /> }; }),
                        { value: NEW_SPACE, label: t("Nuevo espacio"), detail: t("Con un ambiente propio"), icon: <IconPlus size={16} /> }]} />
                    {creatingSpace && createPortal(<SpaceDialog vms={[]} onSaved={(s) => { setSpaceId(s.id); touch(); }} onClose={() => setCreatingSpace(false)} />, portalRoot())}
                  </div>
                </div>
              ))}

              {section("start", t("Punto de partida"), t("Un perfil llena todo lo de abajo; puedes cambiar lo que quieras."), (
                <>
                  <div className="segment-row">
                    <Segmented value={source} onChange={(v) => { setSource(v); touch(); }} options={[
                      { value: "iso", label: <><IconDisc size={15} />{t("Instalar Windows")}</> },
                      ...(templates.length > 0 ? [{ value: "template" as const, label: <><IconTemplate size={15} />{t("Desde plantilla")}</> }] : []),
                      { value: "file", label: <><IconFileImport size={15} />{t("Desde archivo")}</> },
                    ]} />
                  </div>
                  {fromFile && (
                    <>
                      <div className="choice-list">
                        <button type="button" className={`choice ${file ? "on" : ""}`} onClick={pickFile} disabled={reading}>
                          <span className="check">{reading ? <IconLoader2 size={14} className="spin" /> : file ? <CheckMark /> : <IconFileImport size={15} />}</span>
                          <span className="grow">
                            <span className="title">{file ? file.path.split("\\").pop() : t("Elegir archivo")}</span>
                            <span className="desc">{file
                              ? [file.edition, tn(file.installedApps.length, "{n} app", "{n} apps"), `${file.diskGB.toLocaleString(locale())} GB`,
                                file.exportedAt ? t("Exportada el {date}", { date: new Date(file.exportedAt).toLocaleDateString(locale()) }) : null].filter(Boolean).join(" · ")
                              : t("Una máquina exportada con GpuVM (.gpuvm)")}</span>
                          </span>
                        </button>
                      </div>
                      {fileError && <span className="error-text">{fileError}</span>}
                      {file && file.diskGB + 20 > file.freeGB && (
                        <span className="error-text">{t("Faltan {gb} GB libres para importarla", { gb: Math.ceil(file.diskGB + 20 - file.freeGB) })}</span>
                      )}
                      {file && (
                        <div className="create-account">
                          <div className="field">
                            <label className="field-top" htmlFor="vm-user-file"><span>{t("Usuario")}</span></label>
                            <input id="vm-user-file" className="text-input" value={file.user ?? user} readOnly />
                          </div>
                          <div className="field">
                            <label className="field-top" htmlFor="vm-pass-file"><span>{t("Contraseña de Windows")}</span></label>
                            <input id="vm-pass-file" className="text-input" type="password" value={password} onChange={(e) => { setPassword(e.target.value); touch(); }} />
                          </div>
                        </div>
                      )}
                    </>
                  )}
                  {fromTemplate && (
                    <div className="choice-list" role="radiogroup" aria-label={t("Plantilla")}>
                      {templates.map((tpl) => (
                        <button type="button" role="radio" aria-checked={template === tpl.name} key={tpl.name} className={`choice ${template === tpl.name ? "on" : ""}`}
                          onClick={() => { setTemplate(tpl.name); touch(); }}>
                          <span className="check">{template === tpl.name && <CheckMark />}</span>
                          <span className="grow">
                            <span className="title">{tpl.name}</span>
                            <span className="desc">{[t("Desde {vm}", { vm: tpl.fromVM }), tpl.edition, `${tpl.sizeGB} GB`].filter(Boolean).join(" · ")}</span>
                          </span>
                        </button>
                      ))}
                      <button type="button" role="checkbox" aria-checked={disposable} className={`choice ${disposable ? "on" : ""}`}
                        onClick={() => { setDisposable((d) => !d); touch(); }}>
                        <span className="check">{disposable ? <CheckMark /> : <IconFlask size={15} />}</span>
                        <span className="grow">
                          <span className="title">{t("Desechable")}</span>
                          <span className="desc">{t("Se borra con su disco al apagarla. Para probar algo sin tocar tus máquinas.")}</span>
                        </span>
                      </button>
                    </div>
                  )}
                  <div className="create-profiles" role="radiogroup" aria-label={t("Perfil")}>
                    {profiles.map((p) => (
                      <button type="button" role="radio" aria-checked={profile === p.Name} key={p.Name} className={`create-profile${profile === p.Name ? " on" : ""}`}
                        onClick={() => { applyProfile(p); touch(); }}>
                        <span className="create-profile-name">{profileLabel(p.Name)}{profile === p.Name && changed && <span className="tag">{t("Cambiado")}</span>}</span>
                        {p.Settings && <ResourceChips s={p.Settings} apps={catalog} />}
                      </button>
                    ))}
                  </div>
                </>
              ))}

              {section("resources", t("Recursos"), t("Lo que la máquina toma de tu PC al encenderse."), res && (
                <div className="create-resources">
                  <div className="field"><div className="field-top"><span className="res-cpu"><IconCpu size={15} /> {t("Procesador")}</span><strong>{tn(res.cpu, "{n} hilo", "{n} hilos")}</strong></div>
                    <Slider label={t("Hilos")} value={Math.min(res.cpu, maxCpu)} min={2} max={maxCpu} onChange={(cpu) => { setRes({ ...res, cpu }); touch(); }} /></div>
                  <div className="field"><div className="field-top"><span className="res-mem"><IconTopologyStar3 size={15} /> {t("Memoria")}</span><strong>{res.memoryGB} GB</strong></div>
                    <Slider label={t("Memoria")} value={Math.min(res.memoryGB, maxMem)} min={4} max={maxMem} onChange={(memoryGB) => { setRes({ ...res, memoryGB }); touch(); }} /></div>
                  <div className="field"><div className="field-top"><span className="res-gpu"><IconBolt size={15} /> GPU</span><strong>{res.gpuPercent} %</strong></div>
                    <Slider label="GPU" value={res.gpuPercent} min={10} max={100} step={10} onChange={(gpuPercent) => { setRes({ ...res, gpuPercent }); touch(); }} /></div>
                  <div className="field"><div className="field-top"><span className="res-disk"><IconDatabase size={15} /> {t("Disco")}</span><strong>{res.diskGB} GB</strong></div>
                    <Slider label={t("Disco")} value={res.diskGB} min={64} max={1024} step={16} onChange={(diskGB) => { setRes({ ...res, diskGB }); touch(); }} /></div>
                </div>
              ))}

              {!prebuilt && section("windows", t("Windows y cuenta"), t("La imagen que se instala y la cuenta con la que entras."), (
                <>
                  <div className="field">
                    <div className="field-top"><span>{t("Imagen de Windows")}</span></div>
                    <IsoPicker isos={isos?.filter((f) => !f.missing) ?? null} value={iso} onChange={(v) => { setIso(v); touch(); }} onBrowse={browse} />
                  </div>
                  <div className="create-account">
                    <div className="field">
                      <label className="field-top" htmlFor="vm-user"><span>{t("Usuario")}</span></label>
                      <input id="vm-user" className="text-input" value={user} onChange={(e) => { setUser(e.target.value); touch(); }} />
                      {userError && <span className="error-text">{userError}</span>}
                    </div>
                    <div className="field">
                      <label className="field-top" htmlFor="vm-pass"><span>{t("Contraseña")}</span></label>
                      <input id="vm-pass" className="text-input" type="password" value={password} onBlur={() => blur("password")} onChange={(e) => { setPassword(e.target.value); touch(); }} />
                      {passwordError && <span className="error-text">{passwordError}</span>}
                    </div>
                    <div className="field">
                      <label className="field-top" htmlFor="vm-pass2"><span>{t("Repetir contraseña")}</span></label>
                      <input id="vm-pass2" className="text-input" type="password" value={repeat} onBlur={() => blur("repeat")} onChange={(e) => { setRepeat(e.target.value); touch(); }} />
                      {repeatError && <span className="error-text">{repeatError}</span>}
                    </div>
                  </div>
                </>
              ))}

              {!prebuilt && catalog.length > 0 && section("apps", t("Apps"), t("Se instalan desde su fuente oficial al abrirla por primera vez."), (
                <AppPicker apps={catalog} value={apps} onChange={(v) => { setApps(v); touch(); }} scroll={false} />
              ))}

              {!prebuilt && cleanupLevels.length > 0 && section("cleanup", t("Limpieza de Windows"), t("Cada nivel incluye lo de los anteriores. La seguridad no se toca."), (
                <>
                <div className="level-list create-levels" role="radiogroup" aria-label={t("Limpieza")}>
                  {cleanupLevels.map((l) => (
                    <button key={l.id} type="button" role="radio" aria-checked={l.id === cleanup} className={`level-row${l.id === cleanup ? " on" : ""}`}
                      onClick={() => { setCleanup(l.id); touch(); }}>
                      <span className="level-icon">{LEVEL_LOOK[l.id]?.icon ?? <IconSparkles size={18} />}</span>
                      <span className="level-text"><span className="level-name">{l.name}</span><span className="level-tagline">{LEVEL_LOOK[l.id]?.tagline ?? ""}</span></span>
                    </button>
                  ))}
                </div>
                {/* The same scene as on a machine, and beside it everything Windows comes with: what this level removes
                    has a check, what stays a dot. */}
                <div className="create-cleanup">
                  <CleanupFlow items={allItems.map((i) => i.id)} removed={dropped} />
                  <CleanupItems items={allItems} removed={dropped} />
                </div>
                </>
              ))}

              {section("custom", t("Personalizar"), t("Su color, un letrero, stickers y figuras. Se arrastran al cubo de al lado."), (
                <Customize bare source={decorEdit.source} ops={decorEdit.ops} selected={decorEdit.selected} setSelected={decorEdit.setSelected} openMenu={decorEdit.openMenu} />
              ))}
              {decorEdit.menu}
            </div>

            <aside className="create-summary">
              {/* The machine being put together: every change to its resources, apps and cleanup shows here. */}
              {res && (
                <div className="create-cube">
                  <DraftCube draft={draft} ambient={space.ambient} spaceName={space.name} time={space.time} machine={{
                    power: "on", cores: res.cpu, memoryGB: res.memoryGB, gpuPercent: res.gpuPercent, diskGB: res.diskGB,
                    usage: { cpu: 12, gpu: 18, mem: 30, disk: 8 }, apps, removed: CLEANUP_REMOVED[cleanup] ?? 0,
                  }} name={name} decorOf="" spin={decorEdit.spins} edit={{ ...decorEdit.edit, holdStill: active === "custom" }}
                    others={existing.map((v) => ({ name: v.name, machine: cubeOf(v) }))} />
                </div>
              )}
              <span className="create-summary-title">{t("Resumen")}</span>
              <strong className="create-summary-name">{name || t("Sin nombre")}</strong>
              {res && (
                <div className="create-summary-chips">
                  <Chip kind="cpu">{tn(res.cpu, "{n} hilo", "{n} hilos")}</Chip>
                  <Chip kind="mem">{res.memoryGB} GB</Chip>
                  <Chip kind="gpu">GPU {res.gpuPercent} %</Chip>
                  <Chip kind="disk">{res.diskGB} GB</Chip>
                </div>
              )}
              <span className="create-summary-line"><IconLayoutGrid size={14} /><span>{changed ? t("{profile}, con cambios", { profile: profileLabel(profile) }) : profileLabel(profile)}</span></span>
              {fromTemplate ? (
                <span className="create-summary-line"><IconTemplate size={14} /><span>{t("Plantilla {name}", { name: template ?? "—" })}</span></span>
              ) : fromFile ? (
                <span className="create-summary-line cut" title={file?.path}><IconFileImport size={14} /><span>{file ? file.path.split("\\").pop() : t("Sin archivo")}</span></span>
              ) : (
                <>
                  <span className="create-summary-line cut" title={isoName}><IconDisc size={14} /><span>{isoName ?? t("Sin imagen de Windows")}</span></span>
                  <span className="create-summary-line"><IconUser size={14} /><span>{user || "—"}</span></span>
                  <span className="create-summary-line"><IconApps size={14} /><span>{apps.length ? apps.map((id) => catalog.find((a) => a.id === id)?.name ?? id).join(", ") : t("Sin apps")}</span></span>
                  <span className="create-summary-line"><IconSparkles size={14} /><span>{level ?? t("Normal")}</span></span>
                </>
              )}
              {changed && settings && (saving ? (
                <div className="create-save">
                  <input className="text-input" autoFocus placeholder={t("Nombre del perfil")} value={saving.name} onChange={(e) => setSaving({ ...saving, name: e.target.value, error: "" })}
                    onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); saveProfile(); } }} />
                  {saving.error && <span className="error-text">{saving.error}</span>}
                  <div className="create-save-actions">
                    <button type="button" className="btn ghost" onClick={() => setSaving(null)}>{t("Cancelar")}</button>
                    <button type="button" className="btn" disabled={saving.busy || !saving.name.trim()} onClick={saveProfile}>
                      {saving.busy ? <IconLoader2 size={15} className="spin" /> : <IconDeviceFloppy size={15} />}{t("Guardar")}
                    </button>
                  </div>
                </div>
              ) : (
                <button type="button" className="btn ghost create-save-open" onClick={() => setSaving({ name: "", busy: false, error: "" })}>
                  <IconDeviceFloppy size={15} />{t("Guardar como perfil")}
                </button>
              ))}
            </aside>

            {error && <div className="notice error-notice create-error"><span className="grow">{error}</span></div>}
            <div className="dialog-foot create-foot">
              <button type="button" className="btn ghost" onClick={onClose}>{t("Cancelar")}</button>
              <button type="submit" className="primary compact" disabled={!complete}><IconPlus size={16} />{t("Crear máquina")}</button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
}

/** The cube with the draft decoration: only it follows each change, not the whole dialog. */
function DraftCube({ draft, ...props }: { draft: DecorSource } & Omit<React.ComponentProps<typeof MachineCube>, "decorShown">) {
  const decor = useSource(draft);
  return <MachineCube {...props} decorShown={decor} />;
}
