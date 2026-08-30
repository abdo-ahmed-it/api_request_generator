# API to Dart

A Dart CLI tool (`api2dart`) that turns any API — **Postman**, **OpenAPI**, **Apidog**, or a **YAML** file — into type-safe Dart code: request actions + response models, or response models only. Pick endpoints in an interactive terminal selector **or a local web UI**.

## Features

- **Multi-source** — Postman collections, OpenAPI 3.x specs, Apidog projects, local YAML
- **Live fetch from Postman/Apidog** — browse workspaces, projects, environments, and collections from their APIs (no manual export)
- **Two ways to pick endpoints** — an interactive terminal tree, or a browser-based web UI
- **Web UI** — search/filter endpoints, **try requests live**, preview the generated Dart, control output names/paths, and generate — all from the browser
- **Smart response resolution** — live fetch → example → schema → fallback
- **Auto re-login** — when your token expires mid-run, it logs in again through your own API (password or OTP) and carries on, instead of failing every request
- **Two output modes** — Action + Response (when `api_request` is in your pubspec) or Response-only, auto-detected
- **Markdown request logs** with a built-in `resend` to replay any request
- **Settings persistence** — per project in `.api2dart/config.yaml`

## Installation

```yaml
dev_dependencies:
  api_to_dart:
    git:
      url: https://github.com/abdo-ahmed-it/api_to_dart.git
```

```bash
dart pub get
```

Or activate globally to use the `api2dart` command anywhere:

```bash
dart pub global activate api_to_dart
```

## Quick Start

Run with no arguments to launch the interactive wizard:

```bash
dart run api_to_dart generate     # or just: api2dart
```

The wizard walks you through:

1. **Select source** — local file, Postman API, or Apidog API
2. **Sign in** (Postman/Apidog) — a guided browser flow opens the provider's token page; paste the token once and it's saved for next time
3. **Select endpoints** — interactive tree, or open the printed **web UI** link
4. **Generate** — files are written under `api2dart/<date>/actions/`, with request logs under `api2dart/<date>/logs/`

Next runs go straight to endpoint selection — your source, project/environment, and tokens are saved in `.api2dart/config.yaml`.

### Web UI

After the wizard loads endpoints it prints an optional link (e.g. `http://127.0.0.1:4321`). Open it for a richer, Apidog-like workspace:

- **Sidebar** — endpoint tree with live search, per-method filters, and folder/select-all checkboxes
- **Request builder** — editable method/URL + Params / Headers / Body / Auth tabs, and a **Send** button that fires the real request and shows the live status, time, headers, and JSON
- **Code** — live preview of the generated Dart for the selected endpoint
- **Output** — per-endpoint output dir (with a 📁 folder picker), file name, Action/Response class names, and mode; **Generate selected** writes the files
- **Generate selected** writes the exact same files as the terminal flow

You can also open the web UI directly for a local file (without the wizard):

```bash
api2dart serve -s openapi -c openapi.yaml -b https://api.example.com
```

`serve` parses a local file only. For live Apidog/Postman fetch, use `generate` — its wizard prints the same link.

### Non-interactive (CI / scripting)

```bash
# Generate every endpoint from a Postman collection
api2dart generate -s postman -c collection.json -b https://api.example.com --no-interactive

# Force response-only mode
api2dart generate -s openapi -c openapi.yaml -m response-only --no-interactive

# Preview without writing files
api2dart generate -s postman -c collection.json --dry-run --no-interactive
```

### Replay a request

Every generated log embeds the request, so you can re-run it and refresh the log in place:

```bash
api2dart resend api2dart/<date>/logs/get_users_action.md
```

### Manage settings & version

```bash
api2dart reset            # clear wizard selections (keeps saved tokens)
api2dart reset --all      # also delete saved Postman/Apidog tokens
api2dart version          # show the installed version
api2dart upgrade          # update to the latest version on pub.dev
```

## Commands & flags

### `generate` — main command (wizard when no `-c`)

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--source` | `-s` | | `postman`, `openapi`, `apidog`, `file` |
| `--config` | `-c` | | Collection/spec file. Omit to launch the wizard |
| `--output` | `-o` | `api2dart` | Root output dir (a dated `actions/`+`logs/` subfolder is created inside) |
| `--base-url` | `-b` | | Base URL for live response fetch |
| `--token` | `-t` | | Auth token for live fetch |
| `--mode` | `-m` | `auto` | `auto`, `action`, or `response-only` |
| `--no-interactive` | | `false` | Generate all, skip the selector (for CI/non-TTY) |
| `--dry-run` | | `false` | Preview without writing |

### `serve` — local web UI for a file

Same source flags as `generate` (requires `-s` and `-c`), plus:

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--port` | `-p` | `4321` | Web UI port |
| `--open` | | `true` | Auto-open the browser (`--no-open` to skip) |

### `resend` / `reset` / `version` / `upgrade`

- `api2dart resend <log-file.md>` — replay a logged request and rewrite the log in place
- `api2dart reset [--all] [-y]` — clear saved settings and login credentials (`--all` also removes API tokens; `-y` skips the prompt)
- `api2dart version` (`-v`) — show version and check for updates
- `api2dart upgrade [-f]` — self-update from pub.dev

## Terminal selector keys

| Key | Action |
|-----|--------|
| `↑` `↓` | Move |
| `Space` | Toggle endpoint (or the whole folder when on a folder) |
| `→` / `←` | Expand / collapse folder |
| `a` / `n` | Select all / none |
| `Enter` | Generate selected |
| `q` / `Esc` | Quit |

## Output modes

Auto-detected from your `pubspec.yaml`; override with `-m`.

**Action + Response** (when `api_request` is present) — each endpoint becomes a file with an `ApiRequestAction` subclass and its response model:

```dart
import 'package:api_request/api_request.dart';

class LoginAction extends ApiRequestAction<LoginResponse> {
  @override
  RequestMethod get method => RequestMethod.POST;
  @override
  String get path => '/auth/login';
  @override
  ResponseBuilder<LoginResponse> get responseBuilder =>
      (json) => LoginResponse.fromJson(json);
}

class LoginResponse {
  bool? status;
  String? message;
  Data? data;
  // fromJson / toJson
}
```

**Response-only** (when `api_request` is missing) — only the model, written as `*_response.dart` with no `api_request` import. Endpoints with no response data are skipped.

## Output layout & logs

Each run writes to a dated folder so previous output isn't overwritten:

```
api2dart/
  <YYYY-MM-DD>/
    actions/   # *_action.dart  (or *_response.dart in response-only mode)
    logs/      # *.md           (one Markdown log per request)
```

Each log is Markdown with the method/URL/status/timing, request headers/query/body, the response, a ready-to-run **cURL** snippet, a **Resend** snippet, and a hidden metadata block that powers `api2dart resend`. Failed (non-2xx) requests are logged but skip code generation.

## Response resolution

Each endpoint's response is resolved in priority order:

1. **Live fetch** — sends the real request (best models) when a base URL is set
2. **Example** — from the OpenAPI spec or a Postman saved response
3. **Schema** — synthetic JSON from the OpenAPI schema
4. **Fallback** — `dynamic` (action mode) or skip the file (response-only)

> Apidog projects that use URL-variable path prefixes are resolved automatically (the prefix is stripped and the correct per-endpoint base URL is applied) so terminal, web UI, and generated code all match.

## Auto re-login

Live fetch needs a valid token. When the one from your Apidog/Postman environment expires, every request returns 401 — and the usual fix is to open Apidog, paste a fresh token, and start over.

Instead, let `api2dart` log in through your own API:

```
? Set up auto re-login? (recovers on its own when this token expires) (y/N) y
? How does login work?  → Single step (e.g. email + password)
? Which endpoint?       → POST /auth/login        ← picked from your endpoint tree
? email                 → dev@example.com
? password              → ••••••
  Trying it out…
  ✓ Login works — got a token (eyJh…4f2a)
  ✓ Token found at "data.token"
  ✓ Added .api2dart/ to .gitignore
```

The endpoint comes straight from the parsed tree, so the method and body field names are read from the spec — you only fill in values. The recipe is verified once before it's saved.

From then on, an expired token repairs itself mid-run:

```
↻ GetProfile: token rejected (401) — re-authenticating…
✓ Re-authenticated — got a fresh token.
```

The failing endpoint is retried once, then the run continues with the new token — nothing is skipped just because the token aged out halfway through.

**OTP logins** are supported as a two-step flow (request the code → verify it). Store a fixed code for your dev environment and the whole cycle runs unattended; leave it blank to be prompted each time.

**It won't spin.** If the login itself fails, or a brand-new token is still rejected (a permissions problem, not expiry), it stops trying for the rest of the run and says so. A 50-endpoint run costs at most one wasted login attempt.

**In the web UI**, a token chip in the top bar shows whether auth is healthy — click it to re-login or paste a token. Generate results report when the token was refreshed mid-run.

**In CI**, `generate` with flags uses the same saved recipe without prompting, so an expired token no longer breaks non-interactive runs.

> **Credentials** are stored in plain text in `.api2dart/config.yaml`, namespaced per source. The wizard warns you before collecting them, adds `.api2dart/` to your `.gitignore`, and never echoes passwords as you type — but use development accounts. `api2dart reset` clears them.

## Requirements

- Dart SDK >= 3.6.2
- Postman integration: an API key from [Postman API keys](https://postman.co/settings/me/api-keys)
- Apidog integration: an API Access Token from [Apidog Settings](https://app.apidog.com/settings/api-access-token)
- Action mode needs the [`api_request`](https://pub.dev/packages/api_request) package; response-only mode has no runtime dependencies

## License

See [LICENSE](LICENSE).
