import 'dart:io';

import 'logger.dart';

/// Routes all diagnostics to stderr, keeping stdout clean for machine-readable
/// output.
///
/// `generate --json` writes a single JSON document to stdout; anything else on
/// that stream would make it unparseable. Progress and warnings still reach the
/// user's terminal — they just travel on stderr, where a caller can capture or
/// discard them independently.
class StderrLogger implements Logger {
  const StderrLogger();

  void _write(String level, String message) =>
      stderr.writeln('[$level] $message');

  @override
  void d(String message) => _write('debug', message);

  @override
  void i(String message) => _write('info', message);

  @override
  void w(String message) => _write('warn', message);

  @override
  void e(String message, {Object? error}) =>
      _write('error', error == null ? message : '$message: $error');

  @override
  void n(String message) => _write('info', message);
}
