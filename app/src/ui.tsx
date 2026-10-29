import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent, type PointerEvent, type ReactNode } from "react";
import { IconAlertTriangle, IconCircleCheck, IconCircleX, IconX } from "@tabler/icons-react";

interface SliderProps {
  value: number;
  min: number;
  max: number;
  step?: number;
  onChange: (v: number) => void;
  label: string;
}

/** Custom slider (no native input) with keyboard and drag support. */
export function Slider({ value, min, max, step = 1, onChange, label }: SliderProps) {
  const ref = useRef<HTMLDivElement>(null);
  const pct = ((value - min) / (max - min)) * 100;
  const setFromPointer = (clientX: number) => {
    const rect = ref.current!.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    onChange(Math.round((min + ratio * (max - min)) / step) * step);
  };
  const onDown = (e: PointerEvent<HTMLDivElement>) => {
    e.currentTarget.setPointerCapture(e.pointerId);
    setFromPointer(e.clientX);
  };
  const onMove = (e: PointerEvent<HTMLDivElement>) => {
    if (e.currentTarget.hasPointerCapture(e.pointerId)) setFromPointer(e.clientX);
  };
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.key === "ArrowRight" || e.key === "ArrowUp") onChange(Math.min(max, value + step));
    else if (e.key === "ArrowLeft" || e.key === "ArrowDown") onChange(Math.max(min, value - step));
    else return;
    e.preventDefault();
  };
  return (
    <div ref={ref} className="slider" role="slider" tabIndex={0} aria-label={label} aria-valuemin={min}
      aria-valuemax={max} aria-valuenow={value} onPointerDown={onDown} onPointerMove={onMove} onKeyDown={onKey}>
      <div className="track" />
      <div className="fill" style={{ width: `${pct}%` }} />
      <div className="thumb" style={{ left: `${pct}%` }} />
    </div>
  );
}

interface SegmentedProps<T extends string | number | boolean> {
  value: T;
  options: { value: T; label: ReactNode }[];
  onChange: (v: T) => void;
}

export function Segmented<T extends string | number | boolean>({ value, options, onChange }: SegmentedProps<T>) {
  return (
    <div className="segmented" role="radiogroup">
      {options.map((o) => (
        <button key={String(o.value)} role="radio" aria-checked={o.value === value} className={o.value === value ? "on" : ""}
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
