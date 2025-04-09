import 'package:api_request/api_request.dart';

class UpdateProfileAction extends ApiRequestAction<UpdateProfileResponse> {
  @override
  bool get authRequired => true;

  @override
  RequestMethod get method => RequestMethod.POST;

  @override
  String get path => 'auth/profile/update';

  @override
  Map<String, dynamic> get toMap => {
    "name": "Ahmed",
    "email": "client@info.com",
    "phone": "503649187",
    "phone_code": "966",
  };

  @override
  ContentDataType? get contentDataType => ContentDataType.formData;

  @override
  ResponseBuilder<UpdateProfileResponse> get responseBuilder =>
      (json) => UpdateProfileResponse.fromJson(json);
}

class UpdateProfileResponse {
  String? message;

  UpdateProfileResponse({this.message});

  UpdateProfileResponse.fromJson(Map<String, dynamic> json) {
    message = json['message'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['message'] = message;
    return data;
  }
}
