import 'package:api_request/api_request.dart';

class ReserveAppointmentAction
    extends ApiRequestAction<ReserveAppointmentResponse> {
  @override
  bool get authRequired => true;

  @override
  RequestMethod get method => RequestMethod.POST;

  @override
  String get path => 'service/make/reservation';

  @override
  Map<String, dynamic> get toMap => {
    "date": "2025-03-31",
    "time": "18:00",
    "service[0]": "1",
    "service[1]": "2",
  };

  @override
  ContentDataType? get contentDataType => ContentDataType.formData;

  @override
  ResponseBuilder<ReserveAppointmentResponse> get responseBuilder =>
      (json) => ReserveAppointmentResponse.fromJson(json);
}

class ReserveAppointmentResponse {
  String? message;

  ReserveAppointmentResponse({this.message});

  ReserveAppointmentResponse.fromJson(Map<String, dynamic> json) {
    message = json['message'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['message'] = message;
    return data;
  }
}
