import 'package:api_to_dart/api_to_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RequestLog resend metadata', () {
    test('round-trips request data through markdown', () {
      final log = RequestLog(
        requestName: 'create_user',
        requestMethod: 'POST',
        url: 'https://api.example.com/users?role=admin',
        statusCode: 201,
        headers: {
          'Authorization': 'Bearer abc123',
          'Content-Type': 'application/json',
        },
        queryParameters: {'role': 'admin'},
        requestBody: '{"name":"Sara"}',
        responseBody: '{"id":1,"name":"Sara"}',
        sentTime: DateTime(2026, 1, 1, 10, 0, 0),
        receivedTime: DateTime(2026, 1, 1, 10, 0, 1),
      );

      final restored = RequestLog.fromMarkdown(log.toMarkdown());

      expect(restored, isNotNull);
      expect(restored!.requestName, 'create_user');
      expect(restored.requestMethod, 'POST');
      expect(restored.url, 'https://api.example.com/users?role=admin');
      expect(restored.headers['Authorization'], 'Bearer abc123');
      expect(restored.queryParameters['role'], 'admin');
      expect(restored.requestBody, '{"name":"Sara"}');
      // Response/status are intentionally not restored — they're regenerated.
      expect(restored.statusCode, isNull);
    });

    test('round-trips form-field (Map) request bodies', () {
      final log = RequestLog(
        requestName: 'login',
        requestMethod: 'POST',
        url: 'https://api.example.com/login',
        headers: const {},
        requestBody: const {'email': 'a@b.com', 'password': 'x'},
        sentTime: DateTime(2026, 1, 1),
      );

      final restored = RequestLog.fromMarkdown(log.toMarkdown());

      expect(restored, isNotNull);
      expect(restored!.requestBody, isA<Map>());
      expect((restored.requestBody as Map)['email'], 'a@b.com');
    });

    test('embeds a resend snippet matching the file name', () {
      final log = RequestLog(
        requestName: 'Get Users',
        requestMethod: 'GET',
        url: 'https://api.example.com/users',
        sentTime: DateTime(2026, 1, 1),
      );

      final md = log.toMarkdown(fileName: 'get_users_action');

      expect(md, contains("api2dart resend 'get_users_action.md'"));
    });

    test('returns null for content without metadata', () {
      expect(RequestLog.fromMarkdown('# Just a heading\n\nno meta'), isNull);
    });

    test('round-trips a body containing the block terminator', () {
      // A `-->` in the payload used to truncate the metadata block, leaving
      // JSON that failed to decode — fromMarkdown then returned null and
      // resend refused the log outright.
      final log = RequestLog(
        requestName: 'arrow',
        requestMethod: 'POST',
        url: 'https://api.example.com/notes',
        requestBody: const {'note': 'a --> b'},
        sentTime: DateTime(2026, 1, 1),
      );

      final restored = RequestLog.fromMarkdown(log.toMarkdown());

      expect(restored, isNotNull);
      expect((restored!.requestBody as Map)['note'], 'a --> b');
    });

    test('reads the real block when the body echoes the marker text', () {
      // `indexOf` matched the echoed marker inside the response and truncated
      // there, so fromMarkdown returned null and resend refused the log.
      final log = RequestLog(
        requestName: 'echo',
        requestMethod: 'POST',
        url: 'https://api.example.com/echo',
        requestBody: const {'note': 'docs say <!-- api2dart:request ... -->'},
        sentTime: DateTime(2026, 1, 1),
      );

      final restored = RequestLog.fromMarkdown(log.toMarkdown());

      expect(restored, isNotNull);
      expect(restored!.requestName, 'echo');
      expect(restored.url, 'https://api.example.com/echo');
    });

    test('still reads legacy logs with a plain-JSON metadata block', () {
      const legacy = '# old\n\n'
          '<!-- api2dart:request {"requestName":"old","requestMethod":"GET",'
          '"url":"https://api.example.com/x","headers":{},'
          '"queryParameters":{},"requestBody":null} -->';

      final restored = RequestLog.fromMarkdown(legacy);

      expect(restored, isNotNull);
      expect(restored!.requestName, 'old');
      expect(restored.url, 'https://api.example.com/x');
    });
  });

  group('RequestLog rendering', () {
    test('renders header names and values, redacting secrets', () {
      final log = RequestLog(
        requestName: 'get_users',
        requestMethod: 'GET',
        url: 'https://api.example.com/users',
        headers: const {
          'Authorization': 'Bearer abc123',
          'X-Trace-Id': 'trace-42',
        },
        sentTime: DateTime(2026, 1, 1),
      );

      final md = log.toMarkdown();

      // The interpolations were escaped, so every log rendered the literal
      // text `$k: $v` instead of the headers.
      expect(md, isNot(contains(r'$k: $v')));
      expect(md, contains('X-Trace-Id: trace-42'));
      expect(md, contains('Authorization: <redacted>'));
      expect(md, isNot(contains('Authorization: Bearer abc123')));
    });

    test('redacts a credential carried in the URL query string', () {
      final log = RequestLog(
        requestName: 'login',
        requestMethod: 'GET',
        url: 'https://api.example.com/login?token=SUPERSECRET123456789&page=2',
        sentTime: DateTime(2026, 1, 1),
      );

      // Only the visible section: the hidden resend block keeps the URL
      // verbatim by design, and since it is base64 a whole-document substring
      // search would pass even if the visible section leaked.
      final visible = log.toMarkdown().split('<!-- api2dart:request').first;

      expect(visible, isNot(contains('SUPERSECRET123456789')));
      expect(visible, contains('token=<redacted>'));
      // Non-secret params keep their values.
      expect(visible, contains('page=2'));
    });
  });
}
