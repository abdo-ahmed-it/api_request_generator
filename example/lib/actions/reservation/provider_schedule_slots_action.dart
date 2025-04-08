import 'package:api_request/api_request.dart';
import 'dart:convert';

class ProviderScheduleSlotsAction
    extends ApiRequestAction<ProviderScheduleSlotsResponse> {
  @override
  bool get authRequired => true;

  @override
  RequestMethod get method => RequestMethod.POST;

  @override
  String get path => 'service/{{provider}}/schedules/slot';

  @override
  Map<String, dynamic> get toMap => {
    "date": "2025-04-03",
    "services[0]": "{\"id\": 1, \"count\": 1}",
  };

  @override
  ContentDataType? get contentDataType => ContentDataType.formData;

  @override
  ResponseBuilder<ProviderScheduleSlotsResponse> get responseBuilder =>
      (json) => ProviderScheduleSlotsResponse.fromJson(json);
}

class ProviderScheduleSlotsResponse {
  String? message;

  ProviderScheduleSlotsResponse({this.message});

  ProviderScheduleSlotsResponse.fromJson(Map<String, dynamic> json) {
    message = json['message'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['message'] = message;
    return data;
  }
}
