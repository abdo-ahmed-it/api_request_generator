import 'dart:io';

import 'terminal_utils.dart';

/// Interactive select prompt — user picks one option from a list.
/// Returns the index of the selected option, or -1 if cancelled.
int promptSelect({
  required String message,
  required List<String> options,
  int defaultIndex = 0,
}) {
  if (options.isEmpty) return -1;

  int cursor = defaultIndex.clamp(0, options.length - 1);
  bool firstRender = true;
  final totalLines = options.length + 2; // message + blank + options

  TerminalUtils.hideCursor();

  try {
    while (true) {
      // Move up to redraw
      if (!firstRender) {
        stdout.write('\x1B[${totalLines}A');
      }
      firstRender = false;

      // Render
      stdout.write('\x1B[2K');
      stdout.writeln(TerminalUtils.bold('? $message'));
      stdout.write('\x1B[2K');
      stdout.writeln('');

      for (int i = 0; i < options.length; i++) {
        stdout.write('\x1B[2K');
        if (i == cursor) {
          stdout.writeln('  ${TerminalUtils.cyan('>')} ${TerminalUtils.cyan(options[i])}');
        } else {
          stdout.writeln('    ${TerminalUtils.gray(options[i])}');
        }
      }

      // Read key
      final key = TerminalUtils.readKey();

      switch (key) {
        case 'up':
          if (cursor > 0) cursor--;
          break;
        case 'down':
          if (cursor < options.length - 1) cursor++;
          break;
        case 'enter':
          // Clear and show result
          stdout.write('\x1B[${totalLines}A');
          for (int i = 0; i < totalLines; i++) {
            stdout.write('\x1B[2K\n');
          }
          stdout.write('\x1B[${totalLines}A');
          stdout.writeln(
              '${TerminalUtils.green('✓')} $message: ${TerminalUtils.cyan(options[cursor])}');
          TerminalUtils.showCursor();
          return cursor;
        case 'q':
        case 'escape':
          stdout.write('\x1B[${totalLines}A');
          for (int i = 0; i < totalLines; i++) {
            stdout.write('\x1B[2K\n');
          }
          stdout.write('\x1B[${totalLines}A');
          stdout.writeln('${TerminalUtils.gray('✗')} $message: ${TerminalUtils.gray('cancelled')}');
          TerminalUtils.showCursor();
          return -1;
      }
    }
  } catch (_) {
    TerminalUtils.showCursor();
    rethrow;
  }
}

/// Interactive text input prompt.
/// Returns the entered text, or null if cancelled.
String? promptInput({
  required String message,
  String? defaultValue,
  String? hint,
}) {
  final defaultText = defaultValue != null ? ' (${TerminalUtils.gray(defaultValue)})' : '';
  final hintText = hint != null ? ' ${TerminalUtils.gray(hint)}' : '';

  stdout.write('${TerminalUtils.bold('? $message')}$defaultText$hintText: ');

  final input = stdin.readLineSync()?.trim();

  // Move up and rewrite with result
  stdout.write('\x1B[1A\x1B[2K');

  if (input == null) {
    stdout.writeln(
        '${TerminalUtils.gray('✗')} $message: ${TerminalUtils.gray('cancelled')}');
    return null;
  }

  final result = input.isEmpty ? defaultValue ?? '' : input;
  stdout.writeln(
      '${TerminalUtils.green('✓')} $message: ${TerminalUtils.cyan(result)}');

  return result;
}

/// Like [promptInput] but never echoes what's typed, and shows `••••••` in the
/// confirmation line instead of the value.
///
/// Used for credentials during auto re-login setup: [promptInput] both echoes
/// while typing and re-prints the value afterwards, which would leave a
/// password sitting in terminal scrollback.
///
/// Falls back to a visible [promptInput] (with a warning) when there's no
/// terminal to control echo on — `stdin.echoMode` throws in that case.
String? promptPassword({required String message}) {
  if (!stdin.hasTerminal) {
    stdout.writeln(TerminalUtils.gray(
        '  ⚠ No terminal — input will be visible as you type.'));
    return promptInput(message: message);
  }

  stdout.write('${TerminalUtils.bold('? $message')}: ');

  String? input;
  final hadEcho = stdin.echoMode;
  try {
    stdin.echoMode = false;
    input = stdin.readLineSync()?.trim();
  } on StdinException {
    // Some terminals refuse echo control; don't lose the prompt over it.
    stdout.writeln('');
    stdout.writeln(TerminalUtils.gray(
        '  ⚠ Could not hide input on this terminal.'));
    return promptInput(message: message);
  } finally {
    try {
      stdin.echoMode = hadEcho;
    } catch (_) {/* best-effort restore */}
  }

  // The user's Enter wasn't echoed, so close the line ourselves — otherwise
  // the next write lands mid-line.
  stdout.writeln('');
  // Overwrite the prompt line with the masked confirmation.
  stdout.write('\x1B[1A\x1B[2K');

  if (input == null) {
    stdout.writeln(
        '${TerminalUtils.gray('✗')} $message: ${TerminalUtils.gray('cancelled')}');
    return null;
  }

  final masked = input.isEmpty ? TerminalUtils.gray('(empty)') : '••••••';
  stdout.writeln('${TerminalUtils.green('✓')} $message: $masked');
  return input;
}

/// Interactive yes/no confirm prompt.
/// Returns true for yes, false for no.
bool promptConfirm({
  required String message,
  bool defaultValue = true,
}) {
  final defaultText = defaultValue ? 'Y/n' : 'y/N';
  stdout.write('${TerminalUtils.bold('? $message')} ($defaultText): ');

  final input = stdin.readLineSync()?.trim().toLowerCase();

  // Move up and rewrite
  stdout.write('\x1B[1A\x1B[2K');

  bool result;
  if (input == null || input.isEmpty) {
    result = defaultValue;
  } else {
    result = input == 'y' || input == 'yes';
  }

  final display = result ? 'Yes' : 'No';
  stdout.writeln(
      '${TerminalUtils.green('✓')} $message: ${TerminalUtils.cyan(display)}');

  return result;
}
