// Checks the English catalog against the code: every t()/tn() key has its English, no English is left unused,
// and Spanish text that is not wrapped in t() is pointed out (lines with accents or ¿¡ outside t(), as a hint).
//
//   node scripts/i18n-check.mjs            report
//   node scripts/i18n-check.mjs --strict   exit 1 when a key is missing (CI)
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = new URL("../src/", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
const files = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) { if (name !== "en") walk(p); }
    else if (/\.(tsx?|mts)$/.test(name) && !name.endsWith(".d.ts")) files.push(p);
  }
})(root);

// The catalog: one `"Spanish": "English",` per line in src/i18n/en/*.ts.
const catalog = new Map();
const enDir = join(root, "i18n", "en");
for (const name of readdirSync(enDir)) {
  const text = readFileSync(join(enDir, name), "utf8");
  for (const m of text.matchAll(/^\s*("(?:[^"\\]|\\.)*")\s*:\s*("(?:[^"\\]|\\.)*")\s*,?\s*$/gm)) {
    const key = JSON.parse(m[1]);
    if (catalog.has(key) && catalog.get(key).value !== JSON.parse(m[2])) console.log(`dup  ${name}: ${m[1]} (also in ${catalog.get(key).file})`);
    catalog.set(key, { value: JSON.parse(m[2]), file: name });
  }
}

const str = `(?:"((?:[^"\\\\]|\\\\.)*)"|'((?:[^'\\\\]|\\\\.)*)')`;
const callT = new RegExp(`\\bt\\(\\s*${str}`, "g");
const callTn = new RegExp(`\\btn\\([^,]+,\\s*${str}\\s*,\\s*${str}`, "g");
const used = new Set();
const missing = [];
const hints = [];
for (const file of files) {
  const text = readFileSync(file, "utf8");
  const rel = relative(root, file).replaceAll("\\", "/");
  if (rel.startsWith("i18n/")) continue;
  const unq = (a, b) => (a !== undefined ? JSON.parse(`"${a}"`) : b.replace(/\\'/g, "'"));
  for (const m of text.matchAll(callT)) {
    const key = unq(m[1], m[2]); used.add(key);
    if (!catalog.has(key)) missing.push(`${rel}: ${JSON.stringify(key)}`);
  }
  for (const m of text.matchAll(callTn)) {
    for (const key of [unq(m[1], m[2]), unq(m[3], m[4])]) {
      used.add(key);
      if (!catalog.has(key)) missing.push(`${rel}: ${JSON.stringify(key)}`);
    }
  }
  if (rel === "mock.ts") continue;
  text.split(/\r?\n/).forEach((line, i) => {
    const code = line.replace(/\/\/.*$/, "").replace(/\/\*.*?\*\//g, "");
    if (/^\s*(\*|\/\*)/.test(line) || line.includes("i18n-ignore")) return;
    if (!/[áéíóúñÁÉÍÓÚÑ¿¡]/.test(code)) return;
    const stripped = code.replace(/\btn?\((?:[^()]|\([^()]*\))*\)/g, "");
    if (/[áéíóúñÁÉÍÓÚÑ¿¡]/.test(stripped)) hints.push(`${rel}:${i + 1}: ${line.trim().slice(0, 110)}`);
  });
}

const unused = [...catalog.keys()].filter((k) => !used.has(k) && catalog.get(k).file !== "module.ts" && catalog.get(k).file !== "dynamic.ts");
console.log(`${catalog.size} textos en inglés, ${used.size} usados en el código`);
if (missing.length) console.log(`\nSin inglés (${missing.length}):\n  ` + [...new Set(missing)].join("\n  "));
if (unused.length) console.log(`\nInglés sin uso (${unused.length}):\n  ` + unused.map((k) => JSON.stringify(k)).join("\n  "));
if (hints.length) console.log(`\nPosible español sin t() (${hints.length}):\n  ` + hints.join("\n  "));
if (process.argv.includes("--strict") && missing.length) process.exit(1);
