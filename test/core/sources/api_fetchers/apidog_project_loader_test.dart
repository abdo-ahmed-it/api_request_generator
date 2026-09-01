import 'dart:io';

import 'package:api_to_dart/api_to_dart.dart';
import 'package:api_to_dart/src/core/sources/api_fetchers/apidog_project_loader.dart';
import 'package:test/test.dart';

void main() {
  group('ApidogProjectLoader.savedBinding', () {
    late Directory tempDir;
    late String originalCwd;

    setUp(() {
      originalCwd = Directory.current.path;
      tempDir = Directory.systemTemp.createTempSync('api2dart_binding_test');
      Directory.current = tempDir;
    });

    tearDown(() {
      Directory.current = originalCwd;
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('returns null when no project has been bound', () {
      expect(ApidogProjectLoader.savedBinding(), isNull);
    });

    test('reads the project, environment id and name the wizard saved', () {
      ConfigStorage.set('apidog.last_project_id', '12345');
      ConfigStorage.set('apidog.environment_id', '42');
      ConfigStorage.set('apidog.environment_name', 'Staging');

      final binding = ApidogProjectLoader.savedBinding();

      expect(binding, isNotNull);
      expect(binding!.projectId, '12345');
      expect(binding.environmentId, 42);
      expect(binding.environmentName, 'Staging');
    });

    test('a project with no environment still binds', () {
      ConfigStorage.set('apidog.last_project_id', '12345');

      final binding = ApidogProjectLoader.savedBinding();

      expect(binding, isNotNull);
      expect(binding!.environmentId, isNull);
      expect(binding.environmentName, '');
    });

    test('a non-numeric environment id degrades to none, not a crash', () {
      ConfigStorage.set('apidog.last_project_id', '12345');
      ConfigStorage.set('apidog.environment_id', 'not-a-number');

      expect(ApidogProjectLoader.savedBinding()!.environmentId, isNull);
    });

    test('an empty project id is treated as unbound', () {
      ConfigStorage.set('apidog.last_project_id', '');

      expect(ApidogProjectLoader.savedBinding(), isNull);
    });

    test('the binding never carries the token, even when one is stored', () {
      // config.yaml is cleartext. Callers that must not depend on it (the MCP
      // server) supply the credential themselves, so the binding must expose
      // only the non-secret fields.
      ConfigStorage.set('apidog.last_project_id', '12345');
      ConfigStorage.set('apidog.token', 'cleartext-secret-value');

      final binding = ApidogProjectLoader.savedBinding()!;

      expect(binding.projectId, '12345');
      // ApidogBinding has no token field at all; assert the stored secret is
      // not reachable through any of the ones it does have.
      expect(binding.environmentName, isNot(contains('cleartext')));
    });
  });
}
