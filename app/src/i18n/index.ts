export type Lang = "es" | "en";
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

export function locale(): string {
  return current === "es" ? "es" : "en-US";
}

const warned = new Set<string>();

function fill(text: string, vars?: Record<string, string | number>) {
  if (!vars) return text;
  return text.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k]) : m));
}

const bare = (key: string) => { const bar = key.indexOf("|"); return bar < 0 ? key : key.slice(0, bar); };

export function t(en: string, vars?: Record<string, string | number>): string {
  if (current === "en") return fill(bare(en), vars);
  const es = ES[en];
  if (es === undefined) {
    if (import.meta.env.DEV && !warned.has(en)) { warned.add(en); console.warn(`[i18n] no Spanish: ${JSON.stringify(en)}`); }
    return fill(bare(en), vars);
  }
  return fill(es, vars);
}

export function tn(n: number, one: string, many: string, vars?: Record<string, string | number>): string {
  return t(n === 1 ? one : many, { n: n.toLocaleString(locale()), ...vars });
}

export function translateModule(message: string): string {
  if (current === "en" || !message) return message;
  return translateOne(message, 0);
}

function translateOne(message: string, depth: number): string {
  if (ES[message] !== undefined) return ES[message];
  for (const [pattern, spanish] of MODULE) {
    const m = message.match(pattern);
    if (m) return spanish.replace(/\$(\d+)/g, (_, i) => { const v = m[Number(i)] ?? ""; return depth < 1 && /[a-z]{3}/i.test(v) && v.includes(" ") ? translateOne(v, depth + 1) : v; });
  }
  if (depth < 1) {
    const parts = message.split(/(?<=\.)\s+(?=[A-Z¿])|;\s+/);
    if (parts.length > 1) return parts.map((p) => translateOne(p, depth + 1)).join(message.includes("; ") && !message.includes(". ") ? "; " : " ");
  }
  return message;
}
