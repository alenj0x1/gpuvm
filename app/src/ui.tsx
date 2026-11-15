import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent, type PointerEvent, type ReactNode } from "react";
import { IconAlertTriangle, IconCheck, IconChevronDown, IconCircleCheck, IconCircleX, IconX } from "@tabler/icons-react";
import { createPortal } from "react-dom";

interface SliderProps {
  value: number;
  min: number;
  max: number;
  step?: number;
  onChange: (v: number) => void;
  label: string;
  /** How a scale number is written (e.g. 0 as "Auto"). */
  format?: (v: number) => string;
  /** The numbers written under it, when the automatic ones don't fit the quantity (degrees: every 90). */
  marks?: number[];
}

/** Scale numbers under a slider: about seven, on round values that are multiples of the step, always with both ends. */
function scaleMarks(min: number, max: number, step: number) {
  const range = max - min;
  if (range <= 0) return [min];
  const rough = range / 7;
  const pow = 10 ** Math.floor(Math.log10(rough));
  const nice = [1, 2, 2.5, 5, 10].map((f) => f * pow).find((n) => n >= rough) ?? rough;
  const every = Math.max(step, Math.ceil(nice / step) * step);
  const marks = [min];
  for (let v = Math.ceil((min + 1e-9) / every) * every; v < max; v += every) {
    // Keeps the numbers apart from the ends.
    if (v - min > every * 0.75 && max - v > every * 0.75) marks.push(v);
  }
  marks.push(max);
  return marks;
}

/** Custom slider (no native input): a bar with its scale written underneath, so it says how much each position is.
 *  Drag or click anywhere, arrows and the mouse wheel move one step. */
export function Slider({ value, min, max, step = 1, onChange, label, format = String, marks }: SliderProps) {
  const ref = useRef<HTMLDivElement>(null);
  const clamp = (v: number) => Math.min(max, Math.max(min, v));
  const pct = max > min ? ((clamp(value) - min) / (max - min)) * 100 : 100;
  const [dragging, setDragging] = useState(false);
  const latest = useRef({ value, onChange });
  latest.current = { value, onChange };

  const setFromPointer = (clientX: number) => {
    const rect = ref.current!.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    onChange(clamp(min + Math.round((ratio * (max - min)) / step) * step));
  };
  const onDown = (e: PointerEvent<HTMLDivElement>) => {
    e.currentTarget.setPointerCapture(e.pointerId);
    setDragging(true);
    setFromPointer(e.clientX);
  };
  const onMove = (e: PointerEvent<HTMLDivElement>) => {
    if (e.currentTarget.hasPointerCapture(e.pointerId)) setFromPointer(e.clientX);
  };
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.key === "ArrowRight" || e.key === "ArrowUp") onChange(clamp(value + step));
    else if (e.key === "ArrowLeft" || e.key === "ArrowDown") onChange(clamp(value - step));
    else if (e.key === "Home") onChange(min);
    else if (e.key === "End") onChange(max);
    else return;
    e.preventDefault();
  };
  // The wheel moves one step at a time (fine adjustment); React's wheel handler is passive, so it is attached here.
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const wheel = (e: WheelEvent) => {
      e.preventDefault();
      const { value: v, onChange: change } = latest.current;
      change(Math.min(max, Math.max(min, v + (e.deltaY < 0 ? step : -step))));
    };
    el.addEventListener("wheel", wheel, { passive: false });
    return () => el.removeEventListener("wheel", wheel);
  }, [min, max, step]);

  return (
    <div ref={ref} className={`slider${dragging ? " dragging" : ""}`} role="slider" tabIndex={0} aria-label={label} aria-valuemin={min}
      aria-valuemax={max} aria-valuenow={value} onPointerDown={onDown} onPointerMove={onMove}
      onPointerUp={() => setDragging(false)} onPointerCancel={() => setDragging(false)} onKeyDown={onKey}>
      <div className="track" />
      <div className="fill" style={{ width: `${pct}%` }} />
      <div className="thumb" style={{ left: `${pct}%` }} />
      <div className="scale" aria-hidden="true">
        {(marks ?? scaleMarks(min, max, step)).map((m, i, all) => (
          <span key={m} className={i === 0 ? "first" : i === all.length - 1 ? "last" : ""} style={{ left: `${((m - min) / (max - min || 1)) * 100}%` }}>{format(m)}</span>
        ))}
      </div>
    </div>
  );
}

export interface DropdownOption<T extends string> {
  value: T;
  label: string;
  detail?: string;
  icon?: ReactNode;
  /** Colors the icon to tell groups apart: recommended, fine, or with a drawback. */
  tone?: "accent" | "ok" | "warn";
}

/** The app's own drop-down list (never the system one): the chosen option with its detail, and a floating list with
 *  every option. Closes on any press outside it, Escape, or a choice; arrows move through the list. */
export function Dropdown<T extends string>({ value, options, onChange, label }: {
  value: T; options: DropdownOption<T>[]; onChange: (v: T) => void; label: string;
}) {
  const [open, setOpen] = useState<{ x: number; y: number; width: number; room: number } | null>(null);
  const [active, setActive] = useState(0);
  const button = useRef<HTMLButtonElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const chosen = options.find((o) => o.value === value) ?? options[0];
  const withIcons = options.some((o) => o.icon);

  const show = () => {
    const r = button.current!.getBoundingClientRect();
    // Opens upward when there is no room below.
    const need = options.length * 48 + 12;
    const roomBelow = window.innerHeight - r.bottom - 18, roomAbove = r.top - 18 - 32;
    const below = roomBelow >= need || roomBelow >= roomAbove;
    setOpen({ x: r.left, y: below ? r.bottom + 6 : -(window.innerHeight - r.top + 6), width: r.width, room: below ? roomBelow : roomAbove });
    setActive(Math.max(0, options.findIndex((o) => o.value === value)));
  };
  useEffect(() => {
    if (!open) return;
    const outside = (e: Event) => {
      const t = e.target as Node;
      if (!list.current?.contains(t) && !button.current?.contains(t)) setOpen(null);
    };
    const close = () => setOpen(null);
    window.addEventListener("pointerdown", outside, true);
    window.addEventListener("resize", close);
    window.addEventListener("scroll", close, true);
    return () => {
      window.removeEventListener("pointerdown", outside, true);
      window.removeEventListener("resize", close);
      window.removeEventListener("scroll", close, true);
    };
  }, [open]);
  const pick = (v: T) => { onChange(v); setOpen(null); button.current?.focus(); };
  const onKey = (e: KeyboardEvent) => {
    if (!open) {
      if (e.key === "ArrowDown" || e.key === "Enter" || e.key === " ") { e.preventDefault(); show(); }
      return;
    }
    if (e.key === "Escape") setOpen(null);
    else if (e.key === "ArrowDown") setActive((a) => Math.min(options.length - 1, a + 1));
    else if (e.key === "ArrowUp") setActive((a) => Math.max(0, a - 1));
    else if (e.key === "Enter" || e.key === " ") pick(options[active].value);
    else return;
    e.preventDefault();
  };

  return (
    <>
      <button ref={button} type="button" className={`dropdown${open ? " open" : ""}`} aria-haspopup="listbox" aria-expanded={!!open} aria-label={label}
        onClick={() => (open ? setOpen(null) : show())} onKeyDown={onKey}>
        {chosen?.icon && <span className={`dropdown-icon${chosen.tone ? ` tone-${chosen.tone}` : ""}`}>{chosen.icon}</span>}
        <span className="dropdown-text">
          <span className="dropdown-label">{chosen?.label}</span>
          {chosen?.detail && <span className="dropdown-detail">{chosen.detail}</span>}
        </span>
        <IconChevronDown size={16} className="dropdown-chevron" />
      </button>
      {open && createPortal(
        <div ref={list} className="dropdown-list" role="listbox" aria-label={label}
          style={{ left: open.x, width: Math.max(open.width, 260), maxHeight: open.room, ...(open.y >= 0 ? { top: open.y } : { bottom: -open.y }) }}>
          {options.map((o, i) => (
            <button type="button" role="option" key={o.value} aria-selected={o.value === value}
              className={`${o.value === value ? "on" : ""}${i === active ? " active" : ""}`}
              onMouseEnter={() => setActive(i)} onClick={() => pick(o.value)}>
              {/* Options without an icon keep its room, so every name starts at the same place. */}
              {withIcons && <span className={`dropdown-icon${o.tone ? ` tone-${o.tone}` : ""}`}>{o.icon}</span>}
              <span className="dropdown-text">
                <span className="dropdown-label">{o.label}</span>
                {o.detail && <span className="dropdown-detail">{o.detail}</span>}
              </span>
              {o.value === value && <IconCheck size={16} className="dropdown-check" />}
            </button>
          ))}
        </div>,
        document.body,
      )}
    </>
  );
}

interface SegmentedProps<T extends string | number | boolean> {
  value: T;
  options: { value: T; label: ReactNode }[];
  onChange: (v: T) => void;
}

/** Options side by side. The chosen one is a darker pill that slides to the new choice (no jump); it only animates
 *  when the choice changes, never on the first paint. */
export function Segmented<T extends string | number | boolean>({ value, options, onChange }: SegmentedProps<T>) {
  const ref = useRef<HTMLDivElement>(null);
  const [pill, setPill] = useState<{ left: number; top: number; width: number; height: number } | null>(null);
  const [animate, setAnimate] = useState(false);
  const index = options.findIndex((o) => o.value === value);
  useLayoutEffect(() => {
    const place = () => {
      const el = ref.current?.children[index + 1] as HTMLElement | undefined;
      setPill(el ? { left: el.offsetLeft, top: el.offsetTop, width: el.offsetWidth, height: el.offsetHeight } : null);
    };
    place();
    const resize = new ResizeObserver(place);
    if (ref.current) resize.observe(ref.current);
    return () => resize.disconnect();
  }, [index, options.length]);
  useEffect(() => { const t = requestAnimationFrame(() => setAnimate(true)); return () => cancelAnimationFrame(t); }, []);
  return (
    <div ref={ref} className="segmented" role="radiogroup">
      <span className={`segmented-pill${animate ? " animate" : ""}`} aria-hidden="true"
        style={pill ? { left: pill.left, top: pill.top, width: pill.width, height: pill.height } : { opacity: 0 }} />
      {options.map((o) => (
        // type="button": inside a form (Crear máquina, profiles) a plain button would submit it.
        <button type="button" key={String(o.value)} role="radio" aria-checked={o.value === value} className={o.value === value ? "on" : ""}
          onClick={() => onChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

export interface Toast {
  id: number;
  kind: "error" | "warning" | "ok";
  text: string;
}

export function useToasts() {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const push = useCallback((kind: Toast["kind"], text: string) => {
    const id = Date.now() + Math.random();
    setToasts((t) => [...t.filter((x) => x.text !== text), { id, kind, text }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), kind === "error" ? 9000 : 5000);
  }, []);
  const dismiss = useCallback((id: number) => setToasts((t) => t.filter((x) => x.id !== id)), []);
  return { toasts, push, dismiss };
}

export function Toasts({ toasts, dismiss }: { toasts: Toast[]; dismiss: (id: number) => void }) {
  return (
    <div className="toasts" aria-live="polite">
      {toasts.map((t) => (
        <div key={t.id} className={`toast ${t.kind}`}>
          {t.kind === "error" ? <IconCircleX size={18} /> : t.kind === "warning" ? <IconAlertTriangle size={18} /> : <IconCircleCheck size={18} />}
          <span style={{ flex: 1, lineHeight: 1.45 }}>{t.text}</span>
          <button className="icon-btn" style={{ width: 24, height: 24 }} aria-label="Cerrar" onClick={() => dismiss(t.id)}><IconX size={14} /></button>
        </div>
      ))}
    </div>
  );
}

/** Check mark for the custom checkboxes; the same in every dialog. */
export function CheckMark() {
  return <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><path d="M2 5.2 4.2 7.4 8 3" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" /></svg>;
}

/** Strips technical prefixes from PowerShell/Tauri errors. */
export function humanError(e: unknown) {
  return String(e).replace(/^(Error|Exception|RuntimeException):\s*/i, "").trim();
}

export function formatUptime(seconds: number) {
  if (seconds <= 0) return "—";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h === 0) return `${m} min`;
  if (h < 24) return `${h} h ${m} min`;
  return `${Math.floor(h / 24)} d ${h % 24} h`;
}

export const stateLabel: Record<string, string> = {
  Running: "Encendida",
  Off: "Apagada",
  Paused: "En pausa",
  Saved: "Guardada",
  Starting: "Encendiendo",
  Stopping: "Apagando",
  Saving: "Guardando estado",
  Pausing: "Pausando",
  Resuming: "Reanudando",
};

/** For a box that scrolls: "fade-start" / "fade-end" while there is hidden content on that side, so the edge fades. */
export function useScrollFade<T extends HTMLElement>(axis: "x" | "y" = "y") {
  // A callback ref: the box can appear later or be replaced (a dialog's form after its progress log, tabs that
  // come back after a search), and the listeners must follow the element that is there now.
  const [el, setEl] = useState<T | null>(null);
  const [fade, setFade] = useState("");
  const measure = useCallback(() => {
    if (!el) { setFade(""); return; }
    const [pos, size, total] = axis === "y" ? [el.scrollTop, el.clientHeight, el.scrollHeight] : [el.scrollLeft, el.clientWidth, el.scrollWidth];
    const next = `${pos > 2 ? "fade-start" : ""} ${pos + size < total - 2 ? "fade-end" : ""}`.trim();
    setFade((prev) => (prev === next ? prev : next));
  }, [el, axis]);
  // Content changes (a search, a new section) change what is hidden: measure after every render.
  useLayoutEffect(measure);
  useEffect(() => {
    if (!el) return;
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    el.addEventListener("scroll", measure, { passive: true });
    return () => { observer.disconnect(); el.removeEventListener("scroll", measure); };
  }, [el, measure]);
  return [setEl, fade] as const;
}

// Where dialogs opened through a portal go: the app's own root, so they keep its styles (set by the website demo,
// whose app lives in a shadow root the document can't query).
let portalHost: Element | null = null;
export const setPortalRoot = (el: Element | null) => { portalHost = el; };
export const portalRoot = () => portalHost ?? document.querySelector(".app") ?? document.body;

/** Children of the returned element glide to their new places instead of jumping, when the window or the container
 *  changes size or a child comes or goes (a notice that disappears, a card added). New children fade in. Positions are
 *  taken relative to the container, so scrolling never counts as a move. */
export function useFlip<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const where = (c: Element) => { const a = c.getBoundingClientRect(), b = el.getBoundingClientRect(); return { x: a.left - b.left, y: a.top - b.top }; };
    let last = new Map<Element, { x: number; y: number }>();
    const snap = () => { last = new Map([...el.children].map((c) => [c, where(c)])); };
    const play = () => {
      if (el.closest('[class*="dragging-"]')) { snap(); return; }
      for (const c of el.children) {
        const before = last.get(c), now = where(c);
        if (!before) { c.animate([{ opacity: 0, transform: "scale(0.98)" }, { opacity: 1, transform: "none" }], { duration: 260, easing: "cubic-bezier(0.3, 0.8, 0.3, 1)" }); continue; }
        const dx = before.x - now.x, dy = before.y - now.y;
        if (Math.abs(dx) > 1 || Math.abs(dy) > 1) c.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "none" }], { duration: 340, easing: "cubic-bezier(0.3, 0.8, 0.3, 1)" });
      }
      snap();
    };
    snap();
    const ro = new ResizeObserver(play);
    ro.observe(el);
    const mo = new MutationObserver(() => requestAnimationFrame(play));
    mo.observe(el, { childList: true });
    return () => { ro.disconnect(); mo.disconnect(); };
  }, []);
  return ref;
}
