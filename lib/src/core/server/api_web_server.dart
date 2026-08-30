import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../auth/login_service.dart';
import '../auth/token_session.dart';
import '../generation/code_emitter.dart';
import '../generation/pubspec_inspector.dart';
import '../logger/logger.dart';
import '../models/api_endpoint.dart';
import '../models/api_folder.dart';
import '../models/auth_definition.dart';
import '../models/body_definition.dart';
import '../models/endpoint_tree.dart';
import '../models/login_config.dart';
import '../models/response_definition.dart';
import '../resolution/http_client.dart';
import '../resolution/response_resolver.dart';
import '../sources/api_fetchers/config_storage.dart';
import 'web_assets.dart';

/// Per-endpoint output overrides edited in the web UI's Output tab. All fields
/// are optional — a blank field means "use the derived default".
class OutputSettings {
  final String? outputDir; // override the dir (verbatim, no date appended)
  final String? fileName; // bare file name, e.g. "user.dart"
  final String? actionClass;
  final String? responseClass;
  final String? mode; // 'auto' | 'action' | 'response-only'

  const OutputSettings({
    this.outputDir,
    this.fileName,
    this.actionClass,
    this.responseClass,
    this.mode,
  });

  factory OutputSettings.fromJson(Map<String, dynamic> j) => OutputSettings(
        outputDir: _s(j['outputDir']),
        fileName: _s(j['fileName']),
        actionClass: _s(j['actionClass']),
        responseClass: _s(j['responseClass']),
        mode: _s(j['mode']),
      );

  Map<String, dynamic> toJson() => {
        if (outputDir != null) 'outputDir': outputDir,
        if (fileName != null) 'fileName': fileName,
        if (actionClass != null) 'actionClass': actionClass,
        if (responseClass != null) 'responseClass': responseClass,
        if (mode != null) 'mode': mode,
      };

  bool get isEmpty =>
      outputDir == null &&
      fileName == null &&
      actionClass == null &&
      responseClass == null &&
      mode == null;

  static String? _s(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }
}

/// A local, loopback-only web UI for selecting endpoints and generating code.
///
/// Reuses the exact same core pipeline as the `generate` command
/// ([ResponseResolver] → [CodeEmitter] → [RequestLog.writeToFile]) so output on
/// disk is identical. The browser receives the endpoint tree as JSON (each
/// endpoint carries a stable `index` into [EndpointTree.allEndpoints]) and
/// posts back the selected indexes.
class ApiWebServer {
  final EndpointTree tree;
  final String outputDir;
  final String logsDir;
  final String? baseUrl;
  final bool generateAction;
  final Logger logger;

  /// Owns the live token and knows how to mint a new one when it expires.
  final TokenSession session;

  /// The token to send with outgoing requests. Reads through the session so a
  /// mid-run refresh takes effect without touching the call sites.
  String? get token => session.token;

  /// Stable, ordered list matching the indexes handed to the browser.
  final List<ApiEndpoint> _ordered;

  /// Parallel list of folder labels for each endpoint in [_ordered].
  final List<String> _folderPaths;

  HttpServer? _server;

  /// Per-endpoint output overrides, keyed by [ApiEndpoint.key]. Loaded from
  /// `.api2dart/config.yaml` on first use and re-saved after each generate.
  final Map<String, OutputSettings> _settings = {};
  bool _settingsLoaded = false;

  /// Config key holding the JSON-encoded per-endpoint output overrides,
  /// namespaced by source so overrides from one API don't bleed into another
  /// that happens to share a `<METHOD> <path>` key.
  String get _settingsKey {
    final src = tree.sourceName
        .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return 'output_overrides.${src.isEmpty ? 'default' : src}';
  }

  /// [token] seeds the session; pass [session] instead to share one with a
  /// caller that already owns it (the in-process `serve` command does).
  ApiWebServer({
    required this.tree,
    required this.outputDir,
    required this.logsDir,
    required this.baseUrl,
    required this.generateAction,
    required this.logger,
    String? token,
    TokenSession? session,
  })  : session = session ??
            TokenSession(
              token: token,
              logger: logger,
              config: LoginConfigStore.load(tree.sourceName),
              baseUrl: baseUrl,
              service: LoginService(
                httpClient: ApiHttpClient(logger: logger),
                logger: logger,
              ),
            ),
        _ordered = tree.allEndpoints,
        _folderPaths = _buildFolderPaths(tree);

  /// Lazily loads saved overrides from config (JSON string under one key).
  Map<String, OutputSettings> get _savedSettings {
    if (!_settingsLoaded) {
      _settingsLoaded = true;
      final raw = ConfigStorage.get(_settingsKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw) as Map<String, dynamic>;
          decoded.forEach((k, v) {
            if (v is Map<String, dynamic>) {
              _settings[k] = OutputSettings.fromJson(v);
            }
          });
        } catch (_) {/* ignore corrupt config */}
      }
    }
    return _settings;
  }

  void _persistSettings() {
    final map = <String, dynamic>{};
    _savedSettings.forEach((k, s) {
      if (!s.isEmpty) map[k] = s.toJson();
    });
    try {
      ConfigStorage.set(_settingsKey, jsonEncode(map));
    } catch (_) {/* best-effort */}
  }

  /// Returns the effective output settings for an endpoint, merging any saved
  /// overrides with the server defaults.
  OutputSettings _effectiveSettings(ApiEndpoint ep) =>
      _savedSettings[ep.key] ?? const OutputSettings();

  /// Resolves [s.mode] (or the server default) into the action-vs-response
  /// boolean, matching the CLI's `auto` behavior.
  bool _generateActionFor(OutputSettings s) {
    switch (s.mode) {
      case 'action':
        return true;
      case 'response-only':
        return false;
      case 'auto':
        return PubspecInspector.hasApiRequestDependency();
      default:
        return generateAction; // server default (already resolved)
    }
  }

  /// The directory an endpoint writes to: its override (verbatim) or the
  /// server's default dated dir.
  String _outputDirFor(OutputSettings s) =>
      (s.outputDir?.isNotEmpty == true) ? s.outputDir! : outputDir;

  /// Applies name overrides to a copy of [ep] so the emitter/preview use them.
  ApiEndpoint _withOverrides(ApiEndpoint ep, OutputSettings s) {
    if (s.fileName == null &&
        s.actionClass == null &&
        s.responseClass == null) {
      return ep;
    }
    return ApiEndpoint(
      name: ep.name,
      path: ep.path,
      method: ep.method,
      description: ep.description,
      body: ep.body,
      headers: ep.headers,
      queryParams: ep.queryParams,
      auth: ep.auth,
      response: ep.response,
      baseUrlOverride: ep.baseUrlOverride,
      fileNameOverride: _sanitizeFile(s.fileName),
      actionClassOverride: _sanitizeClass(s.actionClass),
      responseClassOverride: _sanitizeClass(s.responseClass),
    );
  }

  /// Sanitizes a class name to a valid Dart-ish PascalCase identifier; returns
  /// null when blank (caller falls back to the derived default).
  static String? _sanitizeClass(String? v) {
    if (v == null) return null;
    final cleaned = v.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    if (cleaned.isEmpty) return null;
    final head = RegExp(r'^[a-zA-Z]').hasMatch(cleaned) ? cleaned : 'C$cleaned';
    return head[0].toUpperCase() + head.substring(1);
  }

  /// Ensures a file name is a single safe segment ending in `.dart`; returns
  /// null when blank. Path separators and `..` are stripped so a file name can
  /// never escape the output dir.
  static String? _sanitizeFile(String? v) {
    if (v == null) return null;
    // take only the last path segment, then allow a conservative char set
    var name = v.trim().replaceAll('\\', '/');
    name = name.contains('/') ? name.split('/').last : name;
    name = name.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    // collapse any leading dots (defeats "..", hidden files)
    name = name.replaceAll(RegExp(r'^\.+'), '');
    if (name.isEmpty) return null;
    if (!name.endsWith('.dart')) name = '$name.dart';
    return name;
  }

  /// Builds folder labels in the SAME order as [EndpointTree.allEndpoints]
  /// (root endpoints first, then a depth-first walk of folders), so the index
  /// the browser sends maps back to the correct endpoint.
  static List<String> _buildFolderPaths(EndpointTree tree) {
    final paths = <String>[];
    paths.addAll(List.filled(tree.rootEndpoints.length, ''));
    void walk(ApiFolder folder, String prefix) {
      final label = prefix.isEmpty ? folder.name : '$prefix / ${folder.name}';
      paths.addAll(List.filled(folder.endpoints.length, label));
      for (final sub in folder.subfolders) {
        walk(sub, label);
      }
    }

    for (final folder in tree.folders) {
      walk(folder, '');
    }
    return paths;
  }

  /// Binds to loopback only (never exposed to the network) and starts serving.
  /// Returns the URL the user should open.
  Future<String> start(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    final url = 'http://${server.address.host}:${server.port}';
    unawaited(_serve(server));
    return url;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      try {
        await _route(request);
      } catch (e) {
        _json(request, 500, {'error': e.toString()});
      }
    }
  }

  Future<void> _route(HttpRequest req) async {
    final path = req.uri.path;
    final method = req.method;

    if (method == 'GET' && (path == '/' || path == '/index.html')) {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(indexHtml);
      await req.response.close();
      return;
    }

    if (method == 'GET' && path == '/api/tree') {
      _json(req, 200, _treeJson());
      return;
    }

    if (method == 'GET' && path == '/api/endpoint') {
      _handleEndpointDetail(req);
      return;
    }

    if (method == 'GET' && path == '/api/preview') {
      _handlePreview(req);
      return;
    }

    if (method == 'GET' && path == '/api/dirs') {
      _handleDirs(req);
      return;
    }

    if (method == 'POST' && path == '/api/try') {
      final body = await utf8.decoder.bind(req).join();
      await _handleTry(req, body);
      return;
    }

    if (method == 'POST' && path == '/api/generate') {
      final body = await utf8.decoder.bind(req).join();
      await _handleGenerate(req, body);
      return;
    }

    if (method == 'POST' && path == '/api/relogin') {
      final body = await utf8.decoder.bind(req).join();
      await _handleRelogin(req, body);
      return;
    }

    _json(req, 404, {'error': 'Not found: $method $path'});
  }

  /// Returns the index from `?index=N`, or null (after writing a 400) if absent
  /// or out of range.
  int? _indexParam(HttpRequest req) {
    final raw = req.uri.queryParameters['index'];
    final idx = raw == null ? null : int.tryParse(raw);
    if (idx == null || idx < 0 || idx >= _ordered.length) {
      _json(req, 400, {'error': 'Invalid or missing ?index'});
      return null;
    }
    return idx;
  }

  /// Full editable detail for one endpoint — what the "request builder" panel
  /// pre-fills (method, full URL, headers, query params, body, auth).
  void _handleEndpointDetail(HttpRequest req) {
    final idx = _indexParam(req);
    if (idx == null) return;
    final ep = _ordered[idx];

    String? bodyKind;
    String bodyText = '';
    final formFields = <Map<String, String>>[];
    final body = ep.body;
    if (body != null && !body.isEmpty) {
      if (body.hasRawBody) {
        bodyKind = 'raw';
        bodyText = body.rawBody ?? '';
      } else if (body.hasFormFields) {
        bodyKind = body.contentType == BodyContentType.urlEncoded
            ? 'urlencoded'
            : 'formdata';
        body.formFields!.forEach((k, v) {
          formFields.add({'key': k, 'value': v});
        });
      }
    }

    final s = _effectiveSettings(ep);
    _json(req, 200, {
      'index': idx,
      'name': ep.name,
      'method': ep.method.name,
      'path': ep.path,
      'url': _fullUrl(ep),
      'description': ep.description,
      'folderPath': _folderPaths[idx],
      'headers': _kvList(ep.headers),
      'queryParams': _kvList(ep.queryParams),
      'auth': {
        'type': ep.auth.type.name,
        'token': ep.auth.token ?? '',
        'headerName': ep.auth.headerName,
      },
      'body': {
        'kind': bodyKind, // null | raw | formdata | urlencoded
        'raw': bodyText,
        'fields': formFields,
      },
      'responsePreview': ep.response?.jsonBody,
      // Output tab: current saved overrides (may be blank) + derived defaults
      // so the UI can show placeholders.
      'output': {
        'outputDir': s.outputDir ?? '',
        'fileName': s.fileName ?? '',
        'actionClass': s.actionClass ?? '',
        'responseClass': s.responseClass ?? '',
        'mode': s.mode ?? 'default',
        'defaults': {
          'outputDir': outputDir,
          'fileName': ep.fileName,
          'actionClass': ep.actionClassName,
          'responseClass': ep.responseClassName,
          'mode': generateAction ? 'action' : 'response-only',
        },
      },
    });
  }

  /// The generated Dart code for one endpoint, without writing to disk — uses
  /// the same [CodeEmitter.generateCode] the disk path uses. Honors in-flight
  /// Output-tab overrides passed as query params so the preview updates live.
  void _handlePreview(HttpRequest req) {
    final idx = _indexParam(req);
    if (idx == null) return;
    final base = _ordered[idx];

    // Live overrides from the Output tab (fall back to saved settings).
    final q = req.uri.queryParameters;
    final saved = _effectiveSettings(base);
    final s = OutputSettings(
      outputDir: q['outputDir'] ?? saved.outputDir,
      fileName: q['fileName'] ?? saved.fileName,
      actionClass: q['actionClass'] ?? saved.actionClass,
      responseClass: q['responseClass'] ?? saved.responseClass,
      mode: q['mode'] ?? saved.mode,
    );
    final ep = _withOverrides(base, s);
    final genAction = _generateActionFor(s);

    final emitter = CodeEmitter(logger: logger);
    final code = emitter.generateCode(
      endpoint: ep,
      response: ep.response,
      generateAction: genAction,
    );

    _json(req, 200, {
      'index': idx,
      'fileName': genAction
          ? ep.fileName
          : ep.fileName.replaceAll('_action.dart', '_response.dart'),
      'code': code ??
          '// No code could be generated for this endpoint yet.\n'
              '// Send the request first to capture a response, or check the mode.',
      'hasResponse': ep.response?.hasJson ?? false,
    });
  }

  /// Lists subdirectories under a project-relative path so the browser can let
  /// the user pick an output dir instead of typing it. Confined to the project
  /// root (the server's CWD) — `..` segments that would escape are clamped.
  void _handleDirs(HttpRequest req) {
    final root = Directory.current;
    // Normalize the requested relative path and keep it inside the project.
    var rel = (req.uri.queryParameters['path'] ?? '').trim();
    rel = rel.replaceAll('\\', '/');
    final parts = <String>[];
    for (final seg in rel.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    final relPath = parts.join('/');
    final dir = relPath.isEmpty ? root : Directory('${root.path}/$relPath');

    final dirs = <String>[];
    try {
      if (dir.existsSync()) {
        for (final e in dir.listSync(followLinks: false)) {
          if (e is Directory) {
            final name = e.path.split(Platform.pathSeparator).last;
            // hide dot-dirs and common noise
            if (name.startsWith('.')) continue;
            if (name == 'build' || name == '.dart_tool') continue;
            dirs.add(name);
          }
        }
      }
    } catch (_) {/* permission etc. — return what we have */}
    dirs.sort();

    _json(req, 200, {
      'path': relPath, // current relative path ('' = project root)
      'parent':
          parts.isEmpty ? null : parts.sublist(0, parts.length - 1).join('/'),
      'dirs': dirs,
    });
  }

  /// Refreshes the auth token on demand — the token chip's click handler.
  ///
  /// Accepts `{}`, `{"otp": "1111"}` to supply a code the config doesn't carry,
  /// or `{"token": "..."}` to paste one directly. Always answers 200 with an
  /// `ok` flag; a failed login is a normal outcome here, not a server error.
  Future<void> _handleRelogin(HttpRequest req, String rawBody) async {
    Map<String, dynamic> payload = const {};
    if (rawBody.trim().isNotEmpty) {
      try {
        payload = jsonDecode(rawBody) as Map<String, dynamic>;
      } catch (e) {
        _json(req, 400, {'ok': false, 'error': 'Invalid request body: $e'});
        return;
      }
    }

    // A token pasted in the browser wins outright — no login needed.
    final pasted = (payload['token'] as String?)?.trim();
    if (pasted != null && pasted.isNotEmpty) {
      session.adopt(pasted);
      _json(req, 200, {
        'ok': true,
        'token': TokenSession.mask(session.token),
        'source': 'pasted',
      });
      return;
    }

    if (!session.hasLogin) {
      _json(req, 200, {
        'ok': false,
        'error': 'Auto re-login is not configured for this source. '
            'Run `api2dart generate` in the terminal to set it up, '
            'or paste a token here.',
        'hasLogin': false,
      });
      return;
    }

    final otp = (payload['otp'] as String?)?.trim();
    final ok = await session.refresh(
      reason: 'manual refresh from the web UI',
      otpCode: (otp != null && otp.isNotEmpty) ? otp : null,
    );

    _json(req, 200, {
      'ok': ok,
      if (ok) 'token': TokenSession.mask(session.token),
      if (ok) 'source': 'login',
      if (!ok)
        'error': 'Re-login failed. Check the saved credentials '
            '(or paste a token instead).',
      'hasLogin': true,
    });
  }

  /// Sends a one-off request with the (possibly edited) values from the browser
  /// and returns the live response — the "Try it / Send" feature. Does NOT
  /// write any files.
  Future<void> _handleTry(HttpRequest req, String rawBody) async {
    // The terminal may have refreshed the token in the other isolate; pick it
    // up before sending anything with a stale one.
    session.syncFromConfig();

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(rawBody) as Map<String, dynamic>;
    } catch (e) {
      _json(req, 400, {'error': 'Invalid request body: $e'});
      return;
    }

    final rawUrl = (payload['url'] as String?)?.trim() ?? '';
    if (rawUrl.isEmpty) {
      _json(req, 400, {'error': 'A URL is required to send the request.'});
      return;
    }
    final method = _parseMethod(payload['method'] as String? ?? 'GET');
    final headers = _kvToMap(payload['headers']);
    final panelQuery = _kvToMap(payload['queryParams']);
    final bodyDef = _bodyFromPayload(payload['body']);

    // Merge query params already in the URL with those from the params panel
    // (panel wins on conflicts), so neither source is silently dropped — the
    // HttpClient's .replace(queryParameters:) would otherwise overwrite one.
    final parsed = Uri.parse(rawUrl);
    final mergedQuery = <String, String>{
      ...parsed.queryParameters,
      ...panelQuery,
    };
    final url = parsed.replace(query: '').toString();

    // Apply the session token the same way the generate path does (Bearer by
    // default) unless the user already set an Authorization header.
    final hasAuthHeader =
        headers.keys.any((k) => k.toLowerCase() == 'authorization');
    final auth = (!hasAuthHeader && token != null && token!.isNotEmpty)
        ? AuthDefinition(type: AuthType.bearer, token: token)
        : null;

    final httpClient = ApiHttpClient(logger: logger);
    final result = await httpClient.request(
      url: url,
      method: method,
      headers: headers.isNotEmpty ? headers : null,
      queryParams: mergedQuery.isNotEmpty ? mergedQuery : null,
      body: bodyDef,
      auth: auth,
    );

    if (result == null) {
      _json(req, 200, {
        'ok': false,
        'error': 'Request failed (no response). Check the URL and network.',
      });
      return;
    }

    _json(req, 200, {
      'ok': true,
      'status': result.statusCode,
      'timeMs': result.receivedTime.difference(result.sentTime).inMilliseconds,
      'requestUrl': result.requestUrl,
      'responseHeaders': result.headers,
      'body': result.body,
    });
  }

  /// Serializes the FULL nested tree (folders → subfolders → endpoints),
  /// assigning each endpoint a stable `index` in the SAME order as
  /// [EndpointTree.allEndpoints] (root endpoints first, then each folder's
  /// endpoints, then its subfolders — depth-first). This mirrors the terminal
  /// selector's tree exactly so the browser can render the same hierarchy.
  Map<String, dynamic> _treeJson() {
    // The flat list is already in allEndpoints order; map identity → index.
    final indexOf = <ApiEndpoint, int>{};
    for (var i = 0; i < _ordered.length; i++) {
      indexOf[_ordered[i]] = i;
    }

    Map<String, dynamic> endpointNode(ApiEndpoint ep) => {
          'type': 'endpoint',
          'index': indexOf[ep],
          'name': ep.name,
          'method': ep.method.name,
          'path': ep.path,
          'requiresAuth': ep.requiresAuth,
        };

    Map<String, dynamic> folderNode(ApiFolder f) => {
          'type': 'folder',
          'name': f.name,
          'count': f.totalEndpoints,
          // Match allEndpoints order within a folder: own endpoints first,
          // then subfolders.
          'children': [
            ...f.endpoints.map(endpointNode),
            ...f.subfolders.map(folderNode),
          ],
        };

    final roots = <Map<String, dynamic>>[
      ...tree.rootEndpoints.map(endpointNode),
      ...tree.folders.map(folderNode),
    ];

    // Reflect a token the terminal may have refreshed since the page loaded.
    session.syncFromConfig();

    return {
      'sourceName': tree.sourceName,
      'mode': generateAction ? 'action + response' : 'response-only',
      'outputDir': outputDir,
      'baseUrl': baseUrl ?? '',
      'total': _ordered.length,
      'roots': roots,
      'hasToken': token != null && token!.isNotEmpty,
      'hasLogin': session.hasLogin,
      'token': TokenSession.mask(token),
    };
  }

  /// Best-effort full URL for an endpoint: `base + path`, normalizing the slash
  /// at the join. Uses the endpoint's per-endpoint [ApiEndpoint.baseUrlOverride]
  /// (set by Apidog URL-variable resolution) when present, else the default
  /// base URL. Falls back to the raw path when neither is available.
  String _fullUrl(ApiEndpoint ep) {
    final b = ep.baseUrlOverride ?? baseUrl ?? '';
    if (b.isEmpty) return ep.path;
    final base = b.endsWith('/') ? b.substring(0, b.length - 1) : b;
    final path = ep.path.startsWith('/') ? ep.path : '/${ep.path}';
    return '$base$path';
  }

  List<Map<String, String>> _kvList(Map<String, String> map) =>
      map.entries.map((e) => {'key': e.key, 'value': e.value}).toList();

  /// Converts the browser's `[{key, value}]` list back into a string map,
  /// skipping blank keys.
  Map<String, String> _kvToMap(dynamic list) {
    final out = <String, String>{};
    if (list is List) {
      for (final item in list) {
        if (item is Map) {
          final k = (item['key'] ?? '').toString().trim();
          if (k.isEmpty) continue;
          out[k] = (item['value'] ?? '').toString();
        }
      }
    }
    return out;
  }

  HttpMethod _parseMethod(String raw) {
    final upper = raw.toUpperCase();
    return HttpMethod.values.firstWhere(
      (m) => m.name == upper,
      orElse: () => HttpMethod.GET,
    );
  }

  /// Builds a [BodyDefinition] from the browser's body payload
  /// (`{kind, raw, fields}`).
  BodyDefinition? _bodyFromPayload(dynamic body) {
    if (body is! Map) return null;
    final kind = body['kind'] as String?;
    if (kind == 'raw') {
      final raw = (body['raw'] ?? '').toString();
      if (raw.isEmpty) return null;
      return BodyDefinition(contentType: BodyContentType.rawJson, rawBody: raw);
    }
    if (kind == 'formdata' || kind == 'urlencoded') {
      final fields = _kvToMap(body['fields']);
      if (fields.isEmpty) return null;
      return BodyDefinition(
        contentType: kind == 'urlencoded'
            ? BodyContentType.urlEncoded
            : BodyContentType.formData,
        formFields: fields,
      );
    }
    return null;
  }

  Future<void> _handleGenerate(HttpRequest req, String rawBody) async {
    final List<int> indexes;
    Map<String, dynamic> settingsJson = const {};
    try {
      final decoded = jsonDecode(rawBody) as Map<String, dynamic>;
      indexes = (decoded['selectedIndexes'] as List)
          .map((e) => (e as num).toInt())
          .where((i) => i >= 0 && i < _ordered.length)
          .toList();
      if (decoded['settings'] is Map<String, dynamic>) {
        settingsJson = decoded['settings'] as Map<String, dynamic>;
      }
    } catch (e) {
      _json(req, 400, {'error': 'Invalid request body: $e'});
      return;
    }

    if (indexes.isEmpty) {
      _json(req, 400, {'error': 'No endpoints selected.'});
      return;
    }

    // Merge incoming per-endpoint settings over the saved ones, then persist.
    settingsJson.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        final s = OutputSettings.fromJson(v);
        if (s.isEmpty) {
          _savedSettings.remove(k);
        } else {
          _savedSettings[k] = s;
        }
      }
    });
    _persistSettings();

    final buffer = _BufferingLogger(logger);
    final httpClient = ApiHttpClient(logger: buffer);
    final resolver = ResponseResolver(httpClient: httpClient);
    final emitter = CodeEmitter(logger: buffer);

    // Pick up a token the terminal side may have refreshed, then route login
    // progress into the buffer so "↻ Re-authenticating…" reaches the browser
    // through the existing `logs` payload.
    session.syncFromConfig();
    session.attachLogger(buffer);

    final defaultBaseUrl = baseUrl ?? '';
    // Each resolved endpoint, paired with its response + effective output opts.
    final pending = <_PendingEmit>[];
    final generated = <Map<String, dynamic>>[];
    final skipped = <Map<String, dynamic>>[];

    for (final i in indexes) {
      final raw = _ordered[i];
      final s = _effectiveSettings(raw);
      final endpoint = _withOverrides(raw, s);
      final resolvedBaseUrl = endpoint.baseUrlOverride ?? defaultBaseUrl;
      buffer.i('Processing ${endpoint.method.name} ${endpoint.path}...');

      Future<ResolveResult> attempt() async {
        try {
          return await resolver.resolve(
            endpoint,
            baseUrl: resolvedBaseUrl,
            token: session.token,
          );
        } catch (e) {
          return ResolveResult(response: ResponseDefinition.empty);
        }
      }

      var result = await attempt();

      // Auto re-login: an expired token would otherwise fail every remaining
      // endpoint. Retry this one exactly once with a fresh token.
      var status = result.log?.statusCode;
      // Skip the hook for the login endpoints themselves: generating one
      // legitimately 401s on the spec's placeholder credentials, and
      // re-authenticating can't fix that.
      final isLoginEndpoint =
          session.config?.matchesLoginStep(endpoint.path) ?? false;
      if ((status == 401 || status == 403) &&
          !isLoginEndpoint &&
          session.canRefresh) {
        buffer.w('↻ ${endpoint.name}: token rejected ($status) — '
            're-authenticating…');
        if (await session.refresh(reason: '$status on ${endpoint.name}')) {
          result = await attempt();
          status = result.log?.statusCode;
          if (status == 401 || status == 403) {
            session.markRefreshIneffective();
            buffer.w('  Still $status with a fresh token — '
                'treating this as a permissions issue, not expiry.');
          }
        }
      }

      final logFileName = endpoint.fileName.replaceAll('.dart', '');
      String? logFile;
      if (result.log != null) {
        result.log!.writeToFile(logsDir, logFileName);
        logFile = '$logsDir/$logFileName.md';
      }

      if (status != null && (status < 200 || status >= 300)) {
        skipped.add({
          'name': endpoint.name,
          'reason': 'request failed ($status)',
          'logFile': logFile,
          if (status == 401 || status == 403) 'kind': 'auth',
        });
        continue;
      }

      pending.add(_PendingEmit(endpoint, result.response, s));
    }

    // Emit one endpoint at a time, each to its own dir/mode, so we can report
    // the file path per endpoint.
    for (final p in pending) {
      final filePath = emitter.emit(
        endpoint: p.endpoint,
        outputDir: _outputDirFor(p.settings),
        response: p.response,
        generateAction: _generateActionFor(p.settings),
      );
      if (filePath != null) {
        generated.add({'file': filePath, 'status': 200});
      } else {
        skipped.add({
          'name': p.endpoint.name,
          'reason': 'nothing to generate (no response data)',
        });
      }
    }

    _json(req, 200, {
      'generated': generated,
      'skipped': skipped,
      'logs': buffer.messages,
      'outputDir': outputDir,
      'logsDir': logsDir,
      'tokenRefreshed': session.refreshed,
      'authFailed': session.gaveUp,
      'token': TokenSession.mask(session.token),
    });
    session.clearRefreshedFlag();
  }

  void _json(HttpRequest req, int status, Object body) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    req.response.close();
  }
}

/// One endpoint ready to emit, carrying its resolved response and effective
/// output settings so each writes to its own dir/name/mode.
class _PendingEmit {
  final ApiEndpoint endpoint;
  final ResponseDefinition? response;
  final OutputSettings settings;
  _PendingEmit(this.endpoint, this.response, this.settings);
}

/// A [Logger] that mirrors messages to an underlying logger (terminal) while
/// also collecting them so they can be returned to the browser.
class _BufferingLogger implements Logger {
  final Logger _inner;
  final List<String> messages = [];

  _BufferingLogger(this._inner);

  @override
  void d(String message) {
    messages.add(message);
    _inner.d(message);
  }

  @override
  void i(String message) {
    messages.add(message);
    _inner.i(message);
  }

  @override
  void w(String message) {
    messages.add('⚠ $message');
    _inner.w(message);
  }

  @override
  void e(String message, {Object? error}) {
    messages.add('✗ $message${error != null ? ': $error' : ''}');
    _inner.e(message, error: error);
  }

  @override
  void n(String message) {
    messages.add(message);
    _inner.n(message);
  }
}

/// A no-op logger used inside the server isolate so it never writes to the
/// terminal (which the interactive selector owns in the main isolate).
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

/// Everything the server isolate needs to construct an [ApiWebServer]. All
/// fields are plain immutable data, so this passes cleanly across the isolate
/// boundary.
class WebServerConfig {
  final EndpointTree tree;
  final String outputDir;
  final String logsDir;
  final String? baseUrl;
  final String? token;
  final bool generateAction;
  final int port;
  final SendPort replyPort;

  const WebServerConfig({
    required this.tree,
    required this.outputDir,
    required this.logsDir,
    required this.baseUrl,
    required this.token,
    required this.generateAction,
    required this.port,
    required this.replyPort,
  });
}

/// Spawns the web server in a dedicated isolate and returns its URL.
///
/// This is what lets the web UI stay responsive while the main isolate is
/// blocked on the terminal selector's synchronous `readKey()` — the server's
/// own event loop runs independently. The browser can hit it any time.
///
/// Returns null if the server failed to start (e.g. the port is busy).
Future<String?> spawnWebServerIsolate({
  required EndpointTree tree,
  required String outputDir,
  required String logsDir,
  required String? baseUrl,
  required String? token,
  required bool generateAction,
  required int port,
}) async {
  final reply = ReceivePort();
  await Isolate.spawn(
    _webServerIsolateEntry,
    WebServerConfig(
      tree: tree,
      outputDir: outputDir,
      logsDir: logsDir,
      baseUrl: baseUrl,
      token: token,
      generateAction: generateAction,
      port: port,
      replyPort: reply.sendPort,
    ),
  );
  // The isolate sends back the URL string on success, or null on failure.
  final result = await reply.first;
  reply.close();
  return result as String?;
}

/// Isolate entrypoint: starts the server and reports its URL (or null) back.
Future<void> _webServerIsolateEntry(WebServerConfig config) async {
  try {
    final server = ApiWebServer(
      tree: config.tree,
      outputDir: config.outputDir,
      logsDir: config.logsDir,
      baseUrl: config.baseUrl,
      token: config.token,
      generateAction: config.generateAction,
      logger: _SilentLogger(),
    );
    final url = await server.start(config.port);
    config.replyPort.send(url);
    // Keep the isolate alive so the server keeps serving.
  } catch (_) {
    config.replyPort.send(null);
  }
}
