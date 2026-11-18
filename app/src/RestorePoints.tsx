import { useEffect, useRef, useState } from "react";
import { IconArrowBackUp, IconBookmark, IconHistory, IconLoader2, IconPlus, IconTrash, IconFlask } from "@tabler/icons-react";
import type { RestorePoint, RestorePointList, VmOverview } from "./types";
import { api } from "./api";
import { MachineIcon } from "./machineIcon";
import { CheckMark } from "./ui";
import { locale, t, translateModule } from "./i18n";

interface Props {
  vm: VmOverview;
  busy: { cmd?: string; message?: string } | null;
  startJob: (vm: string, cmd: string, args: Record<string, unknown>, after?: () => void, failed?: () => void) => void;
  run: (vm: string, label: string, task: () => Promise<unknown>) => Promise<boolean>;
}

const cache: Record<string, RestorePointList> = {};
const POINT_CMDS = ["New-GpuVMRestorePoint", "Restore-GpuVMRestorePoint", "Remove-GpuVMRestorePoint"];

const when = (iso: string) => new Date(iso).toLocaleString(locale(), { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
const gb = (n: number) => `${n.toLocaleString(locale(), { maximumFractionDigits: 1 })} GB`;

/** Restore points of a machine (Máquina section): Windows as it was at a moment, to go back to. Taken and applied with
 *  the machine off (GpuVM shuts it down cleanly and starts it again). A disposable machine shows instead that it is
 *  deleted when it turns off, and lets it be kept. */
export function RestorePoints({ vm, busy, startJob, run }: Props) {
  const [list, setList] = useState<RestorePointList | null>(cache[vm.name] ?? null);
  const [back, setBack] = useState<RestorePoint | null>(null);
  const [armed, setArmed] = useState<string | null>(null);
  const load = () => api.restorePoints(vm.name).then((l) => { if (l) { cache[vm.name] = l; setList(l); } }).catch(() => {});
  useEffect(() => { setList(cache[vm.name] ?? null); setArmed(null); }, [vm.name]);
  useEffect(() => { if (vm.managed && !vm.disposable) load(); }, [vm.name, vm.restorePoints, busy?.cmd]);
  // A delete that was armed and not confirmed goes back to the trash icon.
  useEffect(() => { if (!armed) return; const id = setTimeout(() => setArmed(null), 4000); return () => clearTimeout(id); }, [armed]);
  if (!vm.managed) return null;

  if (vm.disposable) {
    return (
      <div className="card">
        <div className="opt-rows">
          <div className="opt-row">
            <span className="opt-icon"><IconFlask size={17} /></span>
            <div className="opt-text">
              <span className="opt-title">{t("Máquina desechable")}</span>
              <span className="opt-desc">{t("Se borra con su disco al apagarse. Conservarla la vuelve una máquina normal.")}</span>
            </div>
            <div className="opt-ctl">
              <button className="btn" disabled={!!busy} onClick={() => run(vm.name, t("Conservando"), () => api.keepDisposable(vm.name))}>
                <IconBookmark size={16} />{t("Conservar")}
              </button>
            </div>
          </div>
        </div>
      </div>
    );
  }

  const off = vm.state === "Off";
  const points = [...(list?.points ?? [])].reverse();
  const full = !!list && list.points.length >= list.max;
  const working = !!busy?.cmd && POINT_CMDS.includes(busy.cmd);
  const create = () => startJob(vm.name, "New-GpuVMRestorePoint", { Name: vm.name, ShutdownIfRunning: true, Confirm: false }, load);
  const remove = (p: RestorePoint) => { setArmed(null); startJob(vm.name, "Remove-GpuVMRestorePoint", { Name: vm.name, Id: p.id, ShutdownIfRunning: true, Confirm: false }, load); };

  return (
    <div className="card">
      <div className="opt-rows">
        <div className="opt-row">
          <span className="opt-icon"><IconHistory size={17} /></span>
          <div className="opt-text">
            <span className="opt-title">{t("Puntos de restauración")}</span>
            <span className="opt-desc">{points.length
              ? t("Windows vuelve a como estaba en ese momento, con sus apps y archivos. Los ajustes de la máquina no cambian.")
              : t("Guarda cómo está Windows ahora para volver a ese momento si algo sale mal.")}</span>
          </div>
          <div className="opt-ctl">
            <button className="btn" disabled={!!busy || full} onClick={create} title={full ? t("Borra uno para crear otro") : undefined}>
              {working && busy?.cmd === "New-GpuVMRestorePoint" ? <IconLoader2 size={16} className="spin" /> : <IconPlus size={16} />}
              {working && busy?.cmd === "New-GpuVMRestorePoint" ? translateModule(busy.message ?? "") : off ? t("Crear punto") : t("Apagar y crear punto")}
            </button>
          </div>
        </div>
        {points.map((p) => (
          <div className="opt-row point-row" key={p.id}
            onContextMenu={(e) => { e.preventDefault(); if (!busy) setArmed(p.id); }}>
            <span className="opt-icon"><IconBookmark size={17} /></span>
            <div className="opt-text">
              <span className="opt-title">{(p.label ? translateModule(p.label) : when(p.createdAt))}</span>
              <span className="opt-desc">{[
                p.label ? when(p.createdAt) : null,
                p.missing ? t("Falta su disco") : p.sizeGB !== null ? t("Ocupa {size}", { size: gb(p.sizeGB) }) : null,
                p.current && list?.changesGB != null ? t("Cambios desde entonces {size}", { size: gb(list.changesGB) }) : null,
              ].filter(Boolean).join(" · ")}</span>
            </div>
            <div className="opt-ctl">
              <button className="btn ghost" disabled={!!busy || p.missing} onClick={() => setBack(p)}><IconArrowBackUp size={16} />{t("Volver")}</button>
              {armed === p.id ? (
                <button className="btn danger-fill" onClick={() => remove(p)}><IconTrash size={16} />{t("Borrar")}</button>
              ) : (
                <button className="icon-btn" aria-label={t("Borrar punto")} title={t("Borrar punto")} disabled={!!busy} onClick={() => setArmed(p.id)}><IconTrash size={17} /></button>
              )}
            </div>
          </div>
        ))}
      </div>
      {back && (
        <ConfirmGoBack vm={vm} point={back} canSave={!full} onClose={() => setBack(null)}
          onConfirm={(saveCurrent) => {
            setBack(null);
            startJob(vm.name, "Restore-GpuVMRestorePoint", { Name: vm.name, Id: back.id, SaveCurrent: saveCurrent, ShutdownIfRunning: true, Confirm: false }, load);
          }} />
      )}
    </div>
  );
}

/** Going back: what comes back, and whether the present is kept as a point first (on by default). */
function ConfirmGoBack({ vm, point, canSave, onClose, onConfirm }: {
  vm: VmOverview; point: RestorePoint; canSave: boolean; onClose: () => void; onConfirm: (saveCurrent: boolean) => void;
}) {
  const [save, setSave] = useState(canSave);
  const cancelRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cancelRef.current?.focus();
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);
  const title = t("Volver a {point}", { point: (point.label ? translateModule(point.label) : when(point.createdAt)) });
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog narrow" role="dialog" aria-modal="true" aria-label={title}>
        <div className="dialog-head"><MachineIcon name={vm.name} size={40} radius={10} /><h2>{title}</h2></div>
        <p className="dialog-text">{vm.state === "Off"
          ? t("Windows vuelve a como estaba el {date}. Los ajustes de la máquina no cambian.", { date: when(point.createdAt) })
          : t("La máquina se apaga y Windows vuelve a como estaba el {date}. Los ajustes de la máquina no cambian.", { date: when(point.createdAt) })}</p>
        <div className="choice-list">
          <button type="button" role="checkbox" aria-checked={save} disabled={!canSave} className={`choice ${save ? "on" : ""}`} onClick={() => setSave((s) => !s)}>
            <span className="check">{save && <CheckMark />}</span>
            <span className="grow">
              <span className="title">{t("Guardar cómo está ahora")}</span>
              <span className="desc">{canSave ? t("Se crea un punto antes de volver, por si lo necesitas.") : t("Ya tiene el máximo de puntos; borra uno para guardarlo.")}</span>
            </span>
          </button>
        </div>
        <div className="dialog-foot">
          <button ref={cancelRef} className="btn ghost" onClick={onClose}>{t("Cancelar")}</button>
          <button className={`btn ${save ? "" : "danger-fill"}`} onClick={() => onConfirm(save)}>
            <IconArrowBackUp size={16} />{save ? t("Volver") : t("Volver y descartar lo de ahora")}
          </button>
        </div>
      </div>
    </div>
  );
}
