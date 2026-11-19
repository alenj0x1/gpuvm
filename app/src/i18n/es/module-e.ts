// Spanish for the guest scripts (guest/), the GpuVM service (app/host) and the desktop app's Rust side (src-tauri)
// messages (see module.ts for how patterns work).
export default {
  // Windows cleanup items (guest/cleanup.ps1)
  "Diagnostic data at the lowest level the edition allows (on Pro, “Required”; on Enterprise and Education, off).": "Datos de diagnóstico al mínimo que permite la edición (en Pro, «Requerido»; en Enterprise y Education, apagados).",
  "No advertising ID or tailored experiences from your diagnostic data.": "Sin identificador de publicidad ni experiencias personalizadas con tus datos de diagnóstico.",
  "No activity history and no activity sent to Microsoft.": "Sin historial de actividad ni envío de actividad a Microsoft.",
  "No suggestions, tips, Spotlight or promoted apps that install themselves.": "Sin sugerencias, consejos, Spotlight ni apps promocionadas que se instalan solas.",
  "Start's search looks only on this PC, without Bing.": "La búsqueda de Inicio busca solo en el equipo, sin Bing.",
  "No Copilot or Recall (the screenshots Windows 11 saves).": "Sin Copilot ni Recall (las capturas de pantalla que guarda Windows 11).",
  "Removes preinstalled apps that aren't needed (news, weather, Solitaire, Clipchamp, personal Teams, new Outlook...), for new users too. They can be installed again from Microsoft Store.": "Quita apps preinstaladas que no hacen falta (noticias, clima, Solitario, Clipchamp, Teams personal, Outlook nuevo...), también para usuarios nuevos. Se pueden volver a instalar desde Microsoft Store.",
  "Removes OneDrive and keeps it from installing again.": "Quita OneDrive y evita que se vuelva a instalar.",
  "No widgets or “News and interests” on the taskbar.": "Sin widgets ni «Noticias e intereses» en la barra de tareas.",
  "Turns off the services that send telemetry and error reports to Microsoft.": "Apaga los servicios que envían telemetría y el informe de errores a Microsoft.",
  "Turns off services a VM doesn't use: maps, location, fax, demo mode and Windows Media sharing.": "Apaga servicios que una VM no usa: mapas, ubicación, fax, modo demo y uso compartido de Windows Media.",
  "Microsoft Store apps don't run in the background.": "Las apps de Microsoft Store no corren en segundo plano.",
  // GpuVM service (app/host)
  "The GpuVM service is stopping.": "El servicio de GpuVM se está deteniendo.",
  "This needs your confirmation as administrator.": "Hace falta confirmarlo como administrador.",
  "The Windows session belongs to another user.": "La sesión de Windows pertenece a otro usuario.",
  "GpuVM needs an administrator account on this PC.": "GpuVM necesita una cuenta de administrador de este equipo.",
  // Desktop app (src-tauri)
  "The prompt already closed.": "El aviso ya se cerró.",
  "The prompt is still being read.": "Todavía se está leyendo el aviso.",
  "The prompt just appeared.": "El aviso acaba de aparecer.",
  "The prompt isn't valid.": "El aviso no es válido.",
  "Couldn't open the viewer with reduced rights.": "No se pudo abrir el visor con permisos reducidos.",
  "no folder": "sin carpeta",
  "no stdin": "sin stdin",
  "no stdout": "sin stdout",
} as Record<string, string>;

export const patterns: [RegExp, string][] = [
  [/^(\w+) failed \(error (\d+)\)$/, "$1 falló (error $2)"],
];
