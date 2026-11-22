import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { IconRestore, IconShieldLock } from "@tabler/icons-react";
import { MachineDesktop } from "./MachineDesktop";
import { cornersAt, DOCK_POS, NOTCH_POS, savePrefs, usePrefs, type Pos } from "./prefs";
import { t } from "./i18n";

const SNAP = 10;

type Piece = "dock" | "notch";

export function PlacementEditor() {
  const prefs = usePrefs();
  const stage = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ w: 520, h: 325 });
  const [drag, setDrag] = useState<{ piece: Piece; pos: Pos; guides: { v?: number; h?: number } } | null>(null);
  useEffect(() => {
    const el = stage.current;
    if (!el) return;
    const fit = () => setSize((s) => (Math.abs(el.clientWidth - s.w) > 1 || Math.abs(el.clientHeight - s.h) > 1 ? { w: el.clientWidth, h: el.clientHeight } : s));
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const dims: Record<Piece, { w: number; h: number }> = {
    dock: { w: Math.min(size.w * 0.62, 300), h: 40 },
    notch: { w: Math.min(size.w * 0.6, 270), h: 34 },
  };
  const posOf = (piece: Piece): Pos => (drag?.piece === piece ? drag.pos : piece === "dock" ? prefs.dockPos : prefs.notchPos);
  const box = (piece: Piece, p: Pos) => {
    const d = dims[piece];
    return { x: (size.w - d.w) * p.x, y: (size.h - d.h) * p.y, w: d.w, h: d.h };
  };

  const start = (piece: Piece) => (e: ReactPointerEvent<HTMLDivElement>) => {
    if (e.button !== 0) return;
    e.preventDefault();
    const el = e.currentTarget, r = stage.current!.getBoundingClientRect();
    const d = dims[piece], b0 = box(piece, posOf(piece));
    const grab = { x: e.clientX - r.left - b0.x, y: e.clientY - r.top - b0.y };
    el.setPointerCapture(e.pointerId);
    const roomX = Math.max(1, size.w - d.w), roomY = Math.max(1, size.h - d.h);
    const place = (ev: PointerEvent | ReactPointerEvent): Pos => {
      let x = Math.min(roomX, Math.max(0, ev.clientX - r.left - grab.x));
      let y = Math.min(roomY, Math.max(0, ev.clientY - r.top - grab.y));
      const guides: { v?: number; h?: number } = {};
      if (x < SNAP) { x = 0; guides.v = 0; } else if (roomX - x < SNAP) { x = roomX; guides.v = size.w; }
      else if (Math.abs(x + d.w / 2 - size.w / 2) < SNAP) { x = roomX / 2; guides.v = size.w / 2; }
      if (y < SNAP) { y = 0; guides.h = 0; } else if (roomY - y < SNAP) { y = roomY; guides.h = size.h; }
      else if (Math.abs(y + d.h / 2 - size.h / 2) < SNAP) { y = roomY / 2; guides.h = size.h / 2; }
      const pos = { x: Math.round((x / roomX) * 1000) / 1000, y: Math.round((y / roomY) * 1000) / 1000 };
      setDrag({ piece, pos, guides });
      return pos;
    };
    const move = (ev: PointerEvent) => place(ev);
    const up = (ev: PointerEvent) => {
      const pos = place(ev);
      savePrefs(piece === "dock" ? { dockPos: pos } : { notchPos: pos });
      setDrag(null);
      el.removeEventListener("pointermove", move); el.removeEventListener("pointerup", up); el.removeEventListener("pointercancel", up);
    };
    el.addEventListener("pointermove", move); el.addEventListener("pointerup", up); el.addEventListener("pointercancel", up);
  };

  const render = (piece: Piece) => {
    const p = posOf(piece), b = box(piece, p), dragging = drag?.piece === piece;
    return (
      <div key={piece} className={`pl-piece pl-${piece}${dragging ? " dragging" : ""}`}
        style={{ left: b.x, top: b.y, width: b.w, height: b.h, borderRadius: cornersAt(p, 12) }}
        onPointerDown={start(piece)} onDoubleClick={() => savePrefs(piece === "dock" ? { dockPos: DOCK_POS } : { notchPos: NOTCH_POS })}
        role="button" aria-label={piece === "dock" ? t("Requests") : t("Status notices")}>
        {piece === "dock"
          ? <><span className="pl-icon"><IconShieldLock size={14} /></span><span className="ellipsis">{t("{name} needs you", { name: "Claude Code" })}</span><span className="pl-btn">{t("Allow")}</span></>
          : <><span className="pl-rec" /><span className="ellipsis">{t("Recording")} 00:46 · Claude Code · {t("Drawing")}</span></>}
      </div>
    );
  };
  const moved = prefs.dockPos.x !== DOCK_POS.x || prefs.dockPos.y !== DOCK_POS.y || prefs.notchPos.x !== NOTCH_POS.x || prefs.notchPos.y !== NOTCH_POS.y;
  return (
    <div className="pl">
      <div className="pl-stage" ref={stage}>
        <div className="pl-desk"><MachineDesktop vm="estudio" locked bare /></div>
        {drag?.guides.v !== undefined && <span className="pl-guide v" style={{ left: drag.guides.v }} />}
        {drag?.guides.h !== undefined && <span className="pl-guide h" style={{ top: drag.guides.h }} />}
        {render("dock")}
        {prefs.statusPlacement !== "panel" && render("notch")}
      </div>
      {moved && (
        <div className="pl-foot">
          <button type="button" className="btn ghost compact" onClick={() => savePrefs({ dockPos: DOCK_POS, notchPos: NOTCH_POS })}><IconRestore size={15} />{t("Recommended places")}</button>
        </div>
      )}
    </div>
  );
}
