import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../models/api_endpoint.dart';
import '../models/api_folder.dart';
import '../models/api_source_config.dart';
import '../models/auth_definition.dart';
import '../models/body_definition.dart';
import '../models/endpoint_tree.dart';
import '../models/response_definition.dart';
import 'api_source.dart';

class OpenApiSource implements ApiSource {
  @override
  String get sourceName => 'OpenAPI Specification';

  @override
  Future<EndpointTree> parse(ApiSourceConfig config) async {
    final filePath = config.filePath;
    if (filePath == null || filePath.isEmpty) {
      throw ArgumentError('filePath is required for OpenApiSource');
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('OpenAPI spec file not found', filePath);
    }

    final content = file.readAsStringSync();
    Map<String, dynamic> spec;

    // Try YAML first, then JSON
    try {
      final yamlDoc = loadYaml(content);
      spec = _convertToMap(yamlDoc);
    } catch (_) {
      try {
        spec = jsonDecode(content) as Map<String, dynamic>;
      } catch (e) {
        throw FormatException('Failed to parse OpenAPI spec: $e');
      }
    }

    final title = _extractTitle(spec);
    final components = spec['components'] as Map<String, dynamic>? ?? {};
    final schemas = components['schemas'] as Map<String, dynamic>? ?? {};
    final paths = spec['paths'] as Map<String, dynamic>? ?? {};

    // Group endpoints by tag (first tag becomes the folder)
    final folderMap = <String, List<ApiEndpoint>>{};
    final rootEndpoints = <ApiEndpoint>[];

    paths.forEach((pathStr, pathItem) {
      if (pathItem is! Map) return;

      for (final entry in pathItem.entries) {
        final methodStr = entry.key.toString().toUpperCase();
        if (!['GET', 'POST', 'PUT', 'PATCH', 'DELETE'].contains(methodStr)) {
          continue;
        }

        final operation = entry.value;
        if (operation is! Map) continue;

        final endpoint =
            _parseOperation(pathStr, methodStr, operation, schemas);
        if (endpoint == null) continue;

        // Group by: x-apidog-folder → tags → path segments
        final apidogFolder = operation['x-apidog-folder']?.toString();
        final rawTags = operation['tags'];
        final tags = rawTags is List ? rawTags : <dynamic>[];

        if (apidogFolder != null && apidogFolder.isNotEmpty) {
          // Use Apidog folder path directly (e.g. "E-state/Client/Auth")
          folderMap.putIfAbsent(apidogFolder, () => []).add(endpoint);
        } else if (tags.isNotEmpty && tags.first.toString().isNotEmpty) {
          final tag = tags.first.toString();
          folderMap.putIfAbsent(tag, () => []).add(endpoint);
        } else {
          // Use path segments as nested folder key
          final folderKey = _extractFolderKeyFromPath(pathStr);
          if (folderKey != null) {
            folderMap.putIfAbsent(folderKey, () => []).add(endpoint);
          } else {
            rootEndpoints.add(endpoint);
          }
        }
      }
    });

    // Build nested folder tree from flat "parent/child" keys
    final folders = _buildNestedFolders(folderMap);

    return EndpointTree(
      sourceName: title,
      folders: folders,
      rootEndpoints: rootEndpoints,
    );
  }

  String _extractTitle(Map<String, dynamic> spec) {
    final info = spec['info'] as Map<String, dynamic>? ?? {};
    return info['title']?.toString() ?? 'OpenAPI Spec';
  }

  ApiEndpoint? _parseOperation(
    String path,
    String methodStr,
    Map<dynamic, dynamic> operation,
    Map<String, dynamic> schemas,
  ) {
    final method = _parseHttpMethod(methodStr);
    final operationId = operation['operationId']?.toString();
    final summary = operation['summary']?.toString();
    final name = _buildEndpointName(
      path: path,
      method: methodStr,
      operationId: operationId,
      summary: summary,
    );

    // Parse request body
    final body = _parseRequestBody(operation['requestBody'], schemas);

    // Parse parameters (query, header)
    final headers = <String, String>{};
    final queryParams = <String, String>{};
    final rawParams = operation['parameters'];
    final parameters = rawParams is List ? rawParams : <dynamic>[];
    for (final param in parameters) {
      if (param is! Map) continue;
      final paramIn = param['in']?.toString();
      final paramName = param['name']?.toString();
      if (paramName == null) continue;

      final example = param['example']?.toString() ??
          param['schema']?['example']?.toString() ??
          '';

      if (paramIn == 'query') {
        queryParams[paramName] = example;
      } else if (paramIn == 'header') {
        headers[paramName] = example;
      }
    }

    // Parse security / auth
    final auth = _parseSecurity(operation);

    // Parse response schema
    final responseDef = _parseResponses(operation['responses'], schemas);

    return ApiEndpoint(
      name: name,
      path: path,
      method: method,
      description: summary,
      body: body,
      headers: headers,
      queryParams: queryParams,
      auth: auth,
      response: responseDef,
    );
  }

  BodyDefinition? _parseRequestBody(
      dynamic requestBody, Map<String, dynamic> schemas) {
    if (requestBody == null || requestBody is! Map) return null;

    final content = requestBody['content'] as Map<dynamic, dynamic>? ?? {};

    // application/json
    if (content.containsKey('application/json')) {
      final jsonContent = content['application/json'] as Map?;
      final schema = jsonContent?['schema'] as Map<String, dynamic>?;
      if (schema != null) {
        final resolved = _resolveRef(schema, schemas);
        final example = _schemaToExample(resolved);
        if (example != null) {
          return BodyDefinition(
            contentType: BodyContentType.rawJson,
            rawBody: jsonEncode(example),
          );
        }
      }
    }

    // application/x-www-form-urlencoded
    if (content.containsKey('application/x-www-form-urlencoded')) {
      final formContent = content['application/x-www-form-urlencoded'] as Map?;
      final schema = formContent?['schema'] as Map<String, dynamic>?;
      if (schema != null) {
        final resolved = _resolveRef(schema, schemas);
        final props = resolved['properties'] as Map<String, dynamic>? ?? {};
        final formFields = <String, String>{};
        props.forEach((key, value) {
          formFields[key] =
              (value is Map ? value['example'] : value)?.toString() ?? '';
        });
        return BodyDefinition(
          contentType: BodyContentType.urlEncoded,
          formFields: formFields,
        );
      }
    }

    // multipart/form-data
    if (content.containsKey('multipart/form-data')) {
      final multipartContent = content['multipart/form-data'] as Map?;
      final schema = multipartContent?['schema'] as Map<String, dynamic>?;
      if (schema != null) {
        final resolved = _resolveRef(schema, schemas);
        final props = resolved['properties'] as Map<String, dynamic>? ?? {};
        final formFields = <String, String>{};
        props.forEach((key, value) {
          if (value is Map && value['format'] != 'binary') {
            formFields[key] = value['example']?.toString() ?? '';
          }
        });
        return BodyDefinition(
          contentType: BodyContentType.multipart,
          formFields: formFields.isNotEmpty ? formFields : null,
        );
      }
    }

    return null;
  }

  AuthDefinition _parseSecurity(Map<dynamic, dynamic> operation) {
    final rawSecurity = operation['security'];
    final security = rawSecurity is List ? rawSecurity : null;
    if (security == null || security.isEmpty) return AuthDefinition.noAuth;

    final first = security.first;
    if (first is Map && first.isNotEmpty) {
      final schemeName = first.keys.first.toString().toLowerCase();
      if (schemeName.contains('bearer') || schemeName.contains('jwt')) {
        return const AuthDefinition(type: AuthType.bearer);
      }
      if (schemeName.contains('basic')) {
        return const AuthDefinition(type: AuthType.basic);
      }
      if (schemeName.contains('api') || schemeName.contains('key')) {
        return const AuthDefinition(type: AuthType.apiKey);
      }
      // Default to bearer for any auth scheme
      return const AuthDefinition(type: AuthType.bearer);
    }

    return AuthDefinition.noAuth;
  }

  ResponseDefinition? _parseResponses(
      dynamic responses, Map<String, dynamic> schemas) {
    if (responses == null || responses is! Map) return null;

    // Look for 200 or 201 response
    final successResponse =
        responses['200'] ?? responses['201'] ?? responses['2XX'];
    if (successResponse == null || successResponse is! Map) return null;

    final content = successResponse['content'] as Map<dynamic, dynamic>? ?? {};
    final jsonContent = content['application/json'] as Map?;
    if (jsonContent == null) return null;

    // Resolve schema if available
    final rawSchema = jsonContent['schema'];
    Map<String, dynamic>? resolvedSchema;
    if (rawSchema is Map<String, dynamic>) {
      resolvedSchema = _resolveRef(rawSchema, schemas);
    }

    // Check for example
    final example = jsonContent['example'];
    if (example != null) {
      final exampleJson = jsonEncode(example);

      // If example has empty arrays but we have a schema,
      // generate a synthetic example from the schema instead
      if (resolvedSchema != null && _hasEmptyArrays(example)) {
        final syntheticJson = _generateFromSchema(resolvedSchema, schemas);
        if (syntheticJson != null) {
          return ResponseDefinition(
            source: ResponseSource.schema,
            jsonBody: syntheticJson,
            schema: resolvedSchema,
          );
        }
      }

      return ResponseDefinition(
        source: ResponseSource.example,
        jsonBody: exampleJson,
        schema: resolvedSchema,
      );
    }

    // Schema only — generate synthetic example
    if (resolvedSchema != null) {
      final syntheticJson = _generateFromSchema(resolvedSchema, schemas);
      if (syntheticJson != null) {
        return ResponseDefinition(
          source: ResponseSource.schema,
          jsonBody: syntheticJson,
          schema: resolvedSchema,
        );
      }
      return ResponseDefinition(
        source: ResponseSource.schema,
        schema: resolvedSchema,
      );
    }

    return null;
  }

  /// Resolves `$ref`s one hop deep, then walks the remaining structure.
  ///
  /// A depth cap was tried here and reverted: a matched `$ref` returns the
  /// resolved schema verbatim without recursing into it, so a self-referential
  /// schema cannot loop through this method. The only recursion is structural
  /// descent through a finite map, which terminates on its own. Counting that
  /// descent instead truncated legitimate specs — two depth units per nesting
  /// level meant `$ref`s stopped resolving at eight levels of objects, and the
  /// field silently lost its shape in the generated model. Cycle protection,
  /// if ever needed, must track visited schema names across `$ref` hops.
  Map<String, dynamic> _resolveRef(
      Map<String, dynamic> schema, Map<String, dynamic> schemas) {
    final ref = schema[r'$ref']?.toString();
    if (ref != null && ref.startsWith('#/components/schemas/')) {
      final schemaName = ref.split('/').last;
      final resolved = schemas[schemaName];
      if (resolved is Map<String, dynamic>) {
        return resolved;
      }
    }
    // Recursively resolve nested refs
    final result = <String, dynamic>{};
    schema.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        result[key] = _resolveRef(value, schemas);
      } else {
        result[key] = value;
      }
    });
    return result;
  }

  dynamic _schemaToExample(Map<String, dynamic> schema) {
    final type = schema['type']?.toString();
    final example = schema['example'];
    if (example != null) return example;

    switch (type) {
      case 'object':
        final properties = schema['properties'] as Map<String, dynamic>? ?? {};
        final result = <String, dynamic>{};
        properties.forEach((key, value) {
          if (value is Map<String, dynamic>) {
            result[key] = _schemaToExample(value);
          }
        });
        return result.isNotEmpty ? result : null;
      case 'array':
        final items = schema['items'] as Map<String, dynamic>?;
        if (items != null) {
          final item = _schemaToExample(items);
          return item != null ? [item] : [];
        }
        return [];
      case 'string':
        return 'string';
      case 'integer':
        return 0;
      case 'number':
        return 0.0;
      case 'boolean':
        return false;
      default:
        return null;
    }
  }

  // Generic/vague names that should be replaced with path-based names
  static const _genericNames = {
    'index',
    'store',
    'update',
    'show',
    'delete',
    'destroy',
    'create',
    'edit',
    'list',
    'get',
    'post',
    'put',
    'patch',
  };

  /// Builds a meaningful endpoint name.
  /// If operationId/summary is generic (like "index", "store"),
  /// generates a name from the path instead.
  String _buildEndpointName({
    required String path,
    required String method,
    String? operationId,
    String? summary,
  }) {
    // Check if operationId is usable
    if (operationId != null &&
        operationId.isNotEmpty &&
        !_genericNames.contains(operationId.toLowerCase())) {
      return _toPascalCase(operationId);
    }

    // Check if summary is usable
    if (summary != null &&
        summary.isNotEmpty &&
        !_genericNames.contains(summary.toLowerCase())) {
      return _toPascalCase(summary);
    }

    // Build name from path
    return _nameFromPath(path, method);
  }

  /// Converts "/system_user_url/acceptances/get-data" + "GET" → "GetAcceptancesData"
  /// Adds method prefix for clarity and to avoid name collisions.
  String _nameFromPath(String path, String method) {
    final segments = path
        .split('/')
        .where((s) =>
            s.isNotEmpty &&
            s != 'url' &&
            s != 'api' &&
            !RegExp(r'^\d+$').hasMatch(s) &&
            !RegExp(r'^\{\{.*\}\}$').hasMatch(s) &&
            !RegExp(r'^\{.*\}$').hasMatch(s))
        .toList();

    if (segments.isEmpty) {
      return _toPascalCase(method);
    }

    // Take last 2-3 meaningful segments
    final nameParts =
        segments.length <= 3 ? segments : segments.sublist(segments.length - 3);

    // Add method prefix to avoid collisions (GET /users vs POST /users)
    final pathName = _toPascalCase(nameParts.join('-'));
    final methodPrefix = _toPascalCase(method.toLowerCase());

    return '$methodPrefix$pathName';
  }

  /// Converts any string to PascalCase.
  /// "get-data" → "GetData"
  /// "sale_support_user" → "SaleSupportUser"
  /// "already PascalCase" → "AlreadyPascalCase"
  String _toPascalCase(String text) {
    return text
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), ' ')
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .map((s) => s[0].toUpperCase() + s.substring(1))
        .join();
  }

  /// Extracts a folder key from path using first 2 meaningful segments.
  /// e.g. "/client/attention-requests/123" → "client/attention-requests"
  ///      "/system_user_url/login" → "system_user_url"
  ///      "/url/system/clients/1" → "system/clients"
  String? _extractFolderKeyFromPath(String path) {
    final segments = path
        .split('/')
        .where((s) =>
            s.isNotEmpty &&
            s != 'url' &&
            s != 'api' &&
            !RegExp(r'^\d+$').hasMatch(s) && // skip numeric IDs
            !RegExp(r'^\{\{.*\}\}$').hasMatch(s)) // skip {{vars}}
        .toList();
    if (segments.isEmpty) return null;
    if (segments.length == 1) return segments[0];
    return '${segments[0]}/${segments[1]}';
  }

  /// Builds nested ApiFolder tree from flat folder paths → endpoints map.
  /// Supports multi-level paths like "E-state/Client/Auth".
  List<ApiFolder> _buildNestedFolders(
      Map<String, List<ApiEndpoint>> folderMap) {
    final root = _FolderNode('');

    for (final entry in folderMap.entries) {
      // Split by "/" but handle escaped "\/"
      final parts = entry.key
          .replaceAll(r'\/', '\x00')
          .split('/')
          .map((s) => s.replaceAll('\x00', '/'))
          .where((s) => s.isNotEmpty)
          .toList();

      var current = root;
      for (final part in parts) {
        current = current.children.putIfAbsent(part, () => _FolderNode(part));
      }
      current.endpoints.addAll(entry.value);
    }

    return root.toApiFolders();
  }

  HttpMethod _parseHttpMethod(String method) {
    switch (method.toUpperCase()) {
      case 'GET':
        return HttpMethod.GET;
      case 'POST':
        return HttpMethod.POST;
      case 'PUT':
        return HttpMethod.PUT;
      case 'PATCH':
        return HttpMethod.PATCH;
      case 'DELETE':
        return HttpMethod.DELETE;
      default:
        return HttpMethod.GET;
    }
  }

  /// Checks if an example has empty arrays (which would generate List<Null>).
  bool _hasEmptyArrays(dynamic value) {
    if (value is List && value.isEmpty) return true;
    if (value is Map) {
      return value.values.any(_hasEmptyArrays);
    }
    return false;
  }

  /// Generates a synthetic JSON example from an OpenAPI schema,
  /// fully resolving $ref references.
  String? _generateFromSchema(
      Map<String, dynamic> schema, Map<String, dynamic> allSchemas) {
    final example = _schemaToFullExample(schema, allSchemas, 0);
    if (example != null) {
      return jsonEncode(example);
    }
    return null;
  }

  dynamic _schemaToFullExample(
      Map<String, dynamic> schema, Map<String, dynamic> allSchemas, int depth) {
    if (depth > 5) return null; // prevent infinite recursion

    // Resolve $ref
    final ref = schema[r'$ref']?.toString();
    if (ref != null && ref.startsWith('#/components/schemas/')) {
      final schemaName = ref.split('/').last;
      final resolved = allSchemas[schemaName];
      if (resolved is Map<String, dynamic>) {
        return _schemaToFullExample(resolved, allSchemas, depth + 1);
      }
      return null;
    }

    final type = schema['type']?.toString();
    final example = schema['example'];
    if (example != null && example is! String ||
        example is String && !example.contains('{{')) {
      // Use actual example if it's not a mock template
      if (example != null && example.toString().contains('{{')) {
        // Skip mock templates like {{$person.fullName}}
      } else if (example != null) {
        return example;
      }
    }

    switch (type) {
      case 'object':
        final properties = schema['properties'] as Map<String, dynamic>? ?? {};
        final result = <String, dynamic>{};
        properties.forEach((key, value) {
          if (value is Map<String, dynamic>) {
            result[key] = _schemaToFullExample(value, allSchemas, depth + 1);
          }
        });
        return result.isNotEmpty ? result : null;

      case 'array':
        final items = schema['items'];
        if (items is Map<String, dynamic>) {
          final item = _schemaToFullExample(items, allSchemas, depth + 1);
          return item != null ? [item] : [];
        }
        return [];

      case 'string':
        return 'string';
      case 'integer':
        return 0;
      case 'number':
        return 0;
      case 'boolean':
        return false;
      default:
        // Check if it has properties (implicit object)
        if (schema.containsKey('properties')) {
          final properties =
              schema['properties'] as Map<String, dynamic>? ?? {};
          final result = <String, dynamic>{};
          properties.forEach((key, value) {
            if (value is Map<String, dynamic>) {
              result[key] = _schemaToFullExample(value, allSchemas, depth + 1);
            }
          });
          return result.isNotEmpty ? result : null;
        }
        return null;
    }
  }

  // ── YAML conversion helpers ────────────────────────────────────────

  dynamic _convertValue(dynamic value) {
    if (value is YamlMap) {
      final map = <String, dynamic>{};
      for (final entry in value.entries) {
        map[entry.key.toString()] = _convertValue(entry.value);
      }
      return map;
    } else if (value is YamlList) {
      return value.map(_convertValue).toList();
    } else if (value is Map) {
      final map = <String, dynamic>{};
      value.forEach((k, v) {
        map[k.toString()] = _convertValue(v);
      });
      return map;
    }
    return value;
  }

  Map<String, dynamic> _convertToMap(dynamic value) {
    final result = _convertValue(value);
    if (result is Map<String, dynamic>) return result;
    return <String, dynamic>{};
  }
}

/// Helper for building nested folder trees.
class _FolderNode {
  final String name;
  final Map<String, _FolderNode> children = {};
  final List<ApiEndpoint> endpoints = [];

  _FolderNode(this.name);

  List<ApiFolder> toApiFolders() {
    return children.values.map((child) {
      return ApiFolder(
        name: child.name,
        subfolders: child.toApiFolders(),
        endpoints: child.endpoints,
      );
    }).toList();
  }
}
