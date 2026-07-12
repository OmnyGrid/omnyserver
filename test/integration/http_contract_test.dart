@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Pins the v1 REST wire contract at the seams the omnyhub migration rerouted:
/// routing, method handling, the bearer gate and the error envelope. These are
/// the behaviours a hand-rolled matcher used to own and omnyhub's
/// `RouterService` now owns, so they are exactly where a regression would hide.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;

  setUp(() async {
    cluster = await TestCluster.start();
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      metrics: HubMetrics(cluster.hub.registry),
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
  });

  tearDown(() async {
    await api.close();
    await cluster.dispose();
  });

  Future<(int, dynamic)> call(
    String method,
    String path, {
    String? token,
    String? body,
  }) async {
    final client = HttpClient();
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (body != null) req.write(body);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    client.close();
    final decoded = text.isEmpty
        ? null
        : (res.headers.contentType?.mimeType == 'application/json'
              ? jsonDecode(text)
              : text);
    return (res.statusCode, decoded);
  }

  group('routing', () {
    test('an unknown /api/v1 route is a structured 404', () async {
      final (status, body) = await call(
        'GET',
        '/api/v1/nope',
        token: 'api-secret',
      );
      expect(status, 404);
      expect((body as Map)['error']['code'], 'not_found');
      expect(body['error']['message'], 'unknown route');
    });

    test('an unknown root route is a structured 404', () async {
      final (status, body) = await call('GET', '/nope');
      expect(status, 404);
      expect((body as Map)['error']['code'], 'not_found');
    });

    test('a wrong method on a known path stays a 404, not a 405', () async {
      // omnyhub's RouterService answers 405 when a path matches but the method
      // does not. The v1 contract has never had a 405, so the catch-all route
      // absorbs it — clients switching on the status must not start seeing one.
      final (status, body) = await call(
        'DELETE',
        '/api/v1/nodes',
        token: 'api-secret',
      );
      expect(status, 404);
      expect((body as Map)['error']['code'], 'not_found');
    });
  });

  group('bearer gate', () {
    test('a non-Bearer scheme is rejected', () async {
      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${api.boundPort}/api/v1/nodes'),
      );
      req.headers.set('authorization', 'Basic dXNlcjpwYXNz');
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join());
      client.close();

      expect(res.statusCode, 401);
      expect((body as Map)['error']['code'], 'unauthorized');
      expect(body['error']['message'], 'missing bearer token');
    });

    test('a wrong token is rejected', () async {
      final (status, body) = await call(
        'GET',
        '/api/v1/nodes',
        token: 'not-the-token',
      );
      expect(status, 401);
      expect((body as Map)['error']['message'], 'invalid token');
    });

    test('the gate does not cover /healthz or /metrics', () async {
      expect((await call('GET', '/healthz')).$1, 200);
      expect((await call('GET', '/metrics')).$1, 200);
    });

    test('an unknown route is still gated behind the token', () async {
      // Auth is resolved before dispatch, so a bad token on a nonexistent path
      // reports 401, not 404 — it must not become a route oracle.
      final (status, _) = await call('GET', '/api/v1/nope');
      expect(status, 401);
    });
  });

  group('error envelope', () {
    test('a malformed JSON body is a 400 bad_request', () async {
      final (status, body) = await call(
        'POST',
        '/api/v1/presets/apply',
        token: 'api-secret',
        body: '{not json',
      );
      expect(status, 400);
      expect((body as Map)['error']['code'], 'bad_request');
      expect(body['error']['message'], startsWith('invalid JSON:'));
    });

    test('a non-object JSON body is a 400 bad_request', () async {
      final (status, body) = await call(
        'POST',
        '/api/v1/presets/apply',
        token: 'api-secret',
        body: '[1, 2, 3]',
      );
      expect(status, 400);
      expect((body as Map)['error']['code'], 'bad_request');
    });

    test('a missing required field is a 400 bad_request', () async {
      final (status, body) = await call(
        'POST',
        '/api/v1/presets/apply',
        token: 'api-secret',
        body: '{}',
      );
      expect(status, 400);
      expect((body as Map)['error']['message'], contains('required'));
    });

    test('an offline node surfaces as a 502 operation_failed', () async {
      await cluster.startNode(id: 'worker-01');
      await cluster.stopNodes();

      final (status, body) = await call(
        'POST',
        '/api/v1/nodes/worker-01/restart',
        token: 'api-secret',
      );
      expect(status, 502);
      expect((body as Map)['error']['code'], 'operation_failed');
    });

    test('a malformed node id is a 404, not a 500', () async {
      final (status, body) = await call(
        'GET',
        '/api/v1/nodes/not%20a%20valid%20id',
        token: 'api-secret',
      );
      expect(status, 404);
      expect((body as Map)['error']['code'], 'not_found');
    });
  });

  group('path parameters', () {
    test(
      'the node id is captured from the path on every nested route',
      () async {
        await cluster.startNode(id: 'worker-01');

        for (final path in [
          '/api/v1/nodes/worker-01',
          '/api/v1/nodes/worker-01/capabilities',
        ]) {
          final (status, _) = await call('GET', path, token: 'api-secret');
          expect(status, 200, reason: path);
        }

        // An id that does not exist resolves the param fine and 404s on lookup.
        final (status, body) = await call(
          'GET',
          '/api/v1/nodes/ghost/capabilities',
          token: 'api-secret',
        );
        expect(status, 404);
        expect((body as Map)['error']['message'], contains('ghost'));
      },
    );
  });
}
