import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A thin REST client for the Hub HTTP API, used by the CLI's operational
/// commands so the CLI exercises exactly the same public API surface as any
/// other client.
class HubApiClient {
  /// The API base URL (e.g. `https://hub.example.com:8443`).
  ///
  /// The API shares the Hub's TLS listener, so this is normally `https://` on
  /// the same port nodes connect to.
  final Uri baseUrl;

  /// Optional bearer token.
  final String? token;

  final HttpClient _client;

  /// Creates a client for [baseUrl].
  ///
  /// [securityContext] supplies the trust roots — pass one trusting the Hub's CA
  /// when it serves a private or self-signed certificate.
  /// [allowBadCertificate] skips verification entirely; it is for a dev Hub
  /// only, and never for one reachable off the host.
  HubApiClient(
    this.baseUrl, {
    this.token,
    SecurityContext? securityContext,
    bool allowBadCertificate = false,
  }) : _client = HttpClient(context: securityContext) {
    if (allowBadCertificate) {
      _client.badCertificateCallback = (_, _, _) => true;
    }
  }

  /// GET `/api/v1[path]`, decoding the JSON body.
  Future<dynamic> get(String path) => _send('GET', path);

  /// POST `/api/v1[path]` with an optional JSON [body].
  Future<dynamic> post(String path, [Object? body]) =>
      _send('POST', path, body);

  /// GET a raw text endpoint (e.g. `/metrics`) outside the versioned API.
  Future<String> getText(String absolutePath) async {
    final req = await _client.getUrl(baseUrl.replace(path: absolutePath));
    final res = await req.close();
    return res.transform(utf8.decoder).join();
  }

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final uri = baseUrl.replace(path: '/api/v1$path');
    final req = await _client.openUrl(method, uri);
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final decoded = text.isEmpty ? null : jsonDecode(text);
    if (res.statusCode >= 400) {
      final message = decoded is Map && decoded['error'] is Map
          ? decoded['error']['message']
          : 'HTTP ${res.statusCode}';
      throw HubApiException('$message', res.statusCode);
    }
    return decoded;
  }

  /// Releases the underlying client.
  void close() => _client.close(force: true);
}

/// Thrown when a Hub API request fails.
class HubApiException implements Exception {
  /// The error message.
  final String message;

  /// The HTTP status code.
  final int statusCode;

  /// Creates the exception.
  HubApiException(this.message, this.statusCode);

  @override
  String toString() => 'HubApiException($statusCode): $message';
}
