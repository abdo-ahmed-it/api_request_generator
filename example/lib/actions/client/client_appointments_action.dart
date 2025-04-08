import 'package:api_request/api_request.dart';
import 'dart:convert';

class ClientAppointmentsAction
    extends ApiRequestAction<ClientAppointmentsResponse> {
  @override
  bool get authRequired => true;

  @override
  RequestMethod get method => RequestMethod.GET;

  @override
  String get path => 'client/reservations/list';

  @override
  ResponseBuilder<ClientAppointmentsResponse> get responseBuilder =>
      (json) => ClientAppointmentsResponse.fromJson(json);
}

class ClientAppointmentsResponse {
  String? message;

  ClientAppointmentsResponse({this.message});

  ClientAppointmentsResponse.fromJson(Map<String, dynamic> json) {
    message = json['message'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['message'] = message;
    return data;
  }
}
