import { flushSync } from "react-dom";
import { moveToSpace, spaceOf } from "./spaces";

/** What a dragged machine carries: its name. Machines are dragged from the sidebar or from Home's cards and dropped on
 *  a space (its group in the sidebar or its tab in Home). */
export const MACHINE_DND = "application/x-gpuvm-machine";
/** What a dragged space carries: its id. Spaces are reordered by dragging their name in the sidebar. */
export const SPACE_DND = "application/x-gpuvm-space";

/** The machine or space being dragged right now (dataTransfer can't be read until the drop). */
export const dragging: { machine: string | null; space: string | null } = { machine: null, space: null };
const finishers = new Set<() => void>();
/** Called once a drag is over, however it ended (dropped anywhere, or cancelled). */
export function onDragFinish(fn: () => void) { finishers.add(fn); return () => { finishers.delete(fn); }; }

function startDrag(e: React.DragEvent, type: string, value: string) {
  e.dataTransfer.setData(type, value);
  e.dataTransfer.effectAllowed = "move";
  // The mark comes off however the drag ends: the dragged row may be gone after the drop (it moved to another group),
  // so its own dragend can't be relied on. The finishers run after the drop handlers, which commit what was dropped.
  document.documentElement.classList.add("dragging-machine");
  const end = () => {
    document.documentElement.classList.remove("dragging-machine");
    for (const t of ["dragend", "drop", "pointermove"]) window.removeEventListener(t, end, true);
    setTimeout(() => { dragging.machine = null; dragging.space = null; finishers.forEach((f) => f()); });
  };
  for (const t of ["dragend", "drop", "pointermove"]) window.addEventListener(t, end, true);
}
export function dragMachine(e: React.DragEvent, name: string) { dragging.machine = name; startDrag(e, MACHINE_DND, name); }
export function dragSpace(e: React.DragEvent, id: string) { dragging.space = id; startDrag(e, SPACE_DND, id); }
export const carriesMachine = (e: React.DragEvent | DragEvent) => !!e.dataTransfer?.types.includes(MACHINE_DND);
export const carriesSpace = (e: React.DragEvent | DragEvent) => !!e.dataTransfer?.types.includes(SPACE_DND);

/** Runs a change of the sidebar's order and lets every row (machines and space names) glide from where it was to where
 *  it is now. `lift` is the machine that is travelling: it goes over the others. */
export function glide(change: () => void, lift?: string) {
  const rows = () => [...document.querySelectorAll<HTMLElement>(".side-list [data-vm], .side-list [data-space-row]")];
  const key = (el: HTMLElement) => (el.dataset.vm ? `vm:${el.dataset.vm}` : `sp:${el.dataset.spaceRow}`);
  const was = new Map(rows().map((el) => [key(el), el.getBoundingClientRect()]));
  // Drawn again right away, so the new places can be measured before anything is painted there.
  flushSync(change);
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  for (const el of rows()) {
    const old = was.get(key(el)), now = el.getBoundingClientRect();
    if (!old) continue;
    const dx = old.left - now.left, dy = old.top - now.top;
    if (Math.abs(dx) < 1 && Math.abs(dy) < 1) continue;
    const lifted = el.dataset.vm === lift;
    el.animate([{ transform: `translate(${dx}px, ${dy}px)`, zIndex: lifted ? 2 : 1 }, { transform: "none", zIndex: lifted ? 2 : 1 }],
      { duration: 260, easing: "cubic-bezier(0.3, 0.8, 0.3, 1)" });
  }
}

/** A neutral flash where a machine lands, so the move is seen (never the accent: it is not a selection). */
export function flashMachine(name: string) {
  const el = document.querySelector<HTMLElement>(`.side-list [data-vm="${CSS.escape(name)}"]`);
  el?.animate([{ background: "var(--hover)" }, { background: "var(--hover)", offset: 0.6 }, { background: "transparent" }], { duration: 900, easing: "ease-out" });
}

/** Moves the machine to the space (at the end, or before another machine of it), gliding the sidebar to the new order.
 *  `shown` is the space's machines as they are shown. */
export function moveMachine(name: string, spaceId: string, before?: string | null, shown?: string[]) {
  if (before === name) return;
  if (spaceOf(name).id === spaceId && before === undefined) return;
  glide(() => moveToSpace(name, spaceId, before, shown), name);
  flashMachine(name);
}
