export default {
  "Couldn't read the process's token.": "No se pudo leer el token del proceso.",
  "The Administrators SID isn't valid.": "SID de Administradores no válido.",
  "Couldn't tell where a file is; nothing is sent.": "No se pudo saber dónde está un archivo; no se envía nada.",
  "Couldn't copy the disk: The base disk ended sooner than expected.": "No se pudo copiar el disco: El disco base terminó antes de lo esperado.",
  "nothing was receiving": "sin recepción",
} as Record<string, string>;

export const patterns: [RegExp, string][] = [
  [/^tar still running: (.*)$/s, "tar sigue abierto: $1"],
  [/^That restore point isn't valid: (.+)$/, "Punto de restauración no válido: $1"],
  [/^The disk (.+) isn't connected to the machine '(.+)'\.$/, "El disco $1 no está conectado a la máquina '$2'."],
  [/^The point's disk was already gone \((.+)\)\.$/, "El disco del punto ya no existía ($1)."],
  [/^Couldn't create the user's token \((.+)\)\.$/, "No se pudo crear el token del usuario ($1)."],
  [/^Your user can't access (.+); nothing is sent\.$/, "Tu usuario no tiene acceso a $1; no se envía nada."],
  [/^(.+) couldn't be opened \(error (-?\d+)\); nothing is sent\.$/, "No se pudo abrir $1 (error $2); no se envía nada."],
  [/^(.+) changed while it was being prepared; try again\.$/, "$1 cambió mientras se preparaba; vuelve a intentarlo."],
  [/^(.+) now leads outside the chosen folder; nothing is sent\.$/, "$1 ahora lleva fuera de la carpeta elegida; no se envía nada."],
];
