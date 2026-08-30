import assert from "node:assert/strict";
import { test } from "node:test";

import {
  PLACEHOLDER,
  isSecretKey,
  redactHeaderBlock,
  redactJson,
  redactMarkdown,
  redactText,
  stripResendMetadata,
  truncateArrays,
} from "./redact.js";

// Shapes below mirror what real api2dart logs contain. Values are fake.
const FAKE_SANCTUM = "999|EXAMPLEfaketokenvalue0000000";
const FAKE_UUID = "00000000-1111-2222-3333-444444444444";

test("secret keys are recognised case-insensitively", () => {
  for (const key of ["Authorization", "X-API-KEY", "x-secret-key", "Cookie", "refresh_token"]) {
    assert.equal(isSecretKey(key), true, key);
  }
  for (const key of ["Content-Type", "name", "id"]) {
    assert.equal(isSecretKey(key), false, key);
  }
});

test("bearer tokens are redacted, including the duplicated form", () => {
  assert.equal(redactText(`Bearer ${FAKE_SANCTUM}`), PLACEHOLDER);
  assert.equal(redactText(`Bearer Bearer ${FAKE_SANCTUM}`), PLACEHOLDER);
});

test("bare sanctum tokens are redacted", () => {
  assert.equal(redactText(`token is ${FAKE_SANCTUM}`), `token is ${PLACEHOLDER}`);
});

test("credentials in a URL query string are redacted", () => {
  assert.equal(
    redactText("https://api.example.com/x?token=abc123&page=2"),
    `https://api.example.com/x?token=${PLACEHOLDER}&page=2`,
  );
  assert.equal(
    redactText("https://api.example.com/x?api_key=zzz"),
    `https://api.example.com/x?api_key=${PLACEHOLDER}`,
  );
});

test("ordinary text is untouched", () => {
  assert.equal(redactText("just a name"), "just a name");
  assert.equal(redactText("https://api.example.com/users?page=2"), "https://api.example.com/users?page=2");
});

test("header blocks keep names and drop values", () => {
  const out = redactHeaderBlock(
    [`x-api-key: ${FAKE_UUID}`, "Content-Type: application/json"].join("\n"),
  );
  assert.match(out, /x-api-key: <redacted>/);
  assert.match(out, /Content-Type: application\/json/);
});

test("json is redacted at any depth", () => {
  const out = redactJson({ id: 1, user: { refresh_token: "x", name: "Sara" } }) as any;
  assert.equal(out.id, 1);
  assert.equal(out.user.refresh_token, PLACEHOLDER);
  assert.equal(out.user.name, "Sara");
});

test("translation objects survive - they are shape, not secrets", () => {
  const out = redactJson({ name: { ar: "سكن", en: "Housing" } }) as any;
  assert.equal(out.name.en, "Housing");
});

test("arrays are truncated with the total preserved", () => {
  const out = truncateArrays(Array.from({ length: 20 }, (_, i) => ({ id: i }))) as unknown[];
  assert.equal(out.length, 3);
  assert.match(String(out[2]), /total 20/);
});

test("resend metadata is stripped entirely", () => {
  const md = `# x\n\n<!-- api2dart:request {"headers":{"Authorization":"Bearer ${FAKE_SANCTUM}"}} -->`;
  const out = stripResendMetadata(md);
  assert.equal(out.includes("api2dart:request"), false);
  assert.equal(out.includes(FAKE_SANCTUM), false);
});

test("a full log leaks nothing - fences and prose alike", () => {
  const md = [
    "# get_form_data",
    "",
    `> \`GET\` https://api.example.com/f?token=leakedquery - 120ms`,
    "",
    "```http",
    `x-api-key: ${FAKE_UUID}`,
    `Authorization: Bearer Bearer ${FAKE_SANCTUM}`,
    "```",
    "",
    "```json",
    '{"rows":[1,2,3,4,5],"access_token":"leakedbody"}',
    "```",
    "",
    "```bash",
    `curl -H 'Authorization: Bearer ${FAKE_SANCTUM}'`,
    "```",
    "",
    `<!-- api2dart:request {"h":"${FAKE_SANCTUM}"} -->`,
  ].join("\n");

  const out = redactMarkdown(md);

  for (const secret of [FAKE_UUID, FAKE_SANCTUM, "leakedquery", "leakedbody", "api2dart:request"]) {
    assert.equal(out.includes(secret), false, `leaked: ${secret}`);
  }
  // Structure survives.
  assert.match(out, /x-api-key: <redacted>/);
  assert.match(out, /total 5/);
});

test("malformed json in a fence still cannot leak", () => {
  const md = ["```json", `{"broken": ${FAKE_SANCTUM}`, "```"].join("\n");
  assert.equal(redactMarkdown(md).includes(FAKE_SANCTUM), false);
});
