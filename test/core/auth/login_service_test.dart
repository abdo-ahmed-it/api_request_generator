import 'dart:convert';

import 'package:api_to_dart/api_to_dart.dart';
import 'package:api_to_dart/src/core/auth/login_service.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _MockClient extends Mock implements http.Client {}

class _SilentLogger implements Logger {
  @override
  void d(String message) {}
  @override
  void i(String message) {}
  @override
  void w(String message) {}
  @override
  void e(String message, {Object? error}) {}
  @override
  void n(String message) {}
}

/// Captures the requests a step makes so tests can assert on headers/bodies.
LoginService _serviceWith(_MockClient client) => LoginService(
      httpClient: ApiHttpClient(logger: _SilentLogger(), client: client),
      logger: _SilentLogger(),
    );

void main() {
  setUpAll(() {
    registerFallbackValue(Uri.parse('https://example.com'));
  });

  group('LoginService.extractToken', () {
    test('finds a top-level token', () {
      expect(
        LoginService.extractToken('{"token":"abcdefgh12345"}'),
        'abcdefgh12345',
      );
    });

    test('finds a nested token when nothing is shallower', () {
      expect(
        LoginService.extractToken('{"data":{"token":"nested-token-value"}}'),
        'nested-token-value',
      );
    });

    test('prefers the SHALLOWEST match (BFS, not DFS)', () {
      // A depth-first walk would descend into `data` first and return the
      // nested value. Breadth-first must return the top-level one.
      const body = '{"data":{"token":"nested-token-value"},'
          '"access_token":"top-level-token"}';
      expect(LoginService.extractToken(body), 'top-level-token');
    });

    test('honours an explicit tokenPath over a top-level field', () {
      const body = '{"token":"wrong-token-here",'
          '"data":{"token":"right-token-here"}}';
      expect(
        LoginService.extractToken(body, tokenPath: 'data.token'),
        'right-token-here',
      );
    });

    test('walks array indices in a tokenPath', () {
      const body = '{"data":[{"token":"first-token-val"}]}';
      expect(
        LoginService.extractToken(body, tokenPath: 'data.0.token'),
        'first-token-val',
      );
    });

    test('a wrong tokenPath fails loudly instead of falling back', () {
      // There IS an auto-detectable token here, but the explicit path misses.
      // Returning it anyway would hide a config bug.
      const body = '{"token":"auto-detectable-token"}';
      expect(LoginService.extractToken(body, tokenPath: 'data.token'), isNull);
    });

    test('ignores short values that are not plausible tokens', () {
      expect(LoginService.extractToken('{"token":"no"}'), isNull);
    });

    test('ignores non-string token values', () {
      expect(LoginService.extractToken('{"token":true}'), isNull);
      expect(LoginService.extractToken('{"token":12345678}'), isNull);
    });

    test('returns null for a non-JSON body', () {
      expect(LoginService.extractToken('<html>500</html>'), isNull);
    });

    test('returns null when nothing matches', () {
      expect(LoginService.extractToken('{"user":{"name":"abdo"}}'), isNull);
    });
  });

  group('LoginService.locateToken', () {
    test('reports a top-level path', () {
      final found = LoginService.locateToken('{"token":"abcdefgh12345"}');
      expect(found!.path, 'token');
    });

    test('reports a nested path so setup can pin it', () {
      final found =
          LoginService.locateToken('{"data":{"access_token":"nested-tok-1"}}');
      expect(found!.path, 'data.access_token');
      expect(found.token, 'nested-tok-1');
    });

    test('reports an array path', () {
      final found =
          LoginService.locateToken('{"data":[{"token":"in-array-tok"}]}');
      expect(found!.path, 'data.0.token');
    });

    test('echoes back an explicit path', () {
      final found = LoginService.locateToken(
        '{"data":{"token":"right-token-here"}}',
        tokenPath: 'data.token',
      );
      expect(found!.path, 'data.token');
    });

    test('the reported path round-trips as an explicit lookup', () {
      const body = '{"result":{"auth":{"jwt":"deep-token-value"}}}';
      final found = LoginService.locateToken(body)!;
      // Whatever path we pin must find the same token on the next run.
      expect(LoginService.extractToken(body, tokenPath: found.path),
          found.token);
    });

    test('reports no path when a key contains a literal dot', () {
      // The path walker splits on '.', so `data.x.token` is unwalkable here.
      // Pinning it would make setup succeed and every later run fail.
      const body = '{"data.x":{"token":"dotted-key-token"}}';
      final found = LoginService.locateToken(body)!;

      expect(found.token, 'dotted-key-token');
      expect(found.path, isEmpty, reason: 'must not pin an unwalkable path');
    });

    test('every reported non-empty path round-trips', () {
      const bodies = [
        '{"token":"top-level-token"}',
        '{"data":{"token":"nested-token-x"}}',
        '{"data":[{"access_token":"array-token-1"}]}',
        '{"result":{"auth":{"jwt":"deep-token-value"}}}',
        '{"data.x":{"token":"dotted-key-token"}}',
      ];
      for (final body in bodies) {
        final found = LoginService.locateToken(body)!;
        if (found.path.isEmpty) continue; // deliberately not pinnable
        expect(LoginService.extractToken(body, tokenPath: found.path),
            found.token,
            reason: 'path "${found.path}" must round-trip for $body');
      }
    });
  });

  group('LoginService.login — single step', () {
    late _MockClient client;

    setUp(() => client = _MockClient());

    test('returns the token from a successful login', () async {
      when(() => client.post(any(),
              headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer(
              (_) async => http.Response('{"token":"fresh-token-123"}', 200));

      final result = await _serviceWith(client).login(
        const LoginConfig(steps: [
          LoginStep(url: '/login', fields: {'email': 'a@b.com'}),
        ]),
        baseUrl: 'https://api.example.com',
      );

      expect(result.isSuccess, isTrue);
      expect(result.token, 'fresh-token-123');
    });

    test('never sends an Authorization header (regression guard)', () async {
      // The whole point of re-login is that the old token is dead. Sending it
      // along would break APIs that reject requests with an expired bearer.
      final captured = <Map<String, String>?>[];
      when(() => client.post(any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'))).thenAnswer((invocation) async {
        captured.add(
            invocation.namedArguments[#headers] as Map<String, String>?);
        return http.Response('{"token":"fresh-token-123"}', 200);
      });

      await _serviceWith(client).login(
        const LoginConfig(steps: [LoginStep(url: '/login')]),
        baseUrl: 'https://api.example.com',
      );

      expect(captured, hasLength(1));
      final keys = captured.first!.keys.map((k) => k.toLowerCase());
      expect(keys, isNot(contains('authorization')));
    });

    test('reports an HTTP failure with its status code', () async {
      when(() => client.post(any(),
              headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('{"message":"bad creds"}', 422));

      final result = await _serviceWith(client).login(
        const LoginConfig(steps: [LoginStep(url: '/login')]),
        baseUrl: 'https://api.example.com',
      );

      expect(result.isSuccess, isFalse);
      expect(result.statusCode, 422);
      expect(result.failedStepIndex, 0);
      expect(result.error, contains('422'));
    });

    test('reports 200-with-no-token as a failure', () async {
      when(() => client.post(any(),
              headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('{"status":"ok"}', 200));

      final result = await _serviceWith(client).login(
        const LoginConfig(steps: [LoginStep(url: '/login')]),
        baseUrl: 'https://api.example.com',
      );

      expect(result.isSuccess, isFalse);
      expect(result.error, contains('no token'));
    });

    test('handles a non-JSON error page without throwing', () async {
      when(() => client.post(any(),
              headers: any(named: 'headers'), body: any(named: 'body')))
          .thenAnswer((_) async => http.Response('<html>oops</html>', 200));

      final result = await _serviceWith(client).login(
        const LoginConfig(steps: [LoginStep(url: '/login')]),
        baseUrl: 'https://api.example.com',
      );

      expect(result.isSuccess, isFalse);
    });

    test('rejects an invalid config without any network call', () async {
      final result = await _serviceWith(client)
          .login(const LoginConfig(steps: []), baseUrl: 'https://x.com');

      expect(result.isSuccess, isFalse);
      verifyNever(() => client.post(any(),
          headers: any(named: 'headers'), body: any(named: 'body')));
    });
  });

  group('LoginService.login — two-step OTP', () {
    late _MockClient client;

    setUp(() => client = _MockClient());

    const otpConfig = LoginConfig(
      steps: [
        LoginStep(url: '/send-otp', fields: {'phone': '0100'}),
        LoginStep(url: '/verify', fields: {'phone': '0100'}, otpField: 'code'),
      ],
      fixedOtpCode: '1111',
    );

    test('calls both steps in order and injects the OTP into step 2', () async {
      final urls = <String>[];
      final bodies = <String>[];

      when(() => client.post(any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'))).thenAnswer((invocation) async {
        urls.add((invocation.positionalArguments.first as Uri).path);
        bodies.add(invocation.namedArguments[#body] as String);
        // Only the verify response carries a token.
        return urls.length == 1
            ? http.Response('{"message":"sent"}', 200)
            : http.Response('{"token":"otp-token-abc123"}', 200);
      });

      final result = await _serviceWith(client)
          .login(otpConfig, baseUrl: 'https://api.example.com');

      expect(result.isSuccess, isTrue);
      expect(result.token, 'otp-token-abc123');
      expect(urls, ['/send-otp', '/verify']);

      // Step 1 has no OTP field; step 2 carries the fixed code.
      expect(jsonDecode(bodies[0]), {'phone': '0100'});
      expect(jsonDecode(bodies[1]), {'phone': '0100', 'code': '1111'});
    });

    test('an explicit otpCode overrides the stored fixed code', () async {
      final bodies = <String>[];
      when(() => client.post(any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'))).thenAnswer((invocation) async {
        bodies.add(invocation.namedArguments[#body] as String);
        return bodies.length == 1
            ? http.Response('{"message":"sent"}', 200)
            : http.Response('{"token":"otp-token-abc123"}', 200);
      });

      await _serviceWith(client).login(otpConfig,
          baseUrl: 'https://api.example.com', otpCode: '9999');

      expect(jsonDecode(bodies[1])['code'], '9999');
    });

    test('a failed step 1 never reaches step 2', () async {
      var calls = 0;
      when(() => client.post(any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'))).thenAnswer((_) async {
        calls++;
        return http.Response('{"message":"too many requests"}', 429);
      });

      final result = await _serviceWith(client)
          .login(otpConfig, baseUrl: 'https://api.example.com');

      expect(result.isSuccess, isFalse);
      expect(result.failedStepIndex, 0);
      expect(result.statusCode, 429);
      expect(calls, 1);
    });

    test('fails fast when an OTP is required but unavailable', () async {
      const noCode = LoginConfig(steps: [
        LoginStep(url: '/verify', fields: {'phone': '0100'}, otpField: 'code'),
      ]);

      final result = await _serviceWith(client)
          .login(noCode, baseUrl: 'https://api.example.com');

      expect(result.isSuccess, isFalse);
      expect(result.error, contains('OTP'));
      verifyNever(() => client.post(any(),
          headers: any(named: 'headers'), body: any(named: 'body')));
    });
  });
}
