import 'dart:async';
import 'dart:convert';

import 'api_transport.dart';
// The VM sends with `HttpClient`, the browser with `fetch`. Selected at compile
// time so this library — and everything that imports it — stays free of
// `dart:io` in a web build, which dart2js requires absolutely: it emits *no
// output at all* for an entrypoint that reaches an unsupported SDK library.
import 'api_transport_io.dart'
    if (dart.library.js_interop) 'api_transport_web.dart';

/// A thin REST client for the Hub HTTP API, used by the CLI's operational
/// commands — and by the web dashboard — so both exercise exactly the same
/// public API surface as any other client.
class HubApiClient {
  /// The API base URL (e.g. `https://hub.example.com:8443`).
  ///
  /// The API shares the Hub's TLS listener, so this is normally `https://` on
  /// the same port nodes connect to.
  final Uri baseUrl;

  /// Optional bearer token.
  final String? token;

  /// Optional principal the [token] was granted to.
  ///
  /// Sent as `x-omny-principal`. With a Hub grant (`--grant alice:tok:admin`)
  /// this is half the credential — the Hub verifies the pair and takes the
  /// caller's roles from the grant. With the Hub's static API token it only
  /// attributes the request in the audit trail.
  final String? principal;

  final ApiTransport _transport;

  /// Creates a client for [baseUrl].
  ///
  /// [transport] defaults to the platform's own: `HttpClient` on the VM, `fetch`
  /// in a browser. Inject one to reach a Hub over TLS with a private CA
  /// (`IoApiTransport(securityContext: …)`, VM only), or to drive the client
  /// against a fake Hub in tests.
  HubApiClient(
    this.baseUrl, {
    this.token,
    this.principal,
    ApiTransport? transport,
  }) : _transport = transport ?? defaultApiTransport();

  /// GET `/api/v1[path]`, decoding the JSON body.
  Future<dynamic> get(String path) => _send('GET', path);

  /// POST `/api/v1[path]` with an optional JSON [body].
  Future<dynamic> post(String path, [Object? body]) =>
      _send('POST', path, body);

  /// PUT `/api/v1[path]` with an optional JSON [body].
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body);

  /// DELETE `/api/v1[path]`.
  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// GET a raw text endpoint (e.g. `/metrics`) outside the versioned API.
  Future<String> getText(String absolutePath) async {
    final response = await _transport.send(
      'GET',
      baseUrl.replace(path: absolutePath),
      headers: _headers(),
    );
    return response.body;
  }

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    // `Uri.replace(path: …)` percent-encodes a `?`, which would bury the query
    // string inside the path and turn `/nodes/x/metrics?since=1h` into a route
    // that matches nothing. Split it off and hand it over as a query.
    final split = path.indexOf('?');
    final uri = split == -1
        ? baseUrl.replace(path: '/api/v1$path')
        : baseUrl.replace(
            path: '/api/v1${path.substring(0, split)}',
            query: path.substring(split + 1),
          );
    final response = await _transport.send(
      method,
      uri,
      headers: {
        ..._headers(),
        if (body != null) 'content-type': 'application/json; charset=utf-8',
      },
      body: body == null ? null : jsonEncode(body),
    );

    final text = response.body;
    final decoded = text.isEmpty ? null : jsonDecode(text);
    if (response.statusCode >= 400) {
      final message = decoded is Map && decoded['error'] is Map
          ? decoded['error']['message']
          : 'HTTP ${response.statusCode}';
      throw HubApiException('$message', response.statusCode);
    }
    return decoded;
  }

  Map<String, String> _headers() => {
    if (token != null) 'authorization': 'Bearer $token',
    'x-omny-principal': ?principal,
  };

  /// Releases the underlying transport.
  void close() => _transport.close();
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
