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

  Future<(int, dynamic)> get(
    String path, {
    String? token,
    String? principal,
  }) async {
    final client = HttpClient();
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (principal != null) req.headers.set('x-omny-principal', principal);
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

  group('GET /api/v1/whoami', () {
    test('reports the identity and roles the Hub resolved', () async {
      // The dashboard cannot answer either question for itself: it cannot tell a
      // valid token from an invalid one until the first real call fails, and it
      // cannot know which actions its roles permit.
      final (status, body) = await get(
        '/api/v1/whoami',
        principal: 'alice',
        token: 'admin-token',
      );

      expect(status, 200);
      expect((body as Map)['principal'], 'alice');
      expect(body['roles'], ['admin']);
      expect(body['authenticated'], isTrue);
    });

    test('the master API token has no identity of its own', () async {
      final (status, body) = await get('/api/v1/whoami', token: 'api-secret');

      expect(status, 200);
      expect((body as Map)['principal'], 'api');
      expect(body['roles'], ['admin']);
    });

    test('a bad token is rejected here too', () async {
      final (status, _) = await get('/api/v1/whoami', token: 'nope');
      expect(status, 401);
    });
  });

  // A grant is the credential a node already uses; these say what it means when
  // an *operator* presents one to the HTTP API. The Hub resolves the principal
  // from the grant rather than believing the header, so the identity in the
  // audit trail is one it verified.
  group('grant credentials', () {
    test("an operator's grant authenticates without the API token", () async {
      await cluster.startNode(id: 'worker-04');
      final (status, body) = await get(
        '/api/v1/nodes/worker-04',
        principal: 'alice',
        token: 'admin-token',
      );
      expect(status, 200);
      expect((body as Map)['nodeId'], 'worker-04');
    });

    test("a node's grant authenticates but may not drive the API", () async {
      // node-account holds `node`, and the authorizer's fail-closed default
      // reserves the API for `admin` — so a leaked node token stays useless.
      final (status, body) = await get(
        '/api/v1/nodes',
        principal: 'node-account',
        token: 'node-token',
      );
      expect(status, 403);
      expect((body as Map)['error']['code'], 'forbidden');
    });

    test('a token presented for the wrong principal is rejected', () async {
      final (status, body) = await get(
        '/api/v1/nodes',
        principal: 'mallory',
        token: 'admin-token',
      );
      expect(status, 401);
      expect((body as Map)['error']['code'], 'unauthorized');
    });

    test('an unknown token is rejected even with a known principal', () async {
      final (status, _) = await get(
        '/api/v1/nodes',
        principal: 'alice',
        token: 'not-a-token',
      );
      expect(status, 401);
    });

    test('the audit trail records the principal the Hub verified', () async {
      await cluster.startNode(id: 'worker-05');
      final client = HttpClient();
      final req = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:${api.boundPort}/api/v1/nodes/worker-05/restart',
        ),
      );
      req.headers.set('authorization', 'Bearer admin-token');
      req.headers.set('x-omny-principal', 'alice');
      expect((await req.close()).statusCode, 200);
      client.close();

      final (status, body) = await get(
        '/api/v1/audit',
        principal: 'alice',
        token: 'admin-token',
      );
      expect(status, 200);
      final restart = (body as List).cast<Map>().firstWhere(
        (e) => e['action'] == 'node.restart',
      );
      expect(restart['principal'], 'alice');
    });
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
