/// One HTTP round-trip, abstracted away from `dart:io`.
///
/// This is the seam that lets `HubApiClient` run in a browser as well as on the
/// VM. The client owns the API's *semantics* — the `/api/v1` prefix, the bearer
/// and principal headers, the error envelope — and knows nothing about how the
/// bytes reach the Hub: the VM sends them with `HttpClient`, the browser with
/// `fetch`, and a test with a fake.
abstract interface class ApiTransport {
  /// Sends [method] [uri] with [headers] and an optional [body].
  Future<ApiResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers,
    String? body,
  });

  /// Releases any underlying resources.
  void close();
}

/// A raw HTTP response: the status and the undecoded body.
class ApiResponse {
  /// The HTTP status code.
  final int statusCode;

  /// The response body as text (empty when there is none).
  final String body;

  /// Creates a response.
  const ApiResponse(this.statusCode, this.body);
}
