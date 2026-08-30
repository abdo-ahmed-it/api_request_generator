import 'dart:io';

import 'package:api_to_dart/src/core/sources/gitignore_guard.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String originalCwd;

  setUp(() {
    originalCwd = Directory.current.path;
    tempDir = Directory.systemTemp.createTempSync('api2dart_gitignore_test');
    Directory.current = tempDir;
  });

  tearDown(() {
    Directory.current = originalCwd;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  void makeGitRepo() => Directory('.git').createSync();

  test('creates .gitignore when the repo has none', () {
    makeGitRepo();

    expect(GitignoreGuard.ensureIgnored(), GitignoreOutcome.added);
    expect(File('.gitignore').readAsStringSync(), contains('.api2dart/'));
  });

  test('appends to an existing .gitignore, preserving prior content', () {
    makeGitRepo();
    File('.gitignore').writeAsStringSync('build/\n.dart_tool/\n');

    expect(GitignoreGuard.ensureIgnored(), GitignoreOutcome.added);

    final content = File('.gitignore').readAsStringSync();
    expect(content, contains('build/'));
    expect(content, contains('.dart_tool/'));
    expect(content, contains('.api2dart/'));
  });

  test('does not corrupt a last line that lacks a trailing newline', () {
    makeGitRepo();
    File('.gitignore').writeAsStringSync('build/\n.dart_tool/'); // no newline

    GitignoreGuard.ensureIgnored();

    final lines = File('.gitignore').readAsLinesSync();
    expect(lines, contains('.dart_tool/'));
    expect(lines, contains('.api2dart/'));
  });

  test('leaves the file byte-identical when already ignored', () {
    makeGitRepo();
    const original = 'build/\n.api2dart/\n.dart_tool/\n';
    File('.gitignore').writeAsStringSync(original);

    expect(GitignoreGuard.ensureIgnored(), GitignoreOutcome.alreadyIgnored);
    expect(File('.gitignore').readAsStringSync(), original);
  });

  test('recognizes alternative spellings of the entry', () {
    for (final variant in ['.api2dart', '/.api2dart/', '/.api2dart']) {
      final dir =
          Directory.systemTemp.createTempSync('api2dart_gitignore_variant');
      final previousCwd = Directory.current.path;
      try {
        Directory.current = dir;
        Directory('.git').createSync();
        File('.gitignore').writeAsStringSync('$variant\n');

        expect(GitignoreGuard.ensureIgnored(), GitignoreOutcome.alreadyIgnored,
            reason: 'should recognize "$variant"');
      } finally {
        Directory.current = previousCwd;
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    }
  });

  test('ignores commented-out entries', () {
    makeGitRepo();
    File('.gitignore').writeAsStringSync('# .api2dart/\nbuild/\n');

    expect(GitignoreGuard.ensureIgnored(), GitignoreOutcome.added);
    expect(File('.gitignore').readAsLinesSync(), contains('.api2dart/'));
  });

  test('does nothing outside a git repo', () {
    expect(GitignoreGuard.ensureIgnored(), GitignoreOutcome.notAGitRepo);
    expect(File('.gitignore').existsSync(), isFalse);
  });
}
