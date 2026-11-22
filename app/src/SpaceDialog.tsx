import { useMemo, useState } from "react";
import { IconTrash, IconX } from "@tabler/icons-react";
import type { VmOverview } from "./types";
import { AMBIENTS, AMBIENT_TIMES, ambientInfo, normalizeAmbient, type AmbientId, type AmbientTime } from "./ambient";
import { MAIN_SPACE, deleteSpace, readSpaces, saveSpace, spaceOf, type Space } from "./spaces";
import { MachineCube, cubeOf } from "./MachineCube";
import { MachineIcon } from "./machineIcon";
import { randomMachine } from "./decor/random";
import { CheckMark, Segmented, stateText, useScrollFade } from "./ui";
import { t, tn } from "./i18n";

export function SpaceDialog({ space, vms, onClose, onSaved, initialMachines = [] }: {
  space?: Space;
  vms: VmOverview[];
  onClose: () => void;
  onSaved?: (s: Space) => void;
  initialMachines?: string[];
}) {
  const editing = !!space;
  const [name, setName] = useState(space?.name ?? "");
  const [ambient, setAmbient] = useState<AmbientId>(normalizeAmbient(space?.ambient ?? "board"));
  const [time, setTime] = useState<AmbientTime>(space?.time ?? "day");
  const [picked, setPicked] = useState<string[]>(() => (space ? vms.filter((v) => spaceOf(v.name).id === space.id).map((v) => v.name) : initialMachines));
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [bodyRef, bodyFade] = useScrollFade<HTMLDivElement>();
  const trimmed = name.trim();
  const taken = readSpaces().some((s) => s.id !== space?.id && s.name.trim().toLowerCase() === trimmed.toLowerCase());
  const nameError = taken ? t("There's already a space with that name.") : trimmed.length > 32 ? t("Up to {n} characters.", { n: 32 }) : "";
  const valid = !!trimmed && !nameError;
  const dirty = trimmed !== (space?.name ?? "") || ambient !== normalizeAmbient(space?.ambient ?? "board") || time !== (space?.time ?? "day") || picked.join() !== (space ? picked.join() : initialMachines.join());
  const toggle = (n: string) => setPicked((p) => (p.includes(n) ? p.filter((x) => x !== n) : [...p, n]));
  const save = (e: React.FormEvent) => {
    e.preventDefault();
    if (!valid) return;
    const s = saveSpace({ id: space?.id, name: trimmed, ambient, time, machines: picked });
    if (space && space.id !== MAIN_SPACE) {
      const removed = vms.filter((v) => spaceOf(v.name).id === space.id && !picked.includes(v.name)).map((v) => v.name);
      if (removed.length) { const main = readSpaces().find((x) => x.id === MAIN_SPACE)!; saveSpace({ ...main, machines: [...main.machines, ...removed] }); }
    }
    onSaved?.(s);
    onClose();
  };
  const shown = vms.filter((v) => picked.includes(v.name));
  const sample = useMemo(randomMachine, []);
  const hero = shown[0];
  const mainName = readSpaces().find((s) => s.id === MAIN_SPACE)?.name ?? "";

  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && !dirty && onClose()}>
      <div className="dialog wide space-dialog" role="dialog" aria-modal="true" aria-label={editing ? t("Edit {name}", { name: space!.name }) : t("New space")}>
        <div className="dialog-head">
          <span className="space-dialog-icon">{(() => { const I = ambientInfo(ambient).icon; return <I size={22} />; })()}</span>
          <h2>{editing ? t("Edit {name}", { name: space!.name }) : t("New space")}</h2>
          <button type="button" className="icon-btn" aria-label={t("Close")} onClick={onClose}><IconX size={18} /></button>
        </div>
        <form className="dialog-form" onSubmit={save}>
          <div className="space-editor">
            <div ref={bodyRef} className={`dialog-body ${bodyFade}`}>
              <div className="field">
                <label className="field-top" htmlFor="space-name"><span>{t("Name")}</span></label>
                <input id="space-name" className="text-input" value={name} maxLength={40} placeholder={t("Work, Games, AI tests…")}
                  onChange={(e) => setName(e.target.value)} />
                {nameError && <span className="error-text">{nameError}</span>}
              </div>
              <div className="field">
                <div className="field-top"><span>{t("Ambient")}</span></div>
                <div className="space-ambients" role="radiogroup" aria-label={t("Ambient")}>
                  {AMBIENTS.map((a) => (
                    <button type="button" key={a.id} role="radio" aria-checked={ambient === a.id} className={`space-ambient${ambient === a.id ? " on" : ""}`} onClick={() => setAmbient(a.id)}>
                      <span className="space-ambient-icon"><a.icon size={17} /></span>
                      <span className="grow"><span className="title">{a.name}</span><span className="desc">{a.desc}</span></span>
                    </button>
                  ))}
                </div>
              </div>
              {ambientInfo(ambient).times && (
                <div className="field">
                  <div className="field-top"><span>{t("Time of day")}</span></div>
                  <Segmented value={time} onChange={setTime} options={AMBIENT_TIMES.map((x) => ({ value: x.id, label: x.name }))} />
                </div>
              )}
              <div className="field">
                <div className="field-top"><span>{t("Machines")}</span>{picked.length > 0 && <span className="hint">{tn(picked.length, "{n} picked|one", "{n} picked")}</span>}</div>
                {vms.length === 0 ? (
                  <span className="hint">{t("No machines yet. You can move the ones you create here later.")}</span>
                ) : (
                  <div className="space-machines">
                    {vms.map((v) => {
                      const on = picked.includes(v.name), from = spaceOf(v.name);
                      const elsewhere = from.id !== space?.id;
                      return (
                        <button type="button" key={v.id} role="checkbox" aria-checked={on} className={`space-machine${on ? " on" : ""}`} onClick={() => toggle(v.name)}>
                          <span className="check box">{on && <CheckMark />}</span>
                          <MachineIcon name={v.name} size={26} radius={7} />
                          <span className="grow">
                            <span className="title">{v.name}</span>
                            <span className="desc">{stateText(v.state)}{elsewhere ? ` · ${on ? t("Moves from {space}", { space: from.name }) : t("In {space}", { space: from.name })}` : ""}</span>
                          </span>
                        </button>
                      );
                    })}
                  </div>
                )}
              </div>
            </div>
            <div className="space-editor-cube">
              <MachineCube key="space-preview" ambient={ambient} time={time} spaceName={trimmed || t("New space")} machine={hero ? cubeOf(hero) : sample} name={hero?.name ?? ""} decorOf={hero?.name ?? ""}
                others={shown.slice(1).map((v) => ({ name: v.name, machine: cubeOf(v) }))} />
            </div>
          </div>
          <div className="dialog-foot">
            {editing && space!.id !== MAIN_SPACE && (
              confirmDelete ? (
                <span className="space-delete-confirm">
                  <span>{t("Its machines go back to {space}.", { space: mainName })}</span>
                  <button type="button" className="btn danger-fill" onClick={() => { deleteSpace(space!.id); onClose(); }}><IconTrash size={16} />{t("Delete")}</button>
                </span>
              ) : (
                <button type="button" className="btn ghost danger space-delete" onClick={() => setConfirmDelete(true)}><IconTrash size={16} />{t("Delete space")}</button>
              )
            )}
            <button type="button" className="btn ghost" onClick={onClose}>{t("Cancel")}</button>
            <button type="submit" className="primary compact" disabled={!valid}>{editing ? t("Save") : t("Create space")}</button>
          </div>
        </form>
      </div>
    </div>
  );
}
