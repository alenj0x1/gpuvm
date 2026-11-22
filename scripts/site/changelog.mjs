// Builds site/data/changelog.json from CHANGELOG.md and CHANGELOG.es.md. Usage: node scripts/site/changelog.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SECTIONS = {
  en: { Added: "added", Changed: "changed", Fixed: "fixed", Security: "security" },
  es: { "Añadido": "added", "Agregado": "added", "Cambiado": "changed", "Corregido": "fixed", "Seguridad": "security" },
};

export function parseChangelog(text, lang) {
  const releases = [];
  let release = null;
  let section = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trimEnd();
    const head = line.match(/^## \[(\d+\.\d+\.\d+)\](?: - (\d{4}-\d{2}-\d{2}))?/);
    if (head) {
      release = { version: head[1], date: head[2] ?? null, sections: {} };
      releases.push(release);
      section = null;
      continue;
    }
    if (line.startsWith("## ")) { release = null; section = null; continue; }
    if (!release) continue;
    const sub = line.match(/^### (.+)$/);
    if (sub) {
      section = SECTIONS[lang][sub[1].trim()] ?? null;
      if (section) release.sections[section] = [];
      continue;
    }
    if (!section) continue;
    if (line.startsWith("- ")) release.sections[section].push(line.slice(2).trim());
    else if (line.startsWith("  ") && release.sections[section].length) {
      const items = release.sections[section];
      items[items.length - 1] += " " + line.trim();
    }
  }
  return releases;
}

export function buildChangelogData(en, es) {
  const english = parseChangelog(en, "en");
  const spanish = parseChangelog(es, "es");
  return english.map((r) => ({
    version: r.version,
    date: r.date,
    en: r.sections,
    es: spanish.find((s) => s.version === r.version)?.sections ?? r.sections,
  }));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
  const read = (f) => fs.readFileSync(path.join(root, f), "utf8");
  const data = buildChangelogData(read("CHANGELOG.md"), read("CHANGELOG.es.md"));
  const out = path.join(root, "site", "data", "changelog.json");
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify({ releases: data }, null, 2) + "\n");
  console.log(`${data.length} releases -> ${path.relative(root, out)}`);
}
