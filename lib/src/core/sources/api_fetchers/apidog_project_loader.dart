import 'dart:convert';
import 'dart:io';

import '../../logger/logger.dart';
import '../../models/api_source_config.dart';
import '../../models/endpoint_tree.dart';
import '../openapi_source.dart';
import 'apidog_fetcher.dart';
import 'config_storage.dart';

/// What a saved Apidog binding resolves to: the parsed tree plus the context
/// needed to fetch live responses against it.
class ApidogProjectLoad {
  final EndpointTree tree;
  final String? baseUrl;
  final String? token;
  final Map<String, String> urlVariables;

  ApidogProjectLoad({
    required this.tree,
    this.baseUrl,
    this.token,
    this.urlVariables = const {},
  });
}

/// The project/environment the wizard last bound, read back from
/// `.api2dart/config.yaml`.
///
/// Deliberately carries no token: the credential is looked up separately so
/// non-interactive callers (the MCP server) can source it from the environment
/// or a keychain instead of the cleartext config file.
class ApidogBinding {
  final String projectId;
  final int? environmentId;
  final String environmentName;

  ApidogBinding({
    required this.projectId,
    this.environmentId,
    this.environmentName = '',
  });
}

/// Fetches an Apidog project as OpenAPI and parses it, with no prompting.
///
/// This is the non-interactive half of what the wizard does for a saved Apidog
/// binding. It lives in core so `generate --source apidog` (and through it the
/// MCP server) can replay a binding without going through the wizard, rather
/// than duplicating the export/resolve/parse sequence.
class ApidogProjectLoader {
  final Logger _logger;

  ApidogProjectLoader({required Logger logger}) : _logger = logger;

  /// Reads the project/environment the wizard saved, or null when the user has
  /// not bound one yet.
  ///
  /// Only non-secret fields are read. `apidog.token` is intentionally NOT
  /// returned: config.yaml is cleartext, and callers that must not depend on it
  /// (the MCP server) supply the token themselves.
  static ApidogBinding? savedBinding() {
    final projectId = ConfigStorage.get('apidog.last_project_id');
    if (projectId == null || projectId.isEmpty) return null;

    final envIdStr = ConfigStorage.get('apidog.environment_id');
    return ApidogBinding(
      projectId: projectId,
      environmentId: envIdStr != null ? int.tryParse(envIdStr) : null,
      environmentName: ConfigStorage.get('apidog.environment_name') ?? '',
    );
  }

  /// Looks up the environment's variables, so `{{placeholders}}` in the
  /// exported spec can be resolved. Returns null when there is no environment
  /// bound or it no longer exists.
  Future<Map<String, String>?> environmentVariables(
    String token,
    ApidogBinding binding,
  ) async {
    final envId = binding.environmentId;
    if (envId == null) return null;

    final envs = await ApidogFetcher(token: token, logger: _logger)
        .getEnvironments(binding.projectId);
    for (final env in envs) {
      if (env.id == envId) return env.variables;
    }
    return null;
  }

  /// Exports the project as OpenAPI, resolves environment variables into it,
  /// and parses it into a tree. Returns null on any failure, having logged it.
  Future<ApidogProjectLoad?> load(
    String token,
    ApidogBinding binding, {
    Map<String, String>? envVariables,
  }) async {
    final fetcher = ApidogFetcher(token: token, logger: _logger);

    _logger.i('Exporting Apidog project ${binding.projectId} as OpenAPI...');
    final openApiJson = await fetcher.exportOpenApi(
      binding.projectId,
      environmentId: binding.environmentId,
    );

    if (openApiJson == null) {
      _logger.e('Failed to export project. Check your token and project ID.');
      return null;
    }

    final resolved = _resolveVariables(openApiJson, envVariables);

    // The exported spec carries environment values (internal base URLs, and
    // any header defaults) once variables are resolved, so it is written to the
    // system temp dir rather than the project root: a stray file there is not
    // covered by the `.api2dart/` gitignore entry.
    final tempDir = Directory.systemTemp.createTempSync('api2dart_apidog_');
    final tempFile = File('${tempDir.path}/openapi.json');

    try {
      tempFile.writeAsStringSync(resolved);

      final tree =
          await OpenApiSource().parse(ApiSourceConfig(filePath: tempFile.path));

      final baseUrl = _resolveBaseUrl(resolved, envVariables);
      if (baseUrl != null && baseUrl.isNotEmpty) {
        _logger.i('✓ Base URL: $baseUrl');
      }
      _logger.i('✓ ${tree.sourceName}: ${tree.totalEndpoints} endpoints');

      return ApidogProjectLoad(
        tree: tree,
        baseUrl: baseUrl,
        token: envVariables?['token'] ?? envVariables?['mobile_token'],
        urlVariables: _urlVariables(envVariables),
      );
    } catch (e) {
      _logger.e('Failed to parse exported spec', error: e);
      return null;
    } finally {
      // Delete the directory, not just the file: the spec is the sensitive
      // artifact and a partial write must not survive either.
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  }

  /// Substitutes `{{name}}` placeholders with environment values.
  ///
  /// URL-valued variables are skipped: they get embedded into paths and corrupt
  /// them. They are surfaced through [ApidogProjectLoad.urlVariables] instead,
  /// where UrlVariableResolver can strip the prefixes properly.
  String _resolveVariables(String json, Map<String, String>? envVariables) {
    if (envVariables == null || envVariables.isEmpty) return json;

    var resolved = json;
    var count = 0;
    envVariables.forEach((key, value) {
      if (value.startsWith('http://') || value.startsWith('https://')) return;
      if (value.isEmpty) return;
      resolved = resolved.replaceAll('{{$key}}', value);
      count++;
    });
    if (count > 0) {
      _logger.i('✓ Resolved $count environment variables');
    }
    return resolved;
  }

  String? _resolveBaseUrl(String json, Map<String, String>? envVariables) {
    final fromEnv = envVariables?['url'] ?? envVariables?['base_url'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;

    try {
      final spec = jsonDecode(json);
      final servers = spec is Map ? spec['servers'] : null;
      if (servers is List && servers.isNotEmpty) {
        final first = servers.first;
        if (first is Map) return first['url']?.toString();
      }
    } catch (_) {
      // A spec that parsed as OpenAPI but has no readable servers block is
      // normal; the caller falls back to --base-url.
    }
    return null;
  }

  Map<String, String> _urlVariables(Map<String, String>? envVariables) {
    final urlVars = <String, String>{};
    envVariables?.forEach((key, value) {
      if (value.startsWith('http://') || value.startsWith('https://')) {
        urlVars[key] = value;
      }
    });
    return urlVars;
  }
}
