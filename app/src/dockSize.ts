import { useLayoutEffect, type RefObject } from "react";
import { inTauri } from "./api";

export function useReportDockSize(ref: RefObject<HTMLElement | null>, on: boolean) {
  useLayoutEffect(() => {
    const el = ref.current;
    if (!inTauri || !el || !on) return;
    const send = () => import("@tauri-apps/api/event").then(({ emit }) => emit("dock-size", { width: el.offsetWidth, height: el.offsetHeight })).catch(() => {});
    send();
    const ro = new ResizeObserver(send);
    ro.observe(el);
    return () => ro.disconnect();
  }, [ref, on]);
}
