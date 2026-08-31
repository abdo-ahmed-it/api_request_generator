/**
 * Strips live credentials from anything leaving this server.
 *
 * The Dart CLI already redacts what it writes, but this layer is independent
 * on purpose: the server also reads log files written by older versions of the
 * tool, which contain unredacted tokens. Redaction happens before any output is
 * inspected, parsed further, logged, or returned.
 */

export const PLACEHOLDER = "<redacted>";

/** Header names that always carry a credential. */
const SECRET_HEADERS = new Set([
  "authorization",
  "proxy-authorization",
  "x-api-key",
  "x-secret-key",
  "cookie",
  "set-cookie",
]);

/**
 * Key names that carry credentials wherever they appear, matched as a substring
 * at any depth. `access[-_]?key`, not `access_key`, so `X-Access-Key` and
 * `accessKey` hit too. Kept in step with `_secretKeyPattern` in
 * lib/src/core/models/secret_redactor.dart.
 */
const SECRET_KEY =
  /(token|secret|password|passwd|api[-_]?key|authorization|credential|access[-_]?key)/i;

/**
 * Credential words that must match a whole segment, never a substring.
 *
 * `session` and `signature` are bearer-equivalent when they hold the value
 * itself, but they also head ordinary fields (`session_count`,
 * `signature_required`) — as substrings they would shred the response shape
 * this server exists to deliver. `refresh` alone is a verb
 * (`refresh_interval`); it is a credential only as `refresh_token`, which
 * SECRET_KEY already catches. Kept in step with `_boundedSecretWords` in
 * lib/src/core/models/secret_redactor.dart.
 */
const BOUNDED_SECRET_WORDS = new Set([
  "session",
  "sessionid",
  "signature",
  "sig",
  "auth",
  "jwt",
  "bearer",
  // `refresh_token` is caught by SECRET_KEY via `token`, but a bare
  // `{"refresh": "<token>"}` is not, and several OAuth-ish APIs emit exactly
  // that. `refresh_interval` and `refresh_count` still survive as descriptors.
  "refresh",
]);

/**
 * Whole keys that name an authentication scheme rather than hold one.
 *
 * `auth_type: Bearer` reports which scheme an endpoint uses. An allowlist of
 * whole keys, not a `type` segment: as a segment it also exempted
 * `session_type` and `bearer_type`, which carry no such guarantee.
 *
 * `token_type` and `credential_type` are deliberately absent — they match
 * SECRET_KEY, which settles the answer first, and `access_token_type` must
 * stay redacted. The key is normalised to underscore-joined segments, so
 * `auth-type` and `authType` match. Kept in step with `_schemeNamingKeys` in
 * lib/src/core/models/secret_redactor.dart.
 */
const SCHEME_NAMING_KEYS = new Set(["auth_type", "grant_type"]);

/**
 * Bounded words whose plural names a collection of objects rather than a
 * collection of credentials.
 *
 * `sessions` is a list of session records; `signatures`, `sigs`, `jwts` and
 * `auths` are lists of the secret values themselves. Kept in step with
 * `_pluralNamesCollection` in lib/src/core/models/secret_redactor.dart.
 */
const PLURAL_NAMES_COLLECTION = new Set(["session"]);

/**
 * Segments that turn a credential word into a description of one.
 *
 * `session` holds a credential; `session_count` counts them and
 * `signature_required` reports whether one is needed. Redacting those would
 * destroy the response shape this server exists to deliver.
 *
 * `status`, `at` and `on` were tried here and removed: unlike the SECRET_KEY
 * words there is no backstop for the bounded ones, so they silently exempted
 * `sig_status`, `sig_at`, `auth_at` and `jwt_at` — keys that name no scheme and
 * can hold a value. `type` moved to SCHEME_NAMING_KEYS: as a blanket segment it
 * also exempted `session_type` and `bearer_type`, which can hold a value. Kept
 * in step with `_descriptorSegments` in lib/src/core/models/secret_redactor.dart.
 */
const DESCRIPTOR_SEGMENTS = new Set([
  "count",
  "total",
  "length",
  "size",
  "required",
  "enabled",
  "expired",
  "valid",
  "interval",
  "timeout",
  "ttl",
  "url",
  "uri",
  "endpoint",
]);

/**
 * Splits a key into lowercase word segments. `-`, `_`, `.` and spaces separate,
 * and a camelCase hump starts a new segment — so `authToken` yields
 * [auth, token] while `author` stays [author].
 */
function segments(key: string): string[] {
  return key
    .replace(/(?<=[a-z0-9])(?=[A-Z])/g, " ")
    .toLowerCase()
    .split(/[-_.\s]+/)
    .filter((s) => s.length > 0);
}

/**
 * Credential shapes found in free text, where there is no key to match on.
 * The Bearer pattern tolerates the duplicated `Bearer Bearer <token>` form that
 * appears in real logs.
 */
const VALUE_PATTERNS: RegExp[] = [
  // The token runs to the next quote or whitespace. An allowlist charset was
  // tried and reverted: it excluded `:`, `%`, `*` and `@`, which appear in real
  // credentials (`id:secret` forms, percent-encoded tokens), so it redacted the
  // head and left the tail in place. Excluding the delimiters instead keeps the
  // closing quote of `-H "Authorization: Bearer x"` intact without truncating.
  // `,` and `;` are excluded too: without them `Bearer abc, X-Api-Key: def`
  // ate the comma and ran the two fields together.
  /Bearer\s+(?:Bearer\s+)?[^\s"'`,;]+/gi,
  // Laravel Sanctum personal-access tokens: `<id>|<random string>`
  /\b\d+\|[A-Za-z0-9]{20,}\b/g,
];

/**
 * Locates a `name=value` pair anywhere a query string can start or continue.
 *
 * Only the *positions* come from this regex; the decision to redact is made by
 * `isSecretKey`, so the query rule and the key rule cannot drift apart. Five
 * earlier revisions spelled the credential words out here as well, and each one
 * leaked a spelling the other rule caught.
 *
 * `?`, `&`, `#` and `;` all open a parameter: `#` because an OAuth2
 * implicit-flow callback delivers the token in the fragment, and `;` because it
 * is long-standing CGI practice still emitted by some servers.
 *
 * Whitespace may follow the separator: `FOO=bar; TOKEN=live` is a shell line
 * that appears verbatim in cURL fences, and requiring the name to abut the `;`
 * let the whole line through unredacted. Kept in step with
 * `_queryParamPattern` in lib/src/core/models/secret_redactor.dart.
 */
const QUERY_PARAM = /([?&#;]\s*)([A-Za-z0-9_.%[\]-]+)(=)([^?&#;\s"'`]*)/g;

/**
 * How many times a nested URL is unwrapped before we stop descending.
 *
 * An OAuth `redirect_uri` carries a whole URL whose own query string may hold a
 * credential, so one pass is not enough. A recursive implementation overflowed
 * the stack on ~6 KB of `?a=?a=?a=` — reachable from any API echoing a redirect
 * chain — and an overflow means *no* redaction runs at all. The loop below is
 * iterative and capped; real callback chains are two or three deep.
 */
const MAX_NESTED_URL_DEPTH = 8;

/**
 * True when a value may still hide structure behind percent-encoding.
 *
 * A literal `?` cannot appear here — the value class excludes it, so a plain
 * nested URL's parameters are already matched in the same pass. Only encoding
 * can conceal them, so `%` is the whole test. Kept in step with the `%` check
 * in `_redactQueryParams` in lib/src/core/models/secret_redactor.dart.
 */
function hasNestedQuery(value: string): boolean {
  return value.includes("%");
}

/**
 * Percent-decodes once, for classification only.
 *
 * A `redirect_uri` is normally percent-encoded — the OAuth spec requires it —
 * so `?redirect_uri=https%3A%2F%2Fb.co%2Fcb%3Fapi_key%3DLIVE` is the realistic
 * shape, and a raw scan never sees the inner `api_key`. Likewise `?api%5Fkey=`
 * is `api_key` and must classify as one. Returns the input unchanged when it is
 * not valid encoding, so a stray `%` can never throw.
 */
function decodeOnce(value: string): string {
  if (!value.includes("%")) return value;
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

/**
 * True when a segment is a bounded credential word, singular or plural.
 *
 * Both `-s` and `-es` are stripped: `refreshes` is the correct plural of the
 * one verb-like bounded word.
 */
function isBoundedSecretWord(segment: string): boolean {
  if (BOUNDED_SECRET_WORDS.has(segment)) return true;
  if (segment.endsWith("es") && BOUNDED_SECRET_WORDS.has(segment.slice(0, -2))) {
    return true;
  }
  return segment.endsWith("s") && BOUNDED_SECRET_WORDS.has(segment.slice(0, -1));
}

export function isSecretKey(key: string): boolean {
  const lower = key.toLowerCase().trim();
  if (SECRET_HEADERS.has(lower)) return true;

  const parts = segments(key);

  // An always-credential word settles it outright, whatever else the key
  // contains. `token_type` is a field of every OAuth2 token response, so
  // `access_token_type`, `session_token_type` and `api_key_status` are ordinary
  // shapes that still hold live secrets — the descriptor rule below must never
  // override this.
  if (SECRET_KEY.test(lower)) return true;

  // A key that names the scheme in use rather than holding it.
  if (SCHEME_NAMING_KEYS.has(parts.join("_"))) return false;

  // The remaining words carry a credential only in some spellings. A plural
  // counts as the word: `signatures` is a list of signature values and must
  // redact. Whether the plural *exempts* it is decided below by
  // PLURAL_NAMES_COLLECTION; reaching that decision requires matching here.
  if (!parts.some(isBoundedSecretWord)) return false;

  // Does it hold one, or only report about one? A quantity or flag describes
  // (`session_count`, `signature_required`), and a plural names a collection
  // (`sessions`). Redacting those destroys the response shape.
  if (parts.some((p) => DESCRIPTOR_SEGMENTS.has(p))) return false;
  // Only for words that name a *container*: a list of signatures is a list of
  // the credential values themselves, so the plural inverts the rule there.
  if (
    parts.length === 1 &&
    parts[0].endsWith("s") &&
    PLURAL_NAMES_COLLECTION.has(parts[0].slice(0, -1))
  ) {
    return false;
  }

  return true;
}

/**
 * True when an encoded value hides a credential once decoded.
 *
 * Decoding is repeated while it keeps changing the input (`%2520` needs two
 * passes), capped so a crafted value cannot spin. The decoded text is examined
 * and then discarded — see [redactQueryParams] for why it must never be
 * written back.
 */
function encodedValueHidesSecret(value: string): boolean {
  let current = value;

  for (let depth = 0; depth < MAX_NESTED_URL_DEPTH; depth++) {
    const decoded = decodeOnce(current);
    if (decoded === current) break;
    current = decoded;

    // Any `name=value` pair the decoded form reveals, judged by the same rule.
    QUERY_PARAM.lastIndex = 0;
    for (const m of current.matchAll(QUERY_PARAM)) {
      if (isSecretKey(m[2])) return true;
    }
    // QUERY_PARAM requires a leading `?&#;`, so a decoded fragment that *opens*
    // with the pair matched nothing and leaked — `?state=api_key%3DLIVE` came
    // straight through. Here the whole value is the candidate, so a pair at
    // position zero is the common case rather than an edge one.
    for (const m of current.matchAll(/(?:^|[\s,])([A-Za-z0-9_.%[\]-]+)=/g)) {
      if (isSecretKey(decodeOnce(m[1]))) return true;
    }
    // A decoded value is often a JSON document rather than query syntax
    // (`?data=%7B%22api_key%22...%7D`), where the credential sits behind a
    // quoted key with no separator in front of it.
    for (const m of current.matchAll(/"([A-Za-z0-9_.-]+)"\s*:/g)) {
      if (isSecretKey(m[1])) return true;
    }
    // A bare credential with no parameter syntax around it.
    for (const pattern of VALUE_PATTERNS) {
      pattern.lastIndex = 0;
      if (pattern.test(current)) return true;
    }
  }

  return false;
}

/**
 * Redacts query-string credentials.
 *
 * Percent-encoded values are decoded only to *look inside* them; the encoded
 * text is what gets emitted. Writing the decoded form back turned an opaque
 * blob into plaintext — `?data=%7B%22api_key%22%3A%22LIVE%22%7D` became
 * `?data={"api_key":"LIVE"}`, which no later pass could redact because no `?&#;`
 * separator precedes the inner key. It also let a crafted parameter inject a
 * literal `<!-- api2dart:request -->` or a code fence into output that had
 * already passed the strip and fence phases.
 */
function redactQueryParams(input: string): string {
  QUERY_PARAM.lastIndex = 0;
  return input.replace(
    QUERY_PARAM,
    (match, sep: string, name: string, eq: string, value: string) => {
      // Classify on the decoded name so `?api%5Fkey=` reads as `api_key`.
      if (isSecretKey(decodeOnce(name))) {
        return `${sep}${name}${eq}${PLACEHOLDER}`;
      }
      // `?` terminates a value, so a plain nested URL's parameters are already
      // matched in this same pass. Only encoding can hide one.
      if (hasNestedQuery(value) && encodedValueHidesSecret(value)) {
        return `${sep}${name}${eq}${PLACEHOLDER}`;
      }
      return match;
    },
  );
}

/** Redacts by value shape. Safe to run over arbitrary text. */
export function redactText(input: string): string {
  let out = redactQueryParams(input);
  for (const pattern of VALUE_PATTERNS) {
    out = out.replace(pattern, PLACEHOLDER);
  }
  return out;
}

/**
 * Redacts an `http`-style header block line by line, so a `Key: value` line
 * loses its value but keeps its name.
 */
export function redactHeaderBlock(block: string): string {
  return block
    .split("\n")
    .map((line) => {
      const match = /^([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(line);
      if (!match) return redactText(line);
      const [, name, value] = match;
      return isSecretKey(name) ? `${name}: ${PLACEHOLDER}` : `${name}: ${redactText(value)}`;
    })
    .join("\n");
}

/** Walks decoded JSON, redacting secret-named keys at any depth. */
/**
 * The closed set of type names `EndpointReport._inferTypes` can emit.
 *
 * `inferred_types` mirrors the response's key names, so a credential key like
 * `access_token` lands there too — but the *value* is a Dart type name, never
 * sampled data. Blanket key-based redaction therefore replaced `"String"` with
 * the placeholder and destroyed the one thing the field exists to carry.
 *
 * Matched against this allowlist rather than exempting the subtree wholesale:
 * if the CLI ever puts a real value there, it is redacted as before.
 */
const INFERRED_TYPE_NAMES = /^(bool|int|num|String|dynamic \(null in sample\)|List<dynamic> \(empty — type unknown\))$/;

/**
 * Redacts `inferred_types`, keeping values that are recognisable type names.
 *
 * Keys still come from the API, so they are passed through `redactJson`'s own
 * key handling by way of the caller; only the leaf values are spared.
 */
function redactInferredTypes(data: unknown): unknown {
  if (Array.isArray(data)) return data.map(redactInferredTypes);
  if (data && typeof data === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(data as Record<string, unknown>)) {
      out[key] = redactInferredTypes(value);
    }
    return out;
  }
  if (typeof data === "string") {
    return INFERRED_TYPE_NAMES.test(data) ? data : redactEmbeddedJson(data);
  }
  return data;
}

export function redactJson(data: unknown): unknown {
  if (Array.isArray(data)) return data.map(redactJson);
  if (data && typeof data === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(data as Record<string, unknown>)) {
      // `inferred_types` carries Dart type names keyed by response field, so a
      // key like `access_token` must not blank out its `"String"`.
      if (key === "inferred_types") {
        out[key] = redactInferredTypes(value);
        continue;
      }
      out[key] = isSecretKey(key) ? PLACEHOLDER : redactJson(value);
    }
    return out;
  }
  if (typeof data === "string") return redactEmbeddedJson(data);
  return data;
}

/**
 * Redacts a string that may itself hold a JSON document.
 *
 * APIs echo request bodies back as raw strings (httpbin's `data`, Laravel's
 * `payload` columns, webhook logs). Walking only parsed structures misses
 * those: the key holding them is not secret-named and its value is a string,
 * so a nested `access_token` inside would survive. Parse it, redact it, and
 * re-serialise; fall back to shape-based redaction when it isn't JSON.
 */
function redactEmbeddedJson(value: string): string {
  const trimmed = value.trim();
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    try {
      return JSON.stringify(redactJson(JSON.parse(trimmed)));
    } catch {
      // not valid JSON after all
    }
  }
  return redactText(value);
}

/**
 * Redacts a whole Markdown log: fenced `http` blocks are treated as headers,
 * fenced `json` blocks are parsed and walked, and everything else falls back to
 * shape-based text redaction. Unparseable JSON still gets the text treatment,
 * so a malformed block can never leak.
 */
export function redactMarkdown(markdown: string): string {
  const withoutMeta = stripResendMetadata(markdown);

  // Split on fenced blocks so prose between them is redacted too: a token in a
  // URL on a summary line is just as live as one inside a code fence.
  const parts = withoutMeta.split(/(```\w*\n[\s\S]*?```)/g);
  return parts
    .map((part) => (part.startsWith("```") ? redactFence(part) : redactText(part)))
    .join("");
}

function redactFence(fence: string): string {
  return fence.replace(
    /```(\w*)\n([\s\S]*?)```/g,
    (_full, lang: string, body: string) => {
      const language = lang.toLowerCase();
      if (language === "http") return "```http\n" + redactHeaderBlock(body) + "```";
      if (language === "json") {
        try {
          const parsed = JSON.parse(body);
          // Truncate here too: a log's response array can hold hundreds of
          // real records, and only the element shape is wanted.
          const safe = truncateArrays(redactJson(parsed));
          return "```json\n" + JSON.stringify(safe, null, 2) + "\n```";
        } catch {
          return "```json\n" + redactText(body) + "```";
        }
      }
      // bash (cURL) and anything else
      return "```" + lang + "\n" + redactText(body) + "```";
    },
  );
}

/**
 * Removes the hidden `api2dart:request` block. It holds the full request —
 * including live auth headers — for `resend` to replay, and must never reach
 * a transcript.
 */
export function stripResendMetadata(markdown: string): string {
  // Terminated blocks first. The payload may not itself contain the marker, so
  // a body quoting the marker in prose cannot pair with a *later* real block's
  // `-->` and swallow everything in between — lazy matching alone allowed that.
  const out = markdown.replace(
    /<!--\s*api2dart:request(?:(?!<!--\s*api2dart:request)[\s\S])*?-->/g,
    "",
  );

  // What remains may still hold a marker with no closing `-->` — a log
  // truncated by an interrupted `resend` or a full disk. Its payload is base64,
  // so no value-shape pattern can recognise the token inside it; the plain-JSON
  // form was at least caught by the Bearer/Sanctum fallbacks.
  //
  // The discriminator must recognise an actual payload, not merely characters
  // that *could* be one. `RequestLog._metaBlock` writes either `b64:<base64>`
  // or — in logs written before that encoding — a raw JSON object whose first
  // key is always `requestName`.
  //
  // Both looser forms were tried and destroyed real logs. A permissive
  // character class matched plain prose; a bare `\{` matched any tail starting
  // with a brace, which `_prettyJson` can produce by writing a non-JSON
  // response body raw into the fence. Anchoring on `{"requestName"` bounds it:
  // a truncation shorter than that decodes only to key names, never a header
  // value.
  //
  // The `b64:` arm needs no such length floor. The literal marker plus the
  // `b64:` prefix already identify a metadata block, so any base64 tail after
  // it is a truncated one. The previous `{16,}` left blocks shorter than 16
  // payload characters in the output, and 16 base64 characters is only 12
  // decoded bytes — close enough to `{"requestName` (13) that the guarantee
  // was an assumption rather than a bound.
  const truncatedBlock =
    /(^|\n)<!--[ \t]*api2dart:request[ \t]+(?:b64:[A-Za-z0-9+/=\s]+|\{\s*"requestName"[\s\S]*)$/
      .exec(out);
  if (truncatedBlock) {
    return out.slice(0, truncatedBlock.index).trimEnd();
  }
  return out.trimEnd();
}

/**
 * Caps long arrays so the caller learns the element shape without receiving
 * every record. The total is preserved — it is useful information.
 */
export function truncateArrays(data: unknown, maxItems = 2): unknown {
  if (Array.isArray(data)) {
    const kept: unknown[] = data.slice(0, maxItems).map((item) => truncateArrays(item, maxItems));
    if (data.length > maxItems) {
      kept.push(`… +${data.length - maxItems} more items (total ${data.length})`);
    }
    return kept;
  }
  if (data && typeof data === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(data as Record<string, unknown>)) {
      out[key] = truncateArrays(value, maxItems);
    }
    return out;
  }
  return data;
}
