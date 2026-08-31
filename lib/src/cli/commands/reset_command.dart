import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../core/logger/console_logger.dart';
import '../../core/logger/logger.dart';
import '../../core/models/login_config.dart';
import '../../core/sources/api_fetchers/config_storage.dart';
import '../ui/prompts.dart';
import '../ui/terminal_utils.dart';

class ResetCommand extends Command {
  ResetCommand() {
    argParser
      ..addFlag('all',
          help: 'Also delete saved API tokens (Postman / Apidog).\n'
              'By default the wizard selections and login credentials\n'
              'are cleared, but those tokens are kept.',
          negatable: false,
          defaultsTo: false)
      ..addFlag('yes',
          abbr: 'y',
          help: 'Skip the confirmation prompt',
          negatable: false,
          defaultsTo: false);
  }

  @override
  String get description =>
      'Reset saved settings stored in .api2dart/config.yaml.\n\n'
      'By default this clears the wizard selections '
      '(last source, last project, last collection, etc.) and the saved '
      'auto re-login credentials, so the next run starts the wizard fresh '
      'while keeping your saved API tokens.\n\n'
      'Use --all to also delete the saved Postman and Apidog tokens.';

  @override
  String get name => 'reset';

  @override
  String get invocation => 'api2dart reset [--all] [-y]';

  @override
  Future<void> run() async {
    final Logger logger = ConsoleLogger();
    final clearAll = argResults!['all'] as bool;
    final skipConfirm = argResults!['yes'] as bool;

    final configPath =
        p.join(Directory.current.path, '.api2dart', 'config.yaml');
    final configFile = File(configPath);

    if (!configFile.existsSync()) {
      logger.i('Nothing to reset — no saved settings found.');
      return;
    }

    if (!skipConfirm) {
      stdout.writeln('');
      stdout.writeln(TerminalUtils.gray('  Config file: $configPath'));
      final message = clearAll
          ? 'Delete ALL saved settings (including API tokens)?'
          : 'Clear wizard selections and login credentials (API tokens kept)?';
      final confirmed = promptConfirm(message: message, defaultValue: false);
      if (!confirmed) {
        logger.i('Reset cancelled.');
        return;
      }
    }

    if (clearAll) {
      configFile.deleteSync();
      logger.i('✓ All saved settings cleared.');
    } else {
      ConfigStorage.remove('wizard');
      // Stored credentials are more sensitive than a saved project id, and a
      // rotated password would otherwise keep failing on every run.
      ConfigStorage.remove(LoginConfigStore.section);
      logger.i('✓ Wizard selections and login credentials cleared. '
          'API tokens kept.');
    }
  }
}
