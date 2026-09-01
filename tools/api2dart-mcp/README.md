# api2dart MCP server

Exposes `api2dart`'s API-shape inspection to an agent over stdio, so an API's
real shape can be fetched mid-conversation instead of run-the-tool-then-read-
the-files.

## Why it returns JSON, not Dart

The generator infers types from one sample and knows nothing about a project's
conventions. Given `{"name": {"ar": "…", "en": "…"}}` it writes `String?`, and
the UI prints `{ar: …, en: …}` verbatim. Fixing generated Dart costs more than
writing it. So these tools hand back the JSON, the schema and the inferred
types, and the model writes the action against the project's own rules.

`--dry-run` is the default posture: the read-only tools write nothing.

## Tools

| Tool | Writes? | Use |
|---|---|---|
| `api2dart_list` | no | List endpoints. Cheap — start here. |
| `api2dart_inspect` | no | Shape of specific endpoints: params, schema, sample, notes. |
| `api2dart_read_log` | no | Read a past capture, redacted. |
| `api2dart_resend` | **yes** | Replay a saved request; overwrites the log in place. |
| `api2dart_generate` | **yes** | Write Dart files. Rare — output is a scratch draft. |

Only the three read-only tools are pre-approved in
`.claude/settings.local.json`; the two writers prompt every time.

## Security

Every payload passes a redactor before it is returned, parsed further, or
logged:

- **Headers** — `authorization`, `x-api-key`, `x-secret-key`, `cookie`,
  `proxy-authorization` are blanked by name, case-insensitively.
- **JSON keys** — anything matching `token|secret|password|api_key|
  authorization|credential|refresh|access_key`, at any depth.
- **Value shapes** — bearer tokens (including the duplicated `Bearer Bearer`
  form that appears in real logs), Laravel Sanctum `<id>|<token>`, and
  credentials in URL query strings.
- **Resend metadata** — the hidden `api2dart:request` block holds live auth
  headers for replay and is stripped entirely.

The key is kept and only the value replaced: knowing an endpoint needs auth is
structural information.

Arrays are truncated to two elements plus a count. The goal is the element
shape, not the data — this keeps context small and avoids spilling real
records into a transcript.

Other limits: 60s per call, ~100KB per payload, and every path is resolved and
confined to the project root. Commands run via `execFile` with an argument
array — never a shell — so a filter like `; rm -rf /` is inert text.

### The token

Read from `APIDOG_TOKEN`, then the macOS keychain:

```bash
security add-generic-password -s api2dart-apidog-token -a "$USER" -w '<TOKEN>'
```

It is deliberately **not** read from `.api2dart/config.yaml`, which stores it
in clear text. If neither source has it, the error explains the setup rather
than silently falling back.

That exemption covers the **credential specifically**, not the whole file. When
`config` is omitted (see below) the CLI does read that file — but only for the
non-secret binding: `apidog.last_project_id`, `apidog.environment_id` and
`apidog.environment_name`.

The CLI on its own *does* fall back to `apidog.token` when no token is passed,
which is the right default for a human at a terminal but would reintroduce the
cleartext dependency here. So `run()` sets `API2DART_NO_CONFIG_TOKEN=1` on every
spawn, which disables that fallback: a missing credential fails loudly instead
of quietly reading `config.yaml`. Removing that env var reopens the hole.

## Running without a spec file

`config` is optional for `source: "apidog"`. Omit it and the CLI replays the
project and environment bound in the wizard, exporting the spec from Apidog on
every call — nothing is cached, so the agent always sees the current shape.

Bind one first, from a terminal:

```bash
api2dart          # Apidog -> project -> environment
```

With no binding saved, the tool fails with a message pointing at the wizard. It
never prompts: an interactive fallback would hang the server, which has no
terminal attached.

Every other source still requires `config` — that is enforced in the server,
before the CLI is invoked, so the failure names the real problem.

## Build

```bash
npm install && npm run build && npm test
```

The server prefers the local checkout (`bin/api_to_dart.dart`) over a global
`api2dart`, because `generate --json` may not exist in the published release
yet.
