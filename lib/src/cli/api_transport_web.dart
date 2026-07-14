import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'api_transport.dart';

/// The browser transport: `fetch`.
///
/// There are no TLS options here, and that is not an omission. The browser owns
/// the TLS stack: a self-signed Hub certificate must be trusted at the OS or
/// browser level, because a page cannot wave one through. Nor can it be given a
/// `SecurityContext`.
///
/// The Hub must also allow this app's origin — see `hub start --cors-origin` —
/// or the browser blocks the response before this code ever sees it.
class FetchApiTransport implements ApiTransport {
  /// Creates a transport.
  const FetchApiTransport();

  @override
  Future<ApiResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final requestHeaders = web.Headers();
    // A closure, not a tear-off: dart2js disallows tearing off an external
    // extension-type interop member.
    headers.forEach((name, value) => requestHeaders.append(name, value));

    final response = await web.window
        .fetch(
          uri.toString().toJS,
          web.RequestInit(
            method: method,
            headers: requestHeaders,
            body: body?.toJS,
          ),
        )
        .toDart;

    final text = await response.text().toDart;
    return ApiResponse(response.status, text.toDart);
  }

  @override
  void close() {
    // `fetch` holds nothing to release.
  }
}

/// The transport `HubApiClient` uses when none is injected, in a browser.
ApiTransport defaultApiTransport() => const FetchApiTransport();
