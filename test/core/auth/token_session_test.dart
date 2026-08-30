import 'dart:io';

import 'package:api_to_dart/api_to_dart.dart';
import 'package:api_to_dart/src/core/auth/login_service.dart';
import 'package:api_to_dart/src/core/auth/token_session.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _MockLoginService extends Mock implements LoginService {}

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

const _singleStep = LoginConfig(steps: [
  LoginStep(url: '/login', fields: {'email': 'a@b.com'}),
]);

const _otpNoCode = LoginConfig(steps: [
  LoginStep(url: '/verify', fields: {'phone': '0100'}, otpField: 'code'),
]);

void main() {
  // TokenSession persists refreshed tokens via ConfigStorage, which writes to
  // the CWD — isolate every test in a temp dir so the real project config is
  // never touched.
  late Directory tempDir;
  late String originalCwd;

  setUpAll(() {
    registerFallbackValue(_singleStep);
  });

  setUp(() {
    originalCwd = Directory.current.path;
    tempDir = Directory.systemTemp.createTempSync('api2dart_session_test');
    Directory.current = tempDir;
  });

  tearDown(() {
    Directory.current = originalCwd;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TokenSession session({
    String? token = 'stale-token',
    LoginConfig? config = _singleStep,
    LoginService? service,
    Future<String?> Function()? promptForToken,
    Future<String?> Function()? promptForOtp,
  }) =>
      TokenSession(
        token: token,
        logger: _SilentLogger(),
        config: config,
        baseUrl: 'https://api.example.com',
        service: service,
        promptForToken: promptForToken,
        promptForOtp: promptForOtp,
      );

  group('refresh', () {
    test('adopts the new token on a successful login', () async {
      final service = _MockLoginService();
      when(() => service.login(any(),
              baseUrl: any(named: 'baseUrl'), otpCode: any(named: 'otpCode')))
          .thenAnswer((_) async => const LoginResult.success('brand-new-token'));

      final s = session(service: service);
      expect(await s.refresh(reason: 'test'), isTrue);
      expect(s.token, 'brand-new-token');
      expect(s.refreshed, isTrue);
    });

    test('persists the refreshed token so the web UI can pick it up', () async {
      final service = _MockLoginService();
      when(() => service.login(any(),
              baseUrl: any(named: 'baseUrl'), otpCode: any(named: 'otpCode')))
          .thenAnswer((_) async => const LoginResult.success('brand-new-token'));

      await session(service: service).refresh(reason: 'test');
      expect(ConfigStorage.get(kLastTokenKey), 'brand-new-token');
    });

    test('latches after a failed login — a second call skips the network',
        () async {
      // This is the anti-N-attempts guard: without it, a 50-endpoint run with
      // bad credentials would fire 50 login requests.
      final service = _MockLoginService();
      when(() => service.login(any(),
              baseUrl: any(named: 'baseUrl'), otpCode: any(named: 'otpCode')))
          .thenAnswer((_) async => const LoginResult(error: 'bad credentials'));

      final s = session(service: service);

      expect(await s.refresh(reason: 'first'), isFalse);
      expect(await s.refresh(reason: 'second'), isFalse);
      expect(await s.refresh(reason: 'third'), isFalse);

      verify(() => service.login(any(),
          baseUrl: any(named: 'baseUrl'),
          otpCode: any(named: 'otpCode'))).called(1);
      expect(s.canRefresh, isFalse);
      expect(s.gaveUp, isTrue);
    });

    test('adopts a manually pasted token when login fails', () async {
      final service = _MockLoginService();
      when(() => service.login(any(),
              baseUrl: any(named: 'baseUrl'), otpCode: any(named: 'otpCode')))
          .thenAnswer((_) async => const LoginResult(error: 'server down'));

      final s = session(
        service: service,
        promptForToken: () async => 'pasted-by-hand',
      );

      expect(await s.refresh(reason: 'test'), isTrue);
      expect(s.token, 'pasted-by-hand');
      expect(s.gaveUp, isFalse);
    });

    test('gives up when the paste prompt returns nothing', () async {
      final s = session(config: null, promptForToken: () async => '');
      expect(await s.refresh(reason: 'test'), isFalse);
      expect(s.gaveUp, isTrue);
    });

    test('works with no login config when a paste prompt exists', () async {
      final s = session(config: null, promptForToken: () async => 'hand-token');
      expect(s.canRefresh, isTrue);
      expect(await s.refresh(reason: 'test'), isTrue);
      expect(s.token, 'hand-token');
    });

    test('fails fast when an OTP is needed but nothing can supply it',
        () async {
      final service = _MockLoginService();
      final s = session(config: _otpNoCode, service: service);

      expect(await s.refresh(reason: 'test'), isFalse);
      // Must not have attempted the login — there is no code to send.
      verifyNever(() => service.login(any(),
          baseUrl: any(named: 'baseUrl'), otpCode: any(named: 'otpCode')));
    });

    test('asks for an OTP code interactively when no fixed code is set',
        () async {
      final service = _MockLoginService();
      when(() => service.login(any(),
              baseUrl: any(named: 'baseUrl'), otpCode: any(named: 'otpCode')))
          .thenAnswer((_) async => const LoginResult.success('otp-fresh-token'));

      final s = session(
        config: _otpNoCode,
        service: service,
        promptForOtp: () async => '4321',
      );

      expect(await s.refresh(reason: 'test'), isTrue);
      verify(() => service.login(any(),
          baseUrl: any(named: 'baseUrl'), otpCode: '4321')).called(1);
    });

    test('concurrent refreshes share one login call', () async {
      final service = _MockLoginService();
      when(() => service.login(any(),
              baseUrl: any(named: 'baseUrl'), otpCode: any(named: 'otpCode')))
          .thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return const LoginResult.success('brand-new-token');
      });

      final s = session(service: service);
      final results = await Future.wait([
        s.refresh(reason: 'a'),
        s.refresh(reason: 'b'),
        s.refresh(reason: 'c'),
      ]);

      expect(results, everyElement(isTrue));
      verify(() => service.login(any(),
          baseUrl: any(named: 'baseUrl'),
          otpCode: any(named: 'otpCode'))).called(1);
    });
  });

  group('canRefresh / markRefreshIneffective', () {
    test('is false with neither a login config nor a prompt', () {
      expect(session(config: null).canRefresh, isFalse);
    });

    test('is false for an invalid config', () {
      expect(
        session(config: const LoginConfig(steps: [])).canRefresh,
        isFalse,
      );
    });

    test('markRefreshIneffective stops all further attempts', () async {
      final service = _MockLoginService();
      when(() => service.login(any(),
              baseUrl: any(named: 'baseUrl'), otpCode: any(named: 'otpCode')))
          .thenAnswer((_) async => const LoginResult.success('brand-new-token'));

      final s = session(service: service);
      expect(s.canRefresh, isTrue);

      // A fresh token still hit 401 → this is a permissions problem, not expiry.
      s.markRefreshIneffective();

      expect(s.canRefresh, isFalse);
      expect(await s.refresh(reason: 'after'), isFalse);
      verifyNever(() => service.login(any(),
          baseUrl: any(named: 'baseUrl'), otpCode: any(named: 'otpCode')));
    });
  });

  group('syncFromConfig', () {
    test('picks up a token refreshed by the other isolate', () {
      ConfigStorage.set(kLastTokenKey, 'token-from-terminal');
      final s = session(token: 'old-token');

      expect(s.syncFromConfig(), isTrue);
      expect(s.token, 'token-from-terminal');
    });

    test('is a no-op when the stored token matches', () {
      ConfigStorage.set(kLastTokenKey, 'same-token');
      final s = session(token: 'same-token');
      expect(s.syncFromConfig(), isFalse);
    });

    test('is a no-op when nothing is stored', () {
      expect(session(token: 'unchanged').syncFromConfig(), isFalse);
    });
  });

  group('mask', () {
    test('shows only the ends of a long token', () {
      expect(TokenSession.mask('eyJhbGciOiJIUzI1NiJ9xxxx4f2a'), 'eyJh…4f2a');
    });

    test('barely reveals a short token', () {
      expect(TokenSession.mask('abc'), 'ab…');
    });

    test('handles null and empty', () {
      expect(TokenSession.mask(null), '');
      expect(TokenSession.mask(''), '');
    });
  });
}
