import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Reads a Server-Sent Events stream, yielding each event's `data` payload.
///
/// The browser ships `EventSource` for exactly this, and it is unusable here: it
/// cannot send an `Authorization` header. The only way to authenticate one is to
/// put the token in the URL, where it lands in proxy logs, server access logs and
/// browser history — a bearer token is not a query parameter.
///
/// `fetch` can carry the header, and its response body is a `ReadableStream`, so
/// the frames are decoded here instead: split on lines, collect `data:` lines
/// until the blank line that dispatches the event, ignore `:` comments (the
/// keep-alive pings) and the `event:`/`id:` fields the caller does not need.
///
/// The returned stream closes when the response ends; cancelling it aborts the
/// request, which is what tells the Hub the client has gone.
Stream<String> sseStream(Uri uri, {Map<String, String> headers = const {}}) {
  final abort = web.AbortController();
  late final StreamController<String> out;

  Future<void> pump() async {
    final requestHeaders = web.Headers();
    headers.forEach((name, value) => requestHeaders.append(name, value));

    final response = await web.window
        .fetch(
          uri.toString().toJS,
          web.RequestInit(
            method: 'GET',
            headers: requestHeaders,
            signal: abort.signal,
          ),
        )
        .toDart;

    if (response.status >= 400) {
      throw StateError('event stream failed: HTTP ${response.status}');
    }

    final reader =
        response.body!.getReader() as web.ReadableStreamDefaultReader;
    final decoder = const Utf8Decoder();
    var buffer = '';
    final data = <String>[];

    while (!out.isClosed) {
      final chunk = await reader.read().toDart;
      if (chunk.done) break;

      buffer += decoder.convert((chunk.value as JSUint8Array).toDart);

      // A frame is complete at a newline; anything after the last one is a
      // partial line and stays in the buffer for the next chunk.
      var newline = buffer.indexOf('\n');
      while (newline != -1) {
        final line = buffer.substring(0, newline).trimRight();
        buffer = buffer.substring(newline + 1);
        newline = buffer.indexOf('\n');

        if (line.isEmpty) {
          // The blank line dispatches the event.
          if (data.isNotEmpty && !out.isClosed) {
            out.add(data.join('\n'));
            data.clear();
          }
        } else if (line.startsWith('data:')) {
          data.add(line.substring(5).trimLeft());
        }
        // `:` comments (keep-alive pings), `event:` and `id:` are skipped: the
        // payload carries its own type, so the caller needs none of them.
      }
    }
  }

  out = StreamController<String>(
    onListen: () => pump().then(
      (_) => out.close(),
      onError: (Object e, StackTrace s) {
        if (!out.isClosed) {
          out.addError(e, s);
          out.close();
        }
      },
    ),
    // Cancelling the subscription aborts the request — which is how the Hub
    // learns this client is gone, rather than waiting for a ping to fail.
    onCancel: () => abort.abort(),
  );

  return out.stream;
}
