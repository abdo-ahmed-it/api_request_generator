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

/** Key names that carry credentials, matched as a substring at any depth. */
const SECRET_KEY = /(token|secret|password|api[-_]?key|authorization|credential|refresh|access_key)/i;

/**
 * Credential shapes found in free text, where there is no key to match on.
 * The Bearer pattern tolerates the duplicated `Bearer Bearer <token>` form that
 * appears in real logs.
 */
const VALUE_PATTERNS: RegExp[] = [
  /Bearer\s+(?:Bearer\s+)?[A-Za-z0-9._~+/=|-]+/gi,
  // Laravel Sanctum personal-access tokens: `<id>|<random string>`
  /\b\d+\|[A-Za-z0-9]{20,}\b/g,
];

/**
 * Credentials passed in a URL query string (`?token=...&api_key=...`). These
 * appear in prose lines, not just fenced blocks, so they need their own rule.
 */
const QUERY_SECRET =
  /([?&](?:[A-Za-z0-9_-]*(?:token|secret|password|api[-_]?key|auth|credential|refresh)[A-Za-z0-9_-]*)=)([^&\s"'`]+)/gi;

export function isSecretKey(key: string): boolean {
  const lower = key.toLowerCase().trim();
  return SECRET_HEADERS.has(lower) || SECRET_KEY.test(lower);
}

/** Redacts by value shape. Safe to run over arbitrary text. */
export function redactText(input: string): string {
  let out = input.replace(QUERY_SECRET, (_m, prefix: string) => `${prefix}${PLACEHOLDER}`);
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
export function redactJson(data: unknown): unknown {
  if (Array.isArray(data)) return data.map(redactJson);
  if (data && typeof data === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(data as Record<string, unknown>)) {
      out[key] = isSecretKey(key) ? PLACEHOLDER : redactJson(value);
    }
    return out;
  }
  if (typeof data === "string") return redactText(data);
  return data;
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
  return markdown.replace(/<!--\s*api2dart:request[\s\S]*?-->/g, "").trimEnd();
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
