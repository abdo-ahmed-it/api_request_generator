import 'dart:convert';

import 'package:api_request_generator/api_request_generator.dart';
import 'package:http/http.dart' as http;
import 'body_processor.dart';

Future<String?> fetchResponse({
  required String url,
  required String method,
  String? token,
  dynamic body,
  String authType='noauth',
}) async {
  final logger = Logger();
  final headers = _prepareHeaders(token,authType);
  final processedBody = processBody(body);

  logger.n(
    'Fetching Response:\n'
        'URL: $url\n'
        'Method: $method\n'
        'Headers: $headers\n'
        'Data: ${processedBody.formData}\n'
        'Files: ${processedBody.files}\n'
        'DataType: ${processedBody.dataType}\n'
        'Token: $token',
  );

  try {
    final responseBody = await _executeRequest(
      url: url,
      method: method,
      headers: headers,
      processedBody: processedBody,
      logger: logger,
    );

    if (responseBody != null) {
      return responseBody;
    } else {
      logger.w('No response returned for $method $url');
      return null;
    }
  } catch (e) {
    logger.e('Failed to fetch $method $url', error: e);
    return null;
  }
}

Map<String, String> _prepareHeaders(String? token, String authType) {
  var headers = {'Accept': 'application/json'};
  if (token != null) {
    switch (authType) {
      case 'bearer':
        headers['Authorization'] = 'Bearer $token';
        break;
      case 'basic':
        headers['Authorization'] = 'Basic $token';
        break;
      default:
        headers['Authorization'] = token;
    }
  }
  return headers;
}

// دالة لتنفيذ الطلب بناءً على الـ method
Future<String?> _executeRequest({
  required String url,
  required String method,
  required Map<String, String> headers,
  required BodyData processedBody,
  required Logger logger,
}) async {
  if (method == 'GET') {
    return _handleGetRequest(url, headers, logger);
  } else if (method == 'POST') {
    return _handlePostRequest(url, headers, processedBody, logger);
  }
  return null; // يمكن إضافة دعم لطرق أخرى لاحقًا
}

// دالة لمعالجة طلبات GET
Future<String?> _handleGetRequest(
    String url,
    Map<String, String> headers,
    Logger logger,
    ) async {
  final response = await http.get(Uri.parse(url), headers: headers);
  _logResponse(response, url, 'GET', headers, logger);
  return response.body;
}

// دالة لمعالجة طلبات POST
Future<String?> _handlePostRequest(
    String url,
    Map<String, String> headers,
    BodyData processedBody,
    Logger logger,
    ) async {
  if (processedBody.dataType == null) {
    final response = await http.post(Uri.parse(url), headers: headers);
    _logResponse(response, url, 'POST', headers, logger);
    return response.body;
  }

  if (processedBody.dataType == ContentDataType.formData) {
    if (processedBody.files != null && processedBody.files!.isNotEmpty) {
      final request = http.MultipartRequest('POST', Uri.parse(url));
      request.headers.addAll(headers);
      request.fields.addAll(processedBody.formData ?? {});
      request.files.addAll(processedBody.files!);
      final response = await request.send();
      return await response.stream.bytesToString();
    } else {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      final response = await http.post(
        Uri.parse(url),
        headers: headers,
        body: processedBody.formData,
      );
      _logResponse(response, url, 'POST', headers, logger);
      return response.body;
    }
  } else if (processedBody.dataType == ContentDataType.bodyData) {
    headers['Content-Type'] = 'application/json';
    final response = await http.post(
      Uri.parse(url),
      headers: headers,
      body: processedBody.rawBody,
    );
    _logResponse(response, url, 'POST', headers, logger);
    return response.body;
  }
  return null;
}

// دالة لتنسيق الـ JSON وتحويل Unicode إلى حروف
String _prettyJson(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    return JsonEncoder.withIndent('  ').convert(decoded);
  } catch (e) {
    return rawJson; // لو فشل التحويل، نرجع النص الخام
  }
}

void _logResponse(
    http.Response response,
    String url,
    String method,
    Map<String, String> headers,
    Logger logger,
    ) {
  final prettyResponse = _prettyJson(response.body);
  final logMessage = 'Response:\n'
      'URL: $url\n'
      'Method: $method\n'
      'Headers: $headers\n'
      'Response: $prettyResponse';

  if ([200, 201].contains(response.statusCode)) {
    logger.d(logMessage);
  } else {
    logger.e(logMessage);
  }
}