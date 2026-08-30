import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../../core/auth/login_service.dart';
import '../../core/auth/token_session.dart';
import '../../core/generation/code_emitter.dart';
import '../../core/generation/pubspec_inspector.dart';
import '../../core/logger/console_logger.dart';
import '../../core/logger/stderr_logger.dart';
import '../../core/logger/logger.dart';
import '../../core/models/api_endpoint.dart';
import '../../core/models/api_source_config.dart';
import '../../core/models/endpoint_report.dart';
import '../../core/models/endpoint_tree.dart';
import '../../core/models/login_config.dart';
import '../../core/models/response_definition.dart';
import '../../core/resolution/http_client.dart';
import '../../core/resolution/response_resolver.dart';
import '../../core/sources/api_source.dart';
import '../../core/sources/apidog_source.dart';
import '../../core/sources/local_file_source.dart';
import '../../core/sources/openapi_source.dart';
import '../../core/sources/postman_source.dart';
import '../ui/endpoint_selector.dart';
import '../wizard/generate_wizard.dart';

class GenerateCommand extends Command {
  GenerateCommand() {
    argParser
      ..addSeparator('Source options:')
      ..addOption('source',
          abbr: 's',
          help: 'Source type. Required when --config is provided.',
          allowed: ['postman', 'openapi', 'apidog', 'file'],
          allowedHelp: {
            'postman': 'Postman collection v2.1 (.json)',
            'openapi': 'OpenAPI 3.x spec (.yaml or .json)',
            'apidog': 'Apidog export (OpenAPI-compatible)',
            'file': 'Single-endpoint YAML config',
          })
      ..addOption('config',
          abbr: 'c',
          help: 'Path to the collection/spec file.\n'
              'Omit to launch the interactive wizard instead.')
      ..addOption('output',
          abbr: 'o',
          help: 'Root output directory. A dated subfolder is created inside\n'
              'it containing actions/ and logs/ subfolders.',
          defaultsTo: 'api2dart')
      ..addSeparator('Live fetch options (used to fetch real responses):')
      ..addOption('base-url',
          abbr: 'b',
          help: 'Base URL of the API\n(e.g. https://api.example.com)')
      ..addOption('token',
          abbr: 't',
          help: 'Auth token used when fetching live responses')
      ..addSeparator('Output mode:')
      ..addOption('mode',
          abbr: 'm',
          help: 'What to generate per endpoint.',
          allowed: ['auto', 'action', 'response-only'],
          allowedHelp: {
            'auto':
                'Detect: action+response if `api_request` is in pubspec, else response-only',
            'action': 'Force ApiRequestAction subclass + response model',
            'response-only': 'Only the response model (no api_request import)',
          },
          defaultsTo: 'auto')
      ..addSeparator('Behavior flags:')
      ..addFlag('no-interactive',
          help: 'Skip the endpoint selector and generate every endpoint.\n'
              'Required for CI / non-TTY environments.',
          negatable: false,
          defaultsTo: false)
      ..addFlag('dry-run',
          help: 'Print what would be generated without writing any files',
          negatable: false,
          defaultsTo: false)
      ..addFlag('json',
          help: 'Emit a machine-readable JSON report of each endpoint\n'
              '(shape, params, response schema and sample) instead of\n'
              'human-facing logs. Implies --dry-run: no files are written.\n'
              'Secrets are redacted and long arrays truncated.',
          negatable: false,
          defaultsTo: false);
  }

  @override
  String get description =>
      'Generate Dart actions and response models from an API source.\n\n'
      'Two modes:\n'
      '  • Wizard (no --config): interactive prompts for source, project, '
      'and endpoints — settings are saved per-project in .api2dart/config.yaml.\n'
      '  • Flags (--config): non-interactive, suitable for scripts and CI.\n\n'
      'Examples:\n'
      '  api2dart generate                                 # launch the wizard\n'
      '  api2dart reset                                    # clear saved wizard selections\n'
      '  api2dart generate -s postman -c collection.json -b https://api.example.com\n'
      '  api2dart generate -s openapi -c openapi.yaml --no-interactive\n'
      '  api2dart generate -s postman -c collection.json --dry-run --no-interactive';

  @override
  String get name => 'generate';

  @override
  String get invocation => 'api2dart generate [arguments]';

  @override
  void run() async {
    final configPath = argResults!['config'] as String?;

    // If no config provided, launch interactive wizard
    if (configPath == null || configPath.isEmpty) {
      final wizard = GenerateWizard();
      await wizard.run();
      return;
    }

    // Otherwise, run with flags (non-wizard mode)
    await _runWithFlags();
  }

  Future<void> _runWithFlags() async {
    final jsonMode = argResults!['json'] as bool;
    // In --json mode stdout carries the JSON document, so every diagnostic
    // goes to stderr instead.
    final Logger logger = jsonMode ? const StderrLogger() : ConsoleLogger();
    final sourceType = argResults!['source'] as String? ?? 'postman';
    final configPath = argResults!['config'] as String;
    final rootOutputDir = argResults!['output'] as String;
    final dateFolder = _todayFolder();
    final outputDir = '$rootOutputDir/$dateFolder/actions';
    final logsDir = '$rootOutputDir/$dateFolder/logs';
    final baseUrl = argResults!['base-url'] as String?;
    final token = argResults!['token'] as String?;
    final noInteractive = argResults!['no-interactive'] as bool;
    final dryRun = argResults!['dry-run'] as bool;
    final modeArg = argResults!['mode'] as String;
    final generateAction = _resolveGenerateAction(modeArg, logger);

    // 1. Select source
    final ApiSource source;
    switch (sourceType) {
      case 'postman':
        source = PostmanSource();
        break;
      case 'openapi':
        source = OpenApiSource();
        break;
      case 'apidog':
        source = ApidogSource();
        break;
      case 'file':
        source = LocalFileSource();
        break;
      default:
        logger.e('Unknown source type: $sourceType');
        exit(1);
    }

    // 2. Parse source
    logger.i('Parsing ${source.sourceName} from $configPath...');
    EndpointTree tree;
    try {
      tree = await source.parse(ApiSourceConfig(
        filePath: configPath,
        baseUrl: baseUrl,
        token: token,
        outputDir: outputDir,
      ));
    } catch (e) {
      logger.e('Failed to parse source', error: e);
      exit(1);
    }

    if (tree.isEmpty) {
      logger.w('No endpoints found in the source');
      exit(0);
    }

    logger.i(
        'Found ${tree.totalEndpoints} endpoints in "${tree.sourceName}"');

    // 3. Select endpoints
    List<ApiEndpoint> selectedEndpoints;

    if (noInteractive) {
      selectedEndpoints = tree.allEndpoints;
      logger.i('Generating all ${selectedEndpoints.length} endpoints');
    } else {
      final selector = EndpointSelector(tree);
      final selected = selector.selectInteractively();

      if (selected == null || selected.isEmpty) {
        logger.w('No endpoints selected. Exiting.');
        exit(0);
      }
      selectedEndpoints = selected;
    }

    if (dryRun && !jsonMode) {
      logger.i('Dry run — would generate ${selectedEndpoints.length} files:');
      for (final endpoint in selectedEndpoints) {
        final fileName = generateAction
            ? endpoint.fileName
            : endpoint.fileName.replaceAll('_action.dart', '_response.dart');
        logger.n(
            '  ${endpoint.method.name.padRight(6)} ${endpoint.path} → $outputDir/$fileName');
      }
      exit(0);
    }

    // 4. Resolve responses and batch generate with deduplication
    final httpClient = ApiHttpClient(logger: logger);
    final resolver = ResponseResolver(httpClient: httpClient);
    final emitter = CodeEmitter(logger: logger);

    // Non-interactive by design — this is the CI/flag path, so there are no
    // prompts to fall back on. A stored login recipe (with a fixed OTP code,
    // when the API needs one) still refreshes an expired token unattended.
    final session = TokenSession(
      token: token,
      logger: logger,
      config: LoginConfigStore.load(tree.sourceName),
      baseUrl: baseUrl,
      service: LoginService(httpClient: httpClient, logger: logger),
    );

    final resolvedBaseUrl = baseUrl ?? '';
    final endpointResponses = <ApiEndpoint, ResponseDefinition?>{};

    for (final endpoint in selectedEndpoints) {
      logger.i(
          'Processing ${endpoint.method.name} ${endpoint.path}...');

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

      // Auto re-login: mint a fresh token and retry this endpoint once. Skipped
      // for the login endpoints themselves — they legitimately 401 on the
      // spec's placeholder credentials, and re-authenticating can't fix that.
      final status = result.log?.statusCode;
      final isLoginEndpoint =
          session.config?.matchesLoginStep(endpoint.path) ?? false;
      if ((status == 401 || status == 403) &&
          !isLoginEndpoint &&
          session.canRefresh) {
        logger.w('↻ ${endpoint.name}: token rejected ($status) — '
            're-authenticating…');
        if (await session.refresh(reason: '$status on ${endpoint.name}')) {
          result = await attempt();
          final retried = result.log?.statusCode;
          if (retried == 401 || retried == 403) {
            session.markRefreshIneffective();
            logger.w('  Still $retried with a fresh token — '
                'treating this as a permissions issue, not expiry.');
          }
        }
      }

      final logFileName = endpoint.fileName.replaceAll('.dart', '');
      // --json is a read-only probe: report the shape, touch nothing on disk.
      if (result.log != null && !jsonMode) {
        result.log!.writeToFile(logsDir, logFileName);
      }

      if (result.log != null &&
          result.log!.statusCode != null &&
          (result.log!.statusCode! < 200 || result.log!.statusCode! >= 300)) {
        if (jsonMode) {
          // Keep the endpoint in the report — a non-2xx body is still shape
          // information, and the status tells the caller why it looks odd.
          logger.w('${endpoint.name} returned ${result.log!.statusCode}');
          endpointResponses[endpoint] = result.response;
          continue;
        }
        final logPath = '${Directory.current.path}/$logsDir/$logFileName.md';
        // Use full path — most terminals make it clickable
        logger.e(
            '✗ ${endpoint.name} (${result.log!.statusCode}) → $logPath');
        continue;
      }

      endpointResponses[endpoint] = result.response;
    }

    if (jsonMode) {
      _emitJson(selectedEndpoints, endpointResponses, outputDir,
          generateAction: generateAction);
      return;
    }

    final generated = emitter.emitBatch(
      endpointResponses: endpointResponses,
      outputDir: outputDir,
      generateAction: generateAction,
    );

    final failed = selectedEndpoints.length - generated;
    logger.i(
        'Done! Generated $generated files${failed > 0 ? ', $failed failed' : ''} in $outputDir');
  }

  /// Writes the machine-readable report to stdout as a single JSON document.
  /// Nothing is written to disk — `--json` is a read-only probe.
  void _emitJson(
    List<ApiEndpoint> endpoints,
    Map<ApiEndpoint, ResponseDefinition?> responses,
    String outputDir, {
    required bool generateAction,
  }) {
    final reports = endpoints.map((endpoint) {
      final fileName = generateAction
          ? endpoint.fileName
          : endpoint.fileName.replaceAll('_action.dart', '_response.dart');
      return EndpointReport.build(
        endpoint,
        response: responses[endpoint],
        outputFile: '$outputDir/$fileName',
      );
    }).toList();

    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'endpoint_count': reports.length,
      'endpoints': reports,
    }));
  }

  /// Date folder name (YYYY-MM-DD) used to group each run's output.
  String _todayFolder() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  /// Resolves the requested mode to the boolean the emitter expects.
  /// Logs the detected outcome for `auto`.
  bool _resolveGenerateAction(String mode, Logger logger) {
    switch (mode) {
      case 'action':
        return true;
      case 'response-only':
        return false;
      case 'auto':
      default:
        final hasPkg = PubspecInspector.hasApiRequestDependency();
        if (hasPkg) {
          logger.i('Detected `api_request` in pubspec — '
              'generating action + response.');
        } else {
          logger.i('No `api_request` in pubspec — generating response only.');
        }
        return hasPkg;
    }
  }
}
