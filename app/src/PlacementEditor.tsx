import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { IconShieldLock } from "@tabler/icons-react";
import { PixelScene } from "./PixelScene";
import { cornersFor, savePrefs, SPOTS, usePrefs, type Spot } from "./prefs";
import { Slider } from "./ui";
import { t } from "./i18n";

// Settings › Appearance: where requests (the dock) and status notices (the notch) go over a machine's picture
// (2026-11-21, asked by the person). A preview of a picture with its taskbar: both are dragged to one of six places,
// which show while dragging and pull the piece to the nearest (it snaps); the corners in the preview are the real ones
// (square on an edge it is attached to). The distance from the edge is a slider per piece.

/** The width of a typical viewer the preview stands for: distances are drawn to that scale. */
const VIEWER_W = 1600;
/** The machine's taskbar at the bottom of the picture, as a share of its height. */
const TASKBAR = 0.06;

type Piece = "dock" | "notch";

function spotBox(spot: Spot, W: number, H: number, w: number, h: number, gap: number, side: number) {
  const x = spot.endsWith("left") ? side : spot.endsWith("right") ? W - w - side : (W - w) / 2;
  const y = spot.startsWith("bottom") ? H - h - gap : gap;
  return { x, y };
}

export function PlacementEditor() {
  const prefs = usePrefs();
  const stage = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<{ piece: Piece; x: number; y: number; near: Spot } | null>(null);
  const [size, setSize] = useState({ w: 520, h: 325 });
  const notchSpot: Spot = prefs.statusPlacement === "panel" ? "bottom" : prefs.statusPlacement;
  const scale = size.w / VIEWER_W;
  const pieces: Record<Piece, { w: number; h: number; spot: Spot; gap: number }> = {
    dock: { w: Math.min(size.w * 0.62, 300), h: 40, spot: prefs.dockSpot, gap: prefs.dockGap },
    notch: { w: Math.min(size.w * 0.6, 270), h: 34, spot: notchSpot, gap: prefs.notchGap },
  };
  // The preview's real size (it follows the Settings card's width).
  useEffect(() => {
    const el = stage.current;
    if (!el) return;
    const fit = () => setSize((s) => (Math.abs(el.clientWidth - s.w) > 1 || Math.abs(el.clientHeight - s.h) > 1 ? { w: el.clientWidth, h: el.clientHeight } : s));
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const nearest = (piece: Piece, cx: number, cy: number): Spot => {
    const p = pieces[piece];
    let best: Spot = p.spot, d = Infinity;
    for (const s of SPOTS) {
      const b = spotBox(s, size.w, size.h, p.w, p.h, p.gap * scale, p.gap > 0 ? 8 : 0);
      const dd = Math.hypot(b.x + p.w / 2 - cx, b.y + p.h / 2 - cy);
      if (dd < d) { d = dd; best = s; }
    }
    return best;
  };
  const start = (piece: Piece) => (e: ReactPointerEvent<HTMLDivElement>) => {
    if (e.button !== 0) return;
    e.preventDefault();
    const el = e.currentTarget, r = stage.current!.getBoundingClientRect();
    el.setPointerCapture(e.pointerId);
    const at = (ev: PointerEvent | ReactPointerEvent) => {
      const x = Math.max(0, Math.min(size.w, ev.clientX - r.left)), y = Math.max(0, Math.min(size.h, ev.clientY - r.top));
      setDrag({ piece, x, y, near: nearest(piece, x, y) });
      return { x, y };
    };
    at(e);
    const move = (ev: PointerEvent) => at(ev);
    const up = (ev: PointerEvent) => {
      const { x, y } = at(ev);
      const spot = nearest(piece, x, y);
      savePrefs(piece === "dock" ? { dockSpot: spot } : { statusPlacement: spot });
      setDrag(null);
      el.removeEventListener("pointermove", move); el.removeEventListener("pointerup", up); el.removeEventListener("pointercancel", up);
    };
    el.addEventListener("pointermove", move); el.addEventListener("pointerup", up); el.addEventListener("pointercancel", up);
  };
  const render = (piece: Piece) => {
    const p = pieces[piece];
    const g = p.gap * scale, side = p.gap > 0 ? 8 : 0;
    const dragging = drag?.piece === piece;
    const pos = dragging ? { x: drag.x - p.w / 2, y: drag.y - p.h / 2 } : spotBox(p.spot, size.w, size.h, p.w, p.h, g, side);
    // Sitting where its gap leaves it, the notch steps out of the dock's way as in the viewer.
    let y = pos.y;
    if (!dragging && piece === "notch" && drag?.piece !== "dock") {
      const d = pieces.dock, db = spotBox(d.spot, size.w, size.h, d.w, d.h, d.gap * scale, d.gap > 0 ? 8 : 0);
      if (pos.x < db.x + d.w && db.x < pos.x + p.w && y < db.y + d.h && db.y < y + p.h) y = d.spot.startsWith("bottom") ? db.y - p.h - 4 : db.y + d.h + 4;
    }
    const radius = dragging ? "12px" : cornersFor(p.spot, p.gap, 12);
    return (
      <div key={piece} className={`pl-piece pl-${piece}${dragging ? " dragging" : ""}`} style={{ left: pos.x, top: y, width: p.w, height: p.h, borderRadius: radius }}
        onPointerDown={start(piece)} role="button" aria-label={piece === "dock" ? t("Requests") : t("Status notices")}>
        {piece === "dock"
          ? <><span className="pl-icon"><IconShieldLock size={14} /></span><span className="ellipsis">{t("{name} needs you", { name: "Claude Code" })}</span><span className="pl-btn">{t("Allow")}</span></>
          : <><span className="pl-rec" /><span className="ellipsis">{t("Recording")} 00:46 · Claude Code · {t("Drawing")}</span></>}
      </div>
    );
  };
  return (
    <div className="pl">
      <div className="pl-stage" ref={stage}>
        <PixelScene scene="forest" />
        <div className="pl-taskbar" style={{ height: `${TASKBAR * 100}%` }} />
        {drag && SPOTS.map((s) => {
          const p = pieces[drag.piece], b = spotBox(s, size.w, size.h, p.w, p.h, p.gap * scale, p.gap > 0 ? 8 : 0);
          return <span key={s} className={`pl-spot${drag.near === s ? " near" : ""}`} style={{ left: b.x, top: b.y, width: p.w, height: p.h, borderRadius: cornersFor(s, p.gap, 12) }} />;
        })}
        {render("dock")}
        {prefs.statusPlacement !== "panel" && render("notch")}
      </div>
      <div className="pl-controls">
        <div className="pl-control">
          <strong>{t("Distance of requests from the edge")}</strong>
          <Slider label={t("Distance of requests from the edge")} min={0} max={96} step={4} marks={[0, 32, 64, 96]} value={prefs.dockGap} format={(v) => (v === 0 ? t("Attached") : `${v} px`)} onChange={(dockGap) => savePrefs({ dockGap })} />
        </div>
        <div className="pl-control">
          <strong>{t("Distance of notices from the edge")}</strong>
          <Slider label={t("Distance of notices from the edge")} min={0} max={96} step={4} marks={[0, 32, 64, 96]} value={prefs.notchGap} format={(v) => (v === 0 ? t("Attached") : `${v} px`)} onChange={(notchGap) => savePrefs({ notchGap })} />
        </div>
      </div>
    </div>
  );
}
