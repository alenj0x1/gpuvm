import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = new URL("../src/", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
const files = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) { if (name !== "es") walk(p); }
    else if (/\.(tsx?|mts)$/.test(name) && !name.endsWith(".d.ts")) files.push(p);
  }
})(root);

const catalog = new Map();
const esDir = join(root, "i18n", "es");
for (const name of readdirSync(esDir)) {
  let text = readFileSync(join(esDir, name), "utf8");
  if (name.startsWith("module")) text = text.split("export const patterns")[0];
  for (const m of text.matchAll(/^\s*("(?:[^"\\]|\\.)*")\s*:\s*("(?:[^"\\]|\\.)*")\s*,?\s*$/gm)) {
    const key = JSON.parse(m[1]);
    if (catalog.has(key) && catalog.get(key).value !== JSON.parse(m[2])) console.log(`dup  ${name}: ${m[1]} (also in ${catalog.get(key).file})`);
    catalog.set(key, { value: JSON.parse(m[2]), file: name });
  }
}

const values = (s) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(",");
const mismatched = [...catalog].filter(([k, v]) => values(k.split("|")[0]) !== values(v.value)).map(([k, v]) => `${v.file}: ${JSON.stringify(k)} -> ${JSON.stringify(v.value)}`);

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
  text.split(/\r?\n/).forEach((line, i) => {
    const code = line.replace(/\/\/.*$/, "").replace(/\/\*.*?\*\//g, "");
    if (/^\s*(\*|\/\*)/.test(line) || line.includes("i18n-ignore")) return;
    if (/[áéíóúñÁÉÍÓÚÑ¿¡]/.test(code)) hints.push(`${rel}:${i + 1}: ${line.trim().slice(0, 110)}`);
  });
}

const unused = [...catalog.keys()].filter((k) => !used.has(k) && !catalog.get(k).file.startsWith("module"));
console.log(`${catalog.size} Spanish texts, ${used.size} keys used in the code`);
if (missing.length) console.log(`\nNo Spanish (${missing.length}):\n  ` + [...new Set(missing)].join("\n  "));
if (mismatched.length) console.log(`\nDifferent {values} (${mismatched.length}):\n  ` + mismatched.join("\n  "));
if (unused.length) console.log(`\nUnused Spanish (${unused.length}):\n  ` + unused.map((k) => JSON.stringify(k)).join("\n  "));
if (hints.length) console.log(`\nPossible Spanish left in the code (${hints.length}):\n  ` + hints.join("\n  "));
if (process.argv.includes("--strict") && (missing.length || mismatched.length)) process.exit(1);
