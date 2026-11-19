// GpuVM speaks English (the source language) and Spanish.
//
// The English text stays in the components as the key: t("Start") returns "Start" in English and the Spanish from
// the catalog in Spanish. Each area of the app keeps its Spanish in its own file under ./es/ (merged here), so the
// catalog grows with the code that uses it. `npm run i18n` checks that every key has its Spanish.
//
// Values go in with {name}: t("Open with {gb} GB", { gb: 8 }). The Spanish may move them around.
// When one English text needs two Spanish ones (Spanish has gender, or a word means two things), the key carries a
// context after a bar: t("On|setting") shows "On" in English and "Activado" in Spanish, while t("On") is "Encendida".
// Messages from the PowerShell module (errors, steps) arrive in English; translateModule() turns them into Spanish
// with the patterns in ./es/module.ts.

export type Lang = "es" | "en";
/** "system" follows Windows' display language: Spanish if it is Spanish, English otherwise. */
export type LangPref = "system" | Lang;

type Catalog = Record<string, string>;
const fragments = import.meta.glob<Catalog>("./es/*.ts", { eager: true, import: "default" });
const ES: Catalog = Object.assign({}, ...Object.values(fragments).filter((f) => f && typeof f === "object" && !Array.isArray(f)));
// Patterns from every ./es/module*.ts file, module.ts first (the first pattern that matches wins).
const patternFiles = import.meta.glob<[RegExp, string][]>("./es/module*.ts", { eager: true, import: "patterns" });
const MODULE = Object.keys(patternFiles).sort((a, b) => (a === "./es/module.ts" ? -1 : b === "./es/module.ts" ? 1 : a.localeCompare(b))).flatMap((k) => patternFiles[k] ?? []);

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

/** The English text without its context ("On|setting" is "On"). */
const bare = (key: string) => { const bar = key.indexOf("|"); return bar < 0 ? key : key.slice(0, bar); };

/** The text in the current language. `en` is the English text, which is also the key. */
export function t(en: string, vars?: Record<string, string | number>): string {
  if (current === "en") return fill(bare(en), vars);
  const es = ES[en];
  if (es === undefined) {
    if (import.meta.env.DEV && !warned.has(en)) { warned.add(en); console.warn(`[i18n] no Spanish: ${JSON.stringify(en)}`); }
    return fill(bare(en), vars);
  }
  return fill(es, vars);
}

/** One text for 1 and another for the rest; {n} is the count. tn(n, "{n} machine", "{n} machines"). */
export function tn(n: number, one: string, many: string, vars?: Record<string, string | number>): string {
  return t(n === 1 ? one : many, { n: n.toLocaleString(locale()), ...vars });
}

/** A message from the PowerShell module, in the current language. Unknown messages stay as they are. */
export function translateModule(message: string): string {
  if (current === "en" || !message) return message;
  return translateOne(message, 0);
}

function translateOne(message: string, depth: number): string {
  if (ES[message] !== undefined) return ES[message];
  for (const [pattern, spanish] of MODULE) {
    const m = message.match(pattern);
    // What a message carries inside (another error's text) is translated too, one level down.
    if (m) return spanish.replace(/\$(\d+)/g, (_, i) => { const v = m[Number(i)] ?? ""; return depth < 1 && /[a-z]{3}/i.test(v) && v.includes(" ") ? translateOne(v, depth + 1) : v; });
  }
  // Several problems joined in one message ("… . …" or "…; …"): each one on its own.
  if (depth < 1) {
    const parts = message.split(/(?<=\.)\s+(?=[A-Z¿])|;\s+/);
    if (parts.length > 1) return parts.map((p) => translateOne(p, depth + 1)).join(message.includes("; ") && !message.includes(". ") ? "; " : " ");
  }
  return message;
}
