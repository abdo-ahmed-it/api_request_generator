import 'dart:convert';

import '../sources/api_fetchers/config_storage.dart';
import 'api_endpoint.dart';
import 'body_definition.dart';

/// How a login step encodes its request body on the wire.
enum LoginBodyFormat { json, form }

/// One HTTP call in the login sequence.
///
/// A single-step login has exactly one of these. A two-step OTP login has two:
/// the request-OTP call and the verify call. The verify call needs nothing from
/// the first response — the same identifier plus the code is enough — so steps
/// carry no state between them.
class LoginStep {
  /// Absolute URL, or a path resolved against the run's base URL.
  final String url;
  final HttpMethod method;

  /// Static body fields sent every time (e.g. `{email: .., password: ..}` for
  /// a credentials step, or `{phone: ..}` for an OTP request).
  final Map<String, String> fields;

  final LoginBodyFormat bodyFormat;
  final Map<String, String> headers;

  /// Body field the OTP code is injected into (e.g. `code`, `otp`). Non-null on
  /// the verify step only; null means "send [fields] verbatim".
  final String? otpField;

  const LoginStep({
    required this.url,
    this.method = HttpMethod.POST,
    this.fields = const {},
    this.bodyFormat = LoginBodyFormat.json,
    this.headers = const {},
    this.otpField,
  });

  bool get isValid => url.isNotEmpty;

  /// Resolves [url] against [baseUrl] when it was stored as a bare path.
  String resolvedUrl(String? baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = (baseUrl ?? '').replaceAll(RegExp(r'/+$'), '');
    final path = url.startsWith('/') ? url : '/$url';
    return '$base$path';
  }

  /// Builds this step's request body, injecting [otpCode] into [otpField] when
  /// both are present.
  BodyDefinition toBody({String? otpCode}) {
    final merged = <String, String>{
      ...fields,
      if (otpField != null && otpCode != null && otpCode.isNotEmpty)
        otpField!: otpCode,
    };
    if (merged.isEmpty) return const BodyDefinition();

    return bodyFormat == LoginBodyFormat.json
        ? BodyDefinition(
            contentType: BodyContentType.rawJson,
            rawBody: jsonEncode(merged),
          )
        : BodyDefinition(
            contentType: BodyContentType.urlEncoded,
            formFields: merged,
          );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'method': method.name,
        if (fields.isNotEmpty) 'fields': fields,
        'bodyFormat': bodyFormat.name,
        if (headers.isNotEmpty) 'headers': headers,
        if (otpField != null) 'otpField': otpField,
      };

  static LoginStep? fromJson(Map<String, dynamic> json) {
    final url = json['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    return LoginStep(
      url: url,
      method: _methodFrom(json['method']?.toString()),
      fields: _stringMap(json['fields']),
      bodyFormat: json['bodyFormat']?.toString() == 'form'
          ? LoginBodyFormat.form
          : LoginBodyFormat.json,
      headers: _stringMap(json['headers']),
      otpField: json['otpField']?.toString(),
    );
  }

  LoginStep copyWith({
    String? url,
    HttpMethod? method,
    Map<String, String>? fields,
    LoginBodyFormat? bodyFormat,
    Map<String, String>? headers,
    String? otpField,
  }) =>
      LoginStep(
        url: url ?? this.url,
        method: method ?? this.method,
        fields: fields ?? this.fields,
        bodyFormat: bodyFormat ?? this.bodyFormat,
        headers: headers ?? this.headers,
        otpField: otpField ?? this.otpField,
      );

  static HttpMethod _methodFrom(String? raw) {
    if (raw == null) return HttpMethod.POST;
    final upper = raw.toUpperCase();
    for (final m in HttpMethod.values) {
      if (m.name == upper) return m;
    }
    return HttpMethod.POST;
  }

  static Map<String, String> _stringMap(dynamic raw) {
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries) e.key.toString(): e.value?.toString() ?? '',
    };
  }
}

/// The full re-login recipe for one API.
///
/// This is what lets the tool mint a fresh token on its own instead of making
/// the user paste a new one into Apidog and re-run the whole wizard.
class LoginConfig {
  /// One step (credentials → token) or two (request OTP → verify → token).
  final List<LoginStep> steps;

  /// Dot-path to the token in the LAST step's JSON response (e.g. `data.token`).
  /// Null means "auto-detect from common field names".
  final String? tokenPath;

  /// Fixed OTP code for dev environments (e.g. `1111`). When set, the whole
  /// cycle runs unattended. When null and a step declares [LoginStep.otpField],
  /// the caller has to supply a code interactively.
  final String? fixedOtpCode;

  const LoginConfig({
    required this.steps,
    this.tokenPath,
    this.fixedOtpCode,
  });

  bool get isValid =>
      steps.isNotEmpty && steps.length <= 2 && steps.every((s) => s.isValid);

  /// True when any step needs an OTP code injected.
  bool get needsOtp => steps.any((s) => s.otpField != null);

  /// Whether [endpointPath] is one of this recipe's own login steps.
  ///
  /// Generating a login endpoint legitimately 401s on the spec's placeholder
  /// credentials, and re-authenticating can't fix that — so callers skip the
  /// re-login hook for it rather than burning a login call.
  ///
  /// Compares whole normalized paths. A suffix match would treat a step at
  /// `/auth/login` as covering a distinct `/login` endpoint and wrongly skip
  /// its re-login, which is the exact failure this feature exists to prevent.
  bool matchesLoginStep(String endpointPath) {
    final target = _normalizePath(endpointPath);
    if (target == '/') return false;
    return steps.any((s) => s.url.isNotEmpty && _normalizePath(s.url) == target);
  }

  static String _normalizePath(String raw) {
    final path = Uri.tryParse(raw)?.path ?? raw;
    final trimmed = path.replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return '/';
    return trimmed.startsWith('/') ? trimmed : '/$trimmed';
  }

  /// True when the whole flow can run with zero human input.
  bool get isUnattended =>
      !needsOtp || (fixedOtpCode != null && fixedOtpCode!.isNotEmpty);

  Map<String, dynamic> toJson() => {
        'steps': steps.map((s) => s.toJson()).toList(),
        if (tokenPath != null) 'tokenPath': tokenPath,
        if (fixedOtpCode != null) 'fixedOtpCode': fixedOtpCode,
      };

  static LoginConfig? fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'];
    if (rawSteps is! List || rawSteps.isEmpty) return null;

    final steps = <LoginStep>[];
    for (final raw in rawSteps) {
      if (raw is! Map) continue;
      final step = LoginStep.fromJson(Map<String, dynamic>.from(raw));
      if (step != null) steps.add(step);
    }
    if (steps.isEmpty) return null;

    return LoginConfig(
      steps: steps,
      tokenPath: json['tokenPath']?.toString(),
      fixedOtpCode: json['fixedOtpCode']?.toString(),
    );
  }

  LoginConfig copyWith({
    List<LoginStep>? steps,
    String? tokenPath,
    String? fixedOtpCode,
  }) =>
      LoginConfig(
        steps: steps ?? this.steps,
        tokenPath: tokenPath ?? this.tokenPath,
        fixedOtpCode: fixedOtpCode ?? this.fixedOtpCode,
      );
}

/// Persists a [LoginConfig] in `.api2dart/config.yaml` as a JSON blob under a
/// per-source key.
///
/// Namespacing by source name matters: credentials for one API must not be
/// reused against a different one that happens to be generated in the same
/// project. Mirrors the `output_overrides.<source>` scheme in `ApiWebServer`.
class LoginConfigStore {
  /// Config section holding every saved login recipe. Cleared wholesale by
  /// `api2dart reset`.
  static const String section = 'login';

  static String keyFor(String sourceName) {
    final src = sourceName
        .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return '$section.${src.isEmpty ? 'default' : src}';
  }

  static LoginConfig? load(String sourceName) {
    final raw = ConfigStorage.get(keyFor(sourceName));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return LoginConfig.fromJson(decoded);
    } catch (_) {/* corrupt entry — treat as absent */}
    return null;
  }

  static void save(String sourceName, LoginConfig config) {
    try {
      ConfigStorage.set(keyFor(sourceName), jsonEncode(config.toJson()));
    } catch (_) {/* best-effort */}
  }

  static void clear(String sourceName) {
    try {
      ConfigStorage.remove(keyFor(sourceName));
    } catch (_) {/* best-effort */}
  }
}
