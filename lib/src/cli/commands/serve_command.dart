import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../../core/generation/pubspec_inspector.dart';
import '../../core/logger/console_logger.dart';
import '../../core/logger/logger.dart';
import '../../core/models/api_source_config.dart';
import '../../core/models/endpoint_tree.dart';
import '../../core/server/api_web_server.dart';
import '../../core/sources/api_source.dart';
import '../../core/sources/apidog_source.dart';
import '../../core/sources/local_file_source.dart';
import '../../core/sources/openapi_source.dart';
import '../../core/sources/postman_source.dart';
import '../ui/terminal_utils.dart';

/// Launches a local web UI to pick endpoints and generate code in the browser.
///
/// Same source flags as `generate`; the difference is the selection +
/// generation happen in a browser instead of the terminal selector. Works in
/// non-TTY environments (no raw stdin).
class ServeCommand extends Command {
  ServeCommand() {
    argParser
      ..addSeparator('Source options:')
      ..addOption('source', abbr: 's', help: 'Source type.', allowed: [
        'postman',
        'openapi',
        'apidog',
        'file'
      ], allowedHelp: {
        'postman': 'Postman collection v2.1 (.json)',
        'openapi': 'OpenAPI 3.x spec (.yaml or .json)',
        'apidog': 'Apidog export (OpenAPI-compatible)',
        'file': 'Single-endpoint YAML config',
      })
      ..addOption('config',
          abbr: 'c', help: 'Path to the collection/spec file.')
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
          abbr: 't', help: 'Auth token used when fetching live responses')
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
      ..addSeparator('Server options:')
      ..addOption('port',
          abbr: 'p', help: 'Port for the local web UI.', defaultsTo: '4321')
      ..addFlag('open',
          help: 'Open the web UI in your default browser automatically.',
          defaultsTo: true);
  }

  @override
  String get description =>
      'Launch a local web UI to select endpoints and generate code.\n\n'
      'Parses the source, then prints a localhost link. Open it to pick '
      'endpoints in the browser and generate the exact same files as '
      '`generate` writes. Works in non-TTY environments.\n\n'
      'Example:\n'
      '  api2dart serve -s openapi -c openapi.yaml -b https://api.example.com';

  @override
  String get name => 'serve';

  @override
  String get invocation => 'api2dart serve -s <source> -c <file> [-p <port>]';

  @override
  Future<void> run() async {
    final Logger logger = ConsoleLogger();
    final sourceType = argResults!['source'] as String?;
    final configPath = argResults!['config'] as String?;
    final rootOutputDir = argResults!['output'] as String;
    final baseUrl = argResults!['base-url'] as String?;
    final token = argResults!['token'] as String?;
    final modeArg = argResults!['mode'] as String;
    final portArg = argResults!['port'] as String;

    // Apidog/Postman need live API access (token, project, environment) that
    // only the wizard provides — `serve` only parses a local file. Point the
    // user at `generate`, whose wizard also prints the same web UI link.
    if (sourceType == 'apidog' || sourceType == 'postman') {
      if (configPath == null) {
        logger.e(
            '`serve -s $sourceType` needs a local file via -c (an exported '
            'spec/collection).\n'
            'To pull directly from $sourceType (token/project/environment) and '
            'still get the web UI, run `api2dart generate` — its wizard prints '
            'the same web link.');
        exitCode = 64; // EX_USAGE
        return;
      }
    }

    if (sourceType == null || configPath == null) {
      logger.e('Both --source and --config are required.\n'
          'Usage: $invocation');
      exitCode = 64; // EX_USAGE
      return;
    }

    final port = int.tryParse(portArg);
    if (port == null || port < 0 || port > 65535) {
      logger.e('Invalid --port: $portArg');
      exitCode = 64;
      return;
    }

    final dateFolder = _todayFolder();
    final outputDir = '$rootOutputDir/$dateFolder/actions';
    final logsDir = '$rootOutputDir/$dateFolder/logs';
    final generateAction = _resolveGenerateAction(modeArg, logger);

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
        exitCode = 64;
        return;
    }

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
      exitCode = 1;
      return;
    }

    if (tree.isEmpty) {
      logger.w('No endpoints found in the source');
      return;
    }

    logger.i('Found ${tree.totalEndpoints} endpoints in "${tree.sourceName}"');

    final server = ApiWebServer(
      tree: tree,
      outputDir: outputDir,
      logsDir: logsDir,
      baseUrl: baseUrl,
      token: token,
      generateAction: generateAction,
      logger: logger,
    );

    final String url;
    try {
      url = await server.start(port);
    } catch (e) {
      logger.e('Failed to start server on port $port', error: e);
      exitCode = 1;
      return;
    }

    stdout.writeln('');
    stdout.writeln(TerminalUtils.green('  ▸ Web UI ready — open this link:'));
    stdout.writeln('    ${TerminalUtils.cyan(url)}');
    stdout.writeln('');
    stdout.writeln(TerminalUtils.gray('  Output → $outputDir'));
    stdout.writeln(TerminalUtils.gray('  Press Ctrl+C to stop.'));

    final autoOpen = argResults!['open'] as bool;
    if (autoOpen) {
      await _openInBrowser(url, logger);
    }

    // Stop cleanly on Ctrl+C.
    late final StreamSubscription sigint;
    sigint = ProcessSignal.sigint.watch().listen((_) async {
      await server.stop();
      await sigint.cancel();
      stdout.writeln('');
      logger.i('Server stopped.');
      exit(0);
    });

    // Keep the process alive while the server runs.
    await Completer<void>().future;
  }

  /// Opens [url] in the OS default browser. Best-effort — a failure just leaves
  /// the printed link for the user to click. Uses the platform's standard
  /// opener (`open` on macOS, `xdg-open` on Linux, `start` on Windows).
  Future<void> _openInBrowser(String url, Logger logger) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      } else if (Platform.isWindows) {
        // `start` is a cmd builtin, so it must run through cmd.
        await Process.run('cmd', ['/c', 'start', '', url]);
      }
    } catch (_) {
      // Non-fatal: the link is already printed above.
    }
  }

  /// Date folder name (YYYY-MM-DD) used to group each run's output.
  /// Mirrors `GenerateCommand._todayFolder`.
  String _todayFolder() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  /// Mirrors `GenerateCommand._resolveGenerateAction`.
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
