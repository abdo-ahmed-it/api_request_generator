import 'package:api_request/api_request.dart';
import 'dart:convert';

class ProvidereDetailsAction
    extends ApiRequestAction<ProvidereDetailsResponse> {
  @override
  RequestMethod get method => RequestMethod.GET;

  @override
  String get path => 'providers/{{provider}}/details';

  @override
  ResponseBuilder<ProvidereDetailsResponse> get responseBuilder =>
      (json) => ProvidereDetailsResponse.fromJson(json);
}

class ProvidereDetailsResponse {
  String? message;

  ProvidereDetailsResponse({this.message});

  ProvidereDetailsResponse.fromJson(Map<String, dynamic> json) {
    message = json['message'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['message'] = message;
    return data;
  }
}
