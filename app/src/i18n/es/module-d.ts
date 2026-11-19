// Spanish for the public commands' and bridge messages of the module (see module.ts for how patterns work).
export default {
} as Record<string, string>;

export const patterns: [RegExp, string][] = [
  // One failed host check as the reason a machine can't be created ("This PC doesn't pass the check: <Name>: <Detail>").
  [/^Disk: A disposable machine needs (\d+) GB free on (.+) besides what is reserved for the other machines; there are (\d+) GB\.$/, "Disco: Una máquina desechable necesita $1 GB libres en $2 además de lo reservado para las otras máquinas; hay $3 GB."],
  [/^GPU: There's no GPU matching '(.+?)'\.$/, "GPU: No hay una GPU que coincida con '$1'."],
  [/^Space: (.+?) GB free on (.+?); about (.+?) GB are needed$/, "Espacio: $1 GB libres en $2; se necesitan ~$3 GB"],
  [/^Space: The drive for (.+) doesn't exist$/, "Espacio: No existe la unidad de $1"],
  [/^The machine '(.+?)' has no disk\.$/, "La máquina '$1' no tiene disco."],
  [/^The machine was imported but couldn't turn on: (.+)$/, "La máquina se importó pero no pudo encender: $1"],
  [/^Couldn't delete the disposable machine '(.+?)': (.+)$/, "No se pudo borrar la máquina desechable '$1': $2"],
  [/^Couldn't delete (.+?): (.+)$/, "No se pudo borrar $1: $2"],
  [/^Argument not allowed: (.+)$/, "Argumento no permitido: $1"],
];
