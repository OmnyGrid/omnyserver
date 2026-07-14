@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Credentials the Hub hands out, and takes back.
///
/// Before this, grants were `hub start` flags: adding an operator or revoking a
/// leaked token meant restarting the Hub and dropping every node. That was
/// tolerable when the only client was a CLI holding a token in a shell variable.
/// It is not, now that a browser stores one.
///
/// The security property these pin: **the Hub keeps a hash, not a token.** Its
/// storage is therefore not a list of passwords, and a stolen grant file — or a
/// backup of one — authenticates nobody.
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

  Future<(int, dynamic)> send(
    String method,
    String path, {
    Object? body,
    String token = 'api-secret',
    String? principal,
  }) async {
    final client = HttpClient();
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    req.headers.set('authorization', 'Bearer $token');
    if (principal != null) req.headers.set('x-omny-principal', principal);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    client.close();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  test('an issued credential works immediately, with no restart', () async {
    final (status, issued) = await send(
      'POST',
      '/api/v1/grants',
      body: {
        'principal': 'bob',
        'roles': ['viewer'],
        'note': 'dashboard',
      },
    );
    expect(status, 200);

    final token = (issued as Map)['token'] as String;
    expect(token, isNotEmpty);

    // The Hub was not restarted, and the node channel was never dropped.
    final (whoami, me) = await send(
      'GET',
      '/api/v1/whoami',
      token: token,
      principal: 'bob',
    );
    expect(whoami, 200);
    expect((me as Map)['principal'], 'bob');
    expect(me['roles'], ['viewer']);
  });

  test('the token is shown once and cannot be read back', () async {
    final (_, issued) = await send(
      'POST',
      '/api/v1/grants',
      body: {
        'principal': 'bob',
        'roles': ['viewer'],
      },
    );
    final id = (issued as Map)['id'] as String;
    final token = issued['token'] as String;

    final (status, listed) = await send('GET', '/api/v1/grants');
    expect(status, 200);

    final grant = (listed as List).cast<Map>().firstWhere((g) => g['id'] == id);

    // The list is safe to show precisely because there is nothing in it to
    // steal: a hash, and no token anywhere.
    expect(grant.containsKey('token'), isFalse);
    expect(grant['tokenHash'], isNot(contains(token)));
    expect(jsonEncode(listed), isNot(contains(token)));
  });

  test('revoking one stops the very next request', () async {
    final (_, issued) = await send(
      'POST',
      '/api/v1/grants',
      body: {
        'principal': 'bob',
        'roles': ['viewer'],
      },
    );
    final id = (issued as Map)['id'] as String;
    final token = issued['token'] as String;

    final (before, _) = await send(
      'GET',
      '/api/v1/nodes',
      token: token,
      principal: 'bob',
    );
    expect(before, 200);

    final (revoked, _) = await send('DELETE', '/api/v1/grants/$id');
    expect(revoked, 200);

    // No cache to expire, no restart to wait for: the credential is gone.
    final (after, _) = await send(
      'GET',
      '/api/v1/nodes',
      token: token,
      principal: 'bob',
    );
    expect(after, 401);
  });

  test('a token still has to be claimed by the right principal', () async {
    final (_, issued) = await send(
      'POST',
      '/api/v1/grants',
      body: {
        'principal': 'bob',
        'roles': ['admin'],
      },
    );
    final token = (issued as Map)['token'] as String;

    final (status, _) = await send(
      'GET',
      '/api/v1/nodes',
      token: token,
      principal: 'mallory',
    );
    expect(status, 401);
  });

  test('an issued credential carries exactly the roles it was given', () async {
    final (_, issued) = await send(
      'POST',
      '/api/v1/grants',
      body: {
        'principal': 'victor',
        'roles': ['viewer'],
      },
    );
    final token = (issued as Map)['token'] as String;

    await cluster.startNode(id: 'worker-01');

    // A viewer reads…
    final (read, _) = await send(
      'GET',
      '/api/v1/nodes',
      token: token,
      principal: 'victor',
    );
    expect(read, 200);

    // …and cannot act.
    final (act, _) = await send(
      'POST',
      '/api/v1/nodes/worker-01/restart',
      token: token,
      principal: 'victor',
    );
    expect(act, 403);
  });

  test('only an admin may mint or revoke a credential', () async {
    // `grant.manage` is deliberately unmapped, so it is admin-only: an operator
    // can run the fleet but cannot quietly issue itself an admin token.
    final (_, issued) = await send(
      'POST',
      '/api/v1/grants',
      body: {
        'principal': 'olive',
        'roles': ['operator'],
      },
    );
    final operatorToken = (issued as Map)['token'] as String;

    final (mint, _) = await send(
      'POST',
      '/api/v1/grants',
      body: {
        'principal': 'olive2',
        'roles': ['admin'],
      },
      token: operatorToken,
      principal: 'olive',
    );
    expect(mint, 403);

    final (revoke, _) = await send(
      'DELETE',
      '/api/v1/grants/${issued['id']}',
      token: operatorToken,
      principal: 'olive',
    );
    expect(revoke, 403);
  });

  test('a credential with no roles is refused', () async {
    final (status, body) = await send(
      'POST',
      '/api/v1/grants',
      body: {'principal': 'nobody', 'roles': <String>[]},
    );
    expect(status, 400);
    expect((body as Map)['error']['message'], contains('roles are required'));
  });

  test('the flag-based grants still work alongside the issued ones', () async {
    // The Hub is bootstrapped from its command line and hands out credentials at
    // runtime; both are checked, in that order.
    final (status, me) = await send(
      'GET',
      '/api/v1/whoami',
      token: 'admin-token',
      principal: 'alice',
    );
    expect(status, 200);
    expect((me as Map)['principal'], 'alice');
  });
}
