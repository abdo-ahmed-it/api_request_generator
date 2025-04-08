import 'package:api_request/api_request.dart';
import 'dart:convert';

class ProviderScheduleDaysAction
    extends ApiRequestAction<ProviderScheduleDaysResponse> {
  @override
  bool get authRequired => true;

  @override
  RequestMethod get method => RequestMethod.POST;

  @override
  String get path => 'service/{{provider}}/schedules/days';

  @override
  Map<String, dynamic> get toMap => {};

  @override
  ContentDataType? get contentDataType => ContentDataType.formData;

  @override
  ResponseBuilder<ProviderScheduleDaysResponse> get responseBuilder =>
      (json) => ProviderScheduleDaysResponse.fromJson(json);
}

class ProviderScheduleDaysResponse {
  String? message;

  ProviderScheduleDaysResponse({this.message});

  ProviderScheduleDaysResponse.fromJson(Map<String, dynamic> json) {
    message = json['message'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['message'] = message;
    return data;
  }
}
