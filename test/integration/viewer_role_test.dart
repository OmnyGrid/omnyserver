@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// The `viewer` role: a credential that can watch the fleet and not touch it.
///
/// Before this, `api.access` was fail-closed on `admin`, so *every* dashboard
/// user was a full operator — there was no way to hand someone a link that could
/// not also shut a machine down. Authenticating and being allowed to act are now
/// separate questions, which is the only reason the role means anything.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;

  setUp(() async {
    cluster = await TestCluster.start(
      tokens: {
        'admin-token': TokenGrant(
          principal: PrincipalId('alice'),
          roles: const {'admin'},
        ),
        'operator-token': TokenGrant(
          principal: PrincipalId('olive'),
          roles: const {'operator'},
        ),
        'view-token': TokenGrant(
          principal: PrincipalId('victor'),
          roles: const {'viewer'},
        ),
        'node-token': TokenGrant(
          principal: PrincipalId('node-account'),
          roles: const {'node'},
        ),
      },
    );
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

  Future<int> send(
    String method,
    String path, {
    required String principal,
    required String token,
  }) async {
    final client = HttpClient();
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    req.headers
      ..set('authorization', 'Bearer $token')
      ..set('x-omny-principal', principal);
    final res = await req.close();
    await res.transform(utf8.decoder).join();
    client.close();
    return res.statusCode;
  }

  group('viewer', () {
    test('can read the fleet', () async {
      await cluster.startNode(id: 'worker-01');
      expect(
        await send(
          'GET',
          '/api/v1/nodes',
          principal: 'victor',
          token: 'view-token',
        ),
        200,
      );
      expect(
        await send(
          'GET',
          '/api/v1/audit',
          principal: 'victor',
          token: 'view-token',
        ),
        200,
      );
    });

    test('cannot restart, shut down or update a node', () async {
      await cluster.startNode(id: 'worker-01');
      for (final action in ['restart', 'shutdown', 'update']) {
        expect(
          await send(
            'POST',
            '/api/v1/nodes/worker-01/$action',
            principal: 'victor',
            token: 'view-token',
          ),
          403,
          reason: 'a viewer must not be able to $action a machine',
        );
      }
    });

    test('cannot run a formula or apply a preset', () async {
      await cluster.startNode(id: 'worker-01');
      expect(
        await send(
          'POST',
          '/api/v1/nodes/worker-01/formula',
          principal: 'victor',
          token: 'view-token',
        ),
        403,
      );
      expect(
        await send(
          'POST',
          '/api/v1/presets/apply',
          principal: 'victor',
          token: 'view-token',
        ),
        403,
      );
    });
  });

  group('operator', () {
    test('can both read and act', () async {
      await cluster.startNode(id: 'worker-01');
      expect(
        await send(
          'GET',
          '/api/v1/nodes',
          principal: 'olive',
          token: 'operator-token',
        ),
        200,
      );
      expect(
        await send(
          'POST',
          '/api/v1/nodes/worker-01/restart',
          principal: 'olive',
          token: 'operator-token',
        ),
        200,
      );
    });
  });

  group('the roles that already existed', () {
    test('admin is still allowed everything', () async {
      await cluster.startNode(id: 'worker-01');
      expect(
        await send(
          'POST',
          '/api/v1/nodes/worker-01/restart',
          principal: 'alice',
          token: 'admin-token',
        ),
        200,
      );
    });

    test('the master API token is still an operator', () async {
      await cluster.startNode(id: 'worker-01');
      final client = HttpClient();
      final req = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:${api.boundPort}/api/v1/nodes/worker-01/restart',
        ),
      );
      req.headers.set('authorization', 'Bearer api-secret');
      final res = await req.close();
      await res.drain<void>();
      client.close();
      expect(res.statusCode, 200);
    });

    test('a node credential still cannot reach the API at all', () async {
      // It never could: `node` does not hold `api.access`, so it is refused at
      // the door rather than at the action.
      expect(
        await send(
          'GET',
          '/api/v1/nodes',
          principal: 'node-account',
          token: 'node-token',
        ),
        403,
      );
    });
  });
}
