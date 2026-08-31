#!/usr/bin/env python3
"""Validate what `dart pub publish` would actually ship.

`.pubignore` REPLACES `.gitignore` for publishing, so a gitignored directory is
NOT excluded unless it is also listed there. That already shipped a 52 MB
node_modules once. This asks pub directly rather than reading the two files.

Checks:
  * gitignored files that are still inside the package
  * secret-ish paths in the package (.api2dart/, config.yaml, keys)
  * pubspec version has a matching CHANGELOG section
  * pub's own warnings

Exit 0 when clean, 1 on anything suspicious.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# Paths that must never be published, matched as substrings of the package-
# relative path. These hold API tokens and (since 0.7.0) cleartext credentials.
SECRET_PATTERNS = (
    ".api2dart/",
    ".apigen/",
    "key.properties",
    "upload-keystore.jks",
    "api_key.json",
)

# Noise that is legitimately in the package and would false-positive above.
SECRET_ALLOW = ("lib/", "test/", "bin/")


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def package_files(root: Path) -> tuple[list[str], str]:
    """-> (package-relative paths, full dry-run output)."""
    proc = run(["dart", "pub", "publish", "--dry-run"], root)
    output = proc.stdout + proc.stderr

    files: list[str] = []
    in_listing = False
    for raw in output.splitlines():
        line = raw.rstrip()
        if re.match(r"^Publishing .* to ", line):
            in_listing = True
            continue
        if in_listing:
            # The listing is an indented tree; it ends at the first blank line
            # or a top-level sentence.
            if not line.strip():
                if files:
                    in_listing = False
                continue
            if not line.startswith((" ", "|", "'", "│", "├", "└", "─")):
                in_listing = False
                continue
            # Strip tree drawing characters and any trailing size annotation.
            cleaned = re.sub(r"^[\s|'│├└─`-]+", "", line)
            cleaned = re.sub(r"\s*\(\d+[^)]*\)\s*$", "", cleaned).strip()
            if cleaned and not cleaned.endswith("/"):
                files.append(cleaned)
    return files, output


def gitignored(root: Path, paths: list[str]) -> list[str]:
    """Which of `paths` git would ignore. Batched through check-ignore."""
    if not paths:
        return []
    proc = subprocess.run(
        ["git", "check-ignore", "--stdin"],
        cwd=root,
        input="\n".join(paths),
        capture_output=True,
        text=True,
    )
    # rc 0 = some ignored, 1 = none ignored, >1 = real error.
    if proc.returncode > 1:
        print(f"  (warning: git check-ignore failed: {proc.stderr.strip()})")
        return []
    return [p for p in proc.stdout.splitlines() if p.strip()]


def version_and_changelog(root: Path) -> tuple[str | None, bool]:
    version = None
    pubspec = root / "pubspec.yaml"
    if pubspec.exists():
        for line in pubspec.read_text().splitlines():
            m = re.match(r"^version:\s*(\S+)", line)
            if m:
                version = m.group(1)
                break
    if version is None:
        return None, False

    changelog = root / "CHANGELOG.md"
    if not changelog.exists():
        return version, False
    return version, bool(
        re.search(rf"^##\s*\[?{re.escape(version)}\]?", changelog.read_text(), re.M)
    )


def main() -> int:
    # scripts/ -> release-check/ -> skills/ -> .claude/ -> repo root
    root = Path(__file__).resolve().parents[4]
    failures: list[str] = []

    print("Running `dart pub publish --dry-run` ...\n")
    files, output = package_files(root)

    if not files:
        print(output)
        print("FAIL: could not parse the package file list from pub's output.")
        print("      Read the output above and check it manually.")
        return 1

    print(f"Package contains {len(files)} file(s).")

    size = re.search(r"Total compressed archive size:\s*(.+)", output)
    if size:
        print(f"Archive size: {size.group(1).strip()}")

    # --- gitignored-but-published: the node_modules class of bug ------------
    ignored = gitignored(root, files)
    if ignored:
        failures.append("gitignored files are in the package")
        print("\nGITIGNORED BUT PUBLISHED — .pubignore replaces .gitignore, so add these:")
        for path in sorted(ignored):
            print(f"  {path}")
    else:
        print("\nOK: no gitignored file is in the package.")

    # --- secrets ------------------------------------------------------------
    secrets = [
        f
        for f in files
        if any(pat in f for pat in SECRET_PATTERNS)
        and not any(f.startswith(a) for a in SECRET_ALLOW)
    ]
    if secrets:
        failures.append("secret-ish paths in the package")
        print("\nSECRET-ISH PATHS IN THE PACKAGE:")
        for path in sorted(secrets):
            print(f"  {path}")
    else:
        print("OK: no secret-ish path in the package.")

    # --- version / changelog ------------------------------------------------
    version, has_entry = version_and_changelog(root)
    if version is None:
        failures.append("no version in pubspec.yaml")
        print("\nFAIL: could not read `version:` from pubspec.yaml.")
    elif has_entry:
        print(f"OK: version {version} has a CHANGELOG section.")
    else:
        failures.append(f"CHANGELOG has no section for {version}")
        print(f"\nFAIL: pubspec version is {version}, but CHANGELOG.md has no `## {version}` section.")

    # --- pub's own warnings -------------------------------------------------
    warnings = [
        line
        for line in output.splitlines()
        if re.match(r"^\s*(Warning|Package validation found|\*)", line.strip())
    ]
    if warnings:
        print("\nPub's own warnings:")
        for line in warnings:
            print(f"  {line.strip()}")

    if failures:
        print("\nFAIL: " + "; ".join(failures))
        return 1

    print("\nOK: package contents look clean.")
    print("Publishing is irreversible — confirm with the user before `dart pub publish`.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
