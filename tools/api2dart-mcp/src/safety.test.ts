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

test("filter matches path and name, case-insensitively", () => {
  const endpoint = { path: "/client/attention-requests", name: "GetForm" } as EndpointReport;
  assert.equal(matchesFilter(endpoint, "ATTENTION"), true);
  assert.equal(matchesFilter(endpoint, "getform"), true);
  assert.equal(matchesFilter(endpoint, "; rm -rf /"), false);
  assert.equal(matchesFilter(endpoint, undefined), true);
});
