import 'package:api_request_generator/api_request_generator.dart';
import 'package:http/http.dart' as http;
import 'body_processor.dart';

Future<String?> fetchResponse({
  required String url,
  required String method,
  String? token,
  dynamic body,
}) async {
  final logger = Logger();
  var headers = {
    'Accept': 'application/json',
  };
  BodyData processedBody = processBody(body);

  if (token != null) {
    headers['Authorization'] = 'Bearer $token';
  }
  logger.n(
      '''Fetching Response: \nURL: $url\nMethod: $method\nHeaders: $headers \nData: ${processedBody.formData} \nFiles: ${processedBody.files} \nDataType: ${processedBody.dataType} \nToken: $token''');
  try {
    if (method == 'GET') {
      var response = await http.get(Uri.parse(url), headers: headers);
      if ([200, 201].contains(response.statusCode)) {
        logger.d(
            '''Response: \nURL: $url\nMethod: $method\nHeaders: $headers \nData: ${processedBody.formData} \nFiles: ${processedBody.files} \nDataType: ${processedBody.dataType} \nToken: $token \nResponse: ${response.body}''');
      } else {
        logger.e(
            '''Response: \nURL: $url\nMethod: $method\nHeaders: $headers \nData: ${processedBody.formData} \nFiles: ${processedBody.files} \nDataType: ${processedBody.dataType} \nToken: $token \nResponse: ${response.body}''');
      }

      return response.body;
    } else if (method == 'POST') {
      if (processedBody.dataType == null) {
        var response = await http.post(Uri.parse(url), headers: headers);
        if ([200, 201].contains(response.statusCode)) {
          logger.d(
              '''Response: \nURL: $url\nMethod: $method\nHeaders: $headers \nData: ${processedBody.formData} \nFiles: ${processedBody.files} \nDataType: ${processedBody.dataType} \nToken: $token \nResponse: ${response.body}''');
        } else {
          logger.e(
              '''Response: \nURL: $url\nMethod: $method\nHeaders: $headers \nData: ${processedBody.formData} \nFiles: ${processedBody.files} \nDataType: ${processedBody.dataType} \nToken: $token \nResponse: ${response.body}''');
        }
        return response.body;
      }

      if (processedBody.dataType == ContentDataType.formData) {
        if (processedBody.files != null && processedBody.files!.isNotEmpty) {
          var request = http.MultipartRequest('POST', Uri.parse(url));
          request.headers.addAll(headers);
          request.fields.addAll(processedBody.formData ?? {});
          request.files.addAll(processedBody.files!);
          var response = await request.send();
          var responseBody = await response.stream.bytesToString();
          return responseBody;
        } else {
          headers['Content-Type'] = 'application/x-www-form-urlencoded';
          var response = await http.post(
            Uri.parse(url),
            headers: headers,
            body: processedBody.formData,
          );
          if ([200, 201].contains(response.statusCode)) {
            logger.d(
                '''Response: \nURL: $url\nMethod: $method\nHeaders: $headers \nData: ${processedBody.formData} \nFiles: ${processedBody.files} \nDataType: ${processedBody.dataType} \nToken: $token \nResponse: ${response.body}''');
          } else {
            logger.e(
                '''Response: \nURL: $url\nMethod: $method\nHeaders: $headers \nData: ${processedBody.formData} \nFiles: ${processedBody.files} \nDataType: ${processedBody.dataType} \nToken: $token \nResponse: ${response.body}''');
          }
          return response.body;
        }
      } else if (processedBody.dataType == ContentDataType.bodyData) {
        headers['Content-Type'] = 'application/json';
        var response = await http.post(
          Uri.parse(url),
          headers: headers,
          body: processedBody.rawBody,
        );
        if ([200, 201].contains(response.statusCode)) {
          logger.d(
              '''Response: \nURL: $url\nMethod: $method\nHeaders: $headers \nData: ${processedBody.formData} \nFiles: ${processedBody.files} \nDataType: ${processedBody.dataType} \nToken: $token \nResponse: ${response.body}''');
        } else {
          logger.e(
              '''Response: \nURL: $url\nMethod: $method\nHeaders: $headers \nData: ${processedBody.formData} \nFiles: ${processedBody.files} \nDataType: ${processedBody.dataType} \nToken: $token \nResponse: ${response.body}''');
        }
        return response.body;
      }
    }
    logger.w('No response returned for $method $url');
    return null;
  } catch (e) {
    logger.e('Failed to fetch $method $url', error: e);
    return null;
  }
}
