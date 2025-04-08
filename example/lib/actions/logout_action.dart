import 'package:api_request/api_request.dart';
import 'dart:convert';

class LogoutAction extends ApiRequestAction<LogoutResponse> {
  @override
  bool get authRequired => true;

  @override
  RequestMethod get method => RequestMethod.POST;

  @override
  String get path => 'auth/logout';

  @override
  ResponseBuilder<LogoutResponse> get responseBuilder =>
      (json) => LogoutResponse.fromJson(json);
}

class LogoutResponse {
  String? message;

  LogoutResponse({this.message});

  LogoutResponse.fromJson(Map<String, dynamic> json) {
    message = json['message'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['message'] = message;
    return data;
  }
}
