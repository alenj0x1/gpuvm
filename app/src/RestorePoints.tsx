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

export function RestorePoints({ vm, busy, startJob, run }: Props) {
  const [list, setList] = useState<RestorePointList | null>(cache[vm.name] ?? null);
  const [back, setBack] = useState<RestorePoint | null>(null);
  const [armed, setArmed] = useState<string | null>(null);
  const load = () => api.restorePoints(vm.name).then((l) => { if (l) { cache[vm.name] = l; setList(l); } }).catch(() => {});
  useEffect(() => { setList(cache[vm.name] ?? null); setArmed(null); }, [vm.name]);
  useEffect(() => { if (vm.managed && !vm.disposable) load(); }, [vm.name, vm.restorePoints, busy?.cmd]);
  useEffect(() => { if (!armed) return; const id = setTimeout(() => setArmed(null), 4000); return () => clearTimeout(id); }, [armed]);
  if (!vm.managed) return null;

  if (vm.disposable) {
    return (
      <div className="card">
        <div className="opt-rows">
          <div className="opt-row">
            <span className="opt-icon"><IconFlask size={17} /></span>
            <div className="opt-text">
              <span className="opt-title">{t("Disposable machine")}</span>
              <span className="opt-desc">{t("It's deleted with its disk when it shuts down. Keeping it makes it a regular machine.")}</span>
            </div>
            <div className="opt-ctl">
              <button className="btn" disabled={!!busy} onClick={() => run(vm.name, t("Keeping"), () => api.keepDisposable(vm.name))}>
                <IconBookmark size={16} />{t("Keep")}
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
            <span className="opt-title">{t("Restore points")}</span>
            <span className="opt-desc">{points.length
              ? t("Windows goes back to how it was at that moment, with its apps and files. The machine's settings don't change.")
              : t("Save Windows as it is now to go back to this moment if something goes wrong.")}</span>
          </div>
          <div className="opt-ctl">
            <button className="btn" disabled={!!busy || full} onClick={create} title={full ? t("Delete one to create another") : undefined}>
              {working && busy?.cmd === "New-GpuVMRestorePoint" ? <IconLoader2 size={16} className="spin" /> : <IconPlus size={16} />}
              {working && busy?.cmd === "New-GpuVMRestorePoint" ? translateModule(busy.message ?? "") : off ? t("Create point") : t("Shut down and create point")}
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
                p.missing ? t("Its disk is missing") : p.sizeGB !== null ? t("Takes {size}", { size: gb(p.sizeGB) }) : null,
                p.current && list?.changesGB != null ? t("Changes since then {size}", { size: gb(list.changesGB) }) : null,
              ].filter(Boolean).join(" · ")}</span>
            </div>
            <div className="opt-ctl">
              <button className="btn ghost" disabled={!!busy || p.missing} onClick={() => setBack(p)}><IconArrowBackUp size={16} />{t("Go back")}</button>
              {armed === p.id ? (
                <button className="btn danger-fill" onClick={() => remove(p)}><IconTrash size={16} />{t("Delete point")}</button>
              ) : (
                <button className="icon-btn" aria-label={t("Delete point")} title={t("Delete point")} disabled={!!busy} onClick={() => setArmed(p.id)}><IconTrash size={17} /></button>
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
  const title = t("Go back to {point}", { point: (point.label ? translateModule(point.label) : when(point.createdAt)) });
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog narrow" role="dialog" aria-modal="true" aria-label={title}>
        <div className="dialog-head"><MachineIcon name={vm.name} size={40} radius={10} /><h2>{title}</h2></div>
        <p className="dialog-text">{vm.state === "Off"
          ? t("Windows goes back to how it was on {date}. The machine's settings don't change.", { date: when(point.createdAt) })
          : t("The machine shuts down and Windows goes back to how it was on {date}. The machine's settings don't change.", { date: when(point.createdAt) })}</p>
        <div className="choice-list">
          <button type="button" role="checkbox" aria-checked={save} disabled={!canSave} className={`choice ${save ? "on" : ""}`} onClick={() => setSave((s) => !s)}>
            <span className="check">{save && <CheckMark />}</span>
            <span className="grow">
              <span className="title">{t("Save how it is now")}</span>
              <span className="desc">{canSave ? t("A point is created before going back, in case you need it.") : t("It already has the most points it can keep; delete one to save it.")}</span>
            </span>
          </button>
        </div>
        <div className="dialog-foot">
          <button ref={cancelRef} className="btn ghost" onClick={onClose}>{t("Cancel")}</button>
          <button className={`btn ${save ? "" : "danger-fill"}`} onClick={() => onConfirm(save)}>
            <IconArrowBackUp size={16} />{save ? t("Go back") : t("Go back and discard the present")}
          </button>
        </div>
      </div>
    </div>
  );
}
