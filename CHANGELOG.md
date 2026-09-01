## 0.8.0

### Added
- **Machine-readable `--json` report** — `generate --json` resolves every
  endpoint and emits a single JSON document (params, response schema, a
  redacted sample, and inferred Dart types) while writing nothing to disk.
  `--dry-run` could only ever print filenames, because it exited before
  responses were resolved. Diagnostics move to stderr so stdout stays
  parseable, and `--json` now implies non-interactive as well as dry-run.
- **MCP server** (`tools/api2dart-mcp/`) — exposes endpoint inspection to an
  agent over stdio, so an API's real shape can be fetched mid-conversation.
  Five tools; `list`, `inspect` and `read_log` write nothing, while `resend`
  and `generate` write to disk and prompt every time. It deliberately returns
  JSON, schema and inferred types rather than generated Dart: the generator
  infers from one sample and knows nothing about a consuming project's
  conventions.
- **Apidog without a spec file** — `generate -s apidog` now works with no
  `--config`. It replays the project and environment bound in the wizard
  (saved in `.api2dart/config.yaml`) and exports the spec from Apidog on every
  run, so nothing is cached and no file has to exist on disk. The MCP server's
  `config` argument became optional for the same reason; every other source
  still requires it, enforced before the CLI is invoked. With no binding saved
  the command exits `64` pointing at the wizard — it never prompts, which
  would hang the server.

### Fixed
- **Secrets no longer land in Markdown logs.** `RequestLog` wrote every request
  header verbatim, so live `Authorization`, `x-api-key` and `x-secret-key`
  values were stored in clear text. `SecretRedactor` now scrubs the
  human-facing sections by key name and by value shape — bearer tokens, the
  duplicated `Bearer Bearer` form seen in real logs, and Laravel Sanctum
  tokens. Keys are kept and only values replaced, so it stays visible that an
  endpoint needs auth. The hidden resend-metadata block deliberately keeps real
  headers, since that is what makes `resend` able to replay a request.
- **Secrets inside JSON carried as a string** were invisible to redaction: the
  key holding the document is not secret-named and its value is just a string,
  so an `access_token` nested in an echoed request body reached the output in
  clear text. Such strings are now parsed, redacted and re-serialised, in both
  the Dart redactor and the MCP server's independent copy.
- **`refresh` restored as a bounded secret word** — a bare
  `{"refresh": "<token>"}` was passing through. The bounded-word gate now also
  accepts plurals: `signatures`, `sigs` and `jwts` are lists of credential
  values and were leaking, while `sessions` stays exempt.
- **Exit codes are real.** `run()` was `void run() async` in
  `generate`/`serve`/`resend`/`reset`, so `CommandRunner` could not await it —
  the async body detached and the process exited `0` regardless of `exitCode`.
  A flag typo in CI passed the build while generating nothing. `cli_app` now
  maps a usage error to `64` and an unhandled error to `70`.
- **The non-TTY guard was ineffective on macOS.** It tested `stdin.hasTerminal`
  alone, which is `true` for `< /dev/null` — the most common CI redirection —
  so the endpoint selector still blocked forever on `readKey()`. It now
  requires `stdout.hasTerminal` too.
- **`notes[]` was being truncated away.** Array truncation applied to the whole
  endpoint report, so on a 28-endpoint collection `inspect` returned 2 of 18
  findings followed by `+16 more items` — the diagnostics the tool exists to
  produce were what got discarded. Truncation is now confined to the response
  payload; `notes[]` and `headers[]` are returned in full.
- **`inferred_types` was blanked by key-based redaction.** It is keyed by
  response field, so a credential key such as `access_token` appears there too
  — but its value is a Dart type name, not sampled data, and the placeholder
  destroyed the one thing the field carries. Type names are now exempted by
  allowlist; every other path keeps blanket key-based redaction.
- **Apidog URL-variable prefixes on the non-interactive path.** Apidog leaves
  `<url_var>` as the first path segment on purpose, and the resolver that
  strips it into a per-endpoint base URL was not applied when the spec came
  from a saved binding, yielding paths like `/<url_var>/login` and a bogus
  fetch URL.
- **The wizard wrote its temporary Apidog spec into the project root** as
  `.api2dart_temp_openapi.json`, which the `.api2dart/` gitignore entry does
  not match — an environment-resolved spec containing internal base URLs could
  be committed if the process died before cleanup. The export/resolve/parse
  sequence now lives in one place and writes to the system temp directory.
- **The MCP server no longer depends on cleartext token storage indirectly.**
  It refuses to read `.api2dart/config.yaml`, but the CLI it spawns has its own
  fallback to the token stored there. Every spawn now sets
  `API2DART_NO_CONFIG_TOKEN=1`, so a missing credential fails loudly instead of
  quietly reading that file.

### Changed
- **`tools/` is excluded from the published package.** `.pubignore` replaces
  `.gitignore` entirely for publishing, so the MCP server's git-ignored
  `node_modules` was being bundled into the Dart package — 52 MB on disk, an
  8 MB archive. The archive is now 137 KB.

## 0.7.0

### Added
- **Auto re-login** — when the auth token expires, `api2dart` now mints a fresh
  one by calling your API's own login endpoint, instead of failing every
  request until you paste a new token into Apidog and re-run the wizard.
  - **Setup from the wizard**: pick your login endpoint straight out of the
    parsed tree — the method and body field names come from the spec, so you
    only fill in the values. Offered up front (opt-in, defaults to *no*) and
    again automatically the first time a 401 actually lands.
  - **Two login shapes**: single-step (e.g. `email` + `password`), and
    two-step OTP (request the code, then verify it). Store a fixed OTP code
    (e.g. `1111`) and the whole cycle runs unattended; leave it empty to be
    asked each time.
  - **Mid-run recovery**: a 401/403 pauses the run, re-authenticates, and
    retries the *same* endpoint once before continuing with the new token —
    nothing gets skipped just because the token aged out mid-batch.
  - **Bounded by design**: a failed login, or a fresh token that still gets
    rejected, stops further attempts for the rest of the run. A 50-endpoint run
    costs at most one wasted login, and a 401 that's really a permissions error
    is reported as such instead of being retried forever.
  - **Web UI**: a token chip in the top bar shows whether auth is healthy;
    click it to re-login or paste a token. Generate results now report when the
    token was refreshed mid-run, or when auth failed outright.
  - **CI-friendly**: `generate` with flags uses the same stored recipe with no
    prompts, so an expired token no longer breaks non-interactive runs.
  - **Credentials** are stored in `.api2dart/config.yaml`, namespaced per
    source. The wizard warns before collecting them, adds `.api2dart/` to your
    `.gitignore`, and never echoes passwords as you type. `api2dart reset` now
    clears them.

### Fixed
- `ConfigStorage` resolved `.api2dart/config.yaml` once and cached it for the
  process lifetime, so any later change of working directory kept reading and
  writing the original project's config.

## 0.6.0

### Added
- **Local web UI** — a browser-based, Apidog-like workspace to browse, try, and
  generate from your endpoints. Two ways in:
  - The interactive wizard (`api2dart` with no args) prints an **optional web
    link** after loading endpoints — for any source (Postman/Apidog/file). The
    terminal selector still works exactly as before; the link is an extra way
    to work in the browser. The server runs in its own isolate (so it stays
    responsive while the terminal selector is active) until `Ctrl+C`, and falls
    back to a free port if the default is busy.
  - `api2dart serve -s <source> -c <file>` opens the web UI directly for a
    **local file** (and auto-opens the browser; `--no-open` to skip,
    `-p/--port` to choose a port). For live Apidog/Postman fetch, use the
    wizard.
  - **Sidebar** mirrors the terminal selector's nested folder tree (collapsed
    by default), with live search, per-method filters, and folder/master
    checkboxes — selection state and scroll are preserved while you pick.
  - **Request builder** — editable method/URL + Params/Headers/Body/Auth tabs
    and a **Send** button that fires the real request and shows status, time,
    response headers, and syntax-highlighted JSON (Body/Headers tabs, expandable
    panel). The session token is applied automatically (Bearer) for
    authenticated endpoints; per-endpoint edits are preserved when switching.
  - **Code preview** of the generated Dart per endpoint, updated live as you
    edit output settings.
  - **Output tab** — control, per endpoint, the output directory (with a 📁
    folder picker that browses your project, plus "apply to all"), file name,
    Action/Response class names, and mode. Settings persist to
    `.api2dart/config.yaml` and prefill on the next run.
  - **Generate selected** writes the exact same `*_action.dart` /
    `*_response.dart` files and Markdown logs as the terminal `generate`.
  - Responsive layout (mobile drawer), keyboard shortcuts (`/` focuses search,
    `Ctrl/Cmd+Enter` sends), and an "already generated" marker. Loopback-only;
    works in non-TTY environments.
- **Guided browser token capture** — when no saved token exists, the
  Postman/Apidog sign-in opens a small local page that links to the provider's
  token page; paste the token there and it returns straight to the CLI (no
  terminal paste). Falls back to a terminal prompt when headless or unavailable.

### Fixed
- Apidog endpoints whose paths use a URL-variable prefix (e.g.
  `/system_user_url/login`) are now resolved consistently across the terminal
  and web flows: the prefix is stripped, the correct per-endpoint base URL is
  applied, and the name is rebuilt from the clean path. The logic lives in a
  shared `UrlVariableResolver` used by both.
- Saved settings no longer corrupt `.api2dart/config.yaml`. Stored values are
  now properly YAML-escaped, so values containing quotes round-trip safely
  instead of breaking the file (which previously wiped saved tokens on the next
  read). A config that fails to parse is preserved as a `.bak` rather than
  silently overwritten.
- A custom output file name can no longer escape the chosen output directory
  (path separators and `..` are stripped to a single safe segment).

## 0.4.0

### Added
- New `api2dart resend <log-file.md>` command. Every generated request log now
  ends with a `## Resend` section and a hidden machine-readable request block.
  Running `resend` on a log file replays the exact request (method, URL,
  headers, query, body) and overwrites the same file in place with the fresh
  status, response and timing. The file stays replayable indefinitely. The
  human-facing `## cURL` snippet is preserved for manual copy/paste.
  - On a failed request (no response), the file is left unchanged.
  - Older log files without the metadata block report a clear error pointing
    the user to re-run `generate`.

## 0.3.2

### Fixed
- Endpoints sharing a path but differing in HTTP method (e.g. `GET /users`
  and `POST /users`) no longer overwrite each other. Generated action and
  file names are now prefixed with the method
  (`GetUsersAction` / `get_users_action.dart`,
  `PostUsersAction` / `post_users_action.dart`). The prefix is skipped when
  the name already starts with the method to avoid duplication like
  `GetGetUsers`.
- Fixed structural equality in the json_to_dart model deduplication.
  `TypeDefinition` / `ClassDefinition` declared a method named `operator`
  instead of overriding `operator ==`, so `==` fell back to identity and
  identical nested objects were never merged — emitting duplicate suffixed
  classes (`Data2`, `Links2`) plus orphan, never-referenced classes.
  Structurally identical objects now collapse to one class while distinct
  same-named objects still get distinct names.

## 0.3.1

### Changed
- Running `api2dart` with no arguments now launches the interactive
  wizard directly instead of printing the usage screen. All other
  commands and flags (`--help`, `version`, `upgrade`, etc.) behave
  exactly as before.

## 0.3.0

### New
- `version` subcommand — prints the installed version.
- `upgrade` subcommand — pulls the latest release from pub.dev.
- Automatic update notice after any command when a newer version
  is available on pub.dev.

### Changed
- Request logs are now Markdown (`.md`) instead of plain `.log`, with
  formatted sections for URL, headers, request body, status code, and
  response body.
- Generated files are written under a dated subfolder
  (`<output>/<YYYY-MM-DD>/actions/` and `.../logs/`) so repeated runs
  don't overwrite previous outputs. The default `--output` is now
  `api2dart` (was `lib/actions`).

## 0.2.0

**Renamed package** from `api_request_generator` to `api_to_dart`. The
executable is now `api2dart` and the per-project config directory is
`.api2dart/` (the previous `.apigen/` is no longer read or written).

### New
- `reset` subcommand for clearing saved settings. Defaults to wiping
  wizard selections only; pass `--all` to also remove saved
  Postman/Apidog tokens, or `-y` to skip the confirmation prompt.
- Postman environments — after picking a workspace the wizard now
  fetches its environments, lets you pick one (or skip), and merges
  the variables on top of any collection-level variables before
  resolving `base_url` / `token`.
- Response-only output mode for projects that don't depend on
  `api_request`. Auto-detected from the host `pubspec.yaml`; override
  with `-m, --mode={auto,action,response-only}`. In response-only mode
  files are written as `*_response.dart` (no `api_request` import) and
  endpoints with no response data are skipped.

### Fixed
- Postman collections list parsing: the API returns the array under
  the `collections` key (plural). The previous code read `collection`
  (singular) and always saw an empty list.
- Stop auto-clearing saved API tokens after a failed request. Network
  glitches or rate limits used to wipe a valid key; now the user is
  pointed at `api2dart reset --all` instead.

### Changed
- The `--reset` flag on `generate` was replaced by the standalone
  `reset` subcommand.
- Wizard banner, help text, and saved-settings paths updated for the
  new name.

## 0.1.0

- Initial release
- Multi-source support: Postman collections, OpenAPI 3.x specs, Apidog projects, local YAML files
- Apidog integration: fetch projects, environments, and variables via API
- Interactive terminal endpoint selector with tree navigation
- Smart response resolution: live fetch → example → schema → action-only
- Request logging with detailed .log files per endpoint
- Dart model generation with fromJson/toJson from actual API responses
- Auto-resolve environment variables from Apidog
- Settings persistence per-project in .apigen/config.yaml
- Support for all HTTP methods: GET, POST, PUT, PATCH, DELETE
- PascalCase naming with smart path-based name generation
- Handles duplicate class names and null types in generated models
