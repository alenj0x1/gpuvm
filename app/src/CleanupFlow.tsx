import { useEffect, useRef } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import {
  IconActivity, IconAd, IconCheck, IconPointFilled, IconBolt, IconBrandWindows, IconEyeOff, IconTrash, IconBrandBing, IconBrandOnedrive, IconBrandTeams, IconBug, IconCards, IconHistory, IconLayoutDashboard, IconMap,
  IconMovie, IconNews, IconPlayerPlay, IconPuzzle, IconSparkles, IconSpeakerphone, type Icon,
} from "@tabler/icons-react";
import { t } from "./i18n";

/** How each cleanup item looks: an icon and a color, a short name and one line that says what it is. Several pieces
 *  can stand for one item (the preinstalled apps). Items the UI doesn't know yet get a neutral piece. */
export const CLEANUP_LOOK: Record<string, { pieces: { icon: Icon; color: string }[]; readonly name: string; readonly line: string; readonly done: string }> = {
  "telemetry-minimum": { pieces: [{ icon: IconActivity, color: "#c2410c" }], get name() { return t("Diagnostic data"); }, get line() { return t("Windows sends usage data to Microsoft"); }, get done() { return t("Windows sends the minimum to Microsoft"); } },
  advertising: { pieces: [{ icon: IconAd, color: "#b45309" }], get name() { return t("Advertising ID"); }, get line() { return t("Ads built from your data"); }, get done() { return t("No ads built from your data"); } },
  "activity-history": { pieces: [{ icon: IconHistory, color: "#c2410c" }], get name() { return t("Activity history"); }, get line() { return t("Your activity is sent to the cloud"); }, get done() { return t("Your activity stays on the machine"); } },
  suggestions: { pieces: [{ icon: IconSpeakerphone, color: "#be185d" }], get name() { return t("Promoted apps"); }, get line() { return t("Suggestions and apps that install themselves"); }, get done() { return t("No suggestions or self-installing apps"); } },
  "web-search": { pieces: [{ icon: IconBrandBing, color: "#0e7490" }], get name() { return t("Bing in Start"); }, get line() { return t("Your PC searches go to the web"); }, get done() { return t("Your searches stay on the PC"); } },
  "copilot-recall": { pieces: [{ icon: IconSparkles, color: "#7c3aed" }], get name() { return t("Copilot and Recall"); }, get line() { return t("AI assistant and screenshots"); }, get done() { return t("No assistant or screenshots"); } },
  "store-apps": {
    pieces: [{ icon: IconNews, color: "#dc2626" }, { icon: IconCards, color: "#15803d" }, { icon: IconMovie, color: "#7e22ce" }, { icon: IconBrandTeams, color: "#4f46e5" }],
    get name() { return t("Preinstalled apps"); }, get line() { return t("News, Weather, Solitaire, Clipchamp, Teams…"); }, get done() { return t("Windows arrives without preinstalled apps"); },
  },
  onedrive: { pieces: [{ icon: IconBrandOnedrive, color: "#1d4ed8" }], get name() { return t("OneDrive"); }, get line() { return t("Installs and reinstalls itself"); }, get done() { return t("Removed, won't reinstall"); } },
  widgets: { pieces: [{ icon: IconLayoutDashboard, color: "#0369a1" }], get name() { return t("Widgets"); }, get line() { return t("News and interests on the taskbar"); }, get done() { return t("The taskbar stays clean"); } },
  "telemetry-services": { pieces: [{ icon: IconBug, color: "#c2410c" }], get name() { return t("Error reporting"); }, get line() { return t("Services that report to Microsoft"); }, get done() { return t("Errors aren't reported to Microsoft"); } },
  "unneeded-services": { pieces: [{ icon: IconMap, color: "#475569" }], get name() { return t("Unused services"); }, get line() { return t("Maps, location, fax, demo mode"); }, get done() { return t("Maps, location, fax and demo mode off"); } },
  "background-apps": { pieces: [{ icon: IconPlayerPlay, color: "#475569" }], get name() { return t("Background apps"); }, get line() { return t("Store apps always running"); }, get done() { return t("Store apps only run when you open them"); } },
};
const UNKNOWN = { icon: IconPuzzle, color: "#525252" };

/** Each cleanup level's icon and what it is about, in a few words. */
export const LEVEL_LOOK: Record<string, { icon: React.ReactNode; readonly tagline: string }> = {
  none: { icon: <IconBrandWindows size={18} />, get tagline() { return t("As it comes"); } },
  privacy: { icon: <IconEyeOff size={18} />, get tagline() { return t("Less data to Microsoft"); } },
  apps: { icon: <IconTrash size={18} />, get tagline() { return t("Removes the preinstalled"); } },
  minimal: { icon: <IconBolt size={18} />, get tagline() { return t("Only the essentials"); } },
};

interface Piece { item: string; color: string; image: HTMLImageElement }

/** The cleanup as a scene of chips, in the style of the machine banners: every piece is something Windows comes with
 *  (an app, a tracker, a service), flowing from the four sides toward Windows in the middle. What the chosen level
 *  removes fades out halfway and never arrives. `items` are all the cleanup items; `removed` the ids this level drops. */
export function CleanupFlow({ items, removed }: { items: string[]; removed: Set<string> }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const gone = useRef(removed);
  gone.current = removed;
  const key = items.join(",");

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    // Each piece's icon, drawn once into an image the canvas can paint.
    const pieces: Piece[] = items.flatMap((id) => (CLEANUP_LOOK[id]?.pieces ?? [UNKNOWN]).map((p) => {
      const image = new Image();
      image.src = `data:image/svg+xml;utf8,${encodeURIComponent(renderToStaticMarkup(<p.icon size={48} color="#ffffff" stroke={2} />))}`;
      return { item: id, color: p.color, image };
    }));
    if (!pieces.length) return;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    // Each icon recolored once per color (the accent can change while the dialog is open).
    const tintCache = new Map<string, HTMLCanvasElement>();
    const tinted = (piece: Piece, color: string) => {
      if (!piece.image.complete || !piece.image.naturalWidth) return null;
      const key = `${piece.image.src.length}:${piece.image.src.slice(-80)}:${color}`;
      let c = tintCache.get(key);
      if (!c) {
        c = document.createElement("canvas");
        c.width = c.height = 48;
        const t = c.getContext("2d")!;
        t.drawImage(piece.image, 0, 0, 48, 48);
        t.globalCompositeOperation = "source-in";
        t.fillStyle = color;
        t.fillRect(0, 0, 48, 48);
        tintCache.set(key, c);
      }
      return c;
    };
    const noise = (a: number, b: number) => Math.abs(Math.sin(a * 12.9898 + b * 78.233) * 43758.5453) % 1;
    let frame = 0;
    const start = performance.now();
    // How much each piece is faded: it eases toward its target, so a level change never jumps.
    const fade = new Map<string, number>();

    const draw = (now: number) => {
      const t = reduced ? 3 : (now - start) / 1000;
      const w = canvas.clientWidth, h = canvas.clientHeight, d = window.devicePixelRatio || 1;
      if (w && h) {
        if (canvas.width !== Math.round(w * d) || canvas.height !== Math.round(h * d)) { canvas.width = Math.round(w * d); canvas.height = Math.round(h * d); }
        const g = canvas.getContext("2d")!;
        g.setTransform(d, 0, 0, d, 0, 0);
        g.clearRect(0, 0, w, h);
        const css = getComputedStyle(canvas);
        const ink = css.getPropertyValue("--text").trim() || "#ebe8e1";
        const surface = css.getPropertyValue("--surface-2").trim() || "#1f1f1f";
        // Only the app's own colors: pieces in its dark gray, their icons in the accent.
        const accent = css.getPropertyValue("--accent").trim() || "#7d9cf0";
        const pieceBg = css.getPropertyValue("--pick-bg").trim() || "#262626";
        // Three lanes per side, each lined up with a row or column of Windows in the middle, so no lane crosses another.
        const cx = w / 2, cy = h / 2, s = 22, gap = 3, core = 3 * s + 2 * gap;
        const lanes: [string, number][] = [];
        for (let i = -1; i <= 1; i++) for (const side of ["L", "R", "T", "B"]) lanes.push([side, (side === "L" || side === "R" ? cy : cx) + i * (s + gap) - s / 2]);
        lanes.forEach(([side, pos], li) => {
          const len = (side === "L" || side === "R" ? cx : cy) - core / 2 - gap;
          const speed = 16 + (li % 4) * 4;
          // As many pieces as fit the lane, evenly spaced around one loop: a short lane (top and bottom) never
          // wraps two pieces onto the same spot.
          const count = Math.max(1, Math.floor((len + s) / (s + gap)));
          const loop = count * (s + gap);
          for (let k = 0; k < count; k++) {
            const travelled = (t * speed + k * (s + gap)) % loop;
            const progress = travelled / len;
            if (progress > 1) continue;
            const v = noise(li, k);
            const piece = v < 0.45 ? pieces[Math.floor((v / 0.45) * pieces.length)] : null;
            let x: number, y: number;
            if (side === "L") { x = travelled - s; y = pos; } else if (side === "R") { x = w - travelled; y = pos; }
            else if (side === "T") { x = pos; y = travelled - s; } else { x = pos; y = h - travelled; }
            g.beginPath();
            g.roundRect(x, y, s, s, 5);
            if (!piece) { g.globalAlpha = 0.06; g.fillStyle = ink; g.fill(); continue; }
            // A removed piece fades between a third and half of the way: it never reaches Windows.
            const target = gone.current.has(piece.item) ? 1 : 0;
            const f = fade.get(piece.item) ?? target;
            const eased = f + (target - f) * 0.08;
            fade.set(piece.item, eased);
            const alpha = 1 - eased * Math.min(1, Math.max(0, (progress - 0.3) / 0.2));
            if (alpha <= 0.01) continue;
            g.globalAlpha = alpha;
            g.fillStyle = pieceBg;
            g.fill();
            const icon = tinted(piece, accent);
            if (icon) g.drawImage(icon, x + 4, y + 4, s - 8, s - 8);
          }
        });
        // Windows in the middle: the four squares of its logo.
        g.globalAlpha = 1;
        g.beginPath();
        g.roundRect(cx - core / 2, cy - core / 2, core, core, 14);
        g.fillStyle = surface;
        g.fill();
        g.strokeStyle = ink;
        g.globalAlpha = 0.18;
        g.stroke();
        g.globalAlpha = 1;
        g.fillStyle = accent;
        for (const [a, b] of [[-17, -17], [2, -17], [-17, 2], [2, 2]]) { g.beginPath(); g.roundRect(cx + a, cy + b, 15, 15, 3); g.fill(); }
      }
      if (!reduced) frame = requestAnimationFrame(draw);
    };
    frame = requestAnimationFrame(draw);
    const visibility = () => { cancelAnimationFrame(frame); if (!document.hidden) frame = requestAnimationFrame(draw); };
    document.addEventListener("visibilitychange", visibility);
    return () => { cancelAnimationFrame(frame); document.removeEventListener("visibilitychange", visibility); };
  }, [key]);

  return <canvas ref={ref} className="cleanup-flow" aria-hidden="true" />;
}

/** Everything Windows comes with that a cleanup level can take away, the same list wherever a level is chosen.
 *  What stays is marked in amber and says what it does now; what the level removes is marked in green and says how
 *  Windows ends up without it. */
export function CleanupItems({ items, removed }: { items: { id: string; description: string }[]; removed: Set<string> }) {
  return (
    <ul className="cleanup-items">
      {items.map((i) => {
        const drop = removed.has(i.id);
        const look = CLEANUP_LOOK[i.id];
        return (
          <li key={i.id} className={drop ? "drop" : "keep"} title={i.description}>
            {drop ? <IconCheck size={14} /> : <IconPointFilled size={14} />}
            <span><span className="ci-name">{look?.name ?? i.description}</span>{look && <span className="ci-line">{drop ? look.done : look.line}</span>}</span>
          </li>
        );
      })}
    </ul>
  );
}
