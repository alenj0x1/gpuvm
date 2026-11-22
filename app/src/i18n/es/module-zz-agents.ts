// Last of the module files on purpose (patterns are tried in file order and these are broad).
// Spanish for what the agent broker says in English: request titles and why an agent waits (Get-GpuVMAgent*).
// The agent's own words (its task, its reasons, its notes) are shown as it wrote them.
export default {
  "Use one of your machines": "Usar una de tus máquinas",
  // Connecting Claude Code from the Agents page (claude.rs).
  "Claude Code isn't installed on this PC.": "Claude Code no está instalado en este PC.",
  "Claude Code couldn't add GpuVM.": "Claude Code no pudo agregar GpuVM.",
} as Record<string, string>;

export const patterns: [RegExp, string][] = [
  [/^Connect to (.+)$/, "Conectarse a $1"],
  [/^Deliver (.+)$/, "Entregar $1"],
  [/^Install (.+) as administrator$/, "Instalar $1 como administrador"],
  [/^Run (.+) as administrator$/, "Ejecutar $1 como administrador"],
  [/^Go back to the restore point (.+)$/, "Volver al punto $1"],
  [/^Delete the machine (.+)$/, "Eliminar la máquina $1"],
  [/^Paused by you$/, "Pausado por ti"],
  [/^You took control$/, "Tomaste el control"],
  [/^Waiting for your approval$/, "Espera tu aprobación"],
  [/^Windows asks for a password$/, "Windows pide una contraseña"],
  [/^Windows asks for administrator permission$/, "Windows pide permiso de administrador"],
  [/^The machine is locked$/, "La máquina está bloqueada"],
  [/^Out of steps$/, "Se acabaron los pasos"],
  [/^Out of time$/, "Se acabó el tiempo"],
  // Get-GpuVMAgent "no-display" (lastError).
  [/^The agent is signed in but has seen no display for (\d+) s: it can't take screenshots or use the mouse and keyboard\. Restarting doesn't help; the machine's agent needs fixing\.$/,
    "El agente inició sesión pero no ve ninguna pantalla desde hace $1 s. No puede tomar capturas ni usar el mouse y el teclado. Reiniciar no lo arregla, hay que reparar el agente de la máquina."],
  [/^The agent is signed in but has seen no display for (\d+) s: (.+)$/, "El agente inició sesión pero no ve ninguna pantalla desde hace $1 s. $2"],
  // What the agent did (its actions, newest first).
  [/^Took a screenshot$/, "Tomó una captura"],
  [/^Clicked (.+)$/, "Clic en $1"],
  [/^Double-clicked (.+)$/, "Doble clic en $1"],
  [/^Right-clicked (.+)$/, "Clic derecho en $1"],
  [/^Typed (.+)$/, "Escribió $1"],
  [/^Pressed (.+)$/, "Presionó $1"],
  [/^Scrolled down$/, "Bajó"],
  [/^Scrolled up$/, "Subió"],
  [/^Read the window (.+)$/, "Leyó la ventana $1"],
  [/^Checked (.+)$/, "Marcó $1"],
  [/^Downloaded (.+)$/, "Descargó $1"],
  [/^Ran (.+)$/, "Ejecutó $1"],
  [/^Saved (.+)$/, "Guardó $1"],
  [/^Offered (.+)$/, "Ofreció $1"],
];
