---
name: release-check
description: Prepare or validate an api_to_dart release — version bump, CHANGELOG entry, and above all what the published package will actually contain. Use before `dart pub publish`, when bumping the version, when adding a gitignored directory, or when the user asks what ships.
---

# release-check

Publishing this package is **manual and unscripted** — no CI workflow, no publish
script, no Makefile. The sequence from git history is:

1. bump `pubspec.yaml` `version:`
2. add a `CHANGELOG.md` section
3. commit
4. `dart pub publish`

Everything below is what that sequence doesn't check for you.

## The one that has already bitten

**`.pubignore` REPLACES `.gitignore` for publishing.** It does not add to it.

A directory being gitignored means nothing to `pub`. `tools/api2dart-mcp/node_modules`
(52 MB on disk, 8 MB in the archive) shipped inside the Dart package for exactly
this reason; excluding `tools/` dropped the archive to **137 KB** (commit `2b01fd9`).

> **Any new gitignored directory must be re-listed in `.pubignore` or it ships.**

`.pubignore` currently does not list `.claude/` or `.mcp.json`.

Never trust a reading of the two files — ask pub directly:

```bash
python3 .claude/skills/release-check/scripts/check_release.py
```

It runs `dart pub publish --dry-run`, and reports:

- the resolved archive size and file count
- **any file that is gitignored but still in the package** (the `node_modules` class of bug)
- anything matching a secret-ish path (`.api2dart/`, `.apigen/`, `config.yaml`, `*.jks`, `key.properties`)
- whether `pubspec.yaml`'s version has a matching `CHANGELOG.md` section
- pub's own warnings, verbatim

Exits 1 on anything suspicious. Run it **before** publishing, not after.

To see the file list yourself:

```bash
dart pub publish --dry-run 2>&1 | sed -n '/^Publishing/,/^$/p'
```

## Secrets that live in the tree

These exist as real files in the working tree and are kept out of the package
**only** by `.pubignore` lines:

| Path | Holds |
|---|---|
| `.api2dart/config.yaml` | Postman/Apidog tokens, wizard state, **cleartext login credentials** (0.7.0+) |
| `example/.api2dart/`, `example/.apigen/` | the same, for the example app |
| `.apigen/config.yaml` | legacy pre-rename equivalent |

Confirm each is absent from the dry-run listing. `.api2dart/` is also what
`GitignoreGuard` appends to a *user's* `.gitignore` for the same reason.

## Versioning

**`version.dart` is not hand-synced — don't "fix" it.** It has no version
constant; `packageVersion` lazily reads the bundled `pubspec.yaml`, first by
resolving `package:api_to_dart/api_to_dart.dart` and walking up from `lib/`, then
by walking up ≤5 levels from `Platform.script`. So `pubspec.yaml` is the single
source of truth.

**The trap is the silent `0.0.0` fallback.** If neither lookup finds the pubspec —
including if the barrel `lib/api_to_dart.dart` is ever renamed, since
`version.dart:45` hardcodes that path — `packageVersion` becomes `'0.0.0'`, and
`UpdateChecker.isNewer('0.0.0', anything)` is always true. The user then gets a
permanent, wrong "update available" nag, and **nothing logs when the fallback
fires**. After any change near the barrel or `version.dart`, check it reports the
real version:

```bash
dart run bin/api_to_dart.dart version
```

`UpdateChecker` compares only the three numeric semver components and strips
anything after `-` or `+`, so **`0.7.0-beta` and `0.7.0` compare equal** — a
pre-release is neither offered nor nagged about.

## CHANGELOG

Keep-a-Changelog style: `## <version>` headers with `### Added` / `### Fixed`.
Present: 0.7.0, 0.6.0, 0.4.0, 0.3.2, 0.3.1, 0.3.0, 0.2.0, 0.1.0 — **0.5.0 is
absent**, and it's unclear whether it was skipped or merely undocumented. Don't
"restore" it without knowing.

A version in `pubspec.yaml` with no matching CHANGELOG section is a release bug;
the script checks this.

## Before you publish

- [ ] `python3 .claude/skills/verify-cli/scripts/check_baseline.py` — no new analyzer issues
- [ ] `dart test` — 165 passing
- [ ] `cd tools/api2dart-mcp && npm run build && npm test` if the MCP server changed
- [ ] `python3 .claude/skills/release-check/scripts/check_release.py` — clean
- [ ] `dart run bin/api_to_dart.dart version` reports the real version, not `0.0.0`
- [ ] `pubspec.yaml` version bumped and matched by a CHANGELOG section
- [ ] README updated if a command, flag, or default changed
- [ ] no new gitignored directory missing from `.pubignore`

Publishing is outward-facing and irreversible — **confirm with the user before
running `dart pub publish`**, even when the checklist is green.
