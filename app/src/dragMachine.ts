import { flushSync } from "react-dom";
import { moveToSpace, spaceOf } from "./spaces";

/** What a dragged machine carries: its name. Machines are dragged from the sidebar or from Home's cards and dropped on
 *  a space (its name in the sidebar or its tab in Home). */
export const MACHINE_DND = "application/x-gpuvm-machine";

export function dragMachine(e: React.DragEvent, name: string) {
  e.dataTransfer.setData(MACHINE_DND, name);
  e.dataTransfer.effectAllowed = "move";
  // The mark comes off however the drag ends: the dragged row may be gone after the drop (it moved to another group),
  // so its own dragend can't be relied on.
  document.documentElement.classList.add("dragging-machine");
  const end = () => {
    document.documentElement.classList.remove("dragging-machine");
    for (const t of ["dragend", "drop", "pointermove"]) window.removeEventListener(t, end, true);
  };
  for (const t of ["dragend", "drop", "pointermove"]) window.addEventListener(t, end, true);
}
export const carriesMachine = (e: React.DragEvent | DragEvent) => !!e.dataTransfer?.types.includes(MACHINE_DND);

/** Moves the machine to the space (at the end, or before another machine of it) and lets every machine in the sidebar
 *  glide to its new place; the one moved lands with a short neutral flash, so the move is seen. */
export function moveMachine(name: string, spaceId: string, before?: string | null, shown?: string[]) {
  if (before === name) return;
  if (spaceOf(name).id === spaceId) {
    // Within its own space only a change of place counts.
    const order = shown ?? [];
    const now = order.indexOf(name), next = before ? order.indexOf(before) : order.length;
    if (before === undefined || next === now + 1 || (next === order.length && now === order.length - 1)) return;
  }
  const rows = () => [...document.querySelectorAll<HTMLElement>("[data-vm]")];
  const was = new Map(rows().map((el) => [el.dataset.vm!, el.getBoundingClientRect()]));
  // The sidebar is drawn again right away, so the new places can be measured before anything is painted there.
  flushSync(() => moveToSpace(name, spaceId, before, shown));
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  for (const el of rows()) {
    const old = was.get(el.dataset.vm!), now = el.getBoundingClientRect();
    if (!old) continue;
    const dx = old.left - now.left, dy = old.top - now.top;
    const moved = el.dataset.vm === name;
    if (Math.abs(dx) > 1 || Math.abs(dy) > 1) {
      // The machine that changes space travels on top of the others, lifted a little; the rest make room.
      el.animate(moved
        ? [{ transform: `translate(${dx}px, ${dy}px) scale(1)`, zIndex: 2 }, { transform: `translate(${dx * 0.5}px, ${dy * 0.5}px) scale(1.04)`, zIndex: 2 }, { transform: "none", zIndex: 2 }]
        : [{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "none" }],
        { duration: moved ? 520 : 380, easing: "cubic-bezier(0.3, 0.8, 0.3, 1)" });
    }
    // A neutral flash where it lands, so the move is seen (never the accent: it is not a selection).
    if (moved) el.animate([{ background: "var(--hover)" }, { background: "var(--hover)", offset: 0.6 }, { background: "transparent" }], { duration: 900, easing: "ease-out" });
  }
}
