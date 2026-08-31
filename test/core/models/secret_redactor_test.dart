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
      final out =
          SecretRedactor.text('Bearer Bearer 999|EXAMPLEfaketokenvalue');
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

  group('SecretRedactor JSON embedded in a string', () {
    test('redacts secrets inside a JSON document held as a string', () {
      // Real APIs echo request bodies back as a raw string (a `payload`
      // column, a webhook log). Walking only parsed structures misses those.
      final out = SecretRedactor.json({
        'data': '{"access_token":"leaked","name":"Sara"}',
      }) as Map;

      expect(out['data'], isNot(contains('leaked')));
      expect(out['data'], contains(SecretRedactor.placeholder));
      // Non-secret content inside the embedded document survives.
      expect(out['data'], contains('Sara'));
    });

    test('leaves a plain string that only looks like a brace alone', () {
      final out = SecretRedactor.json({'note': '{not json'}) as Map;
      expect(out['note'], '{not json');
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

  group('SecretRedactor query-string credentials', () {
    test('redacts a secret query parameter but keeps its name', () {
      final out = SecretRedactor.text(
          'https://api.example.com/login?token=SUPERSECRET123456789');

      expect(out, isNot(contains('SUPERSECRET123456789')));
      expect(out, contains('token=${SecretRedactor.placeholder}'));
    });

    test('leaves non-secret parameters untouched', () {
      final out =
          SecretRedactor.text('https://api.example.com/users?page=2&sort=name');

      expect(out, 'https://api.example.com/users?page=2&sort=name');
    });

    test('redacts each secret parameter in a multi-param URL', () {
      final out = SecretRedactor.text(
          'https://api.example.com/x?page=1&api_key=abc123&refresh_token=zzz9');

      expect(out, contains('page=1'));
      expect(out, isNot(contains('abc123')));
      expect(out, isNot(contains('zzz9')));
      expect(out, contains('api_key=${SecretRedactor.placeholder}'));
      expect(out, contains('refresh_token=${SecretRedactor.placeholder}'));
    });

    test('stops at the parameter boundary', () {
      final out =
          SecretRedactor.text('https://api.example.com/x?token=secret&page=7');

      expect(out, contains('page=7'));
      expect(out, isNot(contains('secret&')));
    });

    test('matches the parameter name case-insensitively', () {
      final out =
          SecretRedactor.text('https://api.example.com/x?Access_Key=abc123xyz');

      expect(out, isNot(contains('abc123xyz')));
      expect(out, contains(SecretRedactor.placeholder));
    });

    test('does not redact names that merely contain a bounded word', () {
      // `author` contains `auth`, but `auth` only matches a whole segment.
      final out = SecretRedactor.text(
          'https://api.example.com/posts?author=bob&page=2');

      expect(out, 'https://api.example.com/posts?author=bob&page=2');
    });

    test('errs toward redacting when an always-credential word is present', () {
      // `tokens_count` contains `token`, which is a credential wherever it
      // appears — the same rule that keeps `session_token_type` redacted. A
      // lost count is the cheaper error than a leaked token, and the parameter
      // name itself is always preserved.
      final out =
          SecretRedactor.text('https://api.example.com/x?tokens_count=5');

      expect(out, contains('tokens_count='));
      expect(out, contains(SecretRedactor.placeholder));
    });

    test('stops the redacted value at a URL fragment', () {
      final out =
          SecretRedactor.text('https://api.example.com/x?token=abc123#section');

      expect(out, isNot(contains('abc123')));
      expect(out, contains('#section'));
    });
  });

  group('SecretRedactor preserves non-credential shape', () {
    test('keeps fields that merely contain a credential word', () {
      // Substring matching on `session`/`signature`/`refresh` redacted these,
      // shredding the response shape --json and the MCP inspect tool deliver.
      final out = SecretRedactor.json({
        'session_count': 3,
        'signature_required': true,
        'refresh_interval': 30,
        'sessions': [
          {'id': 1, 'duration': 60},
        ],
      }) as Map;

      expect(out['session_count'], 3);
      expect(out['signature_required'], true);
      expect(out['refresh_interval'], 30);
      expect(out['sessions'], isA<List>());
      expect((out['sessions'] as List).first, isA<Map>());
      expect(((out['sessions'] as List).first as Map)['duration'], 60);
    });

    test('a descriptor never un-redacts an always-credential word', () {
      // The descriptor veto fired on any segment match, so a key ending in
      // `token`/`password`/`api_key` escaped redaction entirely. `token_type`
      // is a field of every OAuth2 token response (RFC 6749), so these are
      // ordinary shapes, not contrived ones.
      final out = SecretRedactor.json({
        'session_token_type': 'sess_live_ABCDEF0123',
        'api_key_status': 'sk_live_9988776655443322',
        'password_valid': 'hunter2plaintext',
        'auth_status_token': 'opaqueLIVEvalue0123456789',
        'access_token_type': 'opaqueLIVEjwtvalue',
        'token_url': 'https://a.co/cb?code=LIVE',
      }) as Map;

      for (final key in out.keys) {
        expect(out[key], SecretRedactor.placeholder, reason: 'leaked: $key');
      }
    });

    test('the same keys are redacted in a rendered log header block', () {
      // Newly reachable: fixing the literal `$k: $v` bug made this block render
      // real values for the first time.
      final log = RequestLog(
        requestName: 'oauth',
        requestMethod: 'POST',
        url: 'https://api.example.com/oauth/token',
        headers: const {
          'X-Session-Token-Type': 'sess_live_OPAQUE_9988',
          'X-Api-Key-Type': 'sk_live_112233445566',
        },
        sentTime: DateTime(2026, 1, 1),
      );

      final visible = log.toMarkdown().split('<!-- api2dart:request').first;

      expect(visible, isNot(contains('sess_live_OPAQUE_9988')));
      expect(visible, isNot(contains('sk_live_112233445566')));
    });

    test('still redacts the credential spellings of those words', () {
      final out = SecretRedactor.json({
        'session': 'sess_live_1',
        'session_id': 'sess_live_2',
        'sessionId': 'sess_live_3',
        'signature': 'sig_live',
        'refresh_token': 'rt_live',
      }) as Map;

      for (final key in out.keys) {
        expect(out[key], SecretRedactor.placeholder, reason: 'leaked: $key');
      }
    });

    test('treats the two auth separator spellings alike', () {
      // `auth\b` matched `auth-type` but not `auth_method`, since `-` is a word
      // boundary and `_` is not. Segment matching makes the separators behave
      // identically; whether a given key is secret is then decided by the
      // descriptor rule, not by which punctuation it happens to use.
      expect(SecretRedactor.isSecretKey('auth-type'),
          SecretRedactor.isSecretKey('auth_type'));
      expect(SecretRedactor.isSecretKey('auth-token'),
          SecretRedactor.isSecretKey('auth_token'));

      // A key holding the credential is redacted, in any spelling.
      expect(SecretRedactor.isSecretKey('auth_method'), isTrue);
      expect(SecretRedactor.isSecretKey('authToken'), isTrue);
      expect(SecretRedactor.isSecretKey('X-Auth'), isTrue);

      // A key describing one keeps its value — `auth_type` names which scheme
      // is in use, not the secret.
      expect(SecretRedactor.isSecretKey('auth_type'), isFalse);

      // Ordinary words that merely start with `auth` are untouched.
      expect(SecretRedactor.isSecretKey('author'), isFalse);
      expect(SecretRedactor.isSecretKey('authority'), isFalse);
    });
  });

  group('SecretRedactor query names the key rule agrees with', () {
    test('redacts spellings the segment rule used to miss', () {
      for (final url in [
        'https://api.example.com/x?authToken=abc123',
        'https://api.example.com/x?authorization=abc123',
        'https://api.example.com/x?credentials=abc123',
      ]) {
        expect(SecretRedactor.text(url), isNot(contains('abc123')),
            reason: 'leaked in: $url');
      }
    });

    test('still leaves ordinary parameters alone', () {
      const url = 'https://api.example.com/posts?author=bob&page=2';

      expect(SecretRedactor.text(url), url);
    });

    test('finds a credential nested inside another parameter value', () {
      // An outer non-secret parameter used to swallow the whole nested URL,
      // so its inner `api_key` survived. OAuth `redirect_uri`/`callback`
      // values are exactly the ones that carry nested credentials.
      final out =
          SecretRedactor.text('https://auth.example.com/authorize?client_id=abc'
              '&redirect_uri=https://app.example.com/cb?api_key=LIVE_NESTED_KEY'
              '&scope=read');

      expect(out, isNot(contains('LIVE_NESTED_KEY')));
      expect(out, contains('client_id=abc'));
      expect(out, contains('scope=read'));
    });

    test('redacts a token delivered in the URL fragment', () {
      // OAuth2 implicit flow returns the token after `#`. Terminating the scan
      // there left the live token untouched while redacting the harmless
      // `token_type` that followed it.
      final out = SecretRedactor.text(
          'https://app.co/cb#access_token=LIVE_IMPLICIT&token_type=bearer');

      expect(out, isNot(contains('LIVE_IMPLICIT')));
      expect(out, contains('access_token=<redacted>'));
    });

    test('classifies percent-encoded nested URLs and names', () {
      // A real OAuth redirect_uri is percent-encoded — the spec requires it —
      // so a raw scan never sees the inner api_key.
      final encoded = SecretRedactor.text(
          'https://a.co/x?redirect_uri=https%3A%2F%2Fb.co%2Fcb%3Fapi_key%3DLIVE_ENC');
      expect(encoded, isNot(contains('LIVE_ENC')));

      // `%5F` is `_`, so `api%5Fkey` is `api_key`.
      final name = SecretRedactor.text('https://a.co/x?api%5Fkey=LIVE_NAME');
      expect(name, isNot(contains('LIVE_NAME')));
    });

    test('finds a doubly-encoded nested credential', () {
      // %2520 decodes to %20, so one pass is not enough; the loop must keep
      // going while decoding still changes the value.
      final out = SecretRedactor.text('https://a.co/x?redirect_uri='
          'https%253A%252F%252Fb.co%252Fcb%253Fapi_key%253DLIVE_DBL');

      expect(out, isNot(contains('LIVE_DBL')));
    });

    test('redacts semicolon-separated parameters', () {
      final out = SecretRedactor.text('https://a.co/x?page=1;token=LIVE_SEMI');

      expect(out, isNot(contains('LIVE_SEMI')));
      expect(out, contains('page=1'));
    });

    test('redacts a bearer token whole, whatever characters it uses', () {
      // An allowlist charset truncated real tokens and left the tail exposed.
      for (final token in ['abc:def:ghi', 'abc%2Fdef', 'sk_live_*abc']) {
        expect(SecretRedactor.text('Authorization: Bearer $token'),
            'Authorization: ${SecretRedactor.placeholder}',
            reason: 'leaked tail for: $token');
      }
    });

    test('terminates on adversarially nested URLs', () {
      final deep = 'https://a.co/?next=https://b.co/?next=https://c.co/'
          '?next=https://d.co/?token=DEEP_LIVE_KEY';

      expect(SecretRedactor.text(deep), isNot(contains('DEEP_LIVE_KEY')));

      // A recursive implementation threw StackOverflowError at ~15 KB of
      // `?a=`, and an overflow means no redaction runs at all. Assert on the
      // output, not `isNotNull` — `text` returns a non-nullable String, so
      // that could never fail for any input.
      final chain = '?a=' * 5000;
      expect(SecretRedactor.text('https://a.co/${chain}z'), contains('a='));

      // Degenerate shapes return unchanged rather than looping.
      expect(SecretRedactor.text('https://a.co/?x=??'), 'https://a.co/?x=??');
      expect(SecretRedactor.text('?a=?b=?c=?d=1'), '?a=?b=?c=?d=1');
    });

    test('decoding never emits a credential that was encoded', () {
      // The decoded form has no `?&#;` before the inner key, so nothing
      // downstream could redact it — writing it back created a plaintext leak.
      final out =
          SecretRedactor.text('?data=%7B%22api_key%22%3A%22LIVE_SECRET%22%7D');

      expect(out, isNot(contains('LIVE_SECRET')));
      expect(out, isNot(contains('api_key')),
          reason: 'the decoded form must not be emitted');
    });

    test('catches a single-encoded key=value that opens a value', () {
      // The query pattern needs a leading `?&#;`, so a decoded fragment that
      // *opens* with the pair matched nothing and leaked straight through.
      for (final url in [
        'https://a.co/cb?state=api_key%3DLIVE_A',
        'https://a.co/cb?state=access_token%3DLIVE_B',
        'https://a.co/cb?cb=done%20api_key%3DLIVE_C',
      ]) {
        expect(SecretRedactor.text(url), isNot(contains('LIVE_')),
            reason: 'leaked in: $url');
      }
    });

    test('an encoded value carrying no secret is left exactly as it was', () {
      const url = 'https://a.co/x?redirect_uri=https%3A%2F%2Fb.co%2Fcb';

      expect(SecretRedactor.text(url), url);
    });

    test('leaves a non-query fragment untouched', () {
      // `#` is a separator now, but a plain anchor has no `name=value` shape.
      const anchor = 'See https://docs.example.com/guide#installation for more';
      expect(SecretRedactor.text(anchor), anchor);

      const heading = 'https://github.com/o/r/blob/main/a.dart#L42';
      expect(SecretRedactor.text(heading), heading);
    });

    test('keeps the cURL snippet well-formed around a bearer token', () {
      // `\S+` ate the closing quote, malforming every rendered cURL block.
      final out = SecretRedactor.text(
          'curl -H "Authorization: Bearer LIVEXYZ" https://a.co');

      expect(out, isNot(contains('LIVEXYZ')));
      expect(out, contains('"Authorization: <redacted>"'));
      expect(out, contains('https://a.co'));
    });
  });

  group('SecretRedactor bearer-equivalent headers', () {
    test('redacts session, signature and jwt headers by name', () {
      final out = SecretRedactor.headers({
        'X-Session': 'sess_abc123def456',
        'X-Signature': 'sig_998877',
        'X-JWT': 'eyJhbGciOiJIUzI1NiJ9.payload.sig',
        'X-Request-Id': 'req-42',
      });

      // Holding any of these is enough to act as the user.
      expect(out['X-Session'], SecretRedactor.placeholder);
      expect(out['X-Signature'], SecretRedactor.placeholder);
      expect(out['X-JWT'], SecretRedactor.placeholder);
      // A correlation id is not a credential — it stays readable.
      expect(out['X-Request-Id'], 'req-42');
    });

    test('a rendered log does not leak a session header', () {
      final log = RequestLog(
        requestName: 'get_profile',
        requestMethod: 'GET',
        url: 'https://api.example.com/profile',
        headers: const {'X-Session': 'sess_live_value_9999'},
        sentTime: DateTime(2026, 1, 1),
      );

      final visible = log.toMarkdown().split('<!-- api2dart:request').first;

      expect(visible, isNot(contains('sess_live_value_9999')));
      expect(visible, contains('X-Session: <redacted>'));
    });
  });
}
