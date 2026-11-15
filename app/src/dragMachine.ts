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

/** Moves the machine to the space and lets every machine in the sidebar glide to its new place; the one moved lands
 *  with a short flash, so the move is seen. */
export function moveMachine(name: string, spaceId: string) {
  if (spaceOf(name).id === spaceId) return;
  const rows = () => [...document.querySelectorAll<HTMLElement>("[data-vm]")];
  const before = new Map(rows().map((el) => [el.dataset.vm!, el.getBoundingClientRect()]));
  moveToSpace(name, spaceId);
  requestAnimationFrame(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    for (const el of rows()) {
      const old = before.get(el.dataset.vm!), now = el.getBoundingClientRect();
      if (!old) continue;
      const dx = old.left - now.left, dy = old.top - now.top;
      if (Math.abs(dx) > 1 || Math.abs(dy) > 1) el.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "none" }], { duration: 380, easing: "cubic-bezier(0.3, 0.8, 0.3, 1)" });
      if (el.dataset.vm === name) el.animate([{ background: "var(--sel)" }, { background: "var(--sel)", offset: 0.6 }, { background: "transparent" }], { duration: 900, easing: "ease-out" });
    }
  });
}
