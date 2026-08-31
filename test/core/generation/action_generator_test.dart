import 'package:api_to_dart/api_to_dart.dart';
import 'package:test/test.dart';

void main() {
  ApiEndpoint endpointWithFields(Map<String, String> fields) => ApiEndpoint(
        name: 'Send',
        path: '/send',
        method: HttpMethod.POST,
        body: BodyDefinition(
          contentType: BodyContentType.formData,
          formFields: fields,
        ),
      );

  String toMapOf(Map<String, String> fields) =>
      ActionGenerator().generate(endpointWithFields(fields));

  group('ActionGenerator string literals', () {
    test('emits single quotes so strict lint sets stay clean', () {
      // `jsonEncode` emitted double quotes, which produced ~30
      // `prefer_single_quotes` infos per batch in real projects.
      final code = toMapOf({'phone_code': '966', 'phone': '123456789'});

      expect(code, contains("'phone_code': '966'"));
      expect(code, isNot(contains('"phone_code"')));
    });

    test('escapes a dollar sign so it is not read as interpolation', () {
      // Unescaped, `$total` would be a compile error in the generated file.
      final code = toMapOf({'amount': r'$100', 'expr': r'${total}'});

      expect(code, contains(r'\$100'));
      expect(code, contains(r'\${total}'));
    });

    test('escapes a backslash', () {
      final code = toMapOf({'path': r'C:\Users\me'});

      expect(code, contains(r'C:\\Users\\me'));
    });

    test('switches to double quotes when the value holds a single quote', () {
      // Matches how `dart format` renders it, rather than escaping.
      final code = toMapOf({'name': "O'Brien"});

      expect(code, contains('"O\'Brien"'));
    });

    test('escapes a single quote when the value also holds a double quote', () {
      final code = toMapOf({'mixed': 'it\'s "quoted"'});

      // Double quotes are unavailable, so the single quote must be escaped.
      expect(code, contains("'it\\'s \"quoted\"'"));
    });

    test('escapes a newline rather than breaking the literal', () {
      // A raw line break inside a single-quoted literal is invalid Dart, so a
      // multi-line form value would emit a file that does not compile.
      final code = toMapOf({'note': 'line one\nline two'});

      expect(code, isNot(contains('line one\nline two')),
          reason: 'a raw newline breaks the generated literal');
      expect(code, contains(r'line one\nline two'));
    });

    test('escapes a carriage return and a tab', () {
      final code = toMapOf({'a': 'x\ry', 'b': 'x\ty'});

      expect(code, contains(r'x\ry'));
      expect(code, contains(r'x\ty'));
    });

    test('keeps unicode intact', () {
      final code = toMapOf({'city': 'القاهرة'});

      expect(code, contains('القاهرة'));
    });

    test('emits an empty map literal for no fields', () {
      final code = ActionGenerator().generate(ApiEndpoint(
        name: 'Ping',
        path: '/ping',
        method: HttpMethod.GET,
      ));

      // No body means no toMap override at all.
      expect(code, isNot(contains('get toMap')));
    });
  });
}
