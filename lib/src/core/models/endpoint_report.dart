import 'dart:convert';

import 'api_endpoint.dart';
import 'body_definition.dart';
import 'response_definition.dart';
import 'secret_redactor.dart';

/// Builds the machine-readable description of an endpoint emitted by
/// `generate --json`.
///
/// The consumer is a tool (an MCP server, a script) that wants the *shape* of
/// an API — methods, params, response types — not generated Dart. Everything
/// here is redacted and truncated before it leaves the process, because the
/// output is designed to be pasted into a model's context.
class EndpointReport {
  const EndpointReport._();

  /// Arrays longer than this are truncated: the goal is to learn the element
  /// shape, not to copy the data. Keeps context small and avoids spilling real
  /// records (customer rows, staff lists) into a transcript.
  static const int maxArrayItems = 2;

  /// Builds the report for one endpoint. [response] is the resolved response
  /// when one was fetched; null when running without live resolution.
  static Map<String, dynamic> build(
    ApiEndpoint endpoint, {
    ResponseDefinition? response,
    String? outputFile,
  }) {
    final sample = _sampleOf(response);
    final report = <String, dynamic>{
      'name': endpoint.name,
      'method': endpoint.method.name,
      'path': endpoint.path,
      if (endpoint.description != null && endpoint.description!.isNotEmpty)
        'description': endpoint.description,
      'requires_auth': endpoint.auth.requiresAuth,
      if (endpoint.auth.requiresAuth) 'auth_type': endpoint.auth.type.name,
      'query_params': _params(endpoint.queryParams),
      'headers': SecretRedactor.headers(endpoint.headers).keys.toList(),
      if (endpoint.body != null && !endpoint.body!.isEmpty)
        'body': _body(endpoint.body!),
      'response': _response(response, sample),
      'notes': notesFor(sample),
      if (outputFile != null) 'would_write': outputFile,
    };
    return report;
  }

  static List<Map<String, String>> _params(Map<String, String> params) {
    return params.entries
        .map((e) => {
              'name': e.key,
              'example': SecretRedactor.isSecretKey(e.key)
                  ? SecretRedactor.placeholder
                  : SecretRedactor.text(e.value),
            })
        .toList();
  }

  static Map<String, dynamic> _body(BodyDefinition body) {
    return {
      if (body.contentType != null) 'content_type': body.contentType!.name,
      if (body.hasFormFields)
        'fields': _params(body.formFields!),
      if (body.hasRawBody)
        'raw': _truncate(_decodeMaybe(body.rawBody!)),
      if (body.hasFiles)
        'files': body.files!.map((f) => f.fieldName).toList(),
    };
  }

  static Map<String, dynamic> _response(
    ResponseDefinition? response,
    dynamic sample,
  ) {
    if (response == null) {
      return {'source': 'none', 'note': 'no response resolved (shape unknown)'};
    }
    return {
      'source': response.source.name,
      if (response.hasSchema)
        'schema': SecretRedactor.json(response.schema),
      if (sample != null) 'sample': _truncate(sample),
      if (sample != null) 'inferred_types': _inferTypes(sample),
    };
  }

  /// Decodes the resolved response body into a structure, redacted.
  static dynamic _sampleOf(ResponseDefinition? response) {
    if (response == null || !response.hasJson) return null;
    return SecretRedactor.json(_decodeMaybe(response.jsonBody!));
  }

  static dynamic _decodeMaybe(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return SecretRedactor.text(raw);
    }
  }

  /// Recursively caps long arrays, replacing the tail with a count marker so
  /// the reader still knows how many elements the real response had.
  static dynamic _truncate(dynamic data) {
    if (data is List) {
      final kept = data.take(maxArrayItems).map(_truncate).toList();
      if (data.length > maxArrayItems) {
        kept.add('… +${data.length - maxArrayItems} more items '
            '(total ${data.length})');
      }
      return kept;
    }
    if (data is Map) {
      return data.map((k, v) => MapEntry(k.toString(), _truncate(v)));
    }
    return data;
  }

  /// Maps each field to the Dart type implied by the sample, so the caller can
  /// write a model without guessing. Only the first element of a list is
  /// inspected — elements are assumed homogeneous, and [notesFor] flags it when
  /// they aren't.
  static dynamic _inferTypes(dynamic data) {
    if (data is Map) {
      return data.map((k, v) => MapEntry(k.toString(), _inferTypes(v)));
    }
    if (data is List) {
      if (data.isEmpty) return 'List<dynamic> (empty — type unknown)';
      return [_inferTypes(data.first)];
    }
    if (data == null) return 'dynamic (null in sample)';
    if (data is bool) return 'bool';
    if (data is int) return 'int';
    if (data is double) return 'num';
    return 'String';
  }

  /// Flags shapes that routinely break naive generated models. This is the
  /// part a plain `cat` of a log can't give you: it ties the observed JSON to
  /// the decisions the caller has to make when hand-writing the model.
  static List<String> notesFor(dynamic sample) {
    if (sample == null) return const [];
    final notes = <String>{};
    _scan(sample, notes);
    return notes.toList();
  }

  static void _scan(dynamic node, Set<String> notes, {String path = ''}) {
    if (node is Map) {
      final keys = node.keys.map((k) => k.toString()).toList();

      // A map keyed "0","1","2"… is a PHP/Laravel array that serialized as an
      // object; decoding it as a List throws at runtime.
      if (keys.isNotEmpty &&
          keys.every((k) => int.tryParse(k) != null)) {
        notes.add('$path: object with numeric keys — a list serialized as an '
            'object; decode as a map, not a List');
      }

      if (keys.contains('data') && keys.contains('meta')) {
        notes.add('$path: paginated envelope (data + meta) — expect a '
            'paginated list response');
      }

      for (final entry in node.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        final childPath = path.isEmpty ? key : '$path.$key';

        // {ar: …, en: …} is a translation object, not a String.
        if (value is Map) {
          final vk = value.keys.map((k) => k.toString()).toSet();
          if (vk.isNotEmpty && vk.length <= 4 &&
              vk.every((k) => k.length == 2) &&
              (vk.contains('ar') || vk.contains('en'))) {
            notes.add("'$childPath' is a localized object "
                '(${vk.join('/')}), not a String — pick a locale explicitly');
          }
        }

        // A `*_text` / `*_name` twin next to a raw field.
        if ((key.endsWith('_text') || key.endsWith('_name'))) {
          final base = key.substring(0, key.lastIndexOf('_'));
          if (node.containsKey(base)) {
            notes.add("'$childPath' is a display twin of '$base' — "
                'decide which one the UI should read');
          }
        }

        if (key == 'id' && value is String) {
          notes.add("'$childPath' is a String, not an int — "
              'parse defensively');
        }

        if (value is String && (value == '---' || value.trim().isEmpty)) {
          final kind = value == '---' ? 'dashes' : 'empty';
          notes.add("'$childPath' holds a placeholder string ($kind) — "
              'treat it as absent, not as a value');
        }

        if (value == null) {
          notes.add("'$childPath' is null in the sample — type unconfirmed; "
              'check the spec before assuming String');
        }

        _scan(value, notes, path: childPath);
      }
      return;
    }

    if (node is List) {
      // Same field carrying different types across elements.
      final typesByKey = <String, Set<String>>{};
      for (final item in node) {
        if (item is Map) {
          item.forEach((k, v) {
            typesByKey
                .putIfAbsent(k.toString(), () => <String>{})
                .add(_typeName(v));
          });
        }
      }
      typesByKey.forEach((k, types) {
        final concrete = types.where((t) => t != 'null').toSet();
        if (concrete.length > 1) {
          notes.add("'$path[].$k' has inconsistent types across items "
              '(${concrete.join(', ')}) — parse defensively');
        }
      });

      // Scan every element, not just the first: the anomaly that breaks a
      // model (a String id, a null, a missing field) often shows up only in a
      // later row. Notes are a Set keyed on the shared `[]` path, so repeated
      // findings across elements collapse into one.
      for (final item in node) {
        _scan(item, notes, path: '$path[]');
      }
      return;
    }
  }

  static String _typeName(dynamic v) {
    if (v == null) return 'null';
    if (v is bool) return 'bool';
    if (v is int) return 'int';
    if (v is double) return 'num';
    if (v is String) return 'String';
    if (v is List) return 'List';
    return 'Map';
  }
}
