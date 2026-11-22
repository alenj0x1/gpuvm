import { useEffect, useState } from "react";
import { IconBulb } from "@tabler/icons-react";
import { t } from "./i18n";

/** Shortcuts and things worth knowing about GpuVM, for the waits (Home loading, a machine opening). Facts only: the
 *  figure is lab 020's (60 FPS adds a frame). */
function tips(): string[] {
  return [
    t("Ctrl+Alt+Shift+G opens the panel while you're on a machine."),
    t("Ctrl+Alt+Shift+A gives the machine back to the agent after you took control."),
    t("Ctrl+Alt+Shift+H takes you Home and the machine stays connected."),
    t("Ctrl+Alt+Shift+Z frees the mouse without leaving the machine."),
    t("Drag the panel's left edge to make it wider."),
    t("Drag machines in the sidebar to reorder them or move them to another space."),
    t("In Personalize you can add stickers, figures and an LED sign to each machine's cube."),
    t("In Overclock you can play as a team with your other machines."),
    t("A shared disk takes your Steam games from one machine to another without downloading them again."),
    t("At 120 FPS or more, the picture answers your keys about 5 ms sooner than at 60 FPS."),
  ];
}

/** One tip at a time, changing every few seconds with a soft fade. */
export function Tips({ className = "" }: { className?: string }) {
  const list = tips();
  const [i, setI] = useState(() => Math.floor(Math.random() * list.length));
  useEffect(() => {
    const timer = window.setInterval(() => setI((n) => (n + 1) % list.length), 6500);
    return () => window.clearInterval(timer);
  }, [list.length]);
  return (
    <p className={`tips ${className}`} aria-live="polite">
      <IconBulb size={15} />
      <span key={i}>{list[i % list.length]}</span>
    </p>
  );
}
