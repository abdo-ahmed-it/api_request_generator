import 'dart:io';

/// What [GitignoreGuard.ensureIgnored] did.
enum GitignoreOutcome {
  /// `.api2dart/` was appended to `.gitignore`.
  added,

  /// An entry covering `.api2dart/` was already present.
  alreadyIgnored,

  /// The current directory isn't a git repo — nothing to do.
  notAGitRepo,

  /// The file couldn't be read or written (e.g. a read-only checkout).
  failed,
}

/// Keeps `.api2dart/` out of git in the *user's* project.
///
/// `config.yaml` holds API keys, and once auto re-login is configured it also
/// holds real credentials. Committing that by accident is the kind of mistake
/// worth spending a few lines to prevent.
class GitignoreGuard {
  static const String _entry = '.api2dart/';

  /// Entries that already cover the config directory, so we don't append a
  /// duplicate when the user wrote it a slightly different way.
  static const List<String> _equivalents = [
    '.api2dart/',
    '.api2dart',
    '/.api2dart/',
    '/.api2dart',
  ];

  /// Appends [_entry] to the project's `.gitignore` unless it's already covered.
  ///
  /// Best-effort by design: a failure here must never take down the wizard, so
  /// every I/O path is guarded and reported rather than thrown.
  static GitignoreOutcome ensureIgnored() {
    try {
      if (!Directory('.git').existsSync()) return GitignoreOutcome.notAGitRepo;

      final file = File('.gitignore');
      if (!file.existsSync()) {
        file.writeAsStringSync('${_comment()}\n$_entry\n');
        return GitignoreOutcome.added;
      }

      final content = file.readAsStringSync();
      if (_alreadyCovered(content)) return GitignoreOutcome.alreadyIgnored;

      // Guarantee the existing last line stays intact when it lacks a newline.
      final separator = content.isEmpty
          ? ''
          : content.endsWith('\n')
              ? '\n'
              : '\n\n';
      file.writeAsStringSync('$separator${_comment()}\n$_entry\n',
          mode: FileMode.append);
      return GitignoreOutcome.added;
    } catch (_) {
      return GitignoreOutcome.failed;
    }
  }

  static bool _alreadyCovered(String content) {
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (_equivalents.contains(line)) return true;
    }
    return false;
  }

  static String _comment() =>
      '# api2dart — local config (API keys and credentials). Do not commit.';
}
