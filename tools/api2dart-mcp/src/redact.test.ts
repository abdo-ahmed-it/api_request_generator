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

test("inferred_types keeps type names under credential keys", () => {
  // `inferred_types` is keyed by response field, so `access_token` appears
  // there — but its value is a Dart type name, not a token. Blanket key
  // redaction blanked it and destroyed what the field exists to carry.
  const out = redactJson({
    inferred_types: {
      access_token: "String",
      expires_at: "int",
      scopes: ["String"],
      nested: { session: "String" },
    },
  }) as any;
  assert.equal(out.inferred_types.access_token, "String");
  assert.equal(out.inferred_types.expires_at, "int");
  assert.deepEqual(out.inferred_types.scopes, ["String"]);
  assert.equal(out.inferred_types.nested.session, "String");
});

test("inferred_types still redacts a value that is not a type name", () => {
  // The exemption is an allowlist of type names, not a blanket pass on the
  // subtree: a real value appearing there is still redacted.
  const out = redactJson({
    inferred_types: { access_token: `Bearer ${FAKE_UUID}` },
  }) as any;
  assert.notEqual(out.inferred_types.access_token, `Bearer ${FAKE_UUID}`);
});

test("a credential key outside inferred_types is still redacted", () => {
  const out = redactJson({ response: { access_token: "String" } }) as any;
  assert.equal(out.response.access_token, PLACEHOLDER);
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

test("fields that merely describe a credential keep their shape", () => {
  // Substring matching on session/signature/refresh redacted these, shredding
  // the response shape this server exists to deliver.
  const out = redactJson({
    session_count: 3,
    signature_required: true,
    refresh_interval: 30,
    sessions: [{ id: 1, duration: 60 }],
  }) as Record<string, unknown>;

  assert.equal(out.session_count, 3);
  assert.equal(out.signature_required, true);
  assert.equal(out.refresh_interval, 30);
  assert.deepEqual(out.sessions, [{ id: 1, duration: 60 }]);
});

test("a descriptor never un-redacts an always-credential word", () => {
  // The descriptor veto fired on any segment match, so a key ending in
  // token/password/api_key escaped entirely. `token_type` is a field of every
  // OAuth2 token response (RFC 6749) — these are ordinary shapes.
  const out = redactJson({
    session_token_type: "sess_live_ABCDEF0123",
    api_key_status: "sk_live_9988776655443322",
    password_valid: "hunter2plaintext",
    auth_status_token: "opaqueLIVEvalue0123456789",
    access_token_type: "opaqueLIVEjwtvalue",
    token_url: "https://a.co/cb?code=LIVE",
  }) as Record<string, unknown>;

  for (const [key, value] of Object.entries(out)) {
    assert.equal(value, PLACEHOLDER, `leaked: ${key}`);
  }
});

test("credential spellings of those same words are still redacted", () => {
  const out = redactJson({
    session: "sess_1",
    session_id: "sess_2",
    sessionId: "sess_3",
    signature: "sig_live",
    refresh_token: "rt_live",
  }) as Record<string, unknown>;

  for (const [key, value] of Object.entries(out)) {
    assert.equal(value, PLACEHOLDER, `leaked: ${key}`);
  }
});

test("query names the key rule agrees with", () => {
  // Spelling the credential words out separately let these slip through.
  for (const url of [
    "https://api.example.com/x?authToken=abc123",
    "https://api.example.com/x?authorization=abc123",
    "https://api.example.com/x?credentials=abc123",
  ]) {
    assert.equal(redactText(url).includes("abc123"), false, `leaked in: ${url}`);
  }

  // ...while ordinary parameters keep their values.
  const plain = "https://api.example.com/posts?author=bob&page=2";
  assert.equal(redactText(plain), plain);
});

test("Dart and TS agree on which keys are secret", () => {
  // These expectations are duplicated in
  // test/core/models/secret_redactor_test.dart; the two implementations are
  // deliberately separate, so they must be changed together.
  for (const key of [
    "X-Session", "session_id", "authToken", "auth_method", "signature", "credentials",
    // A descriptor must not un-redact an always-credential word.
    "session_token_type", "api_key_status", "password_valid", "access_token_type", "token_url",
  ]) {
    assert.equal(isSecretKey(key), true, `should be secret: ${key}`);
  }
  for (const key of ["session_count", "signature_required", "refresh_interval", "auth_type", "author", "authority"]) {
    assert.equal(isSecretKey(key), false, `should not be secret: ${key}`);
  }
});

test("a credential nested inside another parameter value is found", () => {
  // An outer non-secret parameter used to swallow the whole nested URL, so its
  // inner api_key survived. OAuth redirect_uri values carry exactly this shape.
  const out = redactText(
    "https://auth.example.com/authorize?client_id=abc" +
      "&redirect_uri=https://app.example.com/cb?api_key=LIVE_NESTED_KEY" +
      "&scope=read",
  );

  assert.equal(out.includes("LIVE_NESTED_KEY"), false);
  assert.equal(out.includes("client_id=abc"), true);
  assert.equal(out.includes("scope=read"), true);
});

test("a token delivered in the URL fragment is redacted", () => {
  // OAuth2 implicit flow returns the token after `#`.
  const out = redactText(
    "https://app.co/cb#access_token=LIVE_IMPLICIT&token_type=bearer",
  );

  assert.equal(out.includes("LIVE_IMPLICIT"), false);
  assert.match(out, /access_token=<redacted>/);
});

test("a line-start quoted marker with prose after it keeps the log", () => {
  // The previous tests placed the marker mid-line, which the `(^|\n)` anchor
  // can never match — so they passed vacuously and did not pin this at all.
  // These tails are the realistic pasted-excerpt shapes that were destroyed.
  // The tail must sit on the marker's OWN line, separated by a space. An
  // earlier version put a newline there, which `[ \t]+` can never match — so
  // the assertion passed for a structural reason regardless of the tail, and
  // never exercised the branch it claimed to pin.
  const tails = [
    '{"a": 1}\n\n## Response\nstill here\n\nEnd of log.',
    "{tbl}\n\n| col |\n| --- |\n| val |",
    "/v1/users\n\n## Notes\nkept",
    "see the docs for details\n\n## Notes\nkept",
  ];

  for (const tail of tails) {
    const md = `# Log\n\n<!-- api2dart:request ${tail}`;
    const out = stripResendMetadata(md);

    assert.match(out, /# Log/, `heading lost for tail: ${tail}`);
    // Everything after the quoted marker must survive.
    const lastLine = tail.trim().split("\n").pop()!;
    assert.equal(
      out.includes(lastLine),
      true,
      `content destroyed after quoted marker; tail was: ${JSON.stringify(tail)}`,
    );
  }
});

test("a truncated legacy raw-JSON block is still stripped", () => {
  // Logs written before the base64 encoding carry a raw JSON payload whose
  // first key is always `requestName`. Narrowing the pattern to that key must
  // not stop those from being stripped.
  const md =
    '# log\nbody\n<!-- api2dart:request {"requestName":"login","headers":' +
    '{"Authorization":"Bearer LIVE_LEGACY_TOKEN"}';

  const out = stripResendMetadata(md);

  assert.equal(out.includes("LIVE_LEGACY_TOKEN"), false);
  assert.equal(out.includes("api2dart:request"), false);
  assert.match(out, /body/);
});

test("a single-encoded key=value opening a value is still caught", () => {
  // QUERY_PARAM needs a leading ?&#; so a decoded fragment that *opens* with
  // the pair matched nothing and leaked straight through.
  for (const url of [
    "https://a.co/cb?state=api_key%3DLIVE_A",
    "https://a.co/cb?state=access_token%3DLIVE_B",
    "https://a.co/cb?cb=done%20api_key%3DLIVE_C",
  ]) {
    const out = redactText(url);
    assert.equal(out.includes("LIVE_"), false, `leaked in: ${url}`);
  }
});

test("a body quoting the marker does not truncate the log", () => {
  // Anchoring on any surviving marker deleted everything after it, so a
  // response body merely mentioning the marker text silently ate the rest.
  const md = [
    "# log",
    "",
    "## Response",
    "```json",
    '{"note": "see <!-- api2dart:request for details", "count": 42}',
    "```",
    "",
    "## Notes",
    "still here",
  ].join("\n");

  const out = redactMarkdown(md);

  assert.match(out, /## Notes/);
  assert.match(out, /still here/);
});

test("a quoted marker before a real block keeps the surrounding content", () => {
  const payload = Buffer.from(JSON.stringify({ headers: {} })).toString("base64");
  const md = [
    "# log",
    "",
    'body mentions <!-- api2dart:request in prose',
    "",
    "## Notes",
    "kept",
    "",
    `<!-- api2dart:request b64:${payload} -->`,
  ].join("\n");

  const out = redactMarkdown(md);

  assert.match(out, /## Notes/);
  assert.match(out, /kept/);
  assert.equal(out.includes(payload), false);
});

test("nested URL redaction is iterative, not recursive", () => {
  // A recursive implementation threw RangeError at ~6 KB of `?a=?a=`, and an
  // overflow means no redaction runs at all.
  const chain = "?a=".repeat(4000);
  assert.doesNotThrow(() => redactText(`https://a.co/${chain}z`));

  const deep =
    "https://a.co/?next=https://b.co/?next=https://c.co/?next=https://d.co/?token=DEEP_LIVE";
  assert.equal(redactText(deep).includes("DEEP_LIVE"), false);
});

test("percent-encoded nested URLs and names are classified", () => {
  // A real OAuth redirect_uri is percent-encoded — that is the spec-required
  // form, and a raw scan never sees the inner api_key.
  const encoded =
    "https://a.co/x?redirect_uri=https%3A%2F%2Fb.co%2Fcb%3Fapi_key%3DLIVE_ENC";
  assert.equal(redactText(encoded).includes("LIVE_ENC"), false);

  // `%5F` is `_`, so `api%5Fkey` is `api_key`.
  assert.equal(redactText("https://a.co/x?api%5Fkey=LIVE_NAME").includes("LIVE_NAME"), false);
});

test("a doubly-encoded nested credential is still found", () => {
  // %2520 decodes to %20, so one pass is not enough; the loop must keep going
  // while decoding still changes the value.
  const out = redactText(
    "https://a.co/x?redirect_uri=https%253A%252F%252Fb.co%252Fcb%253Fapi_key%253DLIVE_DBL",
  );

  assert.equal(out.includes("LIVE_DBL"), false);
});

test("an encoded value carrying no secret is left exactly as it was", () => {
  // Decoding is for classification only. Writing the decoded form back turned
  // an opaque blob into plaintext and let crafted values inject structural
  // markers past the strip and fence phases.
  const url = "https://a.co/x?redirect_uri=https%3A%2F%2Fb.co%2Fcb";

  assert.equal(redactText(url), url);
});

test("decoding never emits a credential that was encoded", () => {
  // The decoded form has no `?&#;` before the inner key, so nothing downstream
  // could redact it — the write-back actively created a plaintext leak.
  const out = redactText('?data=%7B%22api_key%22%3A%22LIVE_SECRET%22%7D');

  assert.equal(out.includes("LIVE_SECRET"), false);
  assert.equal(out.includes("api_key"), false, "decoded form must not be emitted");
});

test("decoding cannot inject structural markers into processed output", () => {
  // redactText runs after stripResendMetadata and after the fence split, so
  // anything decoding produces is never re-examined.
  const marker = redactMarkdown(
    "# log\n\nsee https://a.co/x?next=%3C!--%20api2dart%3Arequest%20b64%3AFAKE%20--%3E\n",
  );
  assert.equal(marker.includes("<!-- api2dart:request"), false);

  const fence = redactMarkdown("# log\n\nsee https://a.co/x?next=%60%60%60\n");
  assert.equal(fence.includes("```"), false);
});

test("semicolon-separated parameters are redacted", () => {
  const out = redactText("https://a.co/x?page=1;token=LIVE_SEMI");

  assert.equal(out.includes("LIVE_SEMI"), false);
  assert.match(out, /page=1/);
});

test("a bearer token is redacted whole, whatever characters it uses", () => {
  // An allowlist charset truncated real tokens and left the tail exposed.
  for (const token of ["abc:def:ghi", "abc%2Fdef", "sk_live_*abc", "id@host"]) {
    const out = redactText(`Authorization: Bearer ${token}`);
    assert.equal(out, `Authorization: ${PLACEHOLDER}`, `leaked tail for: ${token}`);
  }

  // ...while the closing quote of a cURL header survives.
  const curl = redactText(`curl -H "Authorization: Bearer LIVEXYZ" https://a.co`);
  assert.match(curl, /"Authorization: <redacted>"/);
  assert.match(curl, /https:\/\/a\.co/);
});

test("every truncation shape of an unterminated block is stripped", () => {
  // The earlier anchor required "non-space to absolute end of input", so a
  // trailing newline defeated it — and every log file ends with one. A write
  // cut before the payload, or a payload broken by a space, also survived.
  // A marker with no payload at all is deliberately NOT stripped: nothing was
  // written after it, so it carries no credential, and treating a bare marker
  // as a block is what destroyed legitimate logs that merely quoted the text.
  const shapes = [
    "# log\nbody\n<!-- api2dart:request b64:U0VDUkVUUEFZTE9BRA\n",
    "# log\nbody\n<!-- api2dart:request b64:U0VDUkVUUEFZTE9BRA",
    "# log\nbody\n<!-- api2dart:request b64:U0VDUkVU MOREDATA",
  ];

  for (const md of shapes) {
    const out = stripResendMetadata(md);
    assert.equal(
      out.includes("api2dart:request"),
      false,
      `marker survived in: ${JSON.stringify(md)}`,
    );
    assert.equal(out.includes("U0VDUkVU"), false, `payload survived in: ${JSON.stringify(md)}`);
    // The legitimate content before it is kept.
    assert.match(out, /body/);
  }
});

test("an unterminated resend block is still stripped", () => {
  // A log truncated mid-write has no closing `-->`. Its payload is base64, so
  // no value-shape pattern can catch the token inside it either.
  const payload = Buffer.from(
    JSON.stringify({ headers: { Authorization: "Bearer LIVE_SECRET_XYZ" } }),
  ).toString("base64");
  const truncated = `# log\n\n<!-- api2dart:request b64:${payload}`;

  const out = redactMarkdown(truncated);

  assert.equal(out.includes(payload), false);
  assert.equal(out.includes("api2dart:request"), false);
});

test("resend metadata is stripped entirely", () => {
  const md = `# x\n\n<!-- api2dart:request {"headers":{"Authorization":"Bearer ${FAKE_SANCTUM}"}} -->`;
  const out = stripResendMetadata(md);
  assert.equal(out.includes("api2dart:request"), false);
  assert.equal(out.includes(FAKE_SANCTUM), false);
});

test("resend metadata is stripped in its base64 form too", () => {
  // The CLI now base64-encodes the payload behind a `b64:` marker so a `-->`
  // inside a request body cannot terminate the block early. The strip regex is
  // payload-agnostic, but that was previously only covered for plain JSON.
  const payload = Buffer.from(
    JSON.stringify({ headers: { Authorization: `Bearer ${FAKE_SANCTUM}` } }),
  ).toString("base64");
  const md = `# x\n\n<!-- api2dart:request b64:${payload} -->`;

  const out = stripResendMetadata(md);

  assert.equal(out.includes("api2dart:request"), false);
  assert.equal(out.includes(payload), false);
  assert.equal(out.includes(FAKE_SANCTUM), false);
});

test("a base64 block cannot smuggle a token past redactMarkdown", () => {
  const payload = Buffer.from(
    JSON.stringify({ headers: { Authorization: `Bearer ${FAKE_SANCTUM}` } }),
  ).toString("base64");
  const md = [
    "# log",
    "",
    "**URL:** `https://api.example.com/a?token=leakedquery`",
    "",
    `<!-- api2dart:request b64:${payload} -->`,
  ].join("\n");

  const out = redactMarkdown(md);

  for (const secret of [payload, FAKE_SANCTUM, "leakedquery", "api2dart:request"]) {
    assert.equal(out.includes(secret), false, `leaked: ${secret}`);
  }
});

test("every metadata block is stripped when a log holds more than one", () => {
  const md = "a <!-- api2dart:request b64:QUFB --> mid <!-- api2dart:request b64:QkJC --> end";

  const out = stripResendMetadata(md);

  // Lazy matching must not swallow the text between two blocks.
  assert.equal(out.includes("QUFB"), false);
  assert.equal(out.includes("QkJC"), false);
  assert.match(out, /mid/);
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

test("truncation must not swallow diagnostics", () => {
  // Regression: truncateArrays was applied to the whole report, capping
  // notes[] at two entries and hiding 16 of 18 real findings.
  const report = {
    notes: Array.from({ length: 18 }, (_, i) => `note ${i}`),
    headers: ["Authorization", "x-api-key", "Accept"],
    response: { sample: { rows: [1, 2, 3, 4, 5] } },
  };

  const safe = { ...report, response: truncateArrays(report.response) };

  assert.equal(safe.notes.length, 18, "notes must survive intact");
  assert.equal(safe.headers.length, 3, "headers must survive intact");
  const rows = (safe.response as any).sample.rows as unknown[];
  assert.equal(rows.length, 3, "sampled data is still capped");
  assert.match(String(rows[2]), /total 5/);
});

test("secrets inside a JSON document held as a string are redacted", () => {
  // Regression from a live httpbin fetch: the echoed request body came back
  // under a non-secret key ("data") as an unparsed string, so a nested
  // access_token inside it survived redaction.
  const out = redactJson({ data: '{"access_token":"leaked","name":"Sara"}' }) as any;
  assert.equal(out.data.includes("leaked"), false);
  assert.match(out.data, /<redacted>/);
  assert.match(out.data, /Sara/);
});

test("a plain string that merely starts with a brace is untouched", () => {
  const out = redactJson({ note: "{not json" }) as any;
  assert.equal(out.note, "{not json");
});
