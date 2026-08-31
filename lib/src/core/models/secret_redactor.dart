import 'dart:convert';

/// Scrubs live credentials out of anything rendered for humans or handed to
/// another tool.
///
/// Logs are written to disk and read back by people (and by an MCP server that
/// feeds them into a model's context), so every display path runs through here
/// first. The one deliberate exception is the hidden `api2dart:request`
/// metadata block: `api2dart resend` replays those headers verbatim, so
/// redacting them would break resend. That block is machine-only and never
/// rendered by a Markdown viewer.
class SecretRedactor {
  const SecretRedactor._();

  /// The placeholder that replaces a secret. The key is kept — its presence is
  /// structural information ("this endpoint needs auth"); only the value goes.
  static const String placeholder = '<redacted>';

  /// Header names whose value is always a credential. Matched case-insensitively
  /// against the exact header name.
  static const Set<String> _secretHeaders = {
    'authorization',
    'proxy-authorization',
    'x-api-key',
    'x-secret-key',
    'cookie',
    'set-cookie',
  };

  /// JSON/query keys that carry credentials. Matched case-insensitively as a
  /// substring, so `refresh_token`, `apiKey` and `X-Access-Key` all hit.
  ///
  /// Only words that are credential-bearing wherever they appear belong here.
  /// A word that also names ordinary data (`session`, `signature`) goes in
  /// [_boundedSecretWords] instead — as a substring it would redact
  /// `session_count` or `sessions[]`, shredding the response shape that
  /// `--json` and the MCP `inspect` tool exist to deliver.
  static final RegExp _secretKeyPattern = RegExp(
    r'(token|secret|password|passwd|api[-_]?key|authorization|credential'
    // `access[-_]?key`, not `access_key`: the docstring above promised
    // `X-Access-Key` but only the underscore spelling actually matched.
    r'|access[-_]?key)',
    caseSensitive: false,
  );

  /// Credential words that must match as a whole segment, never a substring.
  ///
  /// `session` and `signature` are bearer-equivalent when they hold the value
  /// itself (`X-Session`, `session_id`), but they also head ordinary fields
  /// (`session_count`, `signature_required`). `refresh` alone is a verb
  /// (`refresh_interval`); it is a credential only as `refresh_token`, which
  /// [_secretKeyPattern] already catches via `token`.
  ///
  /// Compared against whole segments of the key (see [_segments]), so
  /// `X-Auth-Token`, `auth_method` and `authToken` all hit while `author` and
  /// `authority` do not.
  static const Set<String> _boundedSecretWords = {
    'session',
    'sessionid',
    'signature',
    'sig',
    'auth',
    'jwt',
    'bearer',
    // `refresh_token` is caught by [_secretKeyPattern] via `token`, but a bare
    // `{"refresh": "<token>"}` is not, and several OAuth-ish APIs emit exactly
    // that. As a bounded word `refresh_interval` and `refresh_count` still
    // survive via [_descriptorSegments].
    'refresh',
  };

  /// Whole keys that name an authentication *scheme* rather than hold one.
  ///
  /// `token_type: Bearer` is the standard OAuth2 shape, and `auth_type`,
  /// `grant_type` and `credential_type` follow it — reporting which scheme an
  /// endpoint uses is exactly what `--json` and the MCP `inspect` tool exist
  /// for. This is an allowlist of whole keys, not a `type` segment: as a
  /// segment it also exempted `session_type` and `bearer_type`, which carry no
  /// such guarantee and are free to hold a value.
  /// Spelled with `_` because the key is normalised to underscore-joined
  /// segments before the lookup, so `auth-type` and `authType` match too.
  static const Set<String> _schemeNamingKeys = {
    'auth_type',
    'token_type',
    'grant_type',
    'credential_type',
  };

  /// Bounded words whose plural names a collection of objects rather than a
  /// collection of credentials.
  ///
  /// `sessions` is a list of session records; `signatures`, `sigs`, `jwts` and
  /// `auths` are lists of the secret values themselves, so pluralising them
  /// must not exempt them.
  static const Set<String> _pluralNamesCollection = {
    'session',
  };

  /// Segments that turn a *bounded* credential word into a description of one.
  ///
  /// `session` holds a credential; `session_count` counts them and
  /// `signature_required` reports whether one is needed. Redacting those would
  /// destroy the response shape that `--json` and the MCP `inspect` tool exist
  /// to deliver, and neither carries a secret.
  ///
  /// This never applies to [_secretKeyPattern] words: `access_token_type` and
  /// `api_key_status` describe *and* hold, and OAuth2 responses name them
  /// exactly that way. When in doubt the redactor keeps the key and drops the
  /// value — a lost count is cheaper than a leaked token.
  ///
  /// `status`, `at` and `on` were tried here and removed: unlike the
  /// [_secretKeyPattern] words there is no backstop for the bounded ones, so
  /// they silently exempted `sig_status`, `auth_status`, `sig_at`, `auth_at`
  /// and `jwt_at` — keys that name no scheme and can hold a value. `at`/`on`
  /// were only ever meant to spare `expires_at`, and `expires` is not a
  /// credential word, so it never needed the exemption in the first place.
  ///
  /// `type` was kept here briefly and then moved to [_schemeNamingKeys]. As a
  /// blanket segment it exempted `session_type` and `bearer_type` too, which
  /// are not standardised field names and can hold a value — the same weakness
  /// that removed `status`. Only the specific keys that really name a scheme
  /// are exempt now.
  static const Set<String> _descriptorSegments = {
    'count',
    'total',
    'length',
    'size',
    'required',
    'enabled',
    'expired',
    'valid',
    'interval',
    'timeout',
    'ttl',
    'url',
    'uri',
    'endpoint',
  };

  /// Splits a key into its lowercase word segments.
  ///
  /// `-`, `_`, `.` and spaces separate, and a camelCase hump starts a new
  /// segment — so `authToken` yields `[auth, token]` and `X-Session-Id` yields
  /// `[x, session, id]`, while `author` stays a single segment `[author]`.
  static Iterable<String> _segments(String key) {
    final spaced = key.replaceAllMapped(
      RegExp(r'(?<=[a-z0-9])(?=[A-Z])'),
      (_) => ' ',
    );
    return spaced
        .toLowerCase()
        .split(RegExp(r'[-_.\s]+'))
        .where((s) => s.isNotEmpty);
  }

  /// Credential shapes that appear inside free text (cURL snippets, error
  /// bodies, a URL's query string) where there is no key to match on.
  ///
  /// The `Bearer` pattern is deliberately tolerant of the duplicated
  /// `Bearer Bearer <token>` seen in real logs.
  static final List<RegExp> _valuePatterns = [
    // The token runs to the next quote or whitespace. An allowlist charset was
    // tried and reverted: it excluded `:`, `%`, `*` and `@`, which appear in
    // real credentials (`id:secret` forms, percent-encoded tokens), so it
    // redacted the head and left the tail in place. Excluding the delimiters
    // instead keeps the closing quote of `-H "Authorization: Bearer x"` intact
    // without truncating. `,` and `;` are excluded too: without them
    // `Bearer abc, X-Api-Key: def` ate the comma and ran the two fields
    // together, destroying the line the report exists to make readable.
    // Matches the TS pattern in redact.ts exactly.
    RegExp(r'Bearer\s+(?:Bearer\s+)?[^\s"' "'" r'`,;]+', caseSensitive: false),
    // Laravel Sanctum personal-access tokens: `<id>|<random string>`.
    RegExp(r'\b\d+\|[A-Za-z0-9]{20,}\b'),
  ];

  /// Credentials passed in a URL query string (`?token=...&api_key=...`).
  ///
  /// A URL is rendered as prose (the summary line, the `URL:` field, the cURL
  /// snippet), so there is no key/value pair to inspect — only shape. The
  /// parameter name is kept and only its value replaced, matching how
  /// [headers] and [json] preserve structure.
  ///
  /// Mirrors `QUERY_SECRET` in `tools/api2dart-mcp/src/redact.ts`; the two
  /// implementations are deliberately duplicated, so fix both together.
  ///
  /// Every parameter is matched and its name handed to [isSecretKey], so the
  /// query rule and the key rule cannot drift apart. An earlier revision spelled
  /// the credential words out again here and let `?authToken=`,
  /// `?authorization=` and `?credentials=` slip through.
  ///
  /// `?`, `&`, `#` and `;` all open a parameter, and `?` also *ends* a value —
  /// so a nested URL (`?redirect_uri=https://app/cb?api_key=LIVE`) exposes its
  /// own parameters instead of hiding them inside the outer value. `#` matters
  /// because an OAuth2 implicit-flow callback delivers the token in the
  /// fragment; `;` because it is long-standing CGI practice.
  ///
  /// A name containing an always-credential word as a substring
  /// (`?tokens_count=5`) is still redacted, matching how the same key is
  /// treated in a JSON body. Losing a count is the cheaper error, and the
  /// parameter name itself is always preserved.
  ///
  /// Whitespace may follow the separator: `FOO=bar; TOKEN=live` is a shell line
  /// that appears verbatim in cURL fences and error prose, and requiring the
  /// name to abut the `;` let the whole line through unredacted.
  static final RegExp _queryParamPattern = RegExp(
    r'([?&#;]\s*)([A-Za-z0-9_.%\[\]-]+)(=)([^?&#;\s"' "'" r'`]*)',
  );

  /// A quoted JSON key, for scanning a decoded value that turned out to be a
  /// JSON document rather than a query string.
  static final RegExp _jsonKeyPattern = RegExp(r'"([A-Za-z0-9_.-]+)"\s*:');

  /// A `name=` pair with no query separator before it, for scanning a decoded
  /// value that opens with the pair rather than embedding it in a URL.
  static final RegExp _bareParamPattern =
      RegExp(r'(?:^|[\s,])([A-Za-z0-9_.%\[\]-]+)=');

  /// How many times a nested URL is unwrapped before we stop descending.
  ///
  /// A recursive implementation overflowed the stack on ~15 KB of `?a=?a=`,
  /// and an overflow means *no* redaction runs at all. Real callback chains
  /// are two or three deep.
  static const int _maxNestedUrlDepth = 8;

  /// Percent-decodes once, for classification only.
  ///
  /// A `redirect_uri` is normally percent-encoded — the OAuth spec requires it
  /// — so `?redirect_uri=https%3A%2F%2Fb.co%2Fcb%3Fapi_key%3DLIVE` is the
  /// realistic shape and a raw scan never sees the inner `api_key`. Likewise
  /// `?api%5Fkey=` is `api_key`. Returns the input unchanged when it is not
  /// valid encoding, so a stray `%` can never throw.
  static String _decodeOnce(String value) {
    if (!value.contains('%')) return value;
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  /// True when [segment] is a bounded credential word, in singular or plural.
  ///
  /// Both `-s` and `-es` are stripped: `refreshes` is the correct plural of the
  /// one verb-like bounded word, and trying only `-s` left it unmatched while
  /// the incorrect `refreshs` matched.
  static bool _isBoundedSecretWord(String segment) {
    if (_boundedSecretWords.contains(segment)) return true;
    if (segment.endsWith('es') &&
        _boundedSecretWords.contains(
          segment.substring(0, segment.length - 2),
        )) {
      return true;
    }
    return segment.endsWith('s') &&
        _boundedSecretWords.contains(
          segment.substring(0, segment.length - 1),
        );
  }

  /// True when [key] names a credential.
  static bool isSecretKey(String key) {
    final lower = key.toLowerCase().trim();
    if (_secretHeaders.contains(lower)) return true;

    final parts = _segments(key).toList();

    // An always-credential word settles it outright, whatever else the key
    // contains. `token_type` is a field of every OAuth2 token response, so
    // `access_token_type`, `session_token_type` and `api_key_status` are
    // ordinary shapes that still hold live secrets — the descriptor rule below
    // must never override this.
    if (_secretKeyPattern.hasMatch(lower)) return true;

    // A key that names the scheme in use rather than holding it. Checked on
    // the normalised segments so `auth-type`, `auth_type` and `authType` all
    // read alike.
    if (_schemeNamingKeys.contains(parts.join('_'))) return false;

    // The remaining words carry a credential only in some spellings.
    //
    // A plural counts as the word: `signatures` is a list of signature values
    // and must redact. Whether the plural *exempts* it is decided further down
    // by [_pluralNamesCollection]; reaching that decision at all requires
    // matching here first.
    if (!parts.any(_isBoundedSecretWord)) return false;

    // Does it *hold* one, or only report about one? A quantity or flag
    // describes (`session_count`, `signature_required`), and a plural names a
    // collection (`sessions`). Redacting those destroys the response shape
    // that `--json` and the MCP `inspect` tool exist to deliver, and neither
    // carries a secret.
    if (parts.any(_descriptorSegments.contains)) return false;

    // `sessions` is a list of session objects, not a session token.
    //
    // This only holds for words that name a *container*. A list of signatures
    // is a list of the credential values themselves, so the plural inverts the
    // rule there — `signatures` and `sigs` must stay redacted.
    if (parts.length == 1 &&
        parts.single.endsWith('s') &&
        _pluralNamesCollection
            .contains(parts.single.substring(0, parts.single.length - 1))) {
      return false;
    }

    return true;
  }

  /// Redacts a header map by name.
  static Map<String, String> headers(Map<String, String> input) {
    return input.map(
      (k, v) => MapEntry(k, isSecretKey(k) ? placeholder : text(v)),
    );
  }

  /// Redacts free text by shape — used for values with no key to inspect,
  /// such as a cURL command line or a URL containing `?token=...`.
  static String text(String input) {
    var out = _redactQueryParams(input);
    for (final pattern in _valuePatterns) {
      out = out.replaceAll(pattern, placeholder);
    }
    return out;
  }

  /// True when an encoded value hides a credential once decoded.
  ///
  /// Decoding repeats while it keeps changing the input (`%2520` needs two
  /// passes), capped so a crafted value cannot spin. The decoded text is
  /// examined and then discarded — see [_redactQueryParams].
  static bool _encodedValueHidesSecret(String value) {
    var current = value;

    for (var depth = 0; depth < _maxNestedUrlDepth; depth++) {
      final decoded = _decodeOnce(current);
      if (decoded == current) break;
      current = decoded;

      // Any `name=value` pair the decoded form reveals, judged by the same rule.
      for (final m in _queryParamPattern.allMatches(current)) {
        if (isSecretKey(m[2]!)) return true;
      }
      // [_queryParamPattern] requires a leading `?&#;`, so a decoded fragment
      // that *opens* with the pair matched nothing and leaked —
      // `?state=api_key%3DLIVE` came straight through. Here the whole value is
      // the candidate, so a pair at position zero is the common case.
      for (final m in _bareParamPattern.allMatches(current)) {
        if (isSecretKey(_decodeOnce(m[1]!))) return true;
      }
      // A decoded value is often a JSON document rather than query syntax
      // (`?data=%7B%22api_key%22...%7D`), where the credential sits behind a
      // quoted key with no separator in front of it.
      for (final m in _jsonKeyPattern.allMatches(current)) {
        if (isSecretKey(m[1]!)) return true;
      }
      // A bare credential with no parameter syntax around it.
      for (final pattern in _valuePatterns) {
        if (pattern.hasMatch(current)) return true;
      }
    }

    return false;
  }

  /// Redacts query-string credentials.
  ///
  /// Percent-encoded values are decoded only to *look inside* them; the encoded
  /// text is what gets emitted. Writing the decoded form back turned an opaque
  /// blob into plaintext — `?data=%7B%22api_key%22%3A%22LIVE%22%7D` became
  /// `?data={"api_key":"LIVE"}`, which no later pass could redact because no
  /// `?&#;` separator precedes the inner key. It also let a crafted parameter
  /// inject a literal resend marker or code fence into output that had already
  /// passed the strip and fence phases.
  static String _redactQueryParams(String input) {
    final out = input.replaceAllMapped(_queryParamPattern, (m) {
      final separator = m[1]!;
      final name = m[2]!;
      final equals = m[3]!;
      final value = m[4]!;

      // Classify on the decoded name so `?api%5Fkey=` reads as `api_key`.
      if (isSecretKey(_decodeOnce(name))) {
        return '$separator$name$equals$placeholder';
      }
      // `?` terminates a value, so a plain nested URL's parameters are already
      // matched in this same pass. Only encoding can hide one.
      if (value.contains('%') && _encodedValueHidesSecret(value)) {
        return '$separator$name$equals$placeholder';
      }
      return m[0]!;
    });

    return out;
  }

  /// Walks any decoded JSON structure and redacts secret-named keys at any
  /// depth, leaving the surrounding shape intact so the reader still learns
  /// what fields exist.
  static dynamic json(dynamic data) {
    if (data is Map) {
      return data.map((k, v) => MapEntry(
            k,
            isSecretKey(k.toString()) ? placeholder : json(v),
          ));
    }
    if (data is List) return data.map(json).toList();
    if (data is String) return _embeddedJson(data);
    return data;
  }

  /// Redacts a string that may itself hold a JSON document.
  ///
  /// APIs echo request bodies back as raw strings (a `payload` column, a
  /// webhook log, httpbin's `data`). Walking only parsed structures misses
  /// those: the key holding them is not secret-named and its value is a
  /// string, so a nested `access_token` inside would survive.
  static dynamic _embeddedJson(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return jsonEncode(json(jsonDecode(trimmed)));
      } catch (_) {
        // not valid JSON after all
      }
    }
    return text(value);
  }

  /// Redacts a JSON string, preserving it as a string. Falls back to
  /// shape-based text redaction when the input isn't valid JSON.
  static String jsonString(String input) {
    try {
      return jsonEncode(json(jsonDecode(input)));
    } catch (_) {
      return text(input);
    }
  }
}
