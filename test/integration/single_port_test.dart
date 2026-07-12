@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// The Hub serves the node control channel and the REST API on ONE TLS
/// listener: nodes upgrade to a WebSocket on `/node`, operators call `/api/v1`
/// on the same host and port. This pins that they genuinely coexist — the
/// routing, the TLS and the bearer gate all hold with both mounted together.
void main() {
  late OmnyServerHub hub;
  late HttpApiServer api;
  final agents = <NodeAgent>[];

  setUp(() async {
    hub = OmnyServerHub(
      HubConfig(
        host: '127.0.0.1',
        port: 0,
        securityContext: await TestCerts.serverContext(),
        authenticator: TokenAuthenticator({
          'node-token': TokenGrant(
            principal: PrincipalId('node-account'),
            roles: const {'node'},
          ),
        }),
        heartbeatInterval: const Duration(milliseconds: 200),
      ),
    );

    api = HttpApiServer(
      hub: hub,
      apiToken: 'api-secret',
      metrics: HubMetrics(hub.registry)..attach(hub.config.eventBus),
    );
    for (final middleware in api.buildMiddleware()) {
      hub.use(middleware);
    }
    for (final service in api.buildServices()) {
      hub.registerService(
        service,
        authenticator: service.name == HttpApiServer.apiServiceName
            ? api.tokenAuthenticator()
            : null,
      );
    }

    await hub.start();
  });

  tearDown(() async {
    for (final agent in agents) {
      await agent.stop();
    }
    agents.clear();
    await hub.close();
  });

  /// Calls the REST API over TLS on the Hub's own port.
  Future<(int, dynamic)> get(String path, {String? token}) async {
    final client = HttpClient(context: await TestCerts.trustContext())
      ..badCertificateCallback = (_, _, _) => true;
    final req = await client.getUrl(
      Uri.parse('https://127.0.0.1:${hub.port}$path'),
    );
    if (token != null) req.headers.set('authorization', 'Bearer $token');
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

  Future<NodeAgent> startNode(String id) async {
    final agent = NodeAgent(
      NodeAgentConfig(
        hubUri: Uri.parse('wss://127.0.0.1:${hub.port}'),
        nodeId: id,
        credentials: TokenCredentialProvider(
          principal: 'node-account',
          token: 'node-token',
        ),
        securityContext: await TestCerts.trustContext(),
        onBadCertificate: (_, _, _) => true,
      ),
    );
    agents.add(agent);
    await agent.start();
    return agent;
  }

  test('a node and the REST API share one TLS port', () async {
    await startNode('worker-01');

    // Same host, same port, same certificate — different mount.
    final (status, body) = await get('/api/v1/nodes', token: 'api-secret');
    expect(status, 200);
    expect((body as List).single['nodeId'], 'worker-01');
  });

  test('the node channel does not answer HTTP as if it were the API', () async {
    // /node is a WebSocket mount. A plain GET must not fall through to the API's
    // catch-all and pretend the route does not exist.
    final (status, _) = await get('/node');
    expect(status, isNot(404));
  });

  test('the bearer gate still guards /api/v1 on the shared port', () async {
    expect((await get('/api/v1/nodes')).$1, 401);
    expect((await get('/healthz')).$1, 200);
    expect((await get('/metrics')).$1, 200);
  });

  test('the node connects on the mount, not the bare host', () async {
    // NodeAgentConfig takes the Hub URL; the mount is filled in for the
    // operator. An explicit path is honoured as-is.
    final config = NodeAgentConfig(
      hubUri: Uri.parse('wss://hub.example.com:8443'),
      nodeId: 'n1',
      credentials: TokenCredentialProvider(principal: 'p', token: 't'),
    );
    expect(config.controlUri.toString(), 'wss://hub.example.com:8443/node');

    final explicit = NodeAgentConfig(
      hubUri: Uri.parse('wss://hub.example.com:8443/behind/proxy'),
      nodeId: 'n1',
      credentials: TokenCredentialProvider(principal: 'p', token: 't'),
    );
    expect(
      explicit.controlUri.toString(),
      'wss://hub.example.com:8443/behind/proxy',
    );
  });

  test(
    'an operation dispatched over the shared port reaches the node',
    () async {
      var restarted = false;
      final agent = NodeAgent(
        NodeAgentConfig(
          hubUri: Uri.parse('wss://127.0.0.1:${hub.port}'),
          nodeId: 'worker-02',
          credentials: TokenCredentialProvider(
            principal: 'node-account',
            token: 'node-token',
          ),
          securityContext: await TestCerts.trustContext(),
          onBadCertificate: (_, _, _) => true,
          nodeControlHandler: (request) async {
            restarted = request.action == 'restart';
            return (true, 'ok');
          },
        ),
      );
      agents.add(agent);
      await agent.start();

      final client = HttpClient(context: await TestCerts.trustContext())
        ..badCertificateCallback = (_, _, _) => true;
      final req = await client.postUrl(
        Uri.parse(
          'https://127.0.0.1:${hub.port}/api/v1/nodes/worker-02/restart',
        ),
      );
      req.headers.set('authorization', 'Bearer api-secret');
      final res = await req.close();
      await res.drain<void>();
      client.close();

      expect(res.statusCode, 200);
      expect(
        restarted,
        isTrue,
        reason: 'REST call must reach the node channel',
      );
    },
  );
}
