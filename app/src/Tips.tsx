import { useEffect, useState } from "react";
import { IconBulb } from "@tabler/icons-react";
import { t } from "./i18n";

/** Shortcuts and things worth knowing about GpuVM, for the waits (Home loading, a machine opening). Facts only: the
 *  figure is lab 020's (60 FPS adds a frame). */
function tips(): string[] {
  return [
    t("Ctrl+Alt+Shift+G abre el panel mientras ves una máquina."),
    t("Ctrl+Alt+Shift+H te lleva a Inicio y la máquina sigue conectada."),
    t("Ctrl+Alt+Shift+Z suelta el mouse sin salir de la máquina."),
    t("El panel se ensancha arrastrando su borde izquierdo."),
    t("Arrastra las máquinas de la barra lateral para ordenarlas o pasarlas a otro espacio."),
    t("En Personalizar puedes poner stickers, figuras y un letrero LED en el cubo de cada máquina."),
    t("En Overclock puedes jugar en equipo con tus otras máquinas."),
    t("Un disco compartido lleva tus juegos de Steam de una máquina a otra sin descargarlos de nuevo."),
    t("A 120 FPS o más, la imagen responde a tus teclas unos 5 ms antes que a 60 FPS."),
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
