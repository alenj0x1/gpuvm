import { useEffect, useRef, useState } from "react";
import { IconCheck, IconDisc, IconLoader2, IconPlus, IconTemplate, IconX } from "@tabler/icons-react";
import type { AppInfo, CleanupLevelId, IsoFile, ProfileInfo, TemplateInfo, VmOverview } from "./types";
import { api, pickIso } from "./api";
import { PatternButton } from "./bauhaus";
import { CheckMark, Segmented, useScrollFade } from "./ui";
import { AppPicker, CleanupPicker, IsoPicker, useCleanupLevels, profileLabel, profileSummary } from "./pickers";

interface Props {
  existing: VmOverview[];
  job: { message: string; log: string[] } | null;
  error: string | null;
  /** Opens with this template chosen (from the library). */
  template?: string | null;
  onCreate: (args: { name: string; iso: string | null; template: string | null; profile: string; password: string; apps: string[]; cleanup: CleanupLevelId }) => void;
  onClose: () => void;
}

const MIN_PASSWORD = 6;

export function CreateDialog({ existing, job, error, template: initialTemplate, onCreate, onClose }: Props) {
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
  const [password, setPassword] = useState("");
  const [repeat, setRepeat] = useState("");
  // From a template: Windows, its apps, cleanup level and password come from it, so only name and profile are asked.
  const [templates, setTemplates] = useState<TemplateInfo[]>([]);
  const [source, setSource] = useState<"iso" | "template">(initialTemplate ? "template" : "iso");
  const [template, setTemplate] = useState<string | null>(initialTemplate ?? null);
  const fromTemplate = source === "template";
  const [dirty, setDirty] = useState(false);
  const [, repaint] = useState(0);
  const nameRef = useRef<HTMLInputElement>(null);
  const busy = !!job;
  const [bodyRef, bodyFade] = useScrollFade<HTMLDivElement>();

  useEffect(() => {
    api.isos().then((list) => { setIsos(list); if (list[0]) setIso((cur) => cur ?? list[0].path); }).catch(() => setIsos([]));
    api.profiles().then((p) => setProfiles(p.filter((x) => x.Name !== "base"))).catch(() => {});
    api.apps().then(setCatalog).catch(() => {});
    api.templates().then((list) => { setTemplates(list); if (list[0]) setTemplate((cur) => cur ?? list[0].name); }).catch(() => {});
  }, []);

  // A profile brings its ISO and apps; what the user changes afterwards in the dialog wins.
  const chooseProfile = (p: ProfileInfo) => {
    setProfile(p.Name);
    setDirty(true);
    if (!p.Settings) return;
    setApps(p.Settings.apps);
    setCleanup(p.Settings.cleanup ?? "none");
    const iso = p.Settings.iso;
    if (iso && !isos?.find((f) => f.path === iso)?.missing) setIso(iso);
  };
  useEffect(() => { if (!busy) nameRef.current?.focus(); }, [busy]);
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);

  const touch = () => setDirty(true);
  const [blurred, setBlurred] = useState<Record<string, boolean>>({});
  const blur = (field: string) => setBlurred((b) => ({ ...b, [field]: true }));

  // Checked as you type; "Crear máquina" stays disabled until everything is valid.
  const nameError = !name ? "" : !/^[\w-]{1,40}$/.test(name) ? "Usa letras, números o guiones, sin espacios"
    : existing.some((v) => v.name.toLowerCase() === name.toLowerCase()) ? "Ya hay una máquina con ese nombre" : "";
  const passwordError = password.length >= MIN_PASSWORD || (!blurred.password && repeat.length === 0) || !password ? "" : `Usa al menos ${MIN_PASSWORD} caracteres`;
  const repeatError = repeat && password !== repeat && (blurred.repeat || repeat.length >= password.length) ? "Las contraseñas no coinciden" : "";
  const complete = !!name && !nameError && (fromTemplate
    ? !!template
    : !!iso && password.length >= MIN_PASSWORD && password === repeat);

  const submit = (e?: React.FormEvent) => {
    e?.preventDefault();
    if (!complete) return;
    if (fromTemplate) onCreate({ name, iso: null, template, profile, password: "", apps: [], cleanup: "none" });
    else onCreate({ name, iso, template: null, profile, password, apps, cleanup });
  };

  const browse = async () => {
    const file = await pickIso();
    if (!file) return;
    await api.addIso(file).catch(() => {});
    setIsos(await api.isos().catch(() => [...(isos ?? []), { path: file, name: file.split("\\").pop()!, sizeGB: 0, modified: "" }]));
    setIso(file);
    touch();
  };

  const shownProfiles = profiles.length ? profiles : [{ Name: "balanced", Description: "", Extends: null }, { Name: "max-performance", Description: "", Extends: null }];

  return (
    // Clicking outside only closes when nothing was typed; Esc always closes.
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && (busy || !dirty) && onClose()}>
      <div className={`dialog ${busy || fromTemplate ? "" : "wide"}`} role="dialog" aria-modal="true" aria-label="Crear máquina">
        <div className="dialog-head">
          <PatternButton name={name || "nueva"} size={44} radius={12} onChange={() => repaint((n) => n + 1)} />
          <h2>{busy ? `Creando ${name}` : "Crear máquina"}</h2>
          <button className="icon-btn" aria-label="Cerrar" onClick={onClose}><IconX size={18} /></button>
        </div>

        {busy ? (
          <div className="log" role="status">
            {job!.log.map((line, i) => (
              <span key={i} className={`log-line ${i === job!.log.length - 1 ? "now" : ""}`}>
                {i === job!.log.length - 1 ? <IconLoader2 size={14} className="spin" /> : <IconCheck size={14} />}{line}
              </span>
            ))}
            <span className="log-hint">Puedes cerrar esta ventana: el avance sigue en la barra lateral.</span>
          </div>
        ) : (
          <form className="dialog-form" onSubmit={submit}>
            <div ref={bodyRef} className={`dialog-body ${bodyFade}`}>
              <div className={`dialog-columns ${fromTemplate ? "single" : ""}`}>
                <div className="dialog-column">
                  <div className="field">
                    <label className="field-top" htmlFor="vm-name"><span>Nombre</span></label>
                    <input id="vm-name" ref={nameRef} className="text-input" value={name} onChange={(e) => { setName(e.target.value); touch(); }} />
                    {nameError && <span className="error-text">{nameError}</span>}
                  </div>

                  {templates.length > 0 && (
                    <div className="segment-row">
                      <Segmented value={source} onChange={(v) => { setSource(v); touch(); }} options={[
                        { value: "iso", label: <><IconDisc size={15} />Instalar Windows</> },
                        { value: "template", label: <><IconTemplate size={15} />Desde plantilla</> },
                      ]} />
                    </div>
                  )}

                  {fromTemplate ? (
                    <div className="field">
                      <div className="field-top"><span>Plantilla</span></div>
                      <div className="choice-list" role="radiogroup">
                        {templates.map((t) => (
                          <button type="button" role="radio" aria-checked={template === t.name} key={t.name} className={`choice ${template === t.name ? "on" : ""}`}
                            onClick={() => { setTemplate(t.name); touch(); }}>
                            <span className="check">{template === t.name && <CheckMark />}</span>
                            <span className="grow">
                              <span className="title">{t.name}</span>
                              <span className="desc">{[`Desde ${t.fromVM}`, t.edition, `${t.sizeGB} GB`].filter(Boolean).join(" · ")}</span>
                            </span>
                          </button>
                        ))}
                      </div>
                    </div>
                  ) : (
                    <div className="field">
                      <div className="field-top"><span>Imagen de Windows</span></div>
                      <IsoPicker isos={isos?.filter((f) => !f.missing) ?? null} value={iso} onChange={(v) => { setIso(v); touch(); }} onBrowse={browse} />
                    </div>
                  )}

                  <div className="field">
                    <div className="field-top"><span>Perfil</span></div>
                    <div className="choice-list" role="radiogroup">
                      {shownProfiles.map((p) => (
                        <button type="button" role="radio" aria-checked={profile === p.Name} key={p.Name} className={`choice top ${profile === p.Name ? "on" : ""}`}
                          onClick={() => chooseProfile(p)}>
                          <span className="check">{profile === p.Name && <CheckMark />}</span>
                          <span className="grow">
                            <span className="title">{profileLabel(p.Name)}</span>
                            <span className="desc">{fromTemplate && p.Settings ? profileSummary(p.Settings, catalog, true) : p.Description || (p.Settings ? profileSummary(p.Settings, catalog) : "")}</span>
                          </span>
                        </button>
                      ))}
                    </div>
                  </div>

                  {!fromTemplate && (
                    <>
                      <div className="field">
                        <label className="field-top" htmlFor="vm-pass"><span>Contraseña de Windows</span><span className="hint">Usuario: gpuvm</span></label>
                        <input id="vm-pass" className="text-input" type="password" value={password} onBlur={() => blur("password")} onChange={(e) => { setPassword(e.target.value); touch(); }} />
                        {passwordError && <span className="error-text">{passwordError}</span>}
                      </div>
                      <div className="field">
                        <label className="field-top" htmlFor="vm-pass2"><span>Repetir contraseña</span></label>
                        <input id="vm-pass2" className="text-input" type="password" value={repeat} onBlur={() => blur("repeat")} onChange={(e) => { setRepeat(e.target.value); touch(); }} />
                        {repeatError && <span className="error-text">{repeatError}</span>}
                      </div>
                    </>
                  )}
                </div>

                {!fromTemplate && <div className="dialog-column">
                  {cleanupLevels.length > 0 && (
                    <div className="field">
                      <div className="field-top"><span>Windows</span></div>
                      <CleanupPicker levels={cleanupLevels} value={cleanup} onChange={(v) => { setCleanup(v); touch(); }} />
                    </div>
                  )}

                  {catalog.length > 0 && (
                    <div className="field">
                      <div className="field-top"><span>Apps que se instalan</span><span className="hint">Al abrirla por primera vez</span></div>
                      <AppPicker apps={catalog} value={apps} onChange={(v) => { setApps(v); touch(); }} scroll={false} />
                    </div>
                  )}
                </div>}
              </div>
            </div>
            {error && <div className="notice error-notice"><span className="grow">{error}</span></div>}

            <div className="dialog-foot">
              <button type="button" className="btn ghost" onClick={onClose}>Cancelar</button>
              <button type="submit" className="primary compact" disabled={!complete}><IconPlus size={16} />Crear máquina</button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
}
