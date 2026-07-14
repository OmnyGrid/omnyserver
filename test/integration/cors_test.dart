@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

const String _dashboard = 'https://dashboard.example.com';

/// CORS on the Hub's HTTP API.
///
/// A web dashboard is *always* a different origin from the Hub — in production
/// and in development alike (`webdev` on :8080, Hub on :8443) — so without this
/// the browser blocks every response and the app sees only network errors.
///
/// The failure cases are the ones that matter. A browser cannot read a response
/// it was not granted access to, so a `401` without `Access-Control-Allow-Origin`
/// reaches the app as an opaque error, not as "your token is wrong". Those
/// responses are rendered above ordinary middleware, which is why the Hub
/// installs `cors()` with `useOuter`.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;

  Future<void> startApi({List<String> origins = const [_dashboard]}) async {
    // The Hub's allowed origins come from its config (`hub start --cors-origin`);
    // the API server reads them and installs CORS on whichever listener hosts it.
    cluster = await TestCluster.start(corsOrigins: origins);
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
  }

  tearDown(() async {
    await api.close();
    await cluster.dispose();
  });

  Future<(int, Map<String, String>)> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    headers.forEach(req.headers.set);
    final res = await req.close();
    await res.transform(utf8.decoder).join();
    client.close();
    final out = <String, String>{};
    res.headers.forEach((name, values) => out[name] = values.join(', '));
    return (res.statusCode, out);
  }

  test('a preflight is answered without credentials', () async {
    await startApi();
    // A browser never sends Authorization on a preflight, so if the
    // authenticator saw it first this would be a 401 and the app could never
    // make a single call.
    final (status, headers) = await send(
      'OPTIONS',
      '/api/v1/nodes',
      headers: {
        'origin': _dashboard,
        'access-control-request-method': 'GET',
        'access-control-request-headers': 'authorization, x-omny-principal',
      },
    );

    expect(status, 204);
    expect(headers['access-control-allow-origin'], _dashboard);
    // The dashboard sends both of these; a preflight that does not allow them is
    // rejected by the browser.
    expect(headers['access-control-allow-headers'], contains('authorization'));
    expect(
      headers['access-control-allow-headers'],
      contains('x-omny-principal'),
    );
  });

  test('an authorized request carries the allow-origin header', () async {
    await startApi();
    final (status, headers) = await send(
      'GET',
      '/api/v1/nodes',
      headers: {'origin': _dashboard, 'authorization': 'Bearer api-secret'},
    );

    expect(status, 200);
    expect(headers['access-control-allow-origin'], _dashboard);
  });

  test('a 401 is readable by the browser', () async {
    await startApi();
    final (status, headers) = await send(
      'GET',
      '/api/v1/nodes',
      headers: {'origin': _dashboard, 'authorization': 'Bearer wrong'},
    );

    expect(status, 401);
    expect(
      headers['access-control-allow-origin'],
      _dashboard,
      reason:
          'without this the dashboard sees a network error and cannot tell the '
          'user their token is wrong — this is why cors() goes in useOuter',
    );
  });

  test('a 404 is readable by the browser', () async {
    await startApi();
    final (status, headers) = await send(
      'GET',
      '/api/v1/nodes/ghost',
      headers: {'origin': _dashboard, 'authorization': 'Bearer api-secret'},
    );

    expect(status, 404);
    expect(headers['access-control-allow-origin'], _dashboard);
  });

  test('an unlisted origin is not granted access', () async {
    await startApi();
    final (status, headers) = await send(
      'GET',
      '/api/v1/nodes',
      headers: {
        'origin': 'https://evil.example.com',
        'authorization': 'Bearer api-secret',
      },
    );

    expect(status, 200);
    expect(headers.containsKey('access-control-allow-origin'), isFalse);
  });

  test('the CLI, which sends no Origin, is unaffected', () async {
    await startApi();
    final (status, headers) = await send(
      'GET',
      '/api/v1/nodes',
      headers: {'authorization': 'Bearer api-secret'},
    );

    expect(status, 200);
    expect(headers.containsKey('access-control-allow-origin'), isFalse);
    expect(headers.containsKey('vary'), isFalse);
  });

  test('a Hub with no --cors-origin installs no CORS at all', () async {
    await startApi(origins: const []);
    expect(api.corsMiddleware(), isNull);

    final (status, headers) = await send(
      'GET',
      '/api/v1/nodes',
      headers: {'origin': _dashboard, 'authorization': 'Bearer api-secret'},
    );

    expect(status, 200);
    expect(headers.containsKey('access-control-allow-origin'), isFalse);
  });

  // `--cors-origin '*'` means "any origin". It is a real widening — any page may
  // call the API — but not an open door: the Hub sets no `allow-credentials`, so
  // the browser attaches nothing ambient and a caller still needs a token it was
  // given. The literal `*` must reach the wire, or the flag would be one of
  // those settings that looks configured and does nothing.
  group('the wildcard origin', () {
    test('grants any origin, emitting a literal *', () async {
      await startApi(origins: const ['*']);

      final (status, headers) = await send(
        'GET',
        '/api/v1/nodes',
        headers: {
          'origin': 'https://anything.example.org',
          'authorization': 'Bearer api-secret',
        },
      );

      expect(status, 200);
      expect(headers['access-control-allow-origin'], '*');
    });

    test('answers a preflight from any origin', () async {
      await startApi(origins: const ['*']);

      final (status, headers) = await send(
        'OPTIONS',
        '/api/v1/nodes',
        headers: {
          'origin': 'https://anything.example.org',
          'access-control-request-method': 'GET',
          'access-control-request-headers': 'authorization',
        },
      );

      expect(status, 204);
      expect(headers['access-control-allow-origin'], '*');
      expect(
        headers['access-control-allow-headers'],
        contains('authorization'),
      );
    });

    // A wildcard is not a bypass: it opens who may *ask*, not who may *in*.
    test('still requires a token', () async {
      await startApi(origins: const ['*']);

      final (status, headers) = await send(
        'GET',
        '/api/v1/nodes',
        headers: {'origin': 'https://anything.example.org'},
      );

      expect(status, 401);
      // ...and the 401 is readable, which is the whole point of useOuter.
      expect(headers['access-control-allow-origin'], '*');
    });

    // `cors()` only emits a literal `*` when no specific origin is named, so a
    // wildcard cannot be mixed into an allow-list. Asking for both is asking for
    // everything — anything else would silently downgrade one of the two.
    test('is dominant over a named origin', () async {
      await startApi(origins: const [_dashboard, '*']);

      final (status, headers) = await send(
        'GET',
        '/api/v1/nodes',
        headers: {
          'origin': 'https://anything.example.org',
          'authorization': 'Bearer api-secret',
        },
      );

      expect(status, 200);
      expect(headers['access-control-allow-origin'], '*');
    });

    test('survives the whitespace an env-var passthrough leaves behind', () {
      expect(HttpApiServer.isAnyOrigin('*'), isTrue);
      expect(HttpApiServer.isAnyOrigin(' * '), isTrue);
      expect(HttpApiServer.isAnyOrigin(_dashboard), isFalse);
    });
  });
}
