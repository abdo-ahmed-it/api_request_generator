import 'dart:convert';
import 'dart:io';

import 'secret_redactor.dart';

class RequestLog {
  final String requestName;
  final String requestMethod;
  final String url;
  final int? statusCode;
  final Map<String, String> headers;
  final Map<String, String> queryParameters;
  final dynamic requestBody;
  final dynamic responseBody;
  final DateTime sentTime;
  final DateTime? receivedTime;

  RequestLog({
    required this.requestName,
    required this.requestMethod,
    required this.url,
    this.statusCode,
    this.headers = const {},
    this.queryParameters = const {},
    this.requestBody,
    this.responseBody,
    required this.sentTime,
    this.receivedTime,
  });

  /// Marker that opens the hidden metadata block embedded in every log file.
  /// The block holds the full request as JSON so `api2dart resend` can
  /// reconstruct and replay it without parsing the human-facing sections.
  static const String _metaOpen = '<!-- api2dart:request';
  static const String _metaClose = '-->';

  /// Prefix marking a base64-encoded metadata payload. Logs written before
  /// this encoding stored raw JSON and are still read (see [fromMarkdown]).
  static const String _metaBase64Marker = 'b64:';

  /// Renders the log as Markdown. [fileName] (without extension) is used in
  /// the Resend snippet so the printed `api2dart resend '<file>.md'` matches
  /// the file this log is actually written to.
  String toMarkdown({String? fileName}) {
    final resendName = fileName ?? requestName;
    final sb = StringBuffer();
    final duration = (receivedTime ?? sentTime).difference(sentTime);
    final statusLine = _formatStatus(statusCode);

    sb.writeln('# $requestName');
    sb.writeln();

    // TL;DR — quick summary line
    sb.writeln('> $statusLine `$requestMethod` ${SecretRedactor.text(url)} — '
        '${_formatDuration(duration)}');
    sb.writeln();

    sb.writeln('**Method:** `$requestMethod`  ');
    sb.writeln('**URL:** `${SecretRedactor.text(url)}`  ');
    sb.writeln('**Status:** $statusLine  ');
    sb.writeln('**Sent:** ${_formatTime(sentTime)}  ');
    sb.writeln('**Received:** ${_formatTime(receivedTime ?? sentTime)}  ');
    sb.writeln('**Duration:** `${_formatDuration(duration)}`');
    sb.writeln();

    sb.writeln('## Request');
    sb.writeln();

    sb.writeln('### Headers');
    sb.writeln();
    if (headers.isEmpty) {
      sb.writeln('_(none)_');
    } else {
      sb.writeln('```http');
      SecretRedactor.headers(headers).forEach((k, v) => sb.writeln('$k: $v'));
      sb.writeln('```');
    }
    sb.writeln();

    sb.writeln('### Query Parameters');
    sb.writeln();
    if (queryParameters.isEmpty) {
      sb.writeln('_(none)_');
    } else {
      sb.writeln('```json');
      sb.writeln(_prettyJson(queryParameters));
      sb.writeln('```');
    }
    sb.writeln();

    sb.writeln('### Body');
    sb.writeln();
    if (!_hasBody(requestBody)) {
      sb.writeln('_(none)_');
    } else {
      sb.writeln('```json');
      sb.writeln(_prettyJson(requestBody));
      sb.writeln('```');
    }
    sb.writeln();

    sb.writeln('## Response');
    sb.writeln();
    sb.writeln('```json');
    sb.writeln(_prettyJson(responseBody));
    sb.writeln('```');
    sb.writeln();

    sb.writeln('## cURL');
    sb.writeln();
    sb.writeln('```bash');
    sb.writeln(_buildCurl());
    sb.writeln('```');
    sb.writeln();

    sb.writeln('## Resend');
    sb.writeln();
    sb.writeln('Re-run this exact request and overwrite this file with the '
        'fresh response:');
    sb.writeln();
    sb.writeln('```bash');
    sb.writeln("api2dart resend '$resendName.md'");
    sb.writeln('```');
    sb.writeln();

    // Hidden machine-readable request block — the source of truth for
    // `resend`. Not rendered by Markdown viewers.
    sb.writeln(_metaBlock());

    return sb.toString();
  }

  /// Serializes the request (everything needed to replay it) as a hidden
  /// HTML comment. Response/timing are intentionally excluded — they're
  /// regenerated on resend.
  String _metaBlock() {
    final meta = <String, dynamic>{
      'requestName': requestName,
      'requestMethod': requestMethod,
      'url': url,
      'headers': headers,
      'queryParameters': queryParameters,
      'requestBody': requestBody,
    };
    // Base64 so the payload can never contain the `-->` terminator itself.
    // A body carrying an arrow (`{"note": "a --> b"}`) used to truncate the
    // block, leaving JSON that failed to decode — `fromMarkdown` then returned
    // null and `resend` refused the log outright.
    final encoded = base64.encode(utf8.encode(jsonEncode(meta)));
    return '$_metaOpen $_metaBase64Marker$encoded $_metaClose';
  }

  /// Reconstructs a [RequestLog] from the hidden metadata block in a previously
  /// written log file. Only the request portion is restored; status, response
  /// and timing are left empty and filled in when the request is resent.
  ///
  /// Returns `null` if no metadata block is found (e.g. an older log file).
  static RequestLog? fromMarkdown(String content) {
    // `lastIndexOf`: the real block is always written last, so a response body
    // that echoes the literal marker text no longer shadows it.
    final start = content.lastIndexOf(_metaOpen);
    if (start < 0) return null;
    final end = content.indexOf(_metaClose, start + _metaOpen.length);
    if (end < 0) return null;

    var json = content.substring(start + _metaOpen.length, end).trim();
    final Map<String, dynamic> meta;
    try {
      if (json.startsWith(_metaBase64Marker)) {
        json = utf8.decode(
          base64.decode(json.substring(_metaBase64Marker.length)),
        );
      }
      meta = jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    Map<String, String> stringMap(dynamic v) => v is Map
        ? v.map((k, val) => MapEntry(k.toString(), val.toString()))
        : <String, String>{};

    return RequestLog(
      requestName: meta['requestName']?.toString() ?? 'request',
      requestMethod: meta['requestMethod']?.toString() ?? 'GET',
      url: meta['url']?.toString() ?? '',
      headers: stringMap(meta['headers']),
      queryParameters: stringMap(meta['queryParameters']),
      requestBody: meta['requestBody'],
      sentTime: DateTime.now(),
    );
  }

  /// Writes the log as a `.md` file under [logsDir]. The directory is created
  /// if it doesn't exist; all logs are written flat (no subfolders).
  void writeToFile(String logsDir, String fileName) {
    final dir = Directory(logsDir);
    dir.createSync(recursive: true);
    final filePath = '${dir.path}/$fileName.md';
    File(filePath).writeAsStringSync(toMarkdown(fileName: fileName));
  }

  String _formatStatus(int? code) {
    if (code == null) return '⚪ `—`';
    final icon = code >= 200 && code < 300
        ? '✅'
        : code >= 300 && code < 400
            ? '↪️'
            : code >= 400 && code < 500
                ? '⚠️'
                : '❌';
    return '$icon `$code ${_statusText(code)}`';
  }

  String _statusText(int code) {
    const known = {
      200: 'OK',
      201: 'Created',
      202: 'Accepted',
      204: 'No Content',
      301: 'Moved Permanently',
      302: 'Found',
      304: 'Not Modified',
      400: 'Bad Request',
      401: 'Unauthorized',
      403: 'Forbidden',
      404: 'Not Found',
      405: 'Method Not Allowed',
      409: 'Conflict',
      422: 'Unprocessable Entity',
      429: 'Too Many Requests',
      500: 'Internal Server Error',
      502: 'Bad Gateway',
      503: 'Service Unavailable',
      504: 'Gateway Timeout',
    };
    return known[code] ?? '';
  }

  String _formatTime(DateTime t) {
    final local = t.isUtc ? t.toLocal() : t;
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    final date = '${local.year}-${two(local.month)}-${two(local.day)}';
    final time =
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}.${three(local.millisecond)}';
    return '`$date $time`';
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    final seconds = d.inMilliseconds / 1000;
    if (seconds < 60) return '${seconds.toStringAsFixed(2)}s';
    final minutes = d.inSeconds ~/ 60;
    final remSeconds = d.inSeconds % 60;
    return '${minutes}m ${remSeconds}s';
  }

  /// Builds a copy-pasteable cURL command. Auth headers are redacted, so the
  /// snippet documents the request shape but must have real credentials filled
  /// in before it will run.
  String _buildCurl() {
    final sb = StringBuffer();
    final fullUrl = SecretRedactor.text(_urlWithQuery());
    sb.write("curl -X $requestMethod '$fullUrl'");
    SecretRedactor.headers(headers).forEach((k, v) {
      sb.write(" \\\n  -H '$k: $v'");
    });
    if (_hasBody(requestBody)) {
      final bodyStr = requestBody is String
          ? SecretRedactor.jsonString(requestBody as String)
          : _prettyJson(requestBody);
      final escaped = bodyStr.replaceAll("'", r"'\''");
      sb.write(" \\\n  -d '$escaped'");
    }
    return sb.toString();
  }

  String _urlWithQuery() {
    if (queryParameters.isEmpty) return url;
    final query = queryParameters.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final separator = url.contains('?') ? '&' : '?';
    return '$url$separator$query';
  }

  bool _hasBody(dynamic data) {
    if (data == null) return false;
    if (data is String) return data.isNotEmpty;
    if (data is Map) return data.isNotEmpty;
    if (data is List) return data.isNotEmpty;
    return true;
  }

  /// Renders JSON for display. Everything here is human-facing, so secrets
  /// are scrubbed on the way out; the resend metadata block bypasses this.
  String _prettyJson(dynamic data) {
    if (data == null) return '{}';
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        return const JsonEncoder.withIndent('  ')
            .convert(SecretRedactor.json(decoded));
      } catch (_) {
        return SecretRedactor.text(data);
      }
    }
    try {
      return const JsonEncoder.withIndent('  ')
          .convert(SecretRedactor.json(data));
    } catch (_) {
      return SecretRedactor.text(data.toString());
    }
  }
}
