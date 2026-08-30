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
  static final RegExp _secretKeyPattern = RegExp(
    r'(token|secret|password|api[-_]?key|authorization|credential|refresh|access_key)',
    caseSensitive: false,
  );

  /// Credential shapes that appear inside free text (cURL snippets, error
  /// bodies, a URL's query string) where there is no key to match on.
  ///
  /// The `Bearer` pattern is deliberately tolerant of the duplicated
  /// `Bearer Bearer <token>` seen in real logs.
  static final List<RegExp> _valuePatterns = [
    RegExp(r'Bearer\s+(?:Bearer\s+)?\S+', caseSensitive: false),
    // Laravel Sanctum personal-access tokens: `<id>|<random string>`.
    RegExp(r'\b\d+\|[A-Za-z0-9]{20,}\b'),
  ];

  /// True when [key] names a credential.
  static bool isSecretKey(String key) {
    final lower = key.toLowerCase().trim();
    if (_secretHeaders.contains(lower)) return true;
    return _secretKeyPattern.hasMatch(lower);
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
    var out = input;
    for (final pattern in _valuePatterns) {
      out = out.replaceAll(pattern, placeholder);
    }
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
    if (data is String) return text(data);
    return data;
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
