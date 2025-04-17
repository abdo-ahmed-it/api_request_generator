import 'package:http/http.dart' as http;

enum ContentDataType { formData, bodyData }

class BodyData {
  final ContentDataType? dataType;
  final Map<String, String>? formData;
  final String? rawBody;
  final List<http.MultipartFile>? files; // لدعم الملفات في formdata

  BodyData({this.dataType, this.formData, this.rawBody, this.files});
}

BodyData processBody(dynamic body) {
  if (body == null) {
    return BodyData(dataType: null, formData: null, rawBody: null, files: null);
  }
  if (body is Map && !body.containsKey('mode')) {
    Map<String, String> formData = {};
    body.forEach((key, value) {
      formData[key] = value.toString();
    });
    return BodyData(
      dataType: ContentDataType.formData,
      formData: formData,
      rawBody: null,
      files: null,
    );
  }

  switch (body['mode']) {
    case 'formdata':
      Map<String, String> formData = {};
      List<http.MultipartFile> files = [];
      for (var field in body['formdata']) {
        if (field['type'] == 'text') {
          formData[field['key']] = field['value'].toString();
        } else if (field['type'] == 'file' && field['src'] != null) {
          try {
            // files.add(await http.MultipartFile.fromPath(field['key'], field['src']));
          } catch (e) {
            print('Error loading file ${field['src']}: $e');
          }
        }
      }
      return BodyData(
        dataType: ContentDataType.formData,
        formData: formData,
        files: files.isNotEmpty ? files : null,
        rawBody: null,
      );

    case 'urlencoded':
      Map<String, String> formData = {};
      for (var field in body['urlencoded']) {
        formData[field['key']] = field['value'].toString();
      }
      return BodyData(
        dataType: ContentDataType.formData,
        formData: formData,
        rawBody: null,
        files: null,
      );

    case 'raw':
      String rawBody = body['raw'];
      return BodyData(
        dataType: ContentDataType.bodyData,
        rawBody: rawBody,
        formData: null,
        files: null,
      );

    default:
      print('Unsupported body mode: ${body['mode']}');
      return BodyData(dataType: null, formData: null, rawBody: null, files: null);
  }
}