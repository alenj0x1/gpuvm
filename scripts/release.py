"""Releases a version: new number everywhere, changelog, commit and tag.

    python scripts/release.py 0.3.0            # does everything
    python scripts/release.py 0.3.0 --dry-run  # only shows what it would do
    python scripts/release.py --next           # suggests the number from the commits

Steps:
  1. Checks that the tree is clean and that "Unreleased" (CHANGELOG.md) and "Sin publicar"
     (CHANGELOG.es.md) have entries.
  2. Sets the version in the module (GpuVM.psd1, GpuVM.psm1), the app (package.json, Cargo.toml,
     Cargo.lock, tauri.conf.json) and the docs (package.json).
  3. Turns those sections into "## [<version>] - <date>" with a compare link, leaving no empty
     section above it. The docs changelog is generated from them when the docs are built.
  4. Commits "chore(release): <version>" and creates the annotated tag v<version> with the notes.

It does not push: review, then `git push --follow-tags`.
"""

import argparse
import datetime as dt
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO_URL = "https://github.com/alenj0x1/gpuvm"
# Each changelog with the title of its section of unreleased changes.
CHANGELOGS = [(ROOT / "CHANGELOG.md", "Unreleased"), (ROOT / "CHANGELOG.es.md", "Sin publicar")]
# File and the pattern whose first group is followed by the version (only the first match is replaced).
VERSION_SPOTS = [
    (ROOT / "src" / "GpuVM" / "GpuVM.psd1", r"(ModuleVersion\s*=\s*')[^']+"),
    (ROOT / "src" / "GpuVM" / "GpuVM.psm1", r"(\$script:ToolVersion\s*=\s*')[^']+"),
    (ROOT / "app" / "package.json", r'("version"\s*:\s*")[^"]+'),
    (ROOT / "app" / "src-tauri" / "tauri.conf.json", r'("version"\s*:\s*")[^"]+'),
    (ROOT / "app" / "src-tauri" / "Cargo.toml", r'(?m)(^version = ")[^"]+'),
    (ROOT / "app" / "src-tauri" / "Cargo.lock", r'(name = "gpuvm"\r?\nversion = ")[^"]+'),
    (ROOT / "docs" / "package.json", r'("version"\s*:\s*")[^"]+'),
]


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True,
                          encoding="utf-8").stdout.strip()


def read(path: Path) -> str:
    # newline="" keeps the file's own line endings; utf-8-sig drops a BOM if there is one.
    with open(path, encoding="utf-8-sig", newline="") as f:
        return f.read()


def write(path: Path, text: str) -> None:
    bom = path.read_bytes().startswith(b"\xef\xbb\xbf")
    with open(path, "w", encoding="utf-8-sig" if bom else "utf-8", newline="") as f:
        f.write(text)


def current() -> str:
    return re.search(r"ModuleVersion\s*=\s*'([^']+)'", read(VERSION_SPOTS[0][0]))[1]


def suggest() -> str:
    """Semantic version from the Conventional Commits since the last tag."""
    major, minor, patch = map(int, current().split("."))
    try:
        log = git("log", f"{git('describe', '--tags', '--abbrev=0')}..HEAD", "--format=%s%n%b")
    except subprocess.CalledProcessError:
        log = git("log", "--format=%s%n%b")
    if re.search(r"^[a-z]+(\(.+\))?!:|^BREAKING CHANGE:", log, re.M):
        return f"{major + 1}.0.0"
    if re.search(r"^feat(\(.+\))?:", log, re.M):
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def release_changelog(text: str, title: str, version: str, previous: str, today: str) -> tuple[str, str]:
    """Returns the changelog with the unreleased section turned into the version, and that section's notes."""
    nl = "\r\n" if "\r\n" in text else "\n"
    text = text.replace("\r\n", "\n")
    m = re.search(rf"^## \[{re.escape(title)}\]\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        sys.exit(f"The changelog has no «{title}» section.")
    notes = m[1].strip()
    if not notes:
        sys.exit(f"«{title}» is empty: write the changes there before releasing.")
    text = text[:m.start()] + f"## [{version}] - {today}\n\n{notes}\n\n" + text[m.end():]
    # Compare links: the unreleased one (if any) goes away with its section; the new version goes first.
    text = re.sub(rf"^\[{re.escape(title)}\]: .*\n", "", text, flags=re.M)
    link = f"[{version}]: {REPO_URL}/compare/v{previous}...v{version}\n"
    first = re.search(r"^\[\d+\.\d+\.\d+\]: ", text, re.M)
    text = text[:first.start()] + link + text[first.start():] if first else text.rstrip("\n") + "\n\n" + link
    return text.replace("\n", nl), notes


def main() -> int:
    # The notes have characters (→, accents) that a Windows console's code page can't print.
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("version", nargs="?", help="x.y.z")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--next", action="store_true", help="suggest the next version and exit")
    a = ap.parse_args()

    if a.next:
        print(suggest())
        return 0
    if not a.version or not re.fullmatch(r"\d+\.\d+\.\d+", a.version):
        ap.error("give the version as x.y.z (or use --next)")
    if git("status", "--porcelain"):
        sys.exit("There are uncommitted changes: commit them before releasing.")
    if git("tag", "--list", f"v{a.version}"):
        sys.exit(f"Tag v{a.version} already exists.")

    previous, today = current(), dt.date.today().isoformat()
    updated = [(path, *release_changelog(read(path), title, a.version, previous, today)) for path, title in CHANGELOGS]
    notes_en, notes_es = updated[0][2], updated[1][2]
    print(f"{previous} -> {a.version} ({today})\n\n{notes_en}\n")
    if a.dry_run:
        print("(--dry-run: nothing was changed)")
        return 0

    for path, text, _ in updated:
        write(path, text)
    for path, pattern in VERSION_SPOTS:
        text, n = re.subn(pattern, lambda m: m[1] + a.version, read(path), count=1)
        if not n:
            sys.exit(f"No version found in {path.relative_to(ROOT)}.")
        write(path, text)
    files = [p for p, _ in CHANGELOGS] + [p for p, _ in VERSION_SPOTS]
    git("add", *(str(p) for p in files))
    body = (f"- Version {a.version} in the module (GpuVM.psd1, GpuVM.psm1), the app (package.json, Cargo.toml, "
            f"Cargo.lock, tauri.conf.json) and the docs package.json.\n"
            f"- CHANGELOG.md and CHANGELOG.es.md: the unreleased section becomes {a.version}, with its compare link; "
            f"the docs changelog is generated from them.")
    git("commit", "-m", f"chore(release): {a.version}", "-m", body)
    # verbatim: the default cleanup drops the notes' "### Added" headings as if they were comments.
    git("tag", "-a", "--cleanup=verbatim", f"v{a.version}", "-m", f"GpuVM {a.version}\n\n{notes_en}\n\n---\n\n## Español\n\n{notes_es}")
    print(f"Done: commit and tag v{a.version}. To publish: git push --follow-tags")
    return 0


if __name__ == "__main__":
    sys.exit(main())
