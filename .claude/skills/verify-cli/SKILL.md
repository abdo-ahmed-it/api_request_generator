---
name: verify-cli
description: Verify a change to the api_to_dart CLI by actually running it — analyze delta against the known baseline, the Dart test suite, the MCP server's own tests, and a real end-to-end invocation. Use after editing anything under lib/, bin/, or tools/api2dart-mcp/, and before reporting a change as done.
---

# verify-cli

`dart analyze` proves the code parses. It does not prove the flag is wired, the
exit code is right, the JSON payload is still parseable, or that the tool doesn't
hang on a CI box. This skill closes that gap.

**The whole `cli/` layer has no dedicated test file** — all 6 commands, `cli_app`,
the 1239-line wizard, the selector, prompts, the file browser. If you changed
something there, running it *is* the test.

## 1. Static + suite

```bash
python3 .claude/skills/verify-cli/scripts/check_baseline.py
```

Runs `dart analyze` and reports the **delta against the known 20-issue baseline**
(1 warning + 19 infos), so a pre-existing info doesn't read as your regression.
Exits 1 if the count rose or a new issue appeared in a file you touched.

Then the suite — this project has a real one, unlike the Flutter apps here:

```bash
dart test        # 165 tests, all passing. A break is never acceptable.
```

The run is noisy by design: `ConsoleLogger` prints boxed ANSI output, and
`browser_token_capture_test` waits a real 5 seconds for a genuine timeout. That
is expected, not failure. Read the final `All tests passed!` line.

### Baseline, for reference

| Where | Issue |
|---|---|
| `helpers.dart:5` | `PRIMITIVE_TYPES` non-lowerCamelCase |
| `helpers.dart:21…46` | 5 × `constant_identifier_names` |
| `helpers.dart:87` (×2) | `unrelated_type_equality_checks` — **a real bug**, guard never fires |
| `api_endpoint.dart:5…42` | 5 × `constant_identifier_names` — **intentional**, `HttpMethod` names match HTTP verb strings |
| `endpoint_selector.dart:194,199`, `file_browser.dart:69` | `unnecessary_brace_in_string_interps` |
| `response_resolver.dart:134,146` | `empty_catches` — real silent-failure paths |
| `openapi_source.dart:522` | `unintended_html_in_doc_comment` |
| `api_web_server_relogin_test.dart:42` | `unused_element_parameter` (warning) |

## 2. Run the thing

Pick the paths your change actually touches. Never report a CLI change as done
without at least one real invocation.

```bash
# Flag path, offline, writes nothing
dart run bin/api_to_dart.dart generate -s openapi -c <spec> --dry-run --no-interactive
echo "exit=$?"

# JSON path — stdout must be valid JSON ALONE, diagnostics on stderr
dart run bin/api_to_dart.dart generate -s openapi -c <spec> --json 2>/dev/null | python3 -m json.tool > /dev/null
echo "json ok? exit=$?"

# Help surfaces (cheap, catches a broken arg parser)
dart run bin/api_to_dart.dart --help
dart run bin/api_to_dart.dart generate --help
dart run bin/api_to_dart.dart version
```

**Check `$?` explicitly** whenever the change touches exit codes — that is the
entire point, and it is the thing this codebase most often gets wrong. Recall the
two conventions: `resend`/`serve`/`upgrade` set `exitCode` and return (correct,
with sysexits 64/65/66); `generate_command.dart` calls `exit()` at 5 sites, which
is why the update notice never fires on that path.

**The `--json` contract is load-bearing** — the MCP server parses that stdout. If
anything you added prints to stdout on the json path, you broke it. `StderrLogger`
is selected at `generate_command.dart:129` for exactly this reason.

### The wizard path

`generate` with no `--config` launches the wizard, and bare `api2dart` means
`generate`. The wizard is interactive and hits the network, so don't drive it
blindly in a verification pass — if your change is in `generate_wizard.dart`,
say explicitly whether you ran it or only reasoned about it.

### Non-TTY

If your change is anywhere near prompting, check it doesn't hang without a
terminal:

```bash
dart run bin/api_to_dart.dart generate -s openapi -c <spec> --no-interactive < /dev/null
```

`EndpointSelector.selectInteractively()`, `promptSelect`, and `promptInput` have
**no `hasTerminal` guard** and are reached whenever `--no-interactive` is absent.
That is a known gap — don't add a new unguarded prompt, and adding a guard where
you're already editing is a genuine fix.

## 3. MCP server, if touched

```bash
cd tools/api2dart-mcp
npm run build && npm test
```

**Build before test, always** — `npm test` runs `node --test dist/*.test.js`
against the *compiled* output, so a stale `dist/` silently tests the previous
version. Same reason a fresh clone's MCP server appears missing entirely:
`dist/` is gitignored but `.mcp.json` points into it.

Coverage is `safety.test.ts` and `redact.test.ts` — the two modules holding the
path-confinement and redaction invariants. A change to either ships with a test.

## 4. Security spot-check

If the diff touched redaction, logging, the gitignore guard, token handling, or
MCP path confinement, state which invariant you preserved:

- No new rendering path in `request_log.dart` that skips `SecretRedactor`.
- The hidden `api2dart:request` block still never rendered, still stripped by
  `stripResendMetadata` before any read. **Log files on disk contain live tokens** —
  that block is the one deliberate unredacted exemption.
- A redaction fix landed in **both** `secret_redactor.dart` and `redact.ts`, or
  you said why not. They have already drifted (TS has `QUERY_SECRET`; Dart's
  Bearer pattern is `\S+` vs TS's narrower charset).
- `resolveInsideProject` still realpaths first; `run()` still uses `execFile`
  with `shell: false`; the 60s / 100KB / 32MB caps unchanged.
- No new fallback reading the token from `.api2dart/config.yaml` — it is
  cleartext, and `safety.ts:49-55` refuses on purpose.

A quick grep is fair evidence:

```bash
grep -rn "SecretRedactor" lib/src/core/models/request_log.dart
grep -rn "execFile\|shell:" tools/api2dart-mcp/src/safety.ts
```

## Reporting

State what you verified and how, and be explicit about what you didn't:

- ✅ verified — analyze 20 → 20 (no delta), `dart test` 165 passed, ran
  `generate --json` and the payload parses
- ⚠️ partial — suite green and the flag path runs, but the wizard path was not
  exercised (interactive + network)
- ❌ not verified — e.g. no sample spec available to run against

Never present an unverified change as verified. "It analyzes" is not "it works",
and in this package "the tests pass" is not "the CLI still behaves" — the CLI
layer is exactly the part the tests don't cover.
