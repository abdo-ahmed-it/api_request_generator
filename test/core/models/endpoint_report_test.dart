import 'package:api_to_dart/api_to_dart.dart';
import 'package:test/test.dart';

void main() {
  // The shapes below are taken from a real Laravel API response that the
  // naive generator models incorrectly.
  final realWorldSample = {
    'data': [
      {
        'id': 20,
        'name': {'ar': 'سكن', 'en': 'Housing'},
        'type_text': null,
        'name_text': 'سكن',
        'created_at_text': '---',
        'flag': 1,
      },
      {
        'id': '21',
        'name': {'ar': 'x', 'en': 'y'},
        'flag': 'yes',
      },
    ],
    'meta': {'total': 20},
    'grouped': {'0': 'a', '1': 'b'},
  };

  String joined(dynamic sample) => EndpointReport.notesFor(sample).join('\n');

  group('EndpointReport.notesFor', () {
    test('flags a localized object masquerading as a String', () {
      expect(joined(realWorldSample), contains('localized object'));
    });

    test('flags a display twin next to its raw field', () {
      // `name_text` sits beside `name`.
      expect(joined(realWorldSample), contains('display twin'));
    });

    test('flags a String id', () {
      expect(joined(realWorldSample), contains('is a String, not an int'));
    });

    test('flags a "---" placeholder string', () {
      expect(joined(realWorldSample), contains('placeholder string'));
    });

    test('flags a null-valued field as type-unconfirmed', () {
      expect(joined(realWorldSample), contains('null in the sample'));
    });

    test('flags inconsistent types for the same field across items', () {
      // `flag` is int in one item and String in the next.
      expect(joined(realWorldSample), contains('inconsistent types'));
    });

    test('flags a paginated data+meta envelope', () {
      expect(joined(realWorldSample), contains('paginated envelope'));
    });

    test('flags an object with numeric keys', () {
      expect(joined(realWorldSample), contains('numeric keys'));
    });

    test('returns nothing for a clean, unambiguous shape', () {
      expect(EndpointReport.notesFor({'id': 1, 'title': 'ok'}), isEmpty);
    });

    test('returns nothing when there is no sample', () {
      expect(EndpointReport.notesFor(null), isEmpty);
    });
  });

  group('EndpointReport.build', () {
    ApiEndpoint endpoint({ResponseDefinition? response}) => ApiEndpoint(
          name: 'Get Items',
          path: '/items',
          method: HttpMethod.GET,
          headers: const {'Authorization': 'Bearer secret123'},
          queryParams: const {'page': '1', 'api_key': 'k-should-not-leak'},
          response: response,
        );

    test('truncates long arrays but keeps the total count', () {
      final long = List.generate(20, (i) => {'id': i});
      final report = EndpointReport.build(
        endpoint(),
        response: ResponseDefinition(
          source: ResponseSource.fetched,
          jsonBody: '{"rows": ${long.map((e) => '{"id":${e['id']}}').toList()}}'
              .replaceAll("'", ''),
        ),
      );

      final rows = (report['response'] as Map)['sample']['rows'] as List;
      expect(rows, hasLength(EndpointReport.maxArrayItems + 1));
      expect(rows.last, contains('total 20'));
    });

    test('never leaks a secret query param or header value', () {
      final report = EndpointReport.build(endpoint());

      expect(report.toString(), isNot(contains('k-should-not-leak')));
      expect(report.toString(), isNot(contains('secret123')));
      // The header name survives — it documents that auth is required.
      expect(report['headers'], contains('Authorization'));
    });

    test('reports an unresolved response rather than inventing a shape', () {
      final report = EndpointReport.build(endpoint());
      expect((report['response'] as Map)['source'], 'none');
    });

    test('says why a shape is missing instead of staying silent', () {
      // `source: none` alone is indistinguishable from "returns nothing", so a
      // consuming agent could not tell a missing example from a failed fetch.
      final unresolved = EndpointReport.build(endpoint());
      expect((unresolved['response'] as Map)['note'], isNotNull);

      final empty = EndpointReport.build(
        endpoint(),
        response: const ResponseDefinition(source: ResponseSource.none),
      );
      final note = (empty['response'] as Map)['note'] as String;
      expect(note, contains('base_url'),
          reason: 'the note should say how to get the real shape');
    });

    test('flags a schema-only response as unverified', () {
      final report = EndpointReport.build(
        endpoint(),
        response: const ResponseDefinition(
          source: ResponseSource.schema,
          schema: {
            'type': 'object',
            'properties': {
              'id': {'type': 'integer'}
            }
          },
        ),
      );

      final response = report['response'] as Map;
      expect(response['schema'], isNotNull);
      // A contract is not observed data; the two routinely disagree.
      expect(response['note'], contains('unverified'));
    });

    test('infers Dart types from the sample', () {
      final report = EndpointReport.build(
        endpoint(),
        response: const ResponseDefinition(
          source: ResponseSource.fetched,
          jsonBody: '{"id":1,"name":"x","ok":true,"score":1.5}',
        ),
      );

      final types = (report['response'] as Map)['inferred_types'] as Map;
      expect(types['id'], 'int');
      expect(types['name'], 'String');
      expect(types['ok'], 'bool');
      expect(types['score'], 'num');
    });
  });
}
