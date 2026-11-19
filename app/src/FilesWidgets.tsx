import { useEffect, useState } from "react";
import { IconAlignLeft, IconBolt, IconCheck, IconClipboard, IconDownload, IconFiles, IconLoader2, IconPhoto, IconSend, IconTrash, IconX } from "@tabler/icons-react";
import { api, inTauri } from "./api";
import { locale, t } from "./i18n";
import { humanError } from "./ui";
import { cancelTransfer, startTransfer, transferAmount, useTransfers, type Transfer } from "./transfers";
import type { VmOverview } from "./types";
import type { WidgetSize } from "./ViewerWidgets";

// The panel's Archivos and Portapapeles widgets. Everything goes from the PC into the machines (or from one machine
// into another through the PC's memory); nothing ever comes out of a machine to the PC.

async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!inTauri) return null;
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args);
}

const bytes = (n: number) => n >= 1 << 30
  ? `${(n / (1 << 30)).toLocaleString(locale(), { maximumFractionDigits: 1 })} GB`
  : n >= 1 << 20 ? `${(n / (1 << 20)).toLocaleString(locale(), { maximumFractionDigits: 1 })} MB`
    : `${Math.max(1, Math.round(n / 1024)).toLocaleString(locale())} KB`;

/** "photo.png", "photo.png and 2 more". */
export const namesOf = (names: string[]) => names.length <= 1 ? names[0] ?? "" : t("{first} and {n} more", { first: names[0], n: names.length - 1 });

/** One copy: the percent before the name (a long name never hides it), its bar and Cancelar; once done, where it went. */
export function TransferRow({ tr }: { tr: Transfer }) {
  const running = tr.state === "running";
  const sub = running ? (transferAmount(tr) || t("Preparing…"))
    : tr.state === "done" ? t("In {vm} › {folder}", { vm: tr.vm, folder: !tr.folder || tr.folder === "Received" ? t("Received") : tr.folder })
      : tr.state === "cancelled" ? t("Cancelled") : humanError(tr.error ?? "");
  return (
    <li className={`vp-transfer ${tr.state}`}>
      <span className="vp-transfer-mark">
        {running ? <strong>{tr.percent} %</strong> : tr.state === "done" ? <IconCheck size={15} /> : <IconX size={15} />}
      </span>
      <span className="vp-transfer-text">
        <span className="name">{tr.from ? `${namesOf(tr.names)} · ${tr.from} › ${tr.vm}` : namesOf(tr.names)}</span>
        {running && <span className="vp-transfer-bar"><i style={{ width: `${tr.percent}%` }} /></span>}
        <span className="sub">{sub}</span>
      </span>
      {running && (
        <button type="button" className="vp-icon" aria-label={t("Cancel")} title={t("Cancel")} onClick={() => cancelTransfer(tr.id)}>
          <IconX size={15} />
        </button>
      )}
    </li>
  );
}

/** Archivos: the copies into this machine (and from it) and, with other machines running, what is selected in this
 *  machine's File Explorer goes to one of them in a click. */
export function FilesWidget({ vm, vms, size }: { vm: string; vms: VmOverview[]; size: WidgetSize }) {
  const all = useTransfers();
  const list = all.filter((tr) => tr.vm === vm || tr.from === vm);
  const others = vms.filter((v) => v.name !== vm && v.state === "Running");
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");

  const sendTo = async (target: string) => {
    setError("");
    setBusy(target);
    try {
      const sel = await api.explorerSelection(vm);
      if (!sel?.paths?.length) setError(t("Select files in {vm}'s File Explorer.", { vm }));
      else await startTransfer(target, sel.paths, t("Received"), vm);
    } catch (e) { setError(humanError(e)); }
    setBusy("");
  };

  const sendRow = others.length > 0 && (
    <div className="vp-send">
      <span className="vp-send-label">{t("Send what is selected to")}</span>
      <div className="vp-send-targets">
        {others.slice(0, 4).map((o) => (
          <button key={o.name} type="button" className="vp-chip" disabled={!!busy} onClick={() => sendTo(o.name)}>
            {busy === o.name ? <IconLoader2 size={14} className="spin" /> : <IconSend size={14} />}{o.name}
          </button>
        ))}
      </div>
      {error && <span className="vp-send-error">{error}</span>}
    </div>
  );

  if (!list.length) {
    return (
      <div className="vp-files">
        <div className="vp-files-empty">
          <span className="vp-empty-icon"><IconDownload size={18} /></span>
          <strong>{t("Drop files on the picture")}</strong>
          {size.h >= 2 && <span>{t("They arrive on {vm}'s desktop, in {folder}.", { vm, folder: t("Received") })}</span>}
        </div>
        {sendRow}
      </div>
    );
  }
  return (
    <div className="vp-files">
      <ul className="vp-transfers vp-scroll">{list.map((tr) => <TransferRow key={tr.id} tr={tr} />)}</ul>
      {sendRow}
    </div>
  );
}

interface ClipItem { id: number; kind: "text" | "image" | "files"; text?: string; chars?: number; width?: number; height?: number; bytes?: number; thumb?: string | null; names?: string[]; count?: number }

const CLIP_SAMPLE: ClipItem[] = [
  { id: 1, kind: "text", text: "git clone https://github.com/alenj0x1/gpu-vm.git", chars: 46 },
  { id: 2, kind: "image", width: 1280, height: 720, bytes: 412000, thumb: null },
  { id: 3, kind: "files", names: ["informe.docx", "fotos"], count: 2, bytes: 14_680_064 },
  { id: 4, kind: "text", text: "Av. Siempre Viva 742, piso 3", chars: 28 },
];

function useClipboard(): ClipItem[] {
  // In the browser preview: a few copies of each kind.
  const [items, setItems] = useState<ClipItem[]>(() => inTauri || new URLSearchParams(location.search).has("empty") ? [] : CLIP_SAMPLE);
  useEffect(() => {
    if (!inTauri) return;
    let stop = () => {};
    let alive = true;
    invoke<ClipItem[]>("clipboard_items").then((l) => { if (alive && l) setItems(l); });
    import("@tauri-apps/api/event").then(({ listen }) => listen<ClipItem[]>("clipboard", (e) => setItems(e.payload)))
      .then((un) => { if (alive) stop = un; else un(); });
    return () => { alive = false; stop(); };
  }, []);
  return items;
}

/** Portapapeles: the last copies made on this PC while a machine is open (text, images, files), each pasted into
 *  this machine with a click; "On copy" sends every new text or image on its own. Kept in memory only. */
export function ClipboardWidget({ vm, size }: { vm: string; size: WidgetSize }) {
  const items = useClipboard();
  const [state, setState] = useState<Record<number, "busy" | "done" | string>>({});
  const [auto, setAuto] = useState(false);

  useEffect(() => { invoke("clipboard_auto", { vm: auto ? vm : null }); }, [auto, vm]);
  useEffect(() => {
    if (!inTauri) return;
    let stop = () => {};
    import("@tauri-apps/api/event").then(({ listen }) => listen<{ id: number; error: string | null }>("clipboard-sent", (e) => {
      setState((s) => ({ ...s, [e.payload.id]: e.payload.error ?? "done" }));
    })).then((un) => { stop = un; });
    return () => stop();
  }, []);

  const send = async (it: ClipItem) => {
    setState((s) => ({ ...s, [it.id]: "busy" }));
    try {
      await invoke("clipboard_send", { vm, id: it.id, folder: t("Received") });
      setState((s) => ({ ...s, [it.id]: "done" }));
    } catch (e) { setState((s) => ({ ...s, [it.id]: humanError(e) })); }
  };

  const toggle = (
    <button type="button" className={`vp-chip${auto ? " on" : ""}`} aria-pressed={auto} title={t("What you copy on the PC goes to {vm} on its own", { vm })} onClick={() => setAuto(!auto)}>
      <IconBolt size={14} />{t("On copy")}
    </button>
  );
  if (!items.length) {
    return (
      <div className="vp-clip">
        <div className="vp-files-empty">
          <span className="vp-empty-icon"><IconClipboard size={18} /></span>
          <strong>{t("Copy something on the PC")}</strong>
          {size.h >= 2 && <span>{t("What you copy while using the machine stays here to paste into it.")}</span>}
        </div>
        <div className="vp-clip-foot">{toggle}</div>
      </div>
    );
  }
  return (
    <div className="vp-clip">
      <ul className="vp-clips vp-scroll">
        {items.map((it) => {
          const st = state[it.id];
          const label = it.kind === "text" ? (it.text ?? "")
            : it.kind === "image" ? t("Image {w} × {h}", { w: it.width ?? 0, h: it.height ?? 0 })
              : `${namesOf(it.names ?? [])}${it.bytes ? ` · ${bytes(it.bytes)}` : ""}`;
          return (
            <li key={it.id}>
              {it.kind === "image" ? (it.thumb ? <img className="vp-clip-thumb" src={it.thumb} alt="" /> : <span className="vp-clip-icon"><IconPhoto size={15} /></span>)
                : <span className="vp-clip-icon">{it.kind === "files" ? <IconFiles size={15} /> : <IconAlignLeft size={15} />}</span>}
              <span className="vp-clip-text">
                <span className={it.kind === "text" ? "text" : "name"}>{label}</span>
                {st && st !== "busy" && st !== "done" && <span className="sub err">{st}</span>}
              </span>
              <button type="button" className="vp-icon" disabled={st === "busy"} aria-label={t("Paste in {vm}", { vm })} title={t("Paste in {vm}", { vm })} onClick={() => send(it)}>
                {st === "busy" ? <IconLoader2 size={15} className="spin" /> : st === "done" ? <IconCheck size={15} /> : <IconSend size={15} />}
              </button>
            </li>
          );
        })}
      </ul>
      <div className="vp-clip-foot">
        {toggle}
        <button type="button" className="vp-icon" aria-label={t("Clear")} title={t("Clear")} onClick={() => invoke("clipboard_clear")}><IconTrash size={15} /></button>
      </div>
    </div>
  );
}
