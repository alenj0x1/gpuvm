// GpuVM speaks Spanish (the source language) and English.
//
// The Spanish text stays in the components as the key: t("Encender") returns "Encender" in Spanish and the English
// from the catalog in English. Each area of the app keeps its English in its own file under ./en/ (merged here), so
// the catalog grows with the code that uses it. `npm run i18n` checks that every key has its English.
//
// Values go in with {name}: t("Abrir con {gb} GB", { gb: 8 }). The English may move them around.
// Messages from the PowerShell module (errors, steps) arrive in Spanish; translateModule() turns them into English
// with the patterns in ./en/module.ts.

export type Lang = "es" | "en";
/** "system" follows Windows' display language: Spanish if it is Spanish, English otherwise. */
export type LangPref = "system" | Lang;

type Catalog = Record<string, string>;
const fragments = import.meta.glob<Catalog>("./en/*.ts", { eager: true, import: "default" });
const EN: Catalog = Object.assign({}, ...Object.values(fragments).filter((f) => f && typeof f === "object" && !Array.isArray(f)));
const MODULE = (import.meta.glob<[RegExp, string][]>("./en/module.ts", { eager: true, import: "patterns" })["./en/module.ts"]) ?? [];

let current: Lang = "es";

export function systemLang(): Lang {
  const langs = navigator.languages?.length ? navigator.languages : [navigator.language];
  return (langs[0] ?? "es").toLowerCase().startsWith("es") ? "es" : "en";
}

export function resolveLang(pref: LangPref): Lang {
  return pref === "system" ? systemLang() : pref;
}

export function setLang(lang: Lang) {
  current = lang;
  document.documentElement.lang = lang;
}

export function getLang(): Lang {
  return current;
}

/** The locale for numbers and dates. */
export function locale(): string {
  return current === "es" ? "es" : "en-US";
}

const warned = new Set<string>();

function fill(text: string, vars?: Record<string, string | number>) {
  if (!vars) return text;
  return text.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k]) : m));
}

/** The text in the current language. `es` is the Spanish text, which is also the key. */
export function t(es: string, vars?: Record<string, string | number>): string {
  if (current === "es") return fill(es, vars);
  const en = EN[es];
  if (en === undefined) {
    if (import.meta.env.DEV && !warned.has(es)) { warned.add(es); console.warn(`[i18n] sin inglés: ${JSON.stringify(es)}`); }
    return fill(es, vars);
  }
  return fill(en, vars);
}

/** One text for 1 and another for the rest; {n} is the count. tn(n, "{n} máquina", "{n} máquinas"). */
export function tn(n: number, one: string, many: string, vars?: Record<string, string | number>): string {
  return t(n === 1 ? one : many, { n: n.toLocaleString(locale()), ...vars });
}

/** A message from the PowerShell module, in the current language. Unknown messages stay as they are. */
export function translateModule(message: string): string {
  if (current === "es" || !message) return message;
  return translateOne(message, 0);
}

function translateOne(message: string, depth: number): string {
  if (EN[message] !== undefined) return EN[message];
  for (const [pattern, english] of MODULE) {
    const m = message.match(pattern);
    // What a message carries inside (another error's text) is translated too, one level down.
    if (m) return english.replace(/\$(\d+)/g, (_, i) => { const v = m[Number(i)] ?? ""; return depth < 1 && /[a-záéíóúñ]{3}/i.test(v) && v.includes(" ") ? translateOne(v, depth + 1) : v; });
  }
  // Several problems joined in one message ("… . …" or "…; …"): each one on its own.
  if (depth < 1) {
    const parts = message.split(/(?<=\.)\s+(?=[A-ZÁÉÍÓÚÑ¿])|;\s+/);
    if (parts.length > 1) return parts.map((p) => translateOne(p, depth + 1)).join(message.includes("; ") && !message.includes(". ") ? "; " : " ");
  }
  return message;
}
