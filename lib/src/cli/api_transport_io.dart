import 'dart:convert';
import 'dart:io';

import 'api_transport.dart';

/// The VM transport: `dart:io`'s `HttpClient`.
///
/// This is also where the TLS knobs live, and deliberately so. A browser owns
/// its own TLS stack — it has no `SecurityContext` to configure and no way to
/// wave through a bad certificate — so keeping them here, rather than on
/// `HubApiClient`, is what keeps the client itself browser-compatible.
class IoApiTransport implements ApiTransport {
  final HttpClient _client;

  /// Creates a transport.
  ///
  /// [securityContext] supplies the trust roots — pass one trusting the Hub's CA
  /// when it serves a private or self-signed certificate. [allowBadCertificate]
  /// skips verification entirely; it is for a dev Hub only, and never for one
  /// reachable off the host.
  IoApiTransport({
    SecurityContext? securityContext,
    bool allowBadCertificate = false,
  }) : _client = HttpClient(context: securityContext) {
    if (allowBadCertificate) {
      _client.badCertificateCallback = (_, _, _) => true;
    }
  }

  @override
  Future<ApiResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final request = await _client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (body != null) request.write(body);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return ApiResponse(response.statusCode, text);
  }

  @override
  void close() => _client.close(force: true);
}

/// The transport `HubApiClient` uses when none is injected, on the VM.
ApiTransport defaultApiTransport() => IoApiTransport();
