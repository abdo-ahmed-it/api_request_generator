import 'package:http/http.dart' as http;

import '../logger/logger.dart';
import '../models/api_endpoint.dart';
import '../models/auth_definition.dart';
import '../models/body_definition.dart';

class HttpResult {
  final int statusCode;
  final String body;
  final Map<String, String> headers;
  // Full request details for logging
  final String requestUrl;
  final String requestMethod;
  final Map<String, String> requestHeaders;
  final Map<String, String> requestQueryParams;
  final dynamic requestBody;
  final DateTime sentTime;
  final DateTime receivedTime;

  const HttpResult({
    required this.statusCode,
    required this.body,
    this.headers = const {},
    required this.requestUrl,
    required this.requestMethod,
    this.requestHeaders = const {},
    this.requestQueryParams = const {},
    this.requestBody,
    required this.sentTime,
    required this.receivedTime,
  });

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

class ApiHttpClient {
  final Logger _logger;
  final http.Client _client;

  /// [client] is a test seam — pass a mock to assert on outgoing requests
  /// without hitting the network. Production callers omit it.
  ApiHttpClient({required Logger logger, http.Client? client})
      : _logger = logger,
        _client = client ?? http.Client();

  Future<HttpResult?> request({
    required String url,
    required HttpMethod method,
    Map<String, String>? headers,
    Map<String, String>? queryParams,
    BodyDefinition? body,
    AuthDefinition? auth,
  }) async {
    final finalHeaders = <String, String>{
      'Accept': 'application/json',
      ...?headers,
      ..._authHeaders(auth),
    };

    final uri = Uri.parse(url).replace(
      queryParameters:
          queryParams != null && queryParams.isNotEmpty ? queryParams : null,
    );


    // Prepare request body for logging
    dynamic requestBodyForLog;
    if (body != null) {
      if (body.hasFormFields) {
        requestBodyForLog = body.formFields;
      } else if (body.hasRawBody) {
        requestBodyForLog = body.rawBody;
      }
    }

    final sentTime = DateTime.now();

    try {
      final response = await _executeRequest(
        uri: uri,
        method: method,
        headers: finalHeaders,
        body: body,
      );

      final receivedTime = DateTime.now();

      if (response != null) {
        final result = HttpResult(
          statusCode: response.statusCode,
          body: response.body,
          headers: response.headers,
          requestUrl: uri.toString(),
          requestMethod: method.name,
          requestHeaders: finalHeaders,
          requestQueryParams: queryParams ?? {},
          requestBody: requestBodyForLog,
          sentTime: sentTime,
          receivedTime: receivedTime,
        );

        return result;
      }
      return null;
    } catch (e) {
      _logger.e('Failed to fetch ${method.name} $uri', error: e);
      return null;
    }
  }

  Map<String, String> _authHeaders(AuthDefinition? auth) {
    if (auth == null || !auth.requiresAuth || auth.token == null) return {};

    switch (auth.type) {
      case AuthType.bearer:
        return {'Authorization': 'Bearer ${auth.token}'};
      case AuthType.basic:
        return {'Authorization': 'Basic ${auth.token}'};
      case AuthType.apiKey:
        final headerName = auth.headerName ?? 'X-Api-Key';
        return {headerName: auth.token!};
      case AuthType.none:
        return {};
    }
  }

  Future<http.Response?> _executeRequest({
    required Uri uri,
    required HttpMethod method,
    required Map<String, String> headers,
    BodyDefinition? body,
  }) async {
    switch (method) {
      case HttpMethod.GET:
        return _client.get(uri, headers: headers);
      case HttpMethod.POST:
        return _requestWithBody('POST', uri, headers, body);
      case HttpMethod.PUT:
        return _requestWithBody('PUT', uri, headers, body);
      case HttpMethod.PATCH:
        return _requestWithBody('PATCH', uri, headers, body);
      case HttpMethod.DELETE:
        return _client.delete(uri, headers: headers);
    }
  }

  Future<http.Response?> _requestWithBody(
    String method,
    Uri uri,
    Map<String, String> headers,
    BodyDefinition? body,
  ) async {
    if (body == null || body.isEmpty) {
      return _sendSimple(method, uri, headers);
    }

    switch (body.contentType) {
      case BodyContentType.formData:
      case BodyContentType.urlEncoded:
        headers['Content-Type'] = 'application/x-www-form-urlencoded';
        return _sendSimple(method, uri, headers, bodyFields: body.formFields);

      case BodyContentType.rawJson:
        headers['Content-Type'] = 'application/json';
        return _sendSimple(method, uri, headers, bodyString: body.rawBody);

      case BodyContentType.multipart:
        final request = http.MultipartRequest(method, uri);
        request.headers.addAll(headers);
        if (body.formFields != null) {
          request.fields.addAll(body.formFields!);
        }
        // File handling would go here for real multipart uploads
        final streamedResponse = await _client.send(request);
        return http.Response.fromStream(streamedResponse);

      case null:
        return _sendSimple(method, uri, headers);
    }
  }

  Future<http.Response> _sendSimple(
    String method,
    Uri uri,
    Map<String, String> headers, {
    Map<String, String>? bodyFields,
    String? bodyString,
  }) async {
    switch (method) {
      case 'POST':
        return _client.post(uri,
            headers: headers, body: bodyString ?? bodyFields);
      case 'PUT':
        return _client.put(uri,
            headers: headers, body: bodyString ?? bodyFields);
      case 'PATCH':
        return _client.patch(uri,
            headers: headers, body: bodyString ?? bodyFields);
      default:
        return _client.post(uri,
            headers: headers, body: bodyString ?? bodyFields);
    }
  }
}
