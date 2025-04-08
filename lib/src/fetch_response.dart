import 'package:http/http.dart' as http;
import 'body_processor.dart';

Future<String?> fetchResponse({
  required String url,
  required String method,
  String? token,
  required String locale,
  dynamic body,
}) async {
  var headers = {
    'Accept': 'application/json',
    'Accept-Language': locale,
  };
  if (token != null) {
    headers['Authorization'] = 'Bearer $token';
  }

  print('start fetch url $url method $method body $body');

  try {
    if (method == 'GET') {
      print('start Get Fetching $url');
      var response = await http.get(Uri.parse(url), headers: headers);
      print('response finish ${response.body}');
      return response.body;
    } else if (method == 'POST') {
      BodyData processedBody = processBody(body);

      if (processedBody.dataType == null) {
        print('start Post Fetching $url with body {}');
        var response = await http.post(Uri.parse(url), headers: headers);
        print('response finish ${response.body}');
        return response.body;
      }

      if (processedBody.dataType == ContentDataType.formData) {
        if (processedBody.files != null && processedBody.files!.isNotEmpty) {
          var request = http.MultipartRequest('POST', Uri.parse(url));
          request.headers.addAll(headers);
          request.fields.addAll(processedBody.formData ?? {});
          request.files.addAll(processedBody.files!);
          print('start Post Fetching $url with multipart formData ${processedBody.formData} and files ${processedBody.files!.length}');
          var response = await request.send();
          var responseBody = await response.stream.bytesToString();
          print('response finish $responseBody');
          return responseBody;
        } else {
          headers['Content-Type'] = 'application/x-www-form-urlencoded';
          print('start Post Fetching $url with body ${processedBody.formData}');
          var response = await http.post(
            Uri.parse(url),
            headers: headers,
            body: processedBody.formData,
          );
          print('response finish ${response.body}');
          return response.body;
        }
      } else if (processedBody.dataType == ContentDataType.bodyData) {
        headers['Content-Type'] = 'application/json';
        print('start Post Fetching $url with body ${processedBody.rawBody}');
        var response = await http.post(
          Uri.parse(url),
          headers: headers,
          body: processedBody.rawBody,
        );
        print('response finish ${response.body}');
        return response.body;
      }
    }
    return null;
  } catch (e) {
    print('Error fetching $url: $e');
    return null;
  }
}