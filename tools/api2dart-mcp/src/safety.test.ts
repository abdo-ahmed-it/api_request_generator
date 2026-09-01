import assert from "node:assert/strict";
import { test } from "node:test";

import { generateArgs, matchesFilter, type EndpointReport } from "./api2dart.js";
import { MAX_OUTPUT_BYTES, ToolError, capOutput, resolveInsideProject, run } from "./safety.js";

const ROOT = process.cwd();

test("paths inside the project resolve", async () => {
  assert.ok((await resolveInsideProject(ROOT, "package.json")).endsWith("package.json"));
});

test("traversal out of the project is refused", async () => {
  await assert.rejects(() => resolveInsideProject(ROOT, "../../../../etc/passwd"), ToolError);
  await assert.rejects(() => resolveInsideProject(ROOT, "/etc/passwd"), ToolError);
});

test("a not-yet-existing path inside the project is allowed", async () => {
  assert.ok(await resolveInsideProject(ROOT, "api2dart/2099-01-01/actions"));
});

test("arguments are passed as an array, never through a shell", async () => {
  // If this went through a shell, the metacharacters would be interpreted.
  const { stdout } = await run("echo", ["; rm -rf /", "&& whoami"], { timeoutMs: 5000 });
  assert.match(stdout, /; rm -rf \/ && whoami/);
});

test("a command that exceeds its timeout raises ToolError", async () => {
  await assert.rejects(() => run("sleep", ["5"], { timeoutMs: 300 }), ToolError);
});

test("output over the cap is trimmed with a notice", () => {
  const out = capOutput("x".repeat(MAX_OUTPUT_BYTES + 500));
  assert.ok(Buffer.byteLength(out, "utf8") < MAX_OUTPUT_BYTES + 300);
  assert.match(out, /\[TRUNCATED\]/);
});

test("output under the cap is untouched", () => {
  assert.equal(capOutput("small"), "small");
});

test("generate args always force non-interactive", () => {
  const args = generateArgs({ source: "openapi", config: "s.json", json: true, dryRun: false });
  assert.ok(args.includes("--no-interactive"));
  assert.ok(args.includes("--json"));
  // Each value is its own element, so it can never be re-parsed as syntax.
  assert.ok(args.includes("s.json"));
});

test("apidog without a config omits -c, so the CLI replays the bound project", () => {
  const args = generateArgs({ source: "apidog", json: true, dryRun: false });
  assert.ok(!args.includes("-c"));
  assert.ok(args.includes("--no-interactive"));
  assert.deepEqual(args.slice(0, 3), ["generate", "-s", "apidog"]);
});

test("a config is still passed through when one is given", () => {
  const args = generateArgs({ source: "apidog", config: "spec.json", json: true, dryRun: false });
  const flag = args.indexOf("-c");
  assert.notEqual(flag, -1);
  // The path must be its own argv element, never spliced into the flag.
  assert.equal(args[flag + 1], "spec.json");
});

test("run() forces the cleartext-config token fallback off", async () => {
  // The CLI falls back to the token in .api2dart/config.yaml when none is
  // passed. This server refuses to read that file, so every spawn must carry
  // API2DART_NO_CONFIG_TOKEN=1 or that refusal is bypassed indirectly.
  const { stdout } = await run(process.execPath, [
    "-e",
    "process.stdout.write(String(process.env.API2DART_NO_CONFIG_TOKEN))",
  ]);
  assert.equal(stdout.trim(), "1");
});

test("a caller-supplied env cannot clear the token guard", async () => {
  const { stdout } = await run(
    process.execPath,
    ["-e", "process.stdout.write(String(process.env.API2DART_NO_CONFIG_TOKEN))"],
    { env: { ...process.env, API2DART_NO_CONFIG_TOKEN: "0" } },
  );
  assert.equal(stdout.trim(), "1");
});

test("filter matches path and name, case-insensitively", () => {
  const endpoint = { path: "/client/attention-requests", name: "GetForm" } as EndpointReport;
  assert.equal(matchesFilter(endpoint, "ATTENTION"), true);
  assert.equal(matchesFilter(endpoint, "getform"), true);
  assert.equal(matchesFilter(endpoint, "; rm -rf /"), false);
  assert.equal(matchesFilter(endpoint, undefined), true);
});
