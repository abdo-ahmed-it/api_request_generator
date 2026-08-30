import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/auth/login_service.dart';
import '../../core/auth/token_session.dart';
import '../../core/generation/code_emitter.dart';
import '../../core/generation/pubspec_inspector.dart';
import '../../core/logger/console_logger.dart';
import '../../core/logger/logger.dart';
import '../../core/models/api_endpoint.dart';
import '../../core/models/api_source_config.dart';
import '../../core/models/body_definition.dart';
import '../../core/models/endpoint_tree.dart';
import '../../core/models/login_config.dart';
import '../../core/models/response_definition.dart';
import '../../core/resolution/http_client.dart';
import '../../core/resolution/response_resolver.dart';
import '../../core/server/api_web_server.dart';
import '../../core/server/browser_token_capture.dart';
import '../../core/sources/api_fetchers/apidog_fetcher.dart';
import '../../core/sources/api_fetchers/config_storage.dart';
import '../../core/sources/api_fetchers/postman_fetcher.dart';
import '../../core/sources/gitignore_guard.dart';
import '../../core/sources/openapi_source.dart';
import '../../core/sources/postman_source.dart';
import '../../core/sources/url_variable_resolver.dart';
import '../ui/endpoint_selector.dart';
import '../ui/file_browser.dart';
import '../ui/prompts.dart';
import '../ui/terminal_utils.dart';

class GenerateWizard {
  final Logger _logger;

  /// Whether auto re-login setup has already been offered this run. Declining
  /// must not re-ask once per remaining endpoint.
  bool _offeredLoginSetup = false;

  GenerateWizard({Logger? logger}) : _logger = logger ?? ConsoleLogger();

  Future<void> run() async {
    _printBanner();

    // Check for saved settings
    final savedSource = ConfigStorage.get('wizard.source');
    _LoadResult? loadResult;

    if (savedSource != null) {
      // Try to load from saved settings
      loadResult = await _loadFromSavedSettings(savedSource);

      if (loadResult == null) {
        _logger.w('Saved settings failed. Starting fresh.');
        ConfigStorage.remove('wizard');
      }
    }

    // If no saved settings or they failed, ask the user
    if (loadResult == null) {
      loadResult = await _step1SelectAndLoad();
      if (loadResult == null) return;
    }

    // Resolve Apidog URL-variable path prefixes ONCE, up front, so the tree
    // shown in the terminal, served to the web UI, and used for generation are
    // all identical (clean paths + per-endpoint base URL overrides).
    final tree = UrlVariableResolver(loadResult.urlVariables)
        .resolveTree(loadResult.tree);
    var baseUrl = loadResult.baseUrl;
    var token = loadResult.token;

    if (tree.isEmpty) {
      _logger.w('No endpoints found.');
      return;
    }

    // Ask for base URL and token if not available (for live fetch)
    if (baseUrl == null || baseUrl.isEmpty) {
      final savedBaseUrl = ConfigStorage.get('wizard.base_url');
      if (savedBaseUrl != null && savedBaseUrl.isNotEmpty) {
        baseUrl = savedBaseUrl;
        _logger.i('✓ Base URL: $baseUrl');
      } else {
        stdout.writeln('');
        baseUrl = promptInput(
          message: 'Base URL (for fetching live responses)',
          hint: 'e.g. https://api.example.com',
        );
        if (baseUrl != null && baseUrl.isNotEmpty) {
          ConfigStorage.set('wizard.base_url', baseUrl);
        }
      }
    }

    if (token == null || token.isEmpty) {
      // A token minted by a previous run's auto re-login beats asking again.
      final lastToken = ConfigStorage.get(kLastTokenKey);
      if (lastToken != null && lastToken.isNotEmpty) {
        token = lastToken;
        _logger.i('✓ Reusing the last refreshed token '
            '(${TokenSession.mask(token)})');
      } else {
        token = promptInput(
          message: 'Auth token (leave empty to skip)',
        );
      }
    }

    // Owns the token for the whole run. Mutable and shared by reference, so a
    // mid-run re-login stays visible across every select→generate cycle below.
    final session = _buildSession(
      token: token,
      tree: tree,
      baseUrl: baseUrl,
    );

    // Opt-in offer up front. Declining costs nothing — the same offer comes
    // back automatically the first time a 401 actually lands.
    if (session.config == null &&
        stdin.hasTerminal &&
        token != null &&
        token.isNotEmpty) {
      _offeredLoginSetup = true;
      stdout.writeln('');
      if (promptConfirm(
        message: 'Set up auto re-login? '
            '(recovers on its own when this token expires)',
        defaultValue: false,
      )) {
        final config = await _setupLogin(tree, baseUrl);
        if (config != null) session.applyConfig(config);
      }
    }

    stdout.writeln('');

    // Optional web UI — starts alongside the terminal selector and prints a
    // link the user *may* click to browse/select/generate in the browser. The
    // terminal flow below is unchanged; the server keeps running until the
    // process exits (Ctrl+C).
    final webRunning = await _maybeStartWebServer(
      tree: tree,
      baseUrl: baseUrl,
      token: token,
    );

    // Step 2 & 3: Select and generate loop
    final selector = EndpointSelector(tree);

    while (true) {
      stdout.writeln('');
      final selected = selector.selectInteractively();

      if (selected == null || selected.isEmpty) {
        if (webRunning) {
          _logger.i('Terminal selection done. The web UI is still running — '
              'use it any time, or press Ctrl+C to stop.');
          // Keep the process alive so the web UI stays reachable.
          await Completer<void>().future;
        }
        _logger.i('Done.');
        return;
      }

      stdout.writeln('');
      _logger.i('Selected ${selected.length} endpoints — generating...');
      stdout.writeln('');

      await _step3Generate(
        endpoints: selected,
        baseUrl: baseUrl ?? '',
        session: session,
        tree: tree,
      );

      // Deselect generated endpoints but keep tree state
      selector.deselectAll();
    }
  }

  void _printBanner() {
    stdout.writeln('');
    stdout
        .writeln(TerminalUtils.bold('┌─────────────────────────────────────┐'));
    stdout.writeln(
        TerminalUtils.bold('│   🚀 API to Dart                     │'));
    stdout
        .writeln(TerminalUtils.bold('└─────────────────────────────────────┘'));
    stdout.writeln('');
  }

  /// Best-effort: spins up the local web UI alongside the terminal selector and
  /// prints a link the user may optionally open to browse/select/generate in
  /// the browser. Writes the same files (same outputDir/logsDir/mode) as the
  /// terminal flow. A failure (e.g. busy port) is non-fatal — the wizard
  /// continues in the terminal as usual.
  /// Returns true if the web server started (so the caller can tell the user
  /// to Ctrl+C to stop it on exit).
  Future<bool> _maybeStartWebServer({
    required EndpointTree tree,
    required String? baseUrl,
    required String? token,
  }) async {
    try {
      final generateAction = PubspecInspector.hasApiRequestDependency();
      final dateFolder = _todayFolder();
      final outputDir = 'api2dart/$dateFolder/actions';
      final logsDir = 'api2dart/$dateFolder/logs';

      // Run the server in its own isolate. The terminal selector below blocks
      // the main isolate on synchronous key reads, so an in-process server
      // would never get a chance to answer the browser. A separate isolate
      // keeps the web UI responsive.
      //
      // Try the friendly default port first; if it's busy (e.g. another run is
      // still up), fall back to an OS-assigned free port so the link always
      // appears rather than silently disappearing.
      var url = await spawnWebServerIsolate(
        tree: tree,
        outputDir: outputDir,
        logsDir: logsDir,
        baseUrl: baseUrl,
        token: token,
        generateAction: generateAction,
        port: 4321,
      );
      url ??= await spawnWebServerIsolate(
        tree: tree,
        outputDir: outputDir,
        logsDir: logsDir,
        baseUrl: baseUrl,
        token: token,
        generateAction: generateAction,
        port: 0,
      );
      if (url == null) return false;

      stdout.writeln(
          TerminalUtils.gray('  ◦ Prefer a browser? Open the web UI: ') +
              TerminalUtils.cyan(url));
      stdout.writeln(TerminalUtils.gray(
          '    (optional — the terminal selector below works too)'));
      stdout.writeln('');
      return true;
    } catch (_) {
      // Non-fatal: the terminal selector is always available.
      return false;
    }
  }

  // ── Load from saved settings ────────────────────────────────────────

  Future<_LoadResult?> _loadFromSavedSettings(String source) async {
    switch (source) {
      case 'local':
        final filePath = ConfigStorage.get('wizard.file_path');
        if (filePath == null) return null;
        _logger.i('Using saved settings: local file ($filePath)');
        return _loadLocalFile(filePath);

      case 'postman_api':
        final apiKey = ConfigStorage.get('postman.api_key');
        final collectionUid =
            ConfigStorage.get('wizard.postman_collection_uid');
        if (apiKey == null || collectionUid == null) return null;

        // Refresh environment variables if one was previously selected.
        final envUid = ConfigStorage.get('wizard.postman_environment_uid');
        final envName = ConfigStorage.get('wizard.postman_environment_name');
        Map<String, String>? envVars;
        if (envUid != null && envUid.isNotEmpty) {
          _logger.i(
              'Using saved settings: Postman API (Env: ${envName ?? envUid})');
          final fetcher = PostmanFetcher(apiKey: apiKey, logger: _logger);
          final env = await fetcher.getEnvironment(envUid);
          if (env != null) {
            envVars = env.variables;
            _logger.i('✓ Loaded ${envVars.length} environment variables');
          }
        } else {
          _logger.i('Using saved settings: Postman API');
        }

        return _fetchPostmanCollection(apiKey, collectionUid,
            environmentVars: envVars);

      case 'apidog_api':
        final token = ConfigStorage.get('apidog.token');
        final projectId = ConfigStorage.get('apidog.last_project_id');
        if (token == null || projectId == null) return null;
        final envIdStr = ConfigStorage.get('apidog.environment_id');
        final envId = envIdStr != null ? int.tryParse(envIdStr) : null;
        final envName = ConfigStorage.get('apidog.environment_name') ?? '';
        _logger.i(
            'Using saved settings: Apidog (Project: $projectId, Env: $envName)');

        // Fetch fresh environment variables
        final fetcher = ApidogFetcher(token: token, logger: _logger);
        Map<String, String>? envVars;
        if (envId != null) {
          final envs = await fetcher.getEnvironments(projectId);
          final env = envs.where((e) => e.id == envId).firstOrNull;
          if (env != null) {
            envVars = env.variables;
            _logger.i('✓ Loaded ${envVars.length} environment variables');
          }
        }

        return _fetchApidogProject(token, projectId,
            environmentId: envId, envVariables: envVars);

      default:
        return null;
    }
  }

  // ── Step 1: Select source and load ──────────────────────────────────

  Future<_LoadResult?> _step1SelectAndLoad() async {
    final sourceIndex = promptSelect(
      message: 'Select source',
      options: [
        '📁 Browse local file',
        '🌐 Postman (fetch from API)',
        '🌐 Apidog (fetch from API)',
      ],
    );

    if (sourceIndex == -1) return null;

    switch (sourceIndex) {
      case 0:
        return _loadFromLocalFile();
      case 1:
        return _loadFromPostmanApi();
      case 2:
        return _loadFromApidogApi();
      default:
        return null;
    }
  }

  // ── Local file ──────────────────────────────────────────────────────

  Future<_LoadResult?> _loadFromLocalFile() async {
    final filePath = browseFiles(
      message: 'Select collection or spec file',
      allowedExtensions: ['.json', '.yaml', '.yml'],
    );

    if (filePath == null) return null;

    final result = await _loadLocalFile(filePath);
    if (result != null) {
      // Save settings
      ConfigStorage.set('wizard.source', 'local');
      ConfigStorage.set('wizard.file_path', filePath);
    }
    return result;
  }

  Future<_LoadResult?> _loadLocalFile(String filePath) async {
    stdout.writeln('');

    final ext = filePath.toLowerCase();
    EndpointTree tree;

    if (ext.endsWith('.json')) {
      _logger.i('Parsing as Postman collection...');
      try {
        final source = PostmanSource();
        tree = await source.parse(ApiSourceConfig(filePath: filePath));

        final file = File(filePath);
        final content = jsonDecode(file.readAsStringSync());
        final vars = _extractPostmanVariables(content);

        _logger.i('✓ ${tree.sourceName}: ${tree.totalEndpoints} endpoints');
        if (vars['base_url'] != null) {
          _logger.i('✓ Base URL: ${vars['base_url']}');
        }

        return _LoadResult(
          tree: tree,
          baseUrl: vars['base_url'],
          token: vars['token'],
        );
      } catch (_) {
        _logger.i('Not a Postman collection — trying OpenAPI...');
      }
    }

    try {
      _logger.i('Parsing as OpenAPI spec...');
      final source = OpenApiSource();
      tree = await source.parse(ApiSourceConfig(filePath: filePath));
      _logger.i('✓ ${tree.sourceName}: ${tree.totalEndpoints} endpoints');
      return _LoadResult(tree: tree);
    } catch (e) {
      _logger.e('Failed to parse file', error: e);
      return null;
    }
  }

  Map<String, String?> _extractPostmanVariables(
      Map<String, dynamic> collection) {
    final vars = <String, String?>{};
    final varList = collection['variable'] as List<dynamic>? ?? [];
    for (final v in varList) {
      if (v is Map) {
        final key = v['key']?.toString();
        final value = v['value']?.toString();
        if (key != null && value != null) {
          vars[key] = value;
        }
      }
    }
    return vars;
  }

  // ── Sign in (token capture) ─────────────────────────────────────────

  /// Acquires a provider token via the browser-based guided-paste flow, with a
  /// graceful fallback to a plain terminal prompt.
  ///
  /// Neither Apidog nor Postman exposes an OAuth / device-flow login, so the
  /// user must create the token on the provider's page either way. The browser
  /// flow opens that page for them and captures the pasted token automatically
  /// (no terminal paste). If the local capture server can't start or the user
  /// times out, we fall back to the classic terminal prompt so the wizard
  /// always works (e.g. headless/CI, no browser).
  Future<String?> _signIn({
    required String providerName,
    required String tokenPageUrl,
    required String terminalPrompt,
    List<String>? steps,
  }) async {
    final captured = await BrowserTokenCapture(logger: _logger).captureToken(
      providerName: providerName,
      tokenPageUrl: tokenPageUrl,
      steps: steps,
    );
    if (captured != null && captured.isNotEmpty) return captured;

    // Fallback: classic terminal prompt.
    stdout.writeln('');
    stdout.writeln(TerminalUtils.gray('  Get your token from: $tokenPageUrl'));
    stdout.writeln('');
    return promptInput(message: terminalPrompt);
  }

  // ── Postman API ─────────────────────────────────────────────────────

  Future<_LoadResult?> _loadFromPostmanApi() async {
    var apiKey = ConfigStorage.get('postman.api_key');

    if (apiKey == null || apiKey.isEmpty) {
      apiKey = await _signIn(
        providerName: 'Postman',
        tokenPageUrl: 'https://postman.co/settings/me/api-keys',
        terminalPrompt: 'Postman API Key',
        steps: [
          'On the API keys page, click <strong>Generate API Key</strong>.',
          'Name it, then copy the generated key.',
        ],
      );
      if (apiKey == null || apiKey.isEmpty) return null;

      ConfigStorage.set('postman.api_key', apiKey);
      _logger.i('✓ API key saved');
    }

    final fetcher = PostmanFetcher(apiKey: apiKey, logger: _logger);

    stdout.writeln('');
    _logger.i('Loading workspaces...');
    final workspaces = await fetcher.getWorkspaces();

    if (workspaces.isEmpty) {
      _logger.e('No workspaces found. The saved Postman API key may be invalid '
          'or expired.\n'
          '  Run `api2dart reset --all` to clear it and try a new one.');
      return null;
    }

    final wsIndex = promptSelect(
      message: 'Select workspace',
      options: workspaces.map((w) => '${w.name} (${w.type})').toList(),
    );
    if (wsIndex == -1) return null;
    final workspaceId = workspaces[wsIndex].id;

    // Environment selection (optional)
    _logger.i('Loading environments...');
    final environments =
        await fetcher.getEnvironments(workspaceId: workspaceId);
    PostmanEnvironment? selectedEnv;

    if (environments.isEmpty) {
      _logger.i('No environments in this workspace — skipping.');
    } else {
      final options = ['(no environment)', ...environments.map((e) => e.name)];
      final envIndex = promptSelect(
        message: 'Select environment',
        options: options,
      );
      if (envIndex == -1) return null;

      if (envIndex > 0) {
        final envInfo = environments[envIndex - 1];
        _logger.i('Loading environment "${envInfo.name}"...');
        selectedEnv = await fetcher.getEnvironment(envInfo.uid);
        if (selectedEnv != null) {
          _logger.i(
              '✓ Environment: ${selectedEnv.name} (${selectedEnv.variables.length} variables)');
        } else {
          _logger.w('Failed to load environment, continuing without it.');
        }
      }
    }

    _logger.i('Loading collections...');
    final collections = await fetcher.getCollections(workspaceId: workspaceId);

    if (collections.isEmpty) {
      _logger.e('No collections found in this workspace');
      return null;
    }

    final colIndex = promptSelect(
      message: 'Select collection',
      options: collections.map((c) => c.name).toList(),
    );
    if (colIndex == -1) return null;

    final result = await _fetchPostmanCollection(
      apiKey,
      collections[colIndex].uid,
      environmentVars: selectedEnv?.variables,
    );

    if (result != null) {
      // Save settings
      ConfigStorage.set('wizard.source', 'postman_api');
      ConfigStorage.set(
          'wizard.postman_collection_uid', collections[colIndex].uid);
      if (selectedEnv != null) {
        ConfigStorage.set('wizard.postman_environment_uid', selectedEnv.uid);
        ConfigStorage.set('wizard.postman_environment_name', selectedEnv.name);
      } else {
        ConfigStorage.remove('wizard.postman_environment_uid');
        ConfigStorage.remove('wizard.postman_environment_name');
      }
    }
    return result;
  }

  Future<_LoadResult?> _fetchPostmanCollection(
    String apiKey,
    String collectionUid, {
    Map<String, String>? environmentVars,
  }) async {
    final fetcher = PostmanFetcher(apiKey: apiKey, logger: _logger);

    _logger.i('Loading collection...');
    final collectionJson = await fetcher.getCollection(collectionUid);

    if (collectionJson == null) {
      _logger.e('Failed to fetch collection');
      return null;
    }

    final tempFile = File('.api2dart_temp_collection.json');
    tempFile.writeAsStringSync(collectionJson);

    try {
      final source = PostmanSource();
      final tree = await source.parse(ApiSourceConfig(filePath: tempFile.path));

      final content = jsonDecode(collectionJson);
      // Merge: collection variables first, environment variables override.
      final vars = <String, String?>{
        ..._extractPostmanVariables(content),
        if (environmentVars != null) ...environmentVars,
      };

      _logger.i('✓ ${tree.sourceName}: ${tree.totalEndpoints} endpoints');

      // Pick base URL from common variable names.
      final baseUrl =
          vars['base_url'] ?? vars['baseUrl'] ?? vars['url'] ?? vars['host'];
      if (baseUrl != null && baseUrl.isNotEmpty) {
        _logger.i('✓ Base URL: $baseUrl');
      }

      final token = vars['token'] ??
          vars['access_token'] ??
          vars['accessToken'] ??
          vars['auth_token'];

      return _LoadResult(
        tree: tree,
        baseUrl: baseUrl,
        token: token,
      );
    } finally {
      if (tempFile.existsSync()) tempFile.deleteSync();
    }
  }

  // ── Apidog API ──────────────────────────────────────────────────────

  Future<_LoadResult?> _loadFromApidogApi() async {
    var token = ConfigStorage.get('apidog.token');

    if (token == null || token.isEmpty) {
      token = await _signIn(
        providerName: 'Apidog',
        tokenPageUrl: 'https://app.apidog.com/',
        terminalPrompt: 'Apidog API Token',
        steps: [
          'Click your avatar (top-right) → <strong>Account Settings</strong>.',
          'Open <strong>API Access Token</strong> → '
              '<strong>Create a new personal token</strong>.',
          'Name it, pick a validity, then copy the token (shown once).',
        ],
      );
      if (token == null || token.isEmpty) return null;

      ConfigStorage.set('apidog.token', token);
      _logger.i('✓ Token saved');
    }

    final fetcher = ApidogFetcher(token: token, logger: _logger);

    // Fetch projects
    stdout.writeln('');
    _logger.i('Loading projects...');
    final projects = await fetcher.getProjects();

    if (projects.isEmpty) {
      _logger.e('No projects found. The saved Apidog token may be invalid '
          'or expired.\n'
          '  Run `api2dart reset --all` to clear it and try a new one.');
      return null;
    }

    final projIndex = promptSelect(
      message: 'Select project',
      options: projects.map((p) => p.name).toList(),
    );
    if (projIndex == -1) return null;

    final projectId = projects[projIndex].id;

    // Fetch environments
    _logger.i('Loading environments...');
    final environments = await fetcher.getEnvironments(projectId);

    ApidogEnvironment? selectedEnv;

    if (environments.isNotEmpty) {
      final envIndex = promptSelect(
        message: 'Select environment',
        options: environments.map((e) => '${e.name} (${e.baseUrl})').toList(),
      );
      if (envIndex == -1) return null;
      selectedEnv = environments[envIndex];

      _logger.i('✓ Environment: ${selectedEnv.name}');
      _logger.i('✓ Base URL: ${selectedEnv.baseUrl}');
      if (selectedEnv.variables.isNotEmpty) {
        _logger.i('✓ Variables: ${selectedEnv.variables.keys.join(', ')}');
      }
    } else {
      _logger.w('Could not fetch environments');
    }

    final result = await _fetchApidogProject(
      token,
      projectId,
      environmentId: selectedEnv?.id,
      envVariables: selectedEnv?.variables,
    );

    if (result != null) {
      ConfigStorage.set('wizard.source', 'apidog_api');
      ConfigStorage.set('apidog.last_project_id', projectId);
      if (selectedEnv != null) {
        ConfigStorage.set('apidog.environment_id', selectedEnv.id.toString());
        ConfigStorage.set('apidog.environment_name', selectedEnv.name);
      }
    }
    return result;
  }

  Future<_LoadResult?> _fetchApidogProject(
    String token,
    String projectId, {
    int? environmentId,
    Map<String, String>? envVariables,
  }) async {
    final fetcher = ApidogFetcher(token: token, logger: _logger);

    _logger.i('Exporting project as OpenAPI...');
    final openApiJson =
        await fetcher.exportOpenApi(projectId, environmentId: environmentId);

    if (openApiJson == null) {
      _logger.e('Failed to export project. Check your token and project ID.');
      return null;
    }

    // Resolve {{variables}} in the exported spec using environment variables
    // Skip URL-type variables (they get embedded in paths and break them)
    var resolvedJson = openApiJson;
    int resolvedCount = 0;
    if (envVariables != null && envVariables.isNotEmpty) {
      envVariables.forEach((key, value) {
        if (value.startsWith('http://') || value.startsWith('https://')) {
          // URL variable — don't replace in spec, it would corrupt paths
          return;
        }
        if (value.isEmpty) return;
        resolvedJson = resolvedJson.replaceAll('{{$key}}', value);
        resolvedCount++;
      });
      if (resolvedCount > 0) {
        _logger.i('✓ Resolved $resolvedCount environment variables');
      }
    }

    final tempFile = File('.api2dart_temp_openapi.json');
    tempFile.writeAsStringSync(resolvedJson);

    try {
      final source = OpenApiSource();
      final tree = await source.parse(ApiSourceConfig(filePath: tempFile.path));

      // Extract base URL from environment or servers
      String? baseUrl;
      if (envVariables != null) {
        baseUrl = envVariables['url'] ?? envVariables['base_url'];
      }
      if (baseUrl == null || baseUrl.isEmpty) {
        try {
          final spec = jsonDecode(resolvedJson);
          final servers = spec['servers'];
          if (servers is List && servers.isNotEmpty) {
            baseUrl = servers[0]['url']?.toString();
          }
        } catch (_) {}
      }

      if (baseUrl != null && baseUrl.isNotEmpty) {
        _logger.i('✓ Base URL: $baseUrl');
      }

      _logger.i('✓ ${tree.sourceName}: ${tree.totalEndpoints} endpoints');

      // Collect URL-type variables for path resolution
      final urlVars = <String, String>{};
      if (envVariables != null) {
        envVariables.forEach((key, value) {
          if (value.startsWith('http://') || value.startsWith('https://')) {
            urlVars[key] = value;
          }
        });
      }

      return _LoadResult(
        tree: tree,
        baseUrl: baseUrl,
        token: envVariables?['token'] ?? envVariables?['mobile_token'],
        urlVariables: urlVars,
      );
    } catch (e) {
      _logger.e('Failed to parse exported spec', error: e);
      return null;
    } finally {
      if (tempFile.existsSync()) tempFile.deleteSync();
    }
  }

  // ── Step 3: Generate ───────────────────────────────────────────────

  /// Date folder name (YYYY-MM-DD) used to group each run's output.
  String _todayFolder() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  Future<void> _step3Generate({
    required List<ApiEndpoint> endpoints,
    required String baseUrl,
    required TokenSession session,
    required EndpointTree tree,
  }) async {
    final generateAction = PubspecInspector.hasApiRequestDependency();
    final rootOutputDir = 'api2dart';
    final dateFolder = _todayFolder();
    final outputDir = '$rootOutputDir/$dateFolder/actions';
    final logsDir = '$rootOutputDir/$dateFolder/logs';
    if (generateAction) {
      _logger.i('Detected `api_request` package → '
          'generating actions + responses in $outputDir');
    } else {
      _logger.i('No `api_request` package detected → '
          'generating response-only models in $outputDir');
    }

    final httpClient = ApiHttpClient(logger: _logger);
    final resolver = ResponseResolver(httpClient: httpClient);
    final emitter = CodeEmitter(logger: _logger);

    final endpointResponses = <ApiEndpoint, ResponseDefinition?>{};

    for (final cleanEndpoint in endpoints) {
      // Endpoints are already URL-variable-resolved (clean path + name) up
      // front; use the per-endpoint base override when present.
      final resolvedBaseUrl = cleanEndpoint.baseUrlOverride ?? baseUrl;

      Future<ResolveResult> attempt() async {
        try {
          return await resolver.resolve(
            cleanEndpoint,
            baseUrl: resolvedBaseUrl,
            token: session.token,
          );
        } catch (e) {
          return ResolveResult(response: ResponseDefinition.empty);
        }
      }

      var result = await attempt();

      // ── Auto re-login ───────────────────────────────────────────────────
      // An expired token would otherwise fail every remaining endpoint. Mint a
      // fresh one and retry this endpoint exactly once — `attempt()` runs at
      // most twice by construction, so there's no counter to get wrong.
      // Skipped for the login endpoint itself: generating it legitimately 401s
      // on the spec's placeholder credentials, and re-logging in can't help.
      if (_isAuthFailure(result) && !_isLoginEndpoint(cleanEndpoint, session)) {
        if (!_offeredLoginSetup && !session.hasLogin) {
          // First 401 with nothing configured — this is the moment the pain is
          // real, so offer setup right here rather than burying it in a flag.
          // Latched: declining must not re-ask once per remaining endpoint.
          _offeredLoginSetup = true;
          await _offerLoginSetupOnFailure(session, tree, baseUrl);
        }

        if (session.canRefresh) {
          _logger.w('↻ ${cleanEndpoint.name}: token rejected '
              '(${result.log?.statusCode}) — re-authenticating…');

          if (await session.refresh(reason: '${result.log?.statusCode} on '
              '${cleanEndpoint.name}')) {
            result = await attempt();

            if (_isAuthFailure(result)) {
              // A brand-new token still gets rejected, so this was never a
              // stale-token problem. Stop re-logging in for the rest of the run.
              session.markRefreshIneffective();
              _logger.w('  Still ${result.log?.statusCode} with a fresh token — '
                  'treating this as a permissions issue, not expiry.');
            }
          }
        }
      }

      // Write log file for every request (flat — no subfolders)
      final logFileName = cleanEndpoint.fileName.replaceAll('.dart', '');
      if (result.log != null) {
        result.log!.writeToFile(logsDir, logFileName);
      }

      // Check if request failed (has log with non-success status)
      if (result.log != null &&
          result.log!.statusCode != null &&
          (result.log!.statusCode! < 200 || result.log!.statusCode! >= 300)) {
        final logPath = '${Directory.current.path}/$logsDir/$logFileName.md';
        final link =
            TerminalUtils.fileLink(logPath, label: '$logsDir/$logFileName.md');
        _logger
            .e('✗ ${cleanEndpoint.name} (${result.log!.statusCode}) → $link');
        continue; // Skip generating action for failed requests
      }

      endpointResponses[cleanEndpoint] = result.response;
    }

    final generated = emitter.emitBatch(
      endpointResponses: endpointResponses,
      outputDir: outputDir,
      generateAction: generateAction,
    );

    final failed = endpoints.length - generated;
    stdout.writeln('');
    _logger.i(
        '✅ Done! Generated $generated files${failed > 0 ? ', $failed failed' : ''} in $outputDir');
  }

  // ── Auto re-login ─────────────────────────────────────────────────────

  /// Whether a resolved response failed because of auth.
  ///
  /// Kept as its own predicate so the "expired token" signal has a single
  /// definition — some APIs answer 200 with an error flag in the body, and
  /// that variant would be added here.
  bool _isAuthFailure(ResolveResult r) {
    final status = r.log?.statusCode;
    return status == 401 || status == 403;
  }

  /// True when [ep] is one of the configured login steps.
  ///
  /// Generating the login endpoint itself legitimately 401s (the spec ships
  /// placeholder credentials), and re-authenticating can't fix that — so skip
  /// the hook rather than burn a login call on it.
  bool _isLoginEndpoint(ApiEndpoint ep, TokenSession session) =>
      session.config?.matchesLoginStep(ep.path) ?? false;

  /// Builds the run's [TokenSession], wiring interactive fallbacks only when
  /// there's actually a terminal to prompt on.
  TokenSession _buildSession({
    required String? token,
    required EndpointTree tree,
    required String? baseUrl,
  }) {
    final config = LoginConfigStore.load(tree.sourceName);
    if (config != null) {
      _logger.i('✓ Auto re-login is configured '
          '(${config.steps.length} step${config.steps.length > 1 ? 's' : ''})');
    }

    final interactive = stdin.hasTerminal;
    return TokenSession(
      token: token,
      logger: _logger,
      config: config,
      baseUrl: baseUrl,
      service: LoginService(
        httpClient: ApiHttpClient(logger: _logger),
        logger: _logger,
      ),
      promptForToken: interactive
          ? () async => promptInput(message: 'Paste a fresh token')
          : null,
      promptForOtp:
          interactive ? () async => promptInput(message: 'OTP code') : null,
    );
  }

  /// Offers to configure auto re-login the first time a 401 actually bites.
  Future<void> _offerLoginSetupOnFailure(
    TokenSession session,
    EndpointTree tree,
    String? baseUrl,
  ) async {
    if (!stdin.hasTerminal) return;

    stdout.writeln('');
    _logger.w('The auth token looks expired.');
    final wants = promptConfirm(
      message: 'Set up auto re-login so this fixes itself next time?',
      defaultValue: true,
    );
    if (!wants) return;

    final config = await _setupLogin(tree, baseUrl);
    if (config != null) session.applyConfig(config);
  }

  /// Interactive setup for the auto re-login recipe.
  ///
  /// Picks the login endpoint out of the already-parsed tree so the method and
  /// body field names come from the spec instead of being retyped, then proves
  /// the recipe works before saving it.
  Future<LoginConfig?> _setupLogin(EndpointTree tree, String? baseUrl) async {
    stdout.writeln('');
    stdout.writeln(TerminalUtils.bold('  Auto re-login setup'));

    final kindIndex = promptSelect(
      message: 'How does login work?',
      options: [
        'Single step (e.g. email + password)',
        'Two steps with OTP (request a code, then verify it)',
      ],
    );
    if (kindIndex == -1) return null;

    // Warn BEFORE collecting anything, so backing out costs nothing.
    stdout.writeln('');
    _logger.w('Your credentials will be stored as plain text in '
        '.api2dart/config.yaml');
    stdout.writeln(TerminalUtils.gray(
        '  (this project only, never uploaded anywhere). '
        'Use development accounts.'));
    if (!promptConfirm(message: 'Continue?', defaultValue: false)) return null;

    final steps = <LoginStep>[];

    final first = await _buildLoginStep(
      tree: tree,
      baseUrl: baseUrl,
      title: kindIndex == 0 ? 'Login request' : 'Step 1 — request the OTP',
      askForOtpField: false,
    );
    if (first == null) return null;
    steps.add(first);

    String? fixedOtpCode;
    if (kindIndex == 1) {
      final second = await _buildLoginStep(
        tree: tree,
        baseUrl: baseUrl,
        title: 'Step 2 — verify the OTP',
        askForOtpField: true,
      );
      if (second == null) return null;
      steps.add(second);

      stdout.writeln('');
      fixedOtpCode = promptInput(
        message: 'Fixed OTP code for this environment '
            '(leave empty to be asked each time)',
        hint: 'e.g. 1111',
      );
      if (fixedOtpCode != null && fixedOtpCode.isEmpty) fixedOtpCode = null;
    }

    // Verify before saving — a recipe that has never run isn't worth keeping.
    stdout.writeln('');
    _logger.i('Trying it out…');
    final draft = LoginConfig(steps: steps, fixedOtpCode: fixedOtpCode);
    final service = LoginService(
      httpClient: ApiHttpClient(logger: _logger),
      logger: _logger,
    );

    var otpCode = fixedOtpCode;
    if (draft.needsOtp && (otpCode == null || otpCode.isEmpty)) {
      otpCode = promptInput(message: 'OTP code (to test with)');
    }

    final result = await service.login(draft, baseUrl: baseUrl, otpCode: otpCode);
    if (!result.isSuccess) {
      _logger.e('✗ Test login failed: ${result.error}');
      _logger.w('Not saving — fix the details and try again next run.');
      return null;
    }

    // Pin down where the token actually was, so later runs don't re-guess.
    final config = draft.copyWith(tokenPath: result.tokenPath);
    _logger.i('✓ Login works — got a token '
        '(${TokenSession.mask(result.token)})');
    if (result.tokenPath != null) {
      _logger.i('✓ Token found at "${result.tokenPath}"');
    }

    LoginConfigStore.save(tree.sourceName, config);
    _reportGitignore();
    _logger.i('✓ Saved. Expired tokens will now refresh automatically.');
    return config;
  }

  /// Collects one login step, deriving as much as possible from the spec.
  Future<LoginStep?> _buildLoginStep({
    required EndpointTree tree,
    required String? baseUrl,
    required String title,
    required bool askForOtpField,
  }) async {
    stdout.writeln('');
    stdout.writeln(TerminalUtils.bold('  $title'));

    // Surface likely auth endpoints first — the login route is almost always
    // already in the parsed tree.
    final all = tree.allEndpoints;
    final candidates = all
        .where((e) => RegExp(r'login|signin|sign-in|auth|otp|verify',
                caseSensitive: false)
            .hasMatch('${e.path} ${e.name}'))
        .toList();

    final options = [
      ...candidates.map((e) => '${e.method.name} ${e.path}'),
      'Type a URL manually',
    ];
    final pick = promptSelect(message: 'Which endpoint?', options: options);
    if (pick == -1) return null;

    String url;
    HttpMethod method;
    var bodyFormat = LoginBodyFormat.json;
    var fieldNames = <String>[];
    var headers = <String, String>{};

    if (pick < candidates.length) {
      final ep = candidates[pick];
      url = ep.path;
      method = ep.method;
      headers = _safeHeaders(ep.headers);
      final derived = _deriveBodyFields(ep.body);
      fieldNames = derived.names;
      bodyFormat = derived.format;
    } else {
      final typed = promptInput(
        message: 'Login URL (path or full URL)',
        hint: 'e.g. /auth/login',
      );
      if (typed == null || typed.isEmpty) return null;
      url = typed;
      method = HttpMethod.POST;
    }

    // Nothing usable in the spec — ask for the field names directly.
    if (fieldNames.isEmpty) {
      final raw = promptInput(
        message: 'Body field names, comma-separated',
        hint: askForOtpField ? 'e.g. phone,code' : 'e.g. email,password',
      );
      fieldNames = (raw ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }

    if (fieldNames.isEmpty) {
      _logger.e('No fields given — cannot build a login request.');
      return null;
    }

    // The OTP value is supplied per-call, so its field is named, not filled.
    String? otpField;
    if (askForOtpField) {
      final guess = fieldNames.indexWhere((f) =>
          RegExp(r'otp|code|pin', caseSensitive: false).hasMatch(f));
      final otpPick = promptSelect(
        message: 'Which field carries the OTP code?',
        options: fieldNames,
        defaultIndex: guess >= 0 ? guess : 0,
      );
      if (otpPick == -1) return null;
      otpField = fieldNames[otpPick];
    }

    stdout.writeln('');
    final fields = <String, String>{};
    for (final name in fieldNames) {
      if (name == otpField) continue; // filled at login time
      final isSecret =
          RegExp(r'pass|pwd|secret|pin', caseSensitive: false).hasMatch(name);
      final value = isSecret
          ? promptPassword(message: name)
          : promptInput(message: name);
      if (value != null && value.isNotEmpty) fields[name] = value;
    }

    return LoginStep(
      url: url,
      method: method,
      fields: fields,
      bodyFormat: bodyFormat,
      headers: headers,
      otpField: otpField,
    );
  }

  /// Extracts body field names and encoding from a spec-derived body.
  ({List<String> names, LoginBodyFormat format}) _deriveBodyFields(
      BodyDefinition? body) {
    if (body == null) return (names: <String>[], format: LoginBodyFormat.json);

    if (body.hasFormFields) {
      return (
        names: body.formFields!.keys.toList(),
        format: LoginBodyFormat.form
      );
    }

    if (body.hasRawBody) {
      try {
        final decoded = jsonDecode(body.rawBody!);
        if (decoded is Map) {
          return (
            names: decoded.keys.map((k) => k.toString()).toList(),
            format: LoginBodyFormat.json
          );
        }
      } catch (_) {/* not JSON — fall through */}
    }

    return (names: <String>[], format: LoginBodyFormat.json);
  }

  /// Drops headers that must not ride along on a login request.
  ///
  /// A spec-derived `Authorization: Bearer {{token}}` would send the very token
  /// we're replacing, which is exactly what breaks the refresh.
  Map<String, String> _safeHeaders(Map<String, String> headers) {
    const banned = {'authorization', 'cookie'};
    return {
      for (final e in headers.entries)
        if (!banned.contains(e.key.toLowerCase())) e.key: e.value,
    };
  }

  void _reportGitignore() {
    switch (GitignoreGuard.ensureIgnored()) {
      case GitignoreOutcome.added:
        _logger.i('✓ Added .api2dart/ to .gitignore');
      case GitignoreOutcome.alreadyIgnored:
        _logger.i('✓ .api2dart/ is already git-ignored');
      case GitignoreOutcome.notAGitRepo:
        break; // nothing to protect
      case GitignoreOutcome.failed:
        _logger.w('⚠ Could not update .gitignore — add `.api2dart/` yourself.');
    }
  }
}

class _LoadResult {
  final EndpointTree tree;
  final String? baseUrl;
  final String? token;
  final Map<String, String> urlVariables;

  _LoadResult({
    required this.tree,
    this.baseUrl,
    this.token,
    this.urlVariables = const {},
  });
}
