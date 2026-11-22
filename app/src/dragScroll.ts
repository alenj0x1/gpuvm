import { useCallback, useRef } from "react";

export function useDragScroll<T extends HTMLElement>() {
  const cleanup = useRef<(() => void) | null>(null);
  return useCallback((el: T | null) => {
    cleanup.current?.();
    cleanup.current = null;
    if (!el) return;
    let start: { x: number; left: number; id: number } | null = null, moved = false, vx = 0, lastX = 0, lastT = 0, glide = 0;
    const down = (e: PointerEvent) => {
      if (e.button !== 0 || e.pointerType === "touch" || el.scrollWidth <= el.clientWidth) return;
      if ((e.target as HTMLElement).closest("input, textarea, [role=slider], .home-split")) return;
      cancelAnimationFrame(glide);
      start = { x: e.clientX, left: el.scrollLeft, id: e.pointerId };
      moved = false; vx = 0; lastX = e.clientX; lastT = performance.now();
    };
    const move = (e: PointerEvent) => {
      if (!start || e.pointerId !== start.id) return;
      const dx = e.clientX - start.x;
      if (!moved && Math.abs(dx) < 5) return;
      if (!moved) { moved = true; el.setPointerCapture(e.pointerId); el.classList.add("drag-scrolling"); }
      el.scrollLeft = start.left - dx;
      const now = performance.now();
      vx = (e.clientX - lastX) / Math.max(1, now - lastT);
      lastX = e.clientX; lastT = now;
    };
    const up = (e: PointerEvent) => {
      if (!start || e.pointerId !== start.id) return;
      start = null;
      el.classList.remove("drag-scrolling");
      if (!moved) return;
      // The click that follows the release belongs to the drag, not to the card under the pointer.
      const stop = (ev: MouseEvent) => { ev.stopPropagation(); ev.preventDefault(); };
      el.addEventListener("click", stop, { capture: true, once: true });
      setTimeout(() => el.removeEventListener("click", stop, { capture: true }), 0);
      let v = -vx * 16;
      const step = () => { if (Math.abs(v) < 0.5) return; el.scrollLeft += v; v *= 0.92; glide = requestAnimationFrame(step); };
      glide = requestAnimationFrame(step);
    };
    el.addEventListener("pointerdown", down);
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
    el.addEventListener("pointercancel", up);
    cleanup.current = () => {
      cancelAnimationFrame(glide);
      el.removeEventListener("pointerdown", down);
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", up);
      el.removeEventListener("pointercancel", up);
    };
  }, []);
}
