@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Labels: how a fleet is addressed.
///
/// `NodeDescriptor` has carried a `labels` map from the start, and nothing could
/// ever set one — `node start` had no flag — so nothing could select on one
/// either. These pin the whole path: the agent advertises them at registration,
/// the Hub filters on them, and `--label env=prod` therefore means the same thing
/// to the CLI, the dashboard and a script.
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

  Future<List<String>> ids(String path) async {
    final (_, body) = await get(path);
    return [for (final n in (body as List).cast<Map>()) n['nodeId'] as String]
      ..sort();
  }

  test(
    "a node's labels reach the Hub and come back on its descriptor",
    () async {
      await cluster.startNode(
        id: 'web-01',
        labels: const {'env': 'prod', 'role': 'web'},
      );

      final (status, body) = await get('/api/v1/nodes/web-01');
      expect(status, 200);
      expect((body as Map)['labels'], {'env': 'prod', 'role': 'web'});
    },
  );

  test('the fleet can be narrowed by label, server-side', () async {
    await cluster.startNode(id: 'web-01', labels: const {'env': 'prod'});
    await cluster.startNode(id: 'web-02', labels: const {'env': 'prod'});
    await cluster.startNode(id: 'lab-01', labels: const {'env': 'staging'});

    // Filtering here rather than in the client is the difference between asking
    // which machines are production and downloading the fleet to find out.
    expect(await ids('/api/v1/nodes?label=env=prod'), ['web-01', 'web-02']);
    expect(await ids('/api/v1/nodes?label=env=staging'), ['lab-01']);
    expect(await ids('/api/v1/nodes'), ['lab-01', 'web-01', 'web-02']);
  });

  test('several labels all have to match', () async {
    await cluster.startNode(
      id: 'web-01',
      labels: const {'env': 'prod', 'role': 'web'},
    );
    await cluster.startNode(
      id: 'db-01',
      labels: const {'env': 'prod', 'role': 'db'},
    );

    expect(await ids('/api/v1/nodes?label=env=prod&label=role=db'), ['db-01']);
  });

  test('a label nothing carries selects nothing', () async {
    await cluster.startNode(id: 'web-01', labels: const {'env': 'prod'});
    // Not an error at this layer — the *CLI* refuses to act on an empty
    // selection, because "applied to 0 nodes" reads like success.
    expect(await ids('/api/v1/nodes?label=env=nowhere'), isEmpty);
  });

  test('online filters the fleet the other way', () async {
    await cluster.startNode(id: 'web-01', labels: const {'env': 'prod'});

    expect(await ids('/api/v1/nodes?online=true'), ['web-01']);
    expect(await ids('/api/v1/nodes?online=false'), isEmpty);
  });

  test('a malformed selector is a 400, not a fleet-wide match', () async {
    final (status, body) = await get('/api/v1/nodes?label=env');
    expect(status, 400);
    expect((body as Map)['error']['code'], 'bad_request');

    final (onlineStatus, _) = await get('/api/v1/nodes?online=maybe');
    expect(onlineStatus, 400);
  });
}
