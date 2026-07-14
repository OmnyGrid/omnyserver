@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Authentication on the Hub's HTTP API.
///
/// The Hub is controlled with the `--api-token`, or with a grant's
/// `(principal, token)` pair. There is no third way, and there is no way in
/// without one of them.
///
/// That invariant used to have a hole: `HttpApiServer.tokenAuthenticator()`
/// returned `null` when no `--api-token` was configured, and a service
/// registered with a null authenticator is not authenticated at all. A Hub
/// started with grants but no API token — a perfectly reasonable thing to do,
/// since grants are what `hub start --grant` exists for — served the whole API
/// to anyone who could reach the port: list the fleet, read the audit log, run
/// formulas, issue credentials. `--grant` looked like it secured the API and
/// did not: grants are only ever consulted from *inside* the authenticator that
/// was not there.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;

  Future<void> startApi({String? apiToken}) async {
    cluster = await TestCluster.start();
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: apiToken,
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
  }

  tearDown(() async {
    await api.close();
    await cluster.dispose();
  });

  Future<(int, String)> get(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    final req = await client.openUrl(
      'GET',
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    client.close();
    return (res.statusCode, body);
  }

  group('with no --api-token, grants are the only way in', () {
    setUp(() => startApi());

    // The regression. This was a 200 with the whole fleet in it.
    test('an anonymous caller is refused', () async {
      final (status, _) = await get('/api/v1/nodes');
      expect(
        status,
        401,
        reason:
            'a Hub with no --api-token must still authenticate: without this '
            'the entire API is open to anyone who can reach the port',
      );
    });

    test('a bare token with no principal is refused', () async {
      final (status, _) = await get(
        '/api/v1/nodes',
        headers: {'authorization': 'Bearer admin-token'},
      );
      // A grant is a *pair*. Without the principal there is nothing to look up.
      expect(status, 401);
    });

    test('a grant pair is admitted, and is who it says it is', () async {
      final (status, body) = await get(
        '/api/v1/whoami',
        headers: {
          'authorization': 'Bearer admin-token',
          'x-omny-principal': 'alice',
        },
      );

      expect(status, 200);
      final who = jsonDecode(body) as Map<String, dynamic>;
      expect(who['principal'], 'alice');
      expect(who['authenticated'], isTrue);
      expect(who['roles'], contains('admin'));
    });

    test('a wrong token for a real principal is refused', () async {
      final (status, _) = await get(
        '/api/v1/nodes',
        headers: {
          'authorization': 'Bearer not-the-token',
          'x-omny-principal': 'alice',
        },
      );
      expect(status, 401);
    });

    // The node's own grant is deliberately not an API credential: the Authorizer
    // is fail-closed and reserves the API for admins.
    test("a node's grant cannot drive the API", () async {
      final (status, _) = await get(
        '/api/v1/nodes',
        headers: {
          'authorization': 'Bearer node-token',
          'x-omny-principal': 'node-account',
        },
      );
      expect(status, 403);
    });
  });

  group('with an --api-token, both credentials work', () {
    setUp(() => startApi(apiToken: 'api-secret'));

    test('the master token is admitted', () async {
      final (status, _) = await get(
        '/api/v1/nodes',
        headers: {'authorization': 'Bearer api-secret'},
      );
      expect(status, 200);
    });

    test('a grant pair is still admitted alongside it', () async {
      final (status, body) = await get(
        '/api/v1/whoami',
        headers: {
          'authorization': 'Bearer admin-token',
          'x-omny-principal': 'alice',
        },
      );
      expect(status, 200);
      expect((jsonDecode(body) as Map)['principal'], 'alice');
    });

    test('an anonymous caller is refused', () async {
      final (status, _) = await get('/api/v1/nodes');
      expect(status, 401);
    });
  });

  // Liveness and scrape endpoints are outside the API service on purpose: a load
  // balancer and a Prometheus scraper carry no bearer token, and locking them
  // would make the Hub look dead to the things that check whether it is.
  group('the unauthenticated surface stays unauthenticated', () {
    setUp(() => startApi(apiToken: 'api-secret'));

    test('/healthz needs no token', () async {
      final (status, body) = await get('/healthz');
      expect(status, 200);
      expect(body, contains('ok'));
    });

    test('/metrics needs no token', () async {
      final (status, _) = await get('/metrics');
      expect(status, 200);
    });
  });
}
