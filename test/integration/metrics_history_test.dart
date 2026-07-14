@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// The node history the Hub has been recording all along.
///
/// Every heartbeat already persisted a full `NodeStatus` to the
/// `MetricRepository` — and nothing ever read one back. These pin the endpoint
/// that finally does, and the projection that makes it affordable: a stored
/// sample carries the whole process table, and a chart wants seven numbers.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;

  setUp(() async {
    cluster = await TestCluster.start();
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
  });

  tearDown(() async {
    await api.close();
    await cluster.dispose();
  });

  Future<(int, dynamic)> get(String path) async {
    final client = HttpClient();
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    req.headers.set('authorization', 'Bearer api-secret');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    client.close();
    return (res.statusCode, body.isEmpty ? null : jsonDecode(body));
  }

  test('a heartbeating node accumulates a chartable series', () async {
    await cluster.startNode(id: 'worker-01');

    // The harness heartbeats every 200ms; wait for a few samples to land.
    await _eventually(() async {
      final (_, body) = await get('/api/v1/nodes/worker-01/metrics');
      return (body as List).length >= 2;
    });

    final (status, body) = await get('/api/v1/nodes/worker-01/metrics');
    expect(status, 200);

    final points = (body as List).cast<Map>();
    final first = points.first;
    expect(first['at'], isA<String>());
    expect(first['cpuPercent'], isA<num>());
    expect(first['memoryTotalBytes'], isA<num>());
    expect(first['storageCapacityBytes'], isA<num>());
    // The projection, not the raw sample: no process table, no OS block.
    expect(first.containsKey('processes'), isFalse);
    expect(first.containsKey('os'), isFalse);

    // Newest first, so a caller asking for `limit` gets the most recent.
    final times = [for (final p in points) DateTime.parse(p['at'] as String)];
    for (var i = 1; i < times.length; i++) {
      expect(times[i].isAfter(times[i - 1]), isFalse);
    }
  });

  test('limit bounds the series', () async {
    await cluster.startNode(id: 'worker-02');
    await _eventually(() async {
      final (_, body) = await get('/api/v1/nodes/worker-02/metrics');
      return (body as List).length >= 3;
    });

    final (status, body) = await get('/api/v1/nodes/worker-02/metrics?limit=2');
    expect(status, 200);
    expect((body as List), hasLength(2));
  });

  test(
    'since takes a duration shorthand, because "1h" is what you mean',
    () async {
      await cluster.startNode(id: 'worker-03');
      await _eventually(() async {
        final (_, body) = await get('/api/v1/nodes/worker-03/metrics');
        return (body as List).isNotEmpty;
      });

      // Everything recorded is seconds old, so an hour window holds it all…
      final (status, recent) = await get(
        '/api/v1/nodes/worker-03/metrics?since=1h',
      );
      expect(status, 200);
      expect(recent as List, isNotEmpty);

      // …and a one-second window (in the future of every sample) holds none.
      final future = DateTime.now().toUtc().add(const Duration(minutes: 5));
      final (_, none) = await get(
        '/api/v1/nodes/worker-03/metrics'
        '?since=${Uri.encodeQueryComponent(future.toIso8601String())}',
      );
      expect(none as List, isEmpty);
    },
  );

  test('an unknown node is a 404, not an empty series', () async {
    final (status, body) = await get('/api/v1/nodes/ghost/metrics');
    expect(status, 404);
    expect((body as Map)['error']['code'], 'not_found');
  });

  test('a malformed since is a 400, not a silent full scan', () async {
    await cluster.startNode(id: 'worker-04');
    final (status, body) = await get(
      '/api/v1/nodes/worker-04/metrics?since=yesterday',
    );
    expect(status, 400);
    expect((body as Map)['error']['code'], 'bad_request');
  });
}

Future<void> _eventually(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('condition not met within $timeout');
}
