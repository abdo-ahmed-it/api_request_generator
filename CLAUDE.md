# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A pure-Dart CLI package that turns any API — **Postman**, **OpenAPI 3.x**, **Apidog**, or a local **YAML** file — into type-safe Dart code: an `ApiRequestAction` subclass plus a response model, or a response model only. Endpoints are picked in an interactive terminal tree or in a local web UI.

- **Package name:** `api_to_dart` (pub.dev). **Executable:** `api2dart`. Repo dir is still `api_request_generator` — that's history, not the package name.
- **Version 0.7.0**, SDK `^3.6.2`, no Flutter dependency.
- Generated code targets the `api_request` package.

**Naming trap:** the tool was renamed twice (`api_request_generator` → `apigen` → `api2dart`). `bin/api_request_generator.dart` and the `apigen` command **no longer exist**. Legacy `.apigen/` paths survive only in `.gitignore`/`.pubignore` so stale data isn't shipped.

## Commands

```bash
dart pub get

# The wizard — zero arguments means `generate`, and `generate` with no
# --config launches the interactive wizard.
dart run bin/api_to_dart.dart              # or, when globally activated: api2dart

# Generate with flags (non-interactive path)
dart run bin/api_to_dart.dart generate -s postman  -c collection.json -b https://api.example.com
dart run bin/api_to_dart.dart generate -s openapi  -c openapi.yaml -o lib/actions
dart run bin/api_to_dart.dart generate -s file     -c action_config.yaml
dart run bin/api_to_dart.dart generate -s postman  -c collection.json --no-interactive
dart run bin/api_to_dart.dart generate -s openapi  -c openapi.yaml --dry-run --no-interactive
dart run bin/api_to_dart.dart generate -s openapi  -c openapi.yaml --json   # implies --dry-run

# Other commands
dart run bin/api_to_dart.dart serve  -s openapi -c openapi.yaml -b https://api.example.com
dart run bin/api_to_dart.dart resend api2dart/<date>/logs/<name>.md
dart run bin/api_to_dart.dart reset [--all] [--yes]
dart run bin/api_to_dart.dart version
dart run bin/api_to_dart.dart upgrade [--force]

# Verify
dart analyze
dart test
dart format .
```

`--no-interactive` is `negatable: false` — **there is no `--interactive` flag**, the name itself is the negative. `--json` implies dry-run, prints JSON to stdout and diagnostics to stderr; it is what the MCP server consumes.

Unlike the Flutter projects in this workspace, **`dart test` is the real verification here** — 165 tests, and they pass. Run it. `dart analyze` alone is not enough.

## Architecture

Core/CLI separation: all reusable logic lives in `lib/src/core/`, CLI-only code in `lib/src/cli/`. `lib/` is ~11k lines across 53 files.

### CLI (`lib/src/cli/`)

- `cli_app.dart` — `CommandRunner`. **Zero args ⇒ `['generate']`** (:39). Fires a non-blocking update check (:44), skipped for `version|--version|-v|upgrade|help|--help|-h`, and surfaces the notice after the command completes.
- `commands/` — `generate`, `serve`, `resend`, `reset`, `version` (aliases `--version`/`-v`), `upgrade`.
- `wizard/generate_wizard.dart` — **1239 lines, the largest file in `lib/`**. Owns saved-settings replay, source selection, Postman/Apidog live fetch, browser token capture, URL-variable resolution, the optional web-UI isolate (port 4321, falls back to port 0), the select→generate loop, and interactive auto-re-login setup. `generate` with a null/empty `--config` delegates here (`generate_command.dart:112-118`).
- `ui/` — `endpoint_selector.dart` (tree selector), `prompts.dart`, `file_browser.dart`, `terminal_utils.dart` (ANSI + key reading).

### Core (`lib/src/core/`)

**`models/`** — `ApiEndpoint` (canonical endpoint; derives `key`, `actionClassName`, `responseClassName`, `fileName`), `EndpointTree`/`ApiFolder`, `BodyDefinition` (`formData|urlEncoded|rawJson|multipart`), `AuthDefinition` (`none|bearer|basic|apiKey`), `ResponseDefinition` (`schema|example|fetched|none`), `ApiSourceConfig`, `EndpointReport` (the `--json` payload: redacts, truncates arrays to 2, infers Dart types, emits `notes[]` heuristics), `RequestLog` (Markdown renderer + hidden resend metadata block), `SecretRedactor`, `LoginConfig`/`LoginConfigStore`.

**`sources/`** — each implements `ApiSource.parse(ApiSourceConfig) → EndpointTree`. `PostmanSource` (v2.1, recursive `item[]`), `OpenApiSource` (656 lines; YAML-then-JSON fallback, `$ref` resolution, schema→example synthesis), `ApidogSource` (28-line delegate to `OpenApiSource`), `LocalFileSource` (single-endpoint YAML), `UrlVariableResolver` (strips Apidog `<url_var>` prefixes into `baseUrlOverride` — the shared source of truth for terminal and web paths), `GitignoreGuard`, and `api_fetchers/` (`postman_fetcher`, `apidog_fetcher`, `config_storage`).

**`generation/`** — `ActionGenerator` (emits the `ApiRequestAction` source string), `ResponseGenerator` (thin wrapper over `ModelGenerator`), `CodeEmitter` (formats via `dart_style`, writes, `emitBatch`, `generateCode` for previews), `body_processor.dart`, `PubspecInspector` (looks for `api_request` across `dependencies`/`dev_dependencies`/`dependency_overrides` — this is what drives `mode: auto`).

**`resolution/`** — `ApiHttpClient` (has a `http.Client` seam for tests), `ResponseResolver` (live fetch → example → schema → empty).

**`json_to_dart/`** — `ModelGenerator` (entry point), `syntax.dart` (class/type definitions), `helpers.dart` (type inference, object merging). **This is the oldest, least-maintained corner** — see Traps.

**`auth/`** — `LoginService` (1–2 step login, BFS token discovery, dot-path walker) and `TokenSession` (shared mutable token holder, give-up latch, in-flight dedupe, cross-isolate sync via `ConfigStorage`). Powers the 0.7.0 auto-re-login.

**`server/`** — `ApiWebServer` (1049 lines; loopback HTTP server, routes for endpoint detail / preview / dirs / try / generate / relogin), `web_assets.dart` (1156 lines of inlined HTML/CSS/JS), `browser_token_capture.dart` (ephemeral loopback server for the guided token paste flow).

**`logger/`** — abstract `Logger` (`d/i/w/e/n`), `ConsoleLogger`, `StderrLogger`.

**Standalone** — `version.dart` (reads the bundled pubspec at runtime), `update_checker.dart` (pub.dev poll, 1-day cache in `~/.api2dart/update_check.json`).

### The two `api2dart` directories

Both are gitignored, and confusing them is a common mistake:

| Path | Role |
|---|---|
| **`.api2dart/`** (dotted) | **Config**, per project — `config.yaml` holds wizard state, Postman/Apidog tokens, login recipes, per-endpoint output overrides. Cleartext. |
| **`api2dart/`** (undotted) | **Output** — dated folders `api2dart/<date>/actions/` and `api2dart/<date>/logs/`. |
| `~/.api2dart/` | User-level, holds only `update_check.json`. |

`ApiSourceConfig.outputDir` defaults to `'lib/actions'`, but **no CLI caller uses that default** — both `generate` and `serve` pass an explicit `api2dart/<date>/actions`.

### MCP server (`tools/api2dart-mcp/`)

A TypeScript stdio MCP server (`@modelcontextprotocol/sdk`, `zod`), `"private": true`, wired via `.mcp.json`. It exposes the generator's endpoint inspection to an agent so an API's real shape can be fetched mid-conversation.

| Tool | Writes | Purpose |
|---|---|---|
| `api2dart_list` | no | List endpoints. Cheap — start here. |
| `api2dart_inspect` | no | Shape of specific endpoints: params, schema, sample, notes. |
| `api2dart_read_log` | no | Read a past capture, redacted. |
| `api2dart_resend` | **yes** | Replay a saved request; overwrites the log in place. |
| `api2dart_generate` | **yes** | Write Dart files. Rare — output is a scratch draft. |

Only the three read-only tools are pre-approved in `.claude/settings.local.json`; the two writers prompt every time.

It deliberately returns **JSON and inferred types, not Dart** — the generator infers from one sample and knows nothing about a consuming project's conventions, so the model writes the action against that project's own rules. It re-redacts and re-truncates the CLI's output rather than trusting it, and truncation is applied only to `.response`, never to `notes[]`/`headers[]`.

**A fresh clone's MCP server is dead**: `dist/` and `node_modules/` are gitignored, but `.mcp.json` points at `tools/api2dart-mcp/dist/index.js`. Run `npm install && npm run build` in `tools/api2dart-mcp/` first. Tests: `npm test` (`node --test dist/*.test.js`).

## Conventions

These are measured from the code, not aspirational.

### Logging

- **`Logger` for semantic status; raw `stdout` for interactive UI drawing** (ANSI cursor moves, prompts, banners, links). 110 `stdout.` uses across 12 files, concentrated in `prompts.dart`, `generate_wizard.dart`, `file_browser.dart`, `endpoint_selector.dart`.
- **`print(` is not house style** — 17 uses, and 16 of them are inside `ConsoleLogger` itself (the boxed ANSI output). The 17th (`endpoint_selector.dart:53`) is a stray. Don't add more.
- **`StderrLogger` is the `--json` path only.** Exactly one switch site: `generate_command.dart:129` — `jsonMode ? const StderrLogger() : ConsoleLogger()`. Everything else hard-codes `ConsoleLogger()`. If you add a machine-readable output mode, route its diagnostics to stderr the same way, or you corrupt the payload the MCP server parses.

### Error handling

- **No house exception type.** All 8 `throw`s are SDK types (`ArgumentError`, `FileSystemException`, `FormatException`) and all live in the three source parsers. Everything downstream catches broadly and degrades.
- **Two exit conventions coexist, and one is wrong.** `resend`/`serve`/`upgrade` set `exitCode` and `return`, with real sysexits values (64 usage / 65 dataerr / 66 noinput) — **that is the pattern to follow**. `generate_command.dart` calls `exit(0)`/`exit(1)` directly at 5 sites, which terminates immediately and means the update notice at `cli_app.dart:55` never fires for a flag-mode generate. Don't add new `exit()` calls; prefer `exitCode` + `return`.
- The top-level catch (`cli_app.dart:50-53`) prints the error but **never sets a non-zero exit code**, so an unhandled wizard failure exits 0.

### Style

- `snake_case` files, `PascalCase` classes. **Zero `part`/`part of`.**
- **Imports are relative** inside `lib/src/` (`../../core/…`); `bin/` and `test/` use `package:`. Match the file you're editing.
- **`lib/api_to_dart.dart` is a real but partial public API.** It exports models, sources, fetchers, generation, resolution, `api_web_server`, `model_generator` and the two loggers. It does **not** export anything under `cli/`, nor `auth/`, `gitignore_guard`, `version`, `update_checker`, `browser_token_capture`, `web_assets`, or `json_to_dart/{helpers,syntax}`. Tests import the barrel where they can and reach into `src/` where they must. Adding a new core type that consumers need means adding it to the barrel.
- **Modern Dart is uneven — lean conservative and match the file.** Records appear only in `auth/`. There are **zero switch expressions and zero if-case patterns** in `lib/`; every switch is a statement. 62 bang-derefs. `late` is used twice. Don't mass-modernize; when writing genuinely new code in a new subsystem, modern idioms are fine.
- Single quotes dominate, but **438 double-quoted literals remain**, concentrated in `json_to_dart/` (which also uses `""` as a sentinel). Leave those alone.
- **Comments are English throughout `lib/`.** The old note about Arabic comments in `json_to_dart` no longer applies.

### Analyze baseline

`analysis_options.yaml` is one line: `include: package:lints/recommended.yaml`. **`dart analyze` reports 20 pre-existing issues** (1 warning, 19 infos) and exits 0. Know the baseline so you can tell your issue from the furniture:

- `helpers.dart` — `PRIMITIVE_TYPES` + 5 `constant_identifier_names`, and **2 `unrelated_type_equality_checks` at :87 that are a real bug** (see Traps).
- `api_endpoint.dart:5` — 5 `constant_identifier_names` for `HttpMethod`'s uppercase `GET…DELETE`. **Intentional** — the names are compared against HTTP verb strings — but nothing suppresses the lint.
- 3 `unnecessary_brace_in_string_interps`, 2 `empty_catches` in `response_resolver.dart`, 1 `unintended_html_in_doc_comment`, and 1 `unused_element_parameter` warning in a test.

**A change should not raise that count.** Report the delta, not the total.

### Testing

- **14 files, 2471 lines, 165 tests, all passing** (~11s). `package:test` with `group`/`test`/`expect`; `mocktail` in exactly 2 files (both under `test/core/auth/`).
- `test/` mirrors `lib/src/` **from `core/` down** — `test/core/models/…`, `test/core/auth/…`. Two files break the mirror at the root: `api_to_dart_test.dart` (the original omnibus) and `browser_token_capture_test.dart`. New tests go in the mirrored location.
- **No fixture files.** Zero non-`.dart` files under `test/`; every JSON/YAML input is an inline string literal. Keep that.
- **Untested by dedicated file:** the entire `cli/` layer (all 6 commands, `cli_app`, the 1239-line wizard, the selector, prompts, file browser), all three source parsers, all of `generation/`, all of `json_to_dart/`, `http_client`, `response_resolver`, both fetchers, `version`, `update_checker`, `web_assets`. Some are exercised indirectly inside `api_to_dart_test.dart` — "no dedicated file" is not "no coverage". Anything you touch there is untested until you test it.
- The run is noisy: `ConsoleLogger` boxes and a real 5s timeout wait in `browser_token_capture_test` print into the output. That is expected, not a failure.

## Traps

The things that bite. Verified in the code at the cited lines.

### Security surfaces — check before you touch

- **`SecretRedactor` is the single choke point** for tokens landing in `.md` logs, `--json` output, and (via MCP) a model's context. Three layers: header names (6-name set), JSON keys by regex at any depth, and value shapes in free text (Bearer including the duplicated `Bearer Bearer` form, Laravel Sanctum `<id>|<token>`). `_embeddedJson` handles JSON-carried-as-a-string.
- **The one deliberate exemption is the hidden `api2dart:request` metadata block** (`request_log.dart:134-144`), which writes headers **verbatim and unredacted** so `resend` can replay them. **A log file on disk therefore contains a live token.** Any new code that renders that block, or reads a log without `stripResendMetadata`, leaks it. The MCP server strips it first thing in `redactMarkdown`.
- **The Dart `SecretRedactor` and the TypeScript `redact.ts` are deliberately duplicated and have drifted.** TS adds a `QUERY_SECRET` regex for `?token=…` in prose that Dart lacks; Dart's Bearer pattern is `\S+` while TS uses a narrower charset. Fix a redaction gap in **both** or note explicitly that you didn't.
- **`GitignoreGuard`** appends `.api2dart/` to the user's `.gitignore` because that file holds API keys and, since 0.7.0, **real login credentials in cleartext**. It only triggers when `.git` exists and recognizes 4 spelling equivalents. Renaming the config dir without updating `_entry`/`_equivalents`, or dropping the call from the wizard, silently exposes credentials.
- **`safety.ts` refuses to read the token from `.api2dart/config.yaml`** — deliberately, because it's cleartext. It requires `APIDOG_TOKEN` or the macOS keychain. Don't "helpfully" add that fallback.
- **MCP path confinement** (`safety.ts:18-47`): realpath first (so a symlink is judged on its target), walk to the deepest existing ancestor (so a not-yet-created output dir still validates), reject on `rel.startsWith("..")`. `run()` uses `execFile` with `shell: false`, so shell metacharacters in a filter are inert text. Caps: 60s timeout, 100KB output, 32MB buffer. Switching to `exec`, dropping the realpath, or raising a cap reopens the matching hole.
- **`browser_token_capture.dart`** binds loopback + port 0, 3-minute timeout, closes in `finally`. It has **no CSRF token and no Origin check** on `POST /token` — worst case is injecting a token, not reading one. Its `steps:` are interpolated into HTML raw; they are code-defined today, and passing user input there would be XSS on a loopback page.
- **`ApiWebServer`** binds loopback-only. `_sanitizeFile` strips separators and `..`; `_sanitizeClass` guards class names. Keep both on any new route that accepts a name.

### Confirmed bug

**`request_log.dart:73` renders header blocks literally.** `sb.writeln('\$k: \$v')` escapes both interpolations inside a single-quoted string, so every log's `### Headers` section contains the literal text `$k: $v`, once per header. The MCP server's `redactHeaderBlock` regex consequently never matches anything meaningful. `request_log_test.dart` passes because it never asserts on rendered header content. Fail-safe direction — no secret leaks — but the data is silently lost.

### Silent-failure paths

Places where "nothing happened" is indistinguishable from "it worked". Adding another one is a defect:

- `response_resolver.dart:134` and `:146` — **two empty `catch {}` blocks** (both flagged by analyze). A live fetch that throws yields `null`, identical to "no base URL given".
- `http_client.dart:106-109` — any network exception logs and returns `null`.
- `generate_command.dart:239-241` — the per-endpoint `attempt()` closure swallows every resolver exception into `ResponseDefinition.empty`.
- `pubspec_inspector.dart:38-40` — a malformed pubspec returns `false`, silently downgrading `mode: auto` to response-only.
- `model_generator.dart:38-45` — **`_hintForPath` always returns `null`** on both branches. The whole `hints` mechanism is dead code, and `late List<Hint> hints` exists only to feed it.
- `generate_wizard.dart:246-249` — web-server startup failure is swallowed; the user simply never sees a link.
- Also: `update_checker` (3 sites, intentional and documented), `gitignore_guard.dart:61`, `login_config.dart:246/253/258`, `token_session.dart:153/167`, `cli_app.dart:50` (prints, exits 0).

### Fragile parsing

- **`$ref` resolution** (`openapi_source.dart:327-347`) handles **only** `#/components/schemas/<Name>`. `#/definitions/…`, relative files, URLs, and `#/components/responses/…` fall through and are returned as-is. **No cycle detection** — a self-referential schema recurses to stack overflow. Note the separate `_schemaToFullExample` (:542) *does* guard with `depth > 5`, so the two ref-walkers have different safety properties.
- **Postman recursion** (`postman_source.dart:64-92`) has no depth limit and no cycle guard. `containsKey('request')` ⇒ endpoint, else `containsKey('item')` ⇒ folder; an item with both, or neither, is silently dropped.
- **`json_to_dart` type inference is the weakest code in the repo.** `getInferredType` (`helpers.dart:43-53`) uses `d.runtimeType == int`, which fails for platform subtypes and returns `null` for `bool` — so bools inside lists infer as `ListType.Null`. `mergeObj:87` compares a `Type` to a `String` (`clone[k].runtimeType != 'double'`), which is **always true**, so that guard never fires — those are the 2 `unrelated_type_equality_checks`. `_generateClassDefinition:74` does a bare `Map` assignment that throws on a non-Map. Empty arrays become `List<Null>` → `List<dynamic>`. It infers from **one sample**.
- **`ConfigStorage` reads YAML with `package:yaml` but writes it by hand** (`config_storage.dart:101-132`) — a custom writer double-quoting and escaping 5 characters. A value shape the escaper misses corrupts the file. There is a recovery path (:87-97) that preserves a bad file as `.bak` rather than wiping tokens; it was added after a real incident. Don't remove it.
- **`RequestLog.fromMarkdown`** (:151-178) uses `indexOf` on raw text — a `-->` inside the JSON payload truncates it.
- Both fetchers chain raw subscripts on API JSON (`postman_fetcher.dart:32,36-38`) with no shape guards.

### TTY assumptions

The old CLAUDE.md claimed the selector sets `stdin.lineMode = false`. **It doesn't — there is no `lineMode` assignment anywhere in `lib/`.** `TerminalUtils.readKey` delegates to `package:dart_console`'s `Console().readKey()` (adopted for Windows arrow-key support).

- **Guarded:** `prompts.dart:122` (`promptPassword` falls back to visible input with a warning when `!stdin.hasTerminal`, plus a `StdinException` catch at :135), `generate_wizard.dart:121`, `:939` (`final interactive = stdin.hasTerminal` gates the callbacks passed to `TokenSession`), `:963`.
- **Not guarded:** `EndpointSelector.selectInteractively()` has **no `hasTerminal` check**, and it's reached from `generate_command.dart:194` whenever `--no-interactive` is absent. A CI run with `-c` but without `--no-interactive` calls `readKey()` on a non-TTY. `promptSelect` and `promptInput` are likewise unguarded.
- `endpoint_selector.dart:60` calls `hideCursor()` inside a `try`; verify the restore path on every early return (`promptSelect` does this correctly at `prompts.dart:76-79`).

### Duplicated logic

Copy-paste pairs that must be changed together — several admit it in their own comments:

| Concept | A | B |
|---|---|---|
| `_todayFolder()` | `generate_command.dart:342` | `serve_command.dart:240` ("Mirrors GenerateCommand._todayFolder") |
| `_resolveGenerateAction()` | `generate_command.dart:351` | `serve_command.dart:247` |
| `_openInBrowser()` | `serve_command.dart:223` | `browser_token_capture.dart:149` ("Mirrors ServeCommand._openInBrowser") |
| Secret redaction | `secret_redactor.dart` | `tools/api2dart-mcp/src/redact.ts` (drifted — see above) |
| HTTP method parsing | `postman_source.dart:153` switch | `resend_command.dart:103` `firstWhere` + `login_config.dart:113` loop |

## Release & publishing

- **Versioning is single-sourced at runtime.** `version.dart` has no version constant — `packageVersion` lazily reads the bundled `pubspec.yaml`, first by resolving `package:api_to_dart/api_to_dart.dart` and walking up from `lib/`, then by walking up ≤5 levels from `Platform.script`. So `pubspec.yaml:3` is the only hand-maintained version.
- **The trap is not desync, it's the silent `0.0.0` fallback.** If neither lookup finds the pubspec — including if the barrel `lib/api_to_dart.dart` is ever renamed, since that path is hardcoded — `packageVersion` becomes `'0.0.0'`, and `UpdateChecker.isNewer('0.0.0', …)` is always true, so the user gets a permanent bogus "update available" nag. Nothing logs when the fallback fires.
- `UpdateChecker` GETs `pub.dev/api/packages/api_to_dart` with a 3s timeout and a 1-day cache in `~/.api2dart/update_check.json`. `isNewer` compares only the three numeric semver parts and strips anything after `-`/`+`, so **`0.7.0-beta` and `0.7.0` compare equal**.
- **`.pubignore` replaces `.gitignore` entirely for publishing.** This bit once already: `node_modules` (52 MB) shipped because git-ignored ≠ pub-ignored, and excluding `tools/` dropped the archive to 137 KB. **Any new gitignored directory must be re-listed in `.pubignore` or it ships.** `.pubignore` currently does not list `.claude/` or `.mcp.json`.
- `CHANGELOG.md` is Keep-a-Changelog style (`## <version>` + `### Added`/`### Fixed`). **0.5.0 is absent from the file** — unclear whether skipped or undocumented.
- **Publishing is manual and unscripted** — no CI workflow, no publish script. The sequence from git history is: bump `pubspec.yaml:3` → add a CHANGELOG section → commit → `dart pub publish`.

## Working agreements

- **Verify with `dart analyze` *and* `dart test`.** Both. Report the analyze delta against the 20-issue baseline, not the raw count.
- **Report bugs; don't opportunistically fix them.** Surface findings with `file:line` and wait for the go-ahead — including the confirmed `request_log.dart:73` bug above.
- **Don't mass-modernize.** Match the file you're editing. New subsystems may use modern Dart; old ones stay as they are.
- **Touching redaction, the gitignore guard, token storage, or MCP path confinement is security work.** Say what invariant you're preserving.
