// node --test scripts/site
import test from "node:test";
import assert from "node:assert/strict";
import { buildChangelogData, parseChangelog } from "./changelog.mjs";

const EN = `# Changelog

## [Unreleased]

### Added
- Not released yet.

## [0.2.0] - 2026-10-28

### Added
- **Templates.** A long line
  that wraps.
- Shared disks.

### Security
- Fail closed.

## [0.1.0] - 2026-10-27

### Fixed
- First fix.
`;

const ES = `# Registro de cambios

## [Sin publicar]

### Añadido
- Todavía no.

## [0.2.0] - 2026-10-28

### Añadido
- **Plantillas.**
- Discos compartidos.

### Seguridad
- Falla cerrado.

## [0.1.0] - 2026-10-27

### Corregido
- Primer arreglo.
`;

test("skips Unreleased and keeps releases newest first", () => {
  const releases = parseChangelog(EN, "en");
  assert.deepEqual(releases.map((r) => r.version), ["0.2.0", "0.1.0"]);
  assert.equal(releases[0].date, "2026-10-28");
});

test("joins wrapped bullets and maps section names", () => {
  const [latest] = parseChangelog(EN, "en");
  assert.equal(latest.sections.added[0], "**Templates.** A long line that wraps.");
  assert.deepEqual(latest.sections.security, ["Fail closed."]);
});

test("pairs both languages by version", () => {
  const data = buildChangelogData(EN, ES);
  assert.equal(data[0].es.added[0], "**Plantillas.**");
  assert.deepEqual(data[1].es.fixed, ["Primer arreglo."]);
});
