@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late EventAggregator events;
  late HubMetrics metrics;

  setUp(() async {
    cluster = await TestCluster.start();
    events = EventAggregator()..attach(cluster.hub.config.eventBus);
    metrics = HubMetrics(cluster.hub.registry)
      ..attach(cluster.hub.config.eventBus);
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      events: events,
      metrics: metrics,
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
  });

  tearDown(() async {
    await api.close();
    await events.detach();
    await metrics.detach();
    await cluster.dispose();
  });

  Future<(int, dynamic)> get(String path, {String? token}) async {
    final client = HttpClient();
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    client.close();
    final decoded = body.isEmpty
        ? null
        : (res.headers.contentType?.mimeType == 'application/json'
              ? jsonDecode(body)
              : body);
    return (res.statusCode, decoded);
  }

  test('GET /api/v1/nodes lists nodes (authorized)', () async {
    await cluster.startNode(id: 'worker-01');
    final (status, body) = await get('/api/v1/nodes', token: 'api-secret');
    expect(status, 200);
    expect((body as List).single['nodeId'], 'worker-01');
  });

  test('missing token is rejected with 401', () async {
    final (status, body) = await get('/api/v1/nodes');
    expect(status, 401);
    expect((body as Map)['error']['code'], 'unauthorized');
  });

  test('unknown node returns structured 404', () async {
    final (status, body) = await get(
      '/api/v1/nodes/ghost',
      token: 'api-secret',
    );
    expect(status, 404);
    expect((body as Map)['error']['code'], 'not_found');
  });

  test('GET /api/v1/nodes/{id}/status returns a snapshot', () async {
    await cluster.startNode(id: 'worker-02');
    await _eventually(() async {
      final (s, _) = await get(
        '/api/v1/nodes/worker-02/status',
        token: 'api-secret',
      );
      return s == 200;
    });
    final (status, body) = await get(
      '/api/v1/nodes/worker-02/status',
      token: 'api-secret',
    );
    expect(status, 200);
    expect((body as Map)['os']['osName'], isNotEmpty);
  });

  test('GET /metrics exposes Prometheus text', () async {
    await cluster.startNode(id: 'worker-03');
    final (status, body) = await get('/metrics');
    expect(status, 200);
    expect(body as String, contains('omnyserver_node_connections_total'));
  });

  test('GET /api/v1/openapi.json is served without auth', () async {
    final (status, body) = await get('/api/v1/openapi.json');
    expect(status, 200);
    expect((body as Map)['openapi'], startsWith('3.'));
    expect(body['paths'], contains('/nodes'));
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
