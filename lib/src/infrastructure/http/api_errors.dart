import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Builds the structured JSON error responses used across the v1 API:
/// `{"error": {"code": "...", "message": "..."}}`.
class ApiErrors {
  const ApiErrors._();

  /// A JSON error [Response] with [status], [code] and [message].
  static Response error(int status, String code, String message) => Response(
    status,
    body: jsonEncode({
      'error': {'code': code, 'message': message},
    }),
    headers: const {'content-type': 'application/json'},
  );

  /// 400 Bad Request.
  static Response badRequest(String message) =>
      error(400, 'bad_request', message);

  /// 401 Unauthorized.
  static Response unauthorized(String message) =>
      error(401, 'unauthorized', message);

  /// 404 Not Found.
  static Response notFound(String message) => error(404, 'not_found', message);

  /// 502 Bad Gateway (node unreachable / operation failed).
  static Response upstream(String message) =>
      error(502, 'operation_failed', message);
}

/// A successful JSON [Response].
Response jsonOk(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: const {'content-type': 'application/json'},
);
