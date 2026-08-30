import 'dart:collection';
import 'dart:convert';

import '../logger/logger.dart';
import '../models/login_config.dart';
import '../resolution/http_client.dart';

/// Outcome of running a [LoginConfig].
class LoginResult {
  final String? token;

  /// Human-readable failure reason. Safe to print — never contains credentials.
  final String? error;

  /// Index of the step that failed, when the failure was an HTTP error.
  final int? failedStepIndex;
  final int? statusCode;

  /// Dot-path the token was found at. Set when auto-detection located it, so
  /// setup can pin the path and later runs don't have to guess again.
  final String? tokenPath;

  const LoginResult({
    this.token,
    this.error,
    this.failedStepIndex,
    this.statusCode,
    this.tokenPath,
  });

  const LoginResult.success(String this.token, {this.tokenPath})
      : error = null,
        failedStepIndex = null,
        statusCode = null;

  bool get isSuccess => token != null && token!.isNotEmpty;
}

/// Runs a login sequence against the target API and returns a fresh token.
///
/// Handles both shapes the wizard supports: a single credentials call, and a
/// two-step OTP flow (request the code, then verify it). Steps run in order and
/// only the LAST step's response is searched for a token.
class LoginService {
  final ApiHttpClient _httpClient;
  final Logger _logger;

  LoginService({required ApiHttpClient httpClient, required Logger logger})
      : _httpClient = httpClient,
        _logger = logger;

  /// Field names checked when [LoginConfig.tokenPath] isn't set. Shared with
  /// the wizard's environment-variable lookup so both agree on what a token
  /// looks like.
  static const List<String> tokenFieldNames = [
    'token',
    'access_token',
    'accessToken',
    'authToken',
    'auth_token',
    'jwt',
    'id_token',
    'idToken',
  ];

  /// Shortest value accepted as a token. Guards against picking up flags like
  /// `"token": "no"` during auto-detection.
  static const int _minTokenLength = 8;

  /// Executes [config] and returns a fresh token.
  ///
  /// [otpCode] overrides [LoginConfig.fixedOtpCode] — used when the code had to
  /// be typed by a human. Credential values are never logged.
  Future<LoginResult> login(
    LoginConfig config, {
    String? baseUrl,
    String? otpCode,
  }) async {
    if (!config.isValid) {
      return const LoginResult(error: 'Login config is incomplete.');
    }

    final code = (otpCode != null && otpCode.isNotEmpty)
        ? otpCode
        : config.fixedOtpCode;

    if (config.needsOtp && (code == null || code.isEmpty)) {
      return const LoginResult(
          error: 'This login needs an OTP code, but none was supplied.');
    }

    String? lastBody;

    for (var i = 0; i < config.steps.length; i++) {
      final step = config.steps[i];
      final url = step.resolvedUrl(baseUrl);
      if (Uri.tryParse(url) == null) {
        return LoginResult(
          error: 'Step ${i + 1} has an invalid URL: $url',
          failedStepIndex: i,
        );
      }

      _logger.d('Login step ${i + 1}/${config.steps.length}: '
          '${step.method.name} $url');

      // auth: null is deliberate — the login endpoint must never carry the
      // stale token we're trying to replace.
      final result = await _httpClient.request(
        url: url,
        method: step.method,
        headers: step.headers.isNotEmpty ? step.headers : null,
        body: step.toBody(otpCode: code),
        auth: null,
      );

      if (result == null) {
        return LoginResult(
          error: 'Step ${i + 1} got no response (network error or bad URL).',
          failedStepIndex: i,
        );
      }

      if (!result.isSuccess) {
        return LoginResult(
          error: 'Step ${i + 1} failed with HTTP ${result.statusCode}: '
              '${_truncate(result.body, 200)}',
          failedStepIndex: i,
          statusCode: result.statusCode,
        );
      }

      lastBody = result.body;
    }

    if (lastBody == null || lastBody.isEmpty) {
      return const LoginResult(error: 'Login succeeded but returned no body.');
    }

    final found = locateToken(lastBody, tokenPath: config.tokenPath);
    if (found == null) {
      final where = config.tokenPath != null
          ? 'at "${config.tokenPath}"'
          : 'under any of ${tokenFieldNames.join(", ")}';
      return LoginResult(
        error: 'Login succeeded but no token was found $where. '
            'Response: ${_truncate(lastBody, 200)}',
      );
    }

    // An empty path means "found it, but it can't be expressed as a dot-path"
    // — leave the config on auto-detect rather than pinning something broken.
    return LoginResult.success(
      found.token,
      tokenPath: found.path.isEmpty ? null : found.path,
    );
  }

  /// Pulls a token out of a JSON response body.
  ///
  /// With [tokenPath] set, only that dot-path is consulted — a miss is an error
  /// rather than a silent fallback, because a wrong path is a config bug worth
  /// surfacing. Without it, falls back to a breadth-first search for the first
  /// [tokenFieldNames] key holding a plausible string; breadth-first so a
  /// top-level `token` beats a nested `user.profile.token`.
  ///
  /// Returns null when the body isn't JSON or nothing matches.
  static String? extractToken(String jsonBody, {String? tokenPath}) =>
      locateToken(jsonBody, tokenPath: tokenPath)?.token;

  /// Like [extractToken] but also reports the dot-path the token was found at,
  /// which setup pins into the saved config so later runs skip the guesswork.
  static ({String token, String path})? locateToken(
    String jsonBody, {
    String? tokenPath,
  }) {
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonBody);
    } catch (_) {
      return null;
    }

    if (tokenPath != null && tokenPath.isNotEmpty) {
      final value = _walkPath(decoded, tokenPath);
      return (value is String && value.isNotEmpty)
          ? (token: value, path: tokenPath)
          : null;
    }

    final found = _bfsForToken(decoded);
    if (found == null) return null;

    // A key containing a literal '.' produces a path that can't be walked back
    // (the walker splits on '.'). Pinning it would make setup succeed and every
    // later run fail, so report no path and let auto-detection keep working.
    final roundTrips = _walkPath(decoded, found.path) == found.token;
    return roundTrips ? found : (token: found.token, path: '');
  }

  /// Walks a dot-path like `data.token` or `data.0.token` over decoded JSON.
  static dynamic _walkPath(dynamic root, String path) {
    dynamic current = root;
    for (final part in path.split('.')) {
      if (part.isEmpty) continue;
      if (current is Map) {
        if (!current.containsKey(part)) return null;
        current = current[part];
      } else if (current is List) {
        final index = int.tryParse(part);
        if (index == null || index < 0 || index >= current.length) return null;
        current = current[index];
      } else {
        return null;
      }
    }
    return current;
  }

  /// Breadth-first scan for the shallowest recognizable token field, carrying
  /// each node's dot-path so the winner can be reported.
  static ({String token, String path})? _bfsForToken(dynamic root) {
    final queue = Queue<({dynamic node, String path})>()
      ..add((node: root, path: ''));

    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      final node = current.node;
      final prefix = current.path.isEmpty ? '' : '${current.path}.';

      if (node is Map) {
        // Check every candidate name at this depth before descending, so
        // shallower matches win regardless of key order.
        for (final name in tokenFieldNames) {
          final value = node[name];
          if (value is String && value.length >= _minTokenLength) {
            return (token: value, path: '$prefix$name');
          }
        }
        node.forEach((key, value) {
          queue.add((node: value, path: '$prefix$key'));
        });
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          queue.add((node: node[i], path: '$prefix$i'));
        }
      }
    }
    return null;
  }

  static String _truncate(String text, int maxLength) =>
      text.length <= maxLength ? text : '${text.substring(0, maxLength)}...';
}
