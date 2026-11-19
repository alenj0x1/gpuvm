// Last of the module files on purpose (patterns are tried in file order and these are broad).
// Spanish for what the agent broker says in English: request titles and why an agent waits (Get-GpuVMAgent*).
// The agent's own words (its task, its reasons, its notes) are shown as it wrote them.
export default {} as Record<string, string>;

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
