import { IconDeviceDesktop, IconLayoutBottombarCollapse, IconMoon, IconPower, IconSun } from "@tabler/icons-react";
import { savePrefs, usePrefs, type ClosePref, type ThemePref } from "./prefs";
import { Segmented } from "./ui";

export function Preferences() {
  const prefs = usePrefs();
  return (
    <div className="main">
      <div className="card">
        <h2 className="section-title">Preferencias</h2>
        <div className="pref-list">
          <div className="pref-row">
            <div className="pref-text"><strong>Tema</strong></div>
            <Segmented<ThemePref> value={prefs.theme} onChange={(theme) => savePrefs({ theme })} options={[
              { value: "system", label: <><IconDeviceDesktop size={15} />Sistema</> },
              { value: "light", label: <><IconSun size={15} />Claro</> },
              { value: "dark", label: <><IconMoon size={15} />Oscuro</> },
            ]} />
          </div>
          <div className="pref-row">
            <div className="pref-text"><strong>Al cerrar la ventana</strong><span>En la bandeja, GpuVM sigue abierta junto al reloj y los trabajos en curso continúan.</span></div>
            <Segmented<ClosePref> value={prefs.close} onChange={(close) => savePrefs({ close })} options={[
              { value: "quit", label: <><IconPower size={15} />Salir por completo</> },
              { value: "tray", label: <><IconLayoutBottombarCollapse size={15} />Quedarse en la bandeja</> },
            ]} />
          </div>
        </div>
      </div>
    </div>
  );
}
