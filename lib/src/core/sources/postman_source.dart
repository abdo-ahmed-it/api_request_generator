import 'dart:convert';
import 'dart:io';

import '../generation/body_processor.dart';
import '../models/api_endpoint.dart';
import '../models/api_folder.dart';
import '../models/api_source_config.dart';
import '../models/auth_definition.dart';
import '../models/body_definition.dart';
import '../models/endpoint_tree.dart';
import '../models/response_definition.dart';
import 'api_source.dart';

class PostmanSource implements ApiSource {
  @override
  String get sourceName => 'Postman Collection';

  @override
  Future<EndpointTree> parse(ApiSourceConfig config) async {
    final filePath = config.filePath;
    if (filePath == null || filePath.isEmpty) {
      throw ArgumentError('filePath is required for PostmanSource');
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Collection file not found', filePath);
    }

    final content = file.readAsStringSync();
    final collection = jsonDecode(content) as Map<String, dynamic>;

    final collectionName =
        collection['info']?['name']?.toString() ?? 'Postman Collection';
    final items = collection['item'] as List<dynamic>? ?? [];

    // Extract collection-level variables for token resolution
    final variables = _extractVariables(collection);

    final parseResult = _parseItems(items, variables);

    return EndpointTree(
      sourceName: collectionName,
      folders: parseResult.folders,
      rootEndpoints: parseResult.endpoints,
    );
  }

  Map<String, String> _extractVariables(Map<String, dynamic> collection) {
    final variables = <String, String>{};
    final varList = collection['variable'] as List<dynamic>? ?? [];
    for (final v in varList) {
      if (v is Map) {
        final key = v['key']?.toString();
        final value = v['value']?.toString();
        if (key != null && value != null) {
          variables[key] = value;
        }
      }
    }
    return variables;
  }

  /// Guards against a collection whose `item` arrays nest unreasonably deep
  /// (or reference each other), which would otherwise recurse without bound.
  static const int _maxDepth = 64;

  /// Total items in [items] and every `item` array below it, so the
  /// depth-limit message reports the real size of the dropped subtree.
  ///
  /// Walked iteratively with an explicit stack rather than recursively: this
  /// runs on exactly the structure that just tripped the depth cap, so a
  /// recursive walk would overflow while reporting the guard meant to prevent
  /// it. A recursive version bounded by [_maxDepth] was tried and undercounted
  /// — it restarted its own budget at the depth the parser had already
  /// stopped at, so a 200-deep chain reported 65 of 137 dropped items.
  static int _countItems(List<dynamic> items) {
    var total = 0;
    final stack = <List<dynamic>>[items];
    while (stack.isNotEmpty) {
      final level = stack.removeLast();
      for (final item in level) {
        if (item is! Map) continue;
        total++;
        final nested = item['item'];
        if (nested is List) stack.add(nested);
      }
    }
    return total;
  }

  _ParseResult _parseItems(List<dynamic> items, Map<String, String> variables,
      [int depth = 0]) {
    final folders = <ApiFolder>[];
    final endpoints = <ApiEndpoint>[];

    if (depth >= _maxDepth) {
      // Dropping a subtree in silence would be indistinguishable from an empty
      // folder, which is the silent-failure pattern this package treats as a
      // defect. The parser has no logger, so say it on stderr.
      // Count the whole subtree, not just this level: `items.length` reported
      // only the immediate siblings and understated the loss by however deep
      // the dropped branches ran.
      stderr.writeln(
        'api2dart: collection nesting exceeded $_maxDepth levels — '
        '${_countItems(items)} item(s) below this point were skipped.',
      );
      return _ParseResult(folders: folders, endpoints: endpoints);
    }

    for (final item in items) {
      if (item is! Map) continue;

      // An item may carry both keys. These are checked independently rather
      // than as if/else so a nested folder is no longer silently dropped just
      // because its parent also defines a request.
      if (item.containsKey('request')) {
        final endpoint = _parseEndpoint(item, variables);
        if (endpoint != null) {
          endpoints.add(endpoint);
        }
      }

      if (item.containsKey('item')) {
        final folderName = item['name']?.toString() ?? 'Unknown';
        final subItems = item['item'] as List<dynamic>? ?? [];
        final subResult = _parseItems(subItems, variables, depth + 1);
        folders.add(ApiFolder(
          name: folderName,
          subfolders: subResult.folders,
          endpoints: subResult.endpoints,
        ));
      }
    }

    return _ParseResult(folders: folders, endpoints: endpoints);
  }

  ApiEndpoint? _parseEndpoint(
      Map<dynamic, dynamic> item, Map<String, String> variables) {
    final name = item['name']?.toString() ?? 'Unknown';
    final request = item['request'];
    if (request is! Map) return null;

    // Method
    final methodStr = request['method']?.toString() ?? 'GET';
    final method = _parseHttpMethod(methodStr);

    // URL path
    final url = request['url'];
    String path;
    if (url is Map) {
      final pathParts = url['path'] as List<dynamic>? ?? [];
      path = '/${pathParts.join('/')}';
    } else if (url is String) {
      path = url;
    } else {
      path = '/';
    }

    // Auth
    final auth = _parseAuth(request['auth']);

    // Headers
    final headers = _parseHeaders(request['header']);

    // Query params
    final queryParams = _parseQueryParams(url);

    // Body
    final body = _parseBody(request['body']);

    // Response examples
    final responses = item['response'] as List<dynamic>? ?? [];
    ResponseDefinition? responseDef;
    if (responses.isNotEmpty) {
      final firstResponse = responses[0];
      if (firstResponse is Map && firstResponse['body'] != null) {
        responseDef = ResponseDefinition(
          source: ResponseSource.example,
          jsonBody: firstResponse['body'].toString(),
        );
      }
    }

    return ApiEndpoint(
      name: name,
      path: path,
      method: method,
      auth: auth,
      headers: headers,
      queryParams: queryParams,
      body: body,
      response: responseDef,
    );
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

  AuthDefinition _parseAuth(dynamic auth) {
    if (auth == null || auth is! Map) return AuthDefinition.noAuth;

    final type = auth['type']?.toString() ?? 'noauth';
    switch (type) {
      case 'bearer':
        // Try to extract token from bearer array
        String? token;
        final bearerList = auth['bearer'] as List<dynamic>? ?? [];
        for (final b in bearerList) {
          if (b is Map && b['key'] == 'token') {
            token = b['value']?.toString();
            break;
          }
        }
        return AuthDefinition(type: AuthType.bearer, token: token);
      case 'basic':
        return const AuthDefinition(type: AuthType.basic);
      case 'noauth':
        return AuthDefinition.noAuth;
      default:
        return AuthDefinition.noAuth;
    }
  }

  Map<String, String> _parseHeaders(dynamic headerList) {
    final headers = <String, String>{};
    if (headerList is! List) return headers;

    for (final h in headerList) {
      if (h is Map) {
        final key = h['key']?.toString();
        final value = h['value']?.toString();
        if (key != null && value != null) {
          headers[key] = value;
        }
      }
    }
    return headers;
  }

  Map<String, String> _parseQueryParams(dynamic url) {
    final params = <String, String>{};
    if (url is! Map) return params;

    final queryList = url['query'] as List<dynamic>? ?? [];
    for (final q in queryList) {
      if (q is Map) {
        // Skip disabled params
        if (q['disabled'] == true) continue;
        final key = q['key']?.toString();
        final value = q['value']?.toString();
        if (key != null && value != null) {
          params[key] = value;
        }
      }
    }
    return params;
  }

  BodyDefinition? _parseBody(dynamic body) {
    if (body == null || body is! Map) return null;

    final mode = body['mode']?.toString();
    if (mode == null) return null;

    switch (mode) {
      case 'formdata':
        final formdata = body['formdata'] as List<dynamic>? ?? [];
        if (formdata.isEmpty) return null;
        return processPostmanFormData(formdata);

      case 'urlencoded':
        final urlencoded = body['urlencoded'] as List<dynamic>? ?? [];
        final formFields = <String, String>{};
        for (final field in urlencoded) {
          if (field is Map) {
            final key = field['key']?.toString() ?? '';
            final value = field['value']?.toString() ?? '';
            formFields[key] = value;
          }
        }
        return BodyDefinition(
          contentType: BodyContentType.urlEncoded,
          formFields: formFields.isNotEmpty ? formFields : null,
        );

      case 'raw':
        final raw = body['raw']?.toString();
        return BodyDefinition(
          contentType: BodyContentType.rawJson,
          rawBody: raw,
        );

      default:
        return null;
    }
  }
}

class _ParseResult {
  final List<ApiFolder> folders;
  final List<ApiEndpoint> endpoints;

  _ParseResult({required this.folders, required this.endpoints});
}
