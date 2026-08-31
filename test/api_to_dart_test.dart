import 'dart:io';
import 'dart:isolate';

import 'package:api_to_dart/api_to_dart.dart';
import 'package:test/test.dart';

/// Absolute path to a repo file, resolved from this source file's location.
///
/// Other suites assign `Directory.current`, so a path relative to the CWD
/// raced with them under concurrent scheduling and failed intermittently.
/// `Platform.script` points at a generated entrypoint under the test runner,
/// so resolve against this library's own URI instead.
final String _repoRoot = () {
  // Resolve the package's own lib/ directory, then step up to the package
  // root — the same trick version.dart uses, and independent of both the
  // runner's CWD and its generated entrypoint.
  final libUri = Isolate.resolvePackageUriSync(
      Uri.parse('package:api_to_dart/api_to_dart.dart'));
  if (libUri != null && libUri.scheme == 'file') {
    return File.fromUri(libUri).parent.parent.path;
  }
  return Directory.current.path;
}();

String repoPath(String relative) => '$_repoRoot/$relative';

void main() {
  group('PostmanSource', () {
    test('parses example Postman collection', () async {
      final source = PostmanSource();
      final tree = await source.parse(
        ApiSourceConfig(
          filePath: repoPath('example/lib/api/postman_collection.json'),
        ),
      );

      expect(tree.sourceName, equals('Derman'));
      expect(tree.totalEndpoints, equals(13));
      expect(tree.folders.length, greaterThan(0));

      // Check a folder
      final appFolder = tree.folders.firstWhere((f) => f.name == 'App');
      expect(appFolder.endpoints.length, equals(4));

      // Check an endpoint
      final home = appFolder.endpoints.firstWhere((e) => e.name == 'Home');
      expect(home.method, equals(HttpMethod.GET));
      expect(home.path, equals('/home'));
    });

    test('parses auth types correctly', () async {
      final source = PostmanSource();
      final tree = await source.parse(
        ApiSourceConfig(
          filePath: repoPath('example/lib/api/postman_collection.json'),
        ),
      );

      final allEndpoints = tree.allEndpoints;

      // Home should have noauth
      final home = allEndpoints.firstWhere((e) => e.name == 'Home');
      expect(home.auth.type, equals(AuthType.none));

      // Profile Data should have bearer
      final profile = allEndpoints.firstWhere((e) => e.name == 'Profile Data');
      expect(profile.auth.type, equals(AuthType.bearer));
    });

    test('parses body correctly', () async {
      final source = PostmanSource();
      final tree = await source.parse(
        ApiSourceConfig(
          filePath: repoPath('example/lib/api/postman_collection.json'),
        ),
      );

      final login = tree.allEndpoints.firstWhere((e) => e.name == 'Login');
      expect(login.body, isNotNull);
      expect(login.body!.contentType, equals(BodyContentType.formData));
      expect(login.body!.formFields, containsPair('phone', '123456789'));
    });
  });

  group('ActionGenerator', () {
    test('generates action class', () {
      final generator = ActionGenerator();
      final endpoint = ApiEndpoint(
        name: 'Login',
        path: '/auth/login',
        method: HttpMethod.POST,
        auth: const AuthDefinition(type: AuthType.bearer, token: 'test'),
        body: const BodyDefinition(
          contentType: BodyContentType.formData,
          formFields: {'email': 'test@test.com', 'password': '123'},
        ),
      );

      final code = generator.generate(endpoint);

      // Method is prefixed so same-path endpoints don't collide on names.
      expect(code, contains('class PostLoginAction'));
      expect(code, contains('RequestMethod.POST'));
      expect(code, contains("path => '/auth/login'"));
      expect(code, contains('authRequired => true'));
      expect(code, contains('PostLoginResponse'));
    });

    test('generates action-only class', () {
      final generator = ActionGenerator();
      final endpoint = ApiEndpoint(
        name: 'GetUsers',
        path: '/users',
        method: HttpMethod.GET,
      );

      final code = generator.generateActionOnly(endpoint);

      // Name already starts with the method → no "GetGetUsers" duplication.
      expect(code, contains('class GetUsersAction'));
      expect(code, contains('ApiRequestAction<dynamic>'));
      expect(code, contains('RequestMethod.GET'));
    });

    test('same path different methods produce distinct file and class names',
        () {
      const get =
          ApiEndpoint(name: 'Users', path: '/users', method: HttpMethod.GET);
      const post =
          ApiEndpoint(name: 'Users', path: '/users', method: HttpMethod.POST);

      expect(get.fileName, equals('get_users_action.dart'));
      expect(post.fileName, equals('post_users_action.dart'));
      expect(get.fileName, isNot(equals(post.fileName)));
      expect(get.actionClassName, equals('GetUsersAction'));
      expect(post.actionClassName, equals('PostUsersAction'));
      expect(get.responseClassName, equals('GetUsersResponse'));
    });
  });

  group('BodyProcessor', () {
    test('processes null body', () {
      final body = processBody(null);
      expect(body.isEmpty, isTrue);
    });

    test('processes BodyDefinition passthrough', () {
      const original = BodyDefinition(
        contentType: BodyContentType.rawJson,
        rawBody: '{"test": true}',
      );
      final result = processBody(original);
      expect(identical(result, original), isTrue);
    });

    test('processes formdata map', () {
      final body = processBody({
        'mode': 'formdata',
        'data': {'name': 'John', 'age': '30'},
      });
      expect(body.contentType, equals(BodyContentType.formData));
      expect(body.formFields, containsPair('name', 'John'));
    });

    test('processes raw body', () {
      final body = processBody({
        'mode': 'raw',
        'data': '{"key": "value"}',
      });
      expect(body.contentType, equals(BodyContentType.rawJson));
      expect(body.rawBody, equals('{"key": "value"}'));
    });
  });

  group('ResponseGenerator', () {
    test('generates Dart model from JSON', () {
      final generator = ResponseGenerator();
      const json = '{"id": 1, "name": "Test", "active": true}';

      final code = generator.generate(json, 'UserResponse');

      expect(code, contains('class UserResponse'));
      expect(code, contains('fromJson'));
      expect(code, contains('toJson'));
      expect(code, contains('int?'));
      expect(code, contains('String?'));
      expect(code, contains('bool?'));
    });
  });

  group('EndpointTree', () {
    test('counts total endpoints correctly', () {
      final tree = EndpointTree(
        sourceName: 'Test',
        folders: [
          const ApiFolder(
            name: 'Auth',
            endpoints: [
              ApiEndpoint(
                  name: 'Login', path: '/login', method: HttpMethod.POST),
              ApiEndpoint(
                  name: 'Register', path: '/register', method: HttpMethod.POST),
            ],
          ),
        ],
        rootEndpoints: const [
          ApiEndpoint(name: 'Health', path: '/health', method: HttpMethod.GET),
        ],
      );

      expect(tree.totalEndpoints, equals(3));
      expect(tree.allEndpoints.length, equals(3));
    });
  });

  group('LocalFileSource', () {
    test('parses YAML config', () async {
      // Written to an absolute temp path rather than read from `example/`:
      // other suites assign Directory.current, so a relative path here raced
      // with them under concurrent scheduling and failed intermittently.
      final dir = Directory.systemTemp.createTempSync('api2dart_localfile');
      addTearDown(() => dir.deleteSync(recursive: true));
      final yaml = File('${dir.path}/single_action.yaml')..writeAsStringSync('''
base_url: https://to-deal.code-link.com/api
path: /auth/register
method: POST
action_name: Register
file_name: custom_register.dart
output_dir: lib/features/account/actions
auth:
  type: none
headers:
  Content-Type: application/x-www-form-urlencoded
  Accept: application/json
query_params:
  source: app
body:
  mode: urlencoded
  data:
    type: phone
    phone: 5555555555
    email: user@example.com
''');

      final source = LocalFileSource();
      final tree = await source.parse(ApiSourceConfig(filePath: yaml.path));

      expect(tree.totalEndpoints, equals(1));
      final endpoint = tree.rootEndpoints.first;
      expect(endpoint.name, equals('Register'));
      expect(endpoint.path, equals('/auth/register'));
      expect(endpoint.method, equals(HttpMethod.POST));
      expect(endpoint.body?.contentType, equals(BodyContentType.urlEncoded));
    });
  });
}
