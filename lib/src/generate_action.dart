import 'dart:convert';
import 'body_processor.dart';

String generateAction({
  required String name,
  required String method,
  required String path,
  required bool isAuth,
  dynamic body,
}) {
  BodyData processedBody = processBody(body);

  String getToMapText() {
    if (processedBody.formData != null) {
      String formDataString = jsonEncode(processedBody.formData);
      return '''
  @override
  Map<String, dynamic> get toMap => $formDataString;
      ''';
    } else if (processedBody.rawBody != null) {
      return '''
  @override
  Map<String, dynamic> get toMap => jsonDecode('${processedBody.rawBody?.replaceAll("'", "\\\\'")}');
      ''';
    }
    return '';
  }

  String getAuthRequiredText() {
    if (isAuth) {
      return '''
  @override
  bool get authRequired => true;
      ''';
    }
    return '';
  }

  String getDataTypeText() {
    if (processedBody.dataType != null) {
      if (processedBody.dataType == ContentDataType.formData && processedBody.files != null && processedBody.files!.isNotEmpty) {
        return '''
  @override
  ContentDataType? get contentDataType => ContentDataType.formData;
  // Note: This action includes file uploads which need to be handled separately
      ''';
      }
      return '''
  @override
  ContentDataType? get contentDataType => ContentDataType.${processedBody.dataType!.name};
      ''';
    }
    return '';
  }

  String getFilesText() {
    if (processedBody.files != null && processedBody.files!.isNotEmpty) {
      return '''
  // TODO: Implement file handling for the following fields:
  // ${processedBody.files!.map((f) => f.field).join(', ')}
      ''';
    }
    return '';
  }

  return '''
import 'package:api_request/api_request.dart';


class ${name}Action extends ApiRequestAction<${name}Response> {
  ${getAuthRequiredText()}

  @override
  RequestMethod get method => RequestMethod.$method;

  @override
  String get path => '$path';

  ${getToMapText()}

  ${getDataTypeText()}

  ${getFilesText()}

  @override
  ResponseBuilder<${name}Response> get responseBuilder =>
      (json) => ${name}Response.fromJson(json);
}
  ''';
}