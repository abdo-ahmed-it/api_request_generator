import 'dart:convert';

import '../models/api_endpoint.dart';
import '../models/auth_definition.dart';
import '../models/request_log.dart';
import '../models/response_definition.dart';
import 'http_client.dart';

class ResolveResult {
  final ResponseDefinition response;
  final RequestLog? log;

  ResolveResult({required this.response, this.log});
}

class ResponseResolver {
  final ApiHttpClient _httpClient;

  ResponseResolver({
    required ApiHttpClient httpClient,
  }) : _httpClient = httpClient;

  /// Resolves the response for an endpoint using the fallback chain:
  /// 1. Example with good data → use directly
  /// 2. Live fetch → send real request to server
  /// 3. Schema → generate synthetic JSON
  /// 4. Example with empty arrays → use anyway (better than nothing)
  /// 5. None → return empty (generator will use dynamic)
  Future<ResolveResult> resolve(
    ApiEndpoint endpoint, {
    required String baseUrl,
    String? token,
  }) async {
    final response = endpoint.response;

    // 1. Always try live fetch first if we have a base URL
    if (baseUrl.isNotEmpty) {
      final fetchResult = await _tryLiveFetch(endpoint, baseUrl, token);
      if (fetchResult != null && fetchResult.response.hasJson) {
        return fetchResult;
      }
      if (fetchResult != null && fetchResult.log != null) {
        final fallback = _tryFallbacks(endpoint, response);
        return ResolveResult(response: fallback, log: fetchResult.log);
      }
    }

    // 2. Fallbacks: example → schema → empty
    final fallback = _tryFallbacks(endpoint, response);
    return ResolveResult(response: fallback);
  }

  ResponseDefinition _tryFallbacks(
      ApiEndpoint endpoint, ResponseDefinition? response) {
    if (response != null && response.hasJson) {
      return response;
    }

    if (response != null && response.hasSchema) {
      final syntheticJson = _schemaToJson(response.schema!);
      if (syntheticJson != null) {
        return ResponseDefinition(
          source: ResponseSource.schema,
          jsonBody: syntheticJson,
          schema: response.schema,
        );
      }
    }

    return ResponseDefinition.empty;
  }

  Future<ResolveResult?> _tryLiveFetch(
    ApiEndpoint endpoint,
    String baseUrl,
    String? token,
  ) async {
    final url = '$baseUrl${endpoint.path}';

    final authDef = token != null && token.isNotEmpty
        ? AuthDefinition(
            type: endpoint.auth.type != AuthType.none
                ? endpoint.auth.type
                : AuthType.bearer,
            token: token,
          )
        : endpoint.auth;

    try {
      final result = await _httpClient.request(
        url: url,
        method: endpoint.method,
        headers: endpoint.headers.isNotEmpty ? endpoint.headers : null,
        queryParams:
            endpoint.queryParams.isNotEmpty ? endpoint.queryParams : null,
        body: endpoint.body,
        auth: authDef,
      );

      if (result == null) return null;

      // Build log for every request (success or failure)
      final log = RequestLog(
        requestName: endpoint.name,
        requestMethod: result.requestMethod,
        url: result.requestUrl,
        statusCode: result.statusCode,
        headers: result.requestHeaders,
        queryParameters: result.requestQueryParams,
        requestBody: result.requestBody,
        responseBody: result.body,
        sentTime: result.sentTime,
        receivedTime: result.receivedTime,
      );

      if (result.isSuccess && result.body.isNotEmpty) {
        try {
          jsonDecode(result.body);
          return ResolveResult(
            response: ResponseDefinition(
              source: ResponseSource.fetched,
              jsonBody: result.body,
            ),
            log: log,
          );
        } catch (_) {
          return ResolveResult(response: ResponseDefinition.empty, log: log);
        }
      } else {
        // Return null response but still have the log
        return ResolveResult(response: ResponseDefinition.empty, log: log);
      }
    } catch (_) {
      // A failure here is not fatal: the caller falls back to the example or
      // schema branch, and ApiHttpClient has already logged the underlying
      // network error. Returning null keeps that fallback chain intact.
    }

    return null;
  }

  String? _schemaToJson(Map<String, dynamic> schema) {
    try {
      final example = _schemaToValue(schema);
      if (example != null) {
        return jsonEncode(example);
      }
    } catch (_) {
      // A schema shape we can't synthesise (an unresolved $ref, a cycle) just
      // means no synthetic example; the caller degrades to an empty response.
    }
    return null;
  }

  dynamic _schemaToValue(Map<String, dynamic> schema) {
    final type = schema['type']?.toString();

    switch (type) {
      case 'object':
        final properties = schema['properties'] as Map<String, dynamic>? ?? {};
        final result = <String, dynamic>{};
        properties.forEach((key, value) {
          if (value is Map<String, dynamic>) {
            result[key] = _schemaToValue(value);
          }
        });
        return result;

      case 'array':
        final items = schema['items'] as Map<String, dynamic>?;
        if (items != null) {
          return [_schemaToValue(items)];
        }
        return [];

      case 'string':
        return schema['example']?.toString() ?? 'string';
      case 'integer':
        return schema['example'] ?? 0;
      case 'number':
        return schema['example'] ?? 0.0;
      case 'boolean':
        return schema['example'] ?? false;
      default:
        // Check for properties (implicit object)
        if (schema.containsKey('properties')) {
          final properties =
              schema['properties'] as Map<String, dynamic>? ?? {};
          final result = <String, dynamic>{};
          properties.forEach((key, value) {
            if (value is Map<String, dynamic>) {
              result[key] = _schemaToValue(value);
            }
          });
          return result.isNotEmpty ? result : null;
        }
        return null;
    }
  }
}
