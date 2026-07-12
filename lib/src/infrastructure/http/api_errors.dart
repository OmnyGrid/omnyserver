import 'package:omnyhub/omnyhub.dart'
    show HubResponse, Middleware, RoutingException, mapErrors;

import '../../shared/errors/omnyserver_exception.dart';

/// Builds the structured JSON error responses used across the v1 API:
/// `{"error": {"code": "...", "message": "..."}}`.
class ApiErrors {
  const ApiErrors._();

  /// A JSON error [HubResponse] with [status], [code] and [message].
  static HubResponse error(int status, String code, String message) =>
      HubResponse.json({
        'error': {'code': code, 'message': message},
      }, statusCode: status);

  /// 400 Bad Request.
  static HubResponse badRequest(String message) =>
      error(400, 'bad_request', message);

  /// 401 Unauthorized.
  static HubResponse unauthorized(String message) =>
      error(401, 'unauthorized', message);

  /// 404 Not Found.
  static HubResponse notFound(String message) =>
      error(404, 'not_found', message);

  /// 502 Bad Gateway (node unreachable / operation failed).
  static HubResponse upstream(String message) =>
      error(502, 'operation_failed', message);
}

/// A successful JSON [HubResponse].
HubResponse jsonOk(Object? body, {int status = 200}) =>
    HubResponse.json(body, statusCode: status);

/// Translates OmnyServer's exceptions into the v1 API's error envelope.
///
/// The seam replacing the per-request `try`/`catch` the router used to wrap
/// every handler in: handlers now just throw, and this maps the failure once.
/// Anything unrecognised returns `null` to rethrow, letting omnyhub's built-in
/// error mapper turn it into a generic 500 rather than leaking a stack trace.
Middleware apiErrorMapper() => mapErrors((error, _) {
  return switch (error) {
    NotFoundException e => ApiErrors.notFound(e.message),
    // A node that is unknown, offline or slow is an upstream failure from the
    // API's point of view — the request itself was well-formed.
    NodeUnavailableException e => ApiErrors.upstream(e.message),
    OperationException e => ApiErrors.upstream(e.message),
    OmnyServerTimeoutException e => ApiErrors.upstream(e.message),
    FormatException e => ApiErrors.badRequest('invalid JSON: ${e.message}'),
    // No route matched at all. omnyhub would answer its own 404; re-render it in
    // the v1 envelope so every error on this API has one shape.
    RoutingException() => ApiErrors.notFound('unknown route'),
    _ => null,
  };
});
