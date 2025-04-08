import 'package:api_request/api_request.dart';
import 'dart:convert';

class ProfileDataAction extends ApiRequestAction<ProfileDataResponse> {
  @override
  bool get authRequired => true;

  @override
  RequestMethod get method => RequestMethod.GET;

  @override
  String get path => 'auth/profile';

  @override
  ResponseBuilder<ProfileDataResponse> get responseBuilder =>
      (json) => ProfileDataResponse.fromJson(json);
}

class ProfileDataResponse {
  String? message;

  ProfileDataResponse({this.message});

  ProfileDataResponse.fromJson(Map<String, dynamic> json) {
    message = json['message'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['message'] = message;
    return data;
  }
}
