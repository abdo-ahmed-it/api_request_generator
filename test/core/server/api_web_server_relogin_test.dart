import 'dart:convert';
import 'dart:io';

import 'package:api_to_dart/api_to_dart.dart';
import 'package:api_to_dart/src/core/auth/login_service.dart';
import 'package:api_to_dart/src/core/auth/token_session.dart';
import 'package:test/test.dart';

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

/// A stand-in upstream API: rejects the stale token, accepts the fresh one, and
/// mints tokens from its own `/login` route. Counts hits so tests can prove how
/// many login calls a run actually made.
class _FakeApi {
  late HttpServer _server;
  String origin = '';

  /// Token the API currently considers valid. Null means "reject everything".
  String? validToken;
  final String mintedToken;

  /// When true, a successful login still doesn't make the token work — the way
  /// a genuine permissions error behaves, as opposed to an expired token.
  final bool rejectEvenAfterLogin;

  int loginHits = 0;
  int dataHits = 0;

  _FakeApi({
    this.validToken,
    this.mintedToken = 'fresh-token-abc123',
    this.rejectEvenAfterLogin = false,
  });

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${_server.port}';
    _server.listen((req) async {
      // Drain the body so the connection completes cleanly.
      await utf8.decoder.bind(req).join();

      if (req.uri.path == '/login') {
        loginHits++;
        // Logging in normally makes the fresh token valid; in the
        // permissions-error scenario it deliberately doesn't.
        if (!rejectEvenAfterLogin) validToken = mintedToken;
        _respond(req, 200, '{"data":{"token":"$mintedToken"}}');
        return;
      }

      dataHits++;
      final auth = req.headers.value('authorization');
      final ok = validToken != null && auth == 'Bearer $validToken';
      _respond(
        req,
        ok ? 200 : 401,
        ok ? '{"id":1,"name":"ok"}' : '{"message":"Unauthenticated"}',
      );
    });
  }

  void _respond(HttpRequest req, int status, String body) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(body);
    req.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

Future<Map<String, dynamic>> _postJson(String url, Object body) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    return jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

Future<Map<String, dynamic>> _getJson(String url) async {
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    final text = await utf8.decoder.bind(res).join();
    return jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

ApiEndpoint _ep(String name, String path) =>
    ApiEndpoint(name: name, path: path, method: HttpMethod.GET);

void main() {
  // The server persists tokens through ConfigStorage (CWD-relative), so keep
  // every test in its own temp dir.
  late Directory tempDir;
  late String originalCwd;

  setUp(() {
    originalCwd = Directory.current.path;
    tempDir = Directory.systemTemp.createTempSync('api2dart_relogin_test');
    Directory.current = tempDir;
  });

  tearDown(() {
    Directory.current = originalCwd;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TokenSession sessionFor(_FakeApi api, {LoginConfig? config, String? token}) =>
      TokenSession(
        token: token,
        logger: _SilentLogger(),
        config: config,
        baseUrl: api.origin,
        service: LoginService(
          httpClient: ApiHttpClient(logger: _SilentLogger()),
          logger: _SilentLogger(),
        ),
      );

  LoginConfig loginConfig() => const LoginConfig(
        steps: [
          LoginStep(
            url: '/login',
            fields: {'email': 'a@b.com', 'password': 'secret'},
          ),
        ],
      );

  group('POST /api/relogin', () {
    late _FakeApi api;
    late ApiWebServer server;
    late String base;

    Future<void> startServer({LoginConfig? config, String? token}) async {
      server = ApiWebServer(
        tree: EndpointTree(
          sourceName: 'Relogin Test',
          rootEndpoints: [_ep('Profile', '/profile')],
        ),
        outputDir: 'out/actions',
        logsDir: 'out/logs',
        baseUrl: api.origin,
        generateAction: false,
        logger: _SilentLogger(),
        session: sessionFor(api, config: config, token: token),
      );
      base = await server.start(0);
    }

    setUp(() async {
      api = _FakeApi();
      await api.start();
    });

    tearDown(() async {
      await server.stop();
      await api.stop();
    });

    test('answers 200 with ok:false when no login is configured', () async {
      await startServer();

      final res = await _postJson('$base/api/relogin', {});

      expect(res['ok'], isFalse);
      expect(res['hasLogin'], isFalse);
      expect(res['error'], isNotNull);
    });

    test('refreshes the token when a login is configured', () async {
      await startServer(config: loginConfig(), token: 'stale');

      final res = await _postJson('$base/api/relogin', {});

      expect(res['ok'], isTrue);
      expect(api.loginHits, 1);
    });

    test('never returns the raw token to the browser', () async {
      await startServer(config: loginConfig(), token: 'stale');

      final res = await _postJson('$base/api/relogin', {});

      expect(res['token'], isNotNull);
      expect(res['token'], isNot(contains(api.mintedToken)));
      expect(res['token'], TokenSession.mask(api.mintedToken));
    });

    test('accepts a pasted token without calling the login endpoint', () async {
      await startServer(token: 'stale');

      final res =
          await _postJson('$base/api/relogin', {'token': 'pasted-by-hand'});

      expect(res['ok'], isTrue);
      expect(res['source'], 'pasted');
      expect(api.loginHits, 0);
    });

    test('rejects a malformed body with 400, not a crash', () async {
      await startServer();

      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('$base/api/relogin'));
        req.headers.contentType = ContentType.json;
        req.write('{not json');
        final res = await req.close();
        expect(res.statusCode, 400);
        await utf8.decoder.bind(res).join();
      } finally {
        client.close();
      }
    });
  });

  group('/api/tree token status', () {
    late _FakeApi api;
    late ApiWebServer server;

    setUp(() async {
      api = _FakeApi();
      await api.start();
    });

    tearDown(() async {
      await server.stop();
      await api.stop();
    });

    test('reports hasToken/hasLogin and a masked token', () async {
      server = ApiWebServer(
        tree: EndpointTree(
          sourceName: 'Tree Status',
          rootEndpoints: [_ep('Profile', '/profile')],
        ),
        outputDir: 'out/actions',
        logsDir: 'out/logs',
        baseUrl: api.origin,
        generateAction: false,
        logger: _SilentLogger(),
        session:
            sessionFor(api, config: loginConfig(), token: 'a-stale-token-x'),
      );
      final base = await server.start(0);

      final tree = await _getJson('$base/api/tree');

      expect(tree['hasToken'], isTrue);
      expect(tree['hasLogin'], isTrue);
      expect(tree['token'], TokenSession.mask('a-stale-token-x'));
      expect(tree['token'], isNot('a-stale-token-x'));
    });

    test('reports hasLogin:false when nothing is configured', () async {
      server = ApiWebServer(
        tree: EndpointTree(
          sourceName: 'No Login',
          rootEndpoints: [_ep('Profile', '/profile')],
        ),
        outputDir: 'out/actions',
        logsDir: 'out/logs',
        baseUrl: api.origin,
        generateAction: false,
        logger: _SilentLogger(),
        session: sessionFor(api),
      );
      final base = await server.start(0);

      final tree = await _getJson('$base/api/tree');

      expect(tree['hasToken'], isFalse);
      expect(tree['hasLogin'], isFalse);
    });
  });

  group('generate with an expired token', () {
    late _FakeApi api;
    late ApiWebServer server;
    late String base;

    tearDown(() async {
      await server.stop();
      await api.stop();
    });

    Future<void> startWith(EndpointTree tree) async {
      server = ApiWebServer(
        tree: tree,
        outputDir: 'out/actions',
        logsDir: 'out/logs',
        baseUrl: api.origin,
        generateAction: false,
        logger: _SilentLogger(),
        session: sessionFor(api, config: loginConfig(), token: 'expired-token'),
      );
      base = await server.start(0);
    }

    test('re-logs in and retries the SAME endpoint, then continues', () async {
      // The upstream rejects the stale token until /login is hit.
      api = _FakeApi(validToken: null);
      await api.start();
      await startWith(EndpointTree(
        sourceName: 'Expiry',
        rootEndpoints: [_ep('Profile', '/profile')],
      ));

      final res = await _postJson('$base/api/generate', {
        'selectedIndexes': [0],
      });

      expect(res['tokenRefreshed'], isTrue);
      expect(res['authFailed'], isFalse);
      expect((res['generated'] as List), hasLength(1));
      expect((res['skipped'] as List), isEmpty);
      expect(api.loginHits, 1);
      // First attempt (401) + retry (200).
      expect(api.dataHits, 2);
    });

    test('makes exactly ONE login attempt across N failing endpoints',
        () async {
      // The upstream rejects everything, even a freshly minted token — this is
      // a permissions problem, not expiry. Without the give-up latch, every
      // endpoint would trigger its own login.
      api = _FakeApi(validToken: null, rejectEvenAfterLogin: true);
      await api.start();

      await startWith(EndpointTree(
        sourceName: 'Always 401',
        rootEndpoints: [
          _ep('One', '/one'),
          _ep('Two', '/two'),
          _ep('Three', '/three'),
          _ep('Four', '/four'),
          _ep('Five', '/five'),
        ],
      ));

      final res = await _postJson('$base/api/generate', {
        'selectedIndexes': [0, 1, 2, 3, 4],
      });

      expect(res['authFailed'], isTrue);
      expect((res['generated'] as List), isEmpty);
      expect((res['skipped'] as List), hasLength(5));
      // The whole run pays for one login, not five.
      expect(api.loginHits, 1);
    });

    test('a non-auth failure does not trigger a login at all', () async {
      // 404s and 500s are not auth problems; re-logging in would be pure waste.
      api = _FakeApi(validToken: 'expired-token');
      await api.start();

      server = ApiWebServer(
        tree: EndpointTree(
          sourceName: 'Not Auth',
          rootEndpoints: [_ep('Profile', '/profile')],
        ),
        outputDir: 'out/actions',
        logsDir: 'out/logs',
        baseUrl: api.origin,
        generateAction: false,
        logger: _SilentLogger(),
        // Token matches, so the upstream answers 200 — no auth failure path.
        session: sessionFor(api, config: loginConfig(), token: 'expired-token'),
      );
      base = await server.start(0);

      final res = await _postJson('$base/api/generate', {
        'selectedIndexes': [0],
      });

      expect(res['tokenRefreshed'], isFalse);
      expect(api.loginHits, 0);
    });
  });
}
