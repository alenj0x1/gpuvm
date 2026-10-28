import { useEffect, useRef, useState } from "react";
import { IconCheck, IconLoader2, IconPlus, IconX } from "@tabler/icons-react";
import type { AppInfo, IsoFile, ProfileInfo, VmOverview } from "./types";
import { api, pickIso } from "./api";
import { PatternButton, machineColor, tintVars } from "./bauhaus";
import { CheckMark } from "./ui";
import { AppPicker, IsoPicker, profileLabel, profileSummary } from "./pickers";

interface Props {
  existing: VmOverview[];
  job: { message: string; log: string[] } | null;
  error: string | null;
  onCreate: (args: { name: string; iso: string; profile: string; password: string; apps: string[] }) => void;
  onClose: () => void;
}

const MIN_PASSWORD = 6;

export function CreateDialog({ existing, job, error, onCreate, onClose }: Props) {
  const [name, setName] = useState(() => {
    for (let i = 1; ; i++) { const n = i === 1 ? "win-gpu" : `win-gpu-${i}`; if (!existing.some((v) => v.name === n)) return n; }
  });
  const [isos, setIsos] = useState<IsoFile[] | null>(null);
  const [iso, setIso] = useState<string | null>(null);
  const [profiles, setProfiles] = useState<ProfileInfo[]>([]);
  const [profile, setProfile] = useState("max-performance");
  const [catalog, setCatalog] = useState<AppInfo[]>([]);
  const [apps, setApps] = useState<string[]>([]);
  const [password, setPassword] = useState("");
  const [repeat, setRepeat] = useState("");
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [dirty, setDirty] = useState(false);
  const [, repaint] = useState(0);
  const nameRef = useRef<HTMLInputElement>(null);
  const busy = !!job;

  useEffect(() => {
    api.isos().then((list) => { setIsos(list); if (list[0]) setIso((cur) => cur ?? list[0].path); }).catch(() => setIsos([]));
    api.profiles().then((p) => setProfiles(p.filter((x) => x.Name !== "base"))).catch(() => {});
    api.apps().then(setCatalog).catch(() => {});
  }, []);

  // A profile brings its ISO and apps; what the user changes afterwards in the dialog wins.
  const chooseProfile = (p: ProfileInfo) => {
    setProfile(p.Name);
    setDirty(true);
    if (!p.Settings) return;
    setApps(p.Settings.apps);
    const iso = p.Settings.iso;
    if (iso && !isos?.find((f) => f.path === iso)?.missing) setIso(iso);
  };
  useEffect(() => { if (!busy) nameRef.current?.focus(); }, [busy]);
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);

  const touch = (field: string) => { setDirty(true); if (errors[field]) setErrors({ ...errors, [field]: "" }); };

  const submit = (e?: React.FormEvent) => {
    e?.preventDefault();
    const found: Record<string, string> = {};
    if (!/^[\w-]{1,40}$/.test(name)) found.name = "Usa letras, números o guiones, sin espacios";
    else if (existing.some((v) => v.name.toLowerCase() === name.toLowerCase())) found.name = "Ya hay una máquina con ese nombre";
    if (!iso) found.iso = "Elige la imagen de Windows";
    if (password.length < MIN_PASSWORD) found.password = `Usa al menos ${MIN_PASSWORD} caracteres`;
    else if (password !== repeat) found.repeat = "Las contraseñas no coinciden";
    setErrors(found);
    if (Object.keys(found).length === 0) onCreate({ name, iso: iso!, profile, password, apps });
  };

  const browse = async () => {
    const file = await pickIso();
    if (!file) return;
    await api.addIso(file).catch(() => {});
    setIsos(await api.isos().catch(() => [...(isos ?? []), { path: file, name: file.split("\\").pop()!, sizeGB: 0, modified: "" }]));
    setIso(file);
    touch("iso");
  };

  const shownProfiles = profiles.length ? profiles : [{ Name: "balanced", Description: "", Extends: null }, { Name: "max-performance", Description: "", Extends: null }];

  return (
    // Clicking outside only closes when nothing was typed; Esc always closes.
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && (busy || !dirty) && onClose()}>
      <div className="dialog" role="dialog" aria-modal="true" aria-label="Crear máquina" style={tintVars(machineColor(name || "nueva")) as React.CSSProperties}>
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
            <div className="field">
              <label className="field-top" htmlFor="vm-name"><span>Nombre</span></label>
              <input id="vm-name" ref={nameRef} className="text-input" value={name} onChange={(e) => { setName(e.target.value); touch("name"); }} />
              {errors.name && <span className="error-text">{errors.name}</span>}
            </div>

            <div className="field">
              <div className="field-top"><span>Imagen de Windows</span></div>
              <IsoPicker isos={isos?.filter((f) => !f.missing) ?? null} value={iso} onChange={(v) => { setIso(v); touch("iso"); }} onBrowse={browse} />
              {errors.iso && <span className="error-text">{errors.iso}</span>}
            </div>

            <div className="field">
              <div className="field-top"><span>Perfil</span></div>
              <div className="two" role="radiogroup">
                {shownProfiles.map((p) => (
                  <button type="button" role="radio" aria-checked={profile === p.Name} key={p.Name} className={`choice top ${profile === p.Name ? "on" : ""}`}
                    onClick={() => chooseProfile(p)}>
                    <span className="check">{profile === p.Name && <CheckMark />}</span>
                    <span className="grow">
                      <span className="title">{profileLabel(p.Name)}</span>
                      <span className="desc">{p.Description || (p.Settings ? profileSummary(p.Settings, catalog) : "")}</span>
                    </span>
                  </button>
                ))}
              </div>
            </div>

            {catalog.length > 0 && (
              <div className="field">
                <div className="field-top"><span>Apps que se instalan</span><span className="hint">Al abrirla por primera vez</span></div>
                <AppPicker apps={catalog} value={apps} onChange={(v) => { setApps(v); setDirty(true); }} />
              </div>
            )}

            <div className="two">
              <div className="field">
                <label className="field-top" htmlFor="vm-pass"><span>Contraseña de Windows</span><span className="hint">Usuario: gpuvm</span></label>
                <input id="vm-pass" className="text-input" type="password" value={password} onChange={(e) => { setPassword(e.target.value); touch("password"); }} />
                {errors.password && <span className="error-text">{errors.password}</span>}
              </div>
              <div className="field">
                <label className="field-top" htmlFor="vm-pass2"><span>Repetir contraseña</span></label>
                <input id="vm-pass2" className="text-input" type="password" value={repeat} onChange={(e) => { setRepeat(e.target.value); touch("repeat"); }} />
                {errors.repeat && <span className="error-text">{errors.repeat}</span>}
              </div>
            </div>
            {error && <div className="notice error-notice"><span className="grow">{error}</span></div>}

            <div className="dialog-foot">
              <button type="button" className="btn ghost" onClick={onClose}>Cancelar</button>
              <button type="submit" className="primary compact"><IconPlus size={16} />Crear máquina</button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
}
