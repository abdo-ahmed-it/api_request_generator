import 'package:api_request/api_request.dart';
import 'dart:convert';

class VerifyOTPAction extends ApiRequestAction<VerifyOTPResponse> {
  @override
  RequestMethod get method => RequestMethod.POST;

  @override
  String get path => 'auth/verify-otp';

  @override
  Map<String, dynamic> get toMap => {
    "phone_code": "966",
    "phone": "123456789",
    "verify_code": "1234",
  };

  @override
  ContentDataType? get contentDataType => ContentDataType.formData;

  @override
  ResponseBuilder<VerifyOTPResponse> get responseBuilder =>
      (json) => VerifyOTPResponse.fromJson(json);
}

class VerifyOTPResponse {
  String? token;
  Client? client;
  String? message;

  VerifyOTPResponse({this.token, this.client, this.message});

  VerifyOTPResponse.fromJson(Map<String, dynamic> json) {
    token = json['token'];
    client = json['client'] != null ? Client.fromJson(json['client']) : null;
    message = json['message'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['token'] = token;
    if (client != null) {
      data['client'] = client!.toJson();
    }
    data['message'] = message;
    return data;
  }
}

class Client {
  int? id;
  String? name;
  String? phoneCode;
  String? phone;
  Null? email;
  String? createdAt;
  String? updatedAt;

  Client({
    this.id,
    this.name,
    this.phoneCode,
    this.phone,
    this.email,
    this.createdAt,
    this.updatedAt,
  });

  Client.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    name = json['name'];
    phoneCode = json['phoneCode'];
    phone = json['phone'];
    email = json['email'];
    createdAt = json['createdAt'];
    updatedAt = json['updatedAt'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['id'] = id;
    data['name'] = name;
    data['phoneCode'] = phoneCode;
    data['phone'] = phone;
    data['email'] = email;
    data['createdAt'] = createdAt;
    data['updatedAt'] = updatedAt;
    return data;
  }
}
