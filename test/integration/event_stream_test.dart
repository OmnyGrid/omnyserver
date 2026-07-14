@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// `GET /api/v1/events/stream` — the fleet, pushed.
///
/// `/events` returns a bounded snapshot, so anything built on it is a few
/// seconds stale and keeps re-fetching a list it has mostly seen already. This is
/// the same events as they happen: one long-lived response per client, each event
/// flushed as it occurs.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late HttpClient client;

  setUp(() async {
    cluster = await TestCluster.start();
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
      // Production pings every 15s; a test should not wait that long for a
      // timer to retire.
      eventKeepAlive: const Duration(milliseconds: 200),
    );
    await api.start();
    client = HttpClient();
  });

  tearDown(() async {
    // The API hangs up its live streams first, so this does not wait on a
    // response that never ends.
    await api.close();
    client.close(force: true);
    await cluster.dispose();
  });

  /// Opens the stream and collects its lines as they arrive.
  ///
  /// The response never ends by design, so tearing the client down mid-stream
  /// raises "connection closed while receiving data". That is expected, and is
  /// swallowed here rather than left to fail the test as an unhandled async
  /// error — which is exactly what it did the first time.
  Future<(HttpClientResponse, List<String>)> open() async {
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${api.boundPort}/api/v1/events/stream'),
    );
    req.headers.set('authorization', 'Bearer api-secret');
    final res = await req.close();

    final lines = <String>[];
    // No cancel in teardown: cancelling a subscription on a still-streaming
    // response blocks until the socket dies. Closing the client kills it, and
    // the resulting "connection closed" is expected — hence onError.
    res
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add, onError: (_) {}, cancelOnError: true);
    return (res, lines);
  }

  test('a node connecting shows up on the stream, live', () async {
    final (res, lines) = await open();
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'text/event-stream');

    // Nothing has happened yet: the stream is open, and carries no events.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(lines.where((l) => l.startsWith('data:')), isEmpty);

    await cluster.startNode(id: 'worker-01');

    // It arrives while the response stays open — no polling, no reconnect.
    await _until(() => lines.any((l) => l.contains('node.connected')));

    // The `data:` line, not the `event:` line that precedes it.
    final data = lines.firstWhere(
      (l) => l.startsWith('data: ') && l.contains('node.connected'),
    );
    final event = jsonDecode(data.substring(6)) as Map<String, dynamic>;
    expect(event['type'], 'node.connected');
    expect(event['nodeId'], 'worker-01');
    expect(event['at'], isA<String>());

    // The SSE event *name* carries the type too, so a browser can
    // addEventListener('node.connected', …) instead of switching on a field.
    expect(lines, contains('event: node.connected'));
  });

  test('the stream keeps carrying events as they happen', () async {
    final (_, lines) = await open();

    await cluster.startNode(id: 'worker-02');
    await _until(() => lines.any((l) => l.contains('worker-02')));

    // A second node, on the same still-open response.
    await cluster.startNode(id: 'worker-03');
    await _until(() => lines.any((l) => l.contains('worker-03')));

    // Heartbeats flow too — proof this is the live bus, not a replayed snapshot.
    await _until(() => lines.any((l) => l.contains('heartbeat.received')));
  });

  test('the stream is behind the same auth as everything else', () async {
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${api.boundPort}/api/v1/events/stream'),
    );
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 401);
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  if (!condition()) throw StateError('condition not met before timeout');
}
