import 'package:api_to_dart/api_to_dart.dart';
import 'package:test/test.dart';

void main() {
  group('SecretRedactor.headers', () {
    test('redacts known credential headers regardless of case', () {
      final out = SecretRedactor.headers({
        'Authorization': 'Bearer 999|EXAMPLEfaketokenvalue0000000',
        'X-API-KEY': '00000000-1111-2222-3333-444444444444',
        'x-secret-key': 'EXAMPLEfakesecretkeyvalue0000000',
        'Cookie': 'session=abc',
        'Content-Type': 'application/json',
      });

      expect(out['Authorization'], SecretRedactor.placeholder);
      expect(out['X-API-KEY'], SecretRedactor.placeholder);
      expect(out['x-secret-key'], SecretRedactor.placeholder);
      expect(out['Cookie'], SecretRedactor.placeholder);
      // Non-secret headers survive — they describe the request shape.
      expect(out['Content-Type'], 'application/json');
    });

    test('keeps the key so the reader still sees auth is required', () {
      final out = SecretRedactor.headers({'Authorization': 'Bearer x'});
      expect(out.containsKey('Authorization'), isTrue);
    });
  });

  group('SecretRedactor.text', () {
    test('redacts a bearer token by shape', () {
      expect(SecretRedactor.text('Authorization: Bearer abc123xyz'),
          'Authorization: <redacted>');
    });

    test('redacts the duplicated `Bearer Bearer` form seen in real logs', () {
      final out = SecretRedactor.text('Bearer Bearer 999|EXAMPLEfaketokenvalue');
      expect(out, SecretRedactor.placeholder);
      expect(out, isNot(contains('328|')));
    });

    test('redacts a bare Laravel Sanctum token', () {
      expect(
        SecretRedactor.text('token is 999|EXAMPLEfaketokenvalue0000000'),
        'token is <redacted>',
      );
    });

    test('leaves ordinary text untouched', () {
      expect(SecretRedactor.text('just a name'), 'just a name');
    });
  });

  group('SecretRedactor.json', () {
    test('redacts secret-named keys at any depth', () {
      final out = SecretRedactor.json({
        'id': 20,
        'access_token': 'abc',
        'user': {
          'name': 'Sara',
          'refresh_token': 'xyz',
          'nested': {'api_key': 'k'},
        },
      }) as Map;

      expect(out['id'], 20);
      expect(out['access_token'], SecretRedactor.placeholder);
      expect((out['user'] as Map)['name'], 'Sara');
      expect((out['user'] as Map)['refresh_token'], SecretRedactor.placeholder);
      expect(((out['user'] as Map)['nested'] as Map)['api_key'],
          SecretRedactor.placeholder);
    });

    test('redacts inside lists and preserves shape', () {
      final out = SecretRedactor.json([
        {'password': 'p', 'keep': 1},
      ]) as List;

      expect(out, hasLength(1));
      expect((out.first as Map)['password'], SecretRedactor.placeholder);
      expect((out.first as Map)['keep'], 1);
    });

    test('preserves translation objects — they are shape, not secrets', () {
      final out = SecretRedactor.json({
        'name': {'ar': 'سكن', 'en': 'Housing'},
        'created_at_text': '---',
      }) as Map;

      expect((out['name'] as Map)['en'], 'Housing');
      expect(out['created_at_text'], '---');
    });
  });

  group('RequestLog rendering', () {
    RequestLog buildLog() => RequestLog(
          requestName: 'get_form_data',
          requestMethod: 'GET',
          url: 'https://api.example.com/form-data',
          statusCode: 200,
          headers: const {
            'Authorization': 'Bearer 999|EXAMPLEfaketokenvalue0000000',
            'x-api-key': '00000000-1111-2222-3333-444444444444',
            'x-secret-key': 'EXAMPLEfakesecretkeyvalue0000000',
          },
          responseBody: '{"id":20,"access_token":"leaked"}',
          sentTime: DateTime(2026, 8, 30),
        );

    test('no live secret appears in the human-facing markdown', () {
      final md = buildLog().toMarkdown();
      // Everything before the hidden metadata block is what a reader sees.
      final visible = md.substring(0, md.indexOf('<!-- api2dart:request'));

      expect(visible, isNot(contains('999|EXAMPLEfaketokenvalue')));
      expect(visible, isNot(contains('00000000-1111-2222')));
      expect(visible, isNot(contains('EXAMPLEfakesecretkeyvalue0000000')));
      expect(visible, isNot(contains('leaked')));
      expect(visible, contains(SecretRedactor.placeholder));
    });

    test('the cURL snippet is redacted too', () {
      final md = buildLog().toMarkdown();
      final curl = md.substring(md.indexOf('## cURL'), md.indexOf('## Resend'));

      expect(curl, contains('curl -X GET'));
      expect(curl, isNot(contains('999|EXAMPLEfaketokenvalue')));
      expect(curl, contains(SecretRedactor.placeholder));
    });

    test('resend metadata keeps real credentials so replay still works', () {
      final restored = RequestLog.fromMarkdown(buildLog().toMarkdown());

      expect(restored, isNotNull);
      expect(restored!.headers['Authorization'],
          'Bearer 999|EXAMPLEfaketokenvalue0000000');
      expect(restored.headers['x-api-key'],
          '00000000-1111-2222-3333-444444444444');
    });
  });
}
