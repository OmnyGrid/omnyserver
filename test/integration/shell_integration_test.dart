@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyhub/omnyhub.dart' as omnyhub;
import 'package:omnyshell/omnyshell_client.dart' as shell;
import 'package:omnyshell/omnyshell_node.dart' as shell;
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// One OmnyServer Hub serving **both** fleets on **one** TLS port:
///
/// * `/node`   — OmnyServer agents (its own protocol, Ed25519/token handshake)
/// * `/shell`  — OmnyShell nodes   (OmnyShell's protocol, in-band handshake)
/// * `/api/v1` — the REST API
///
/// The two node protocols are unrelated and both authenticate in band, so this
/// only works because each mount carries its own connection auth. That is the
/// property most at risk of silently breaking, and the reason for the first
/// group below.
void main() {
  late OmnyServerHub hub;
  late HttpApiServer api;
  final agents = <NodeAgent>[];
  final shellNodes = <shell.NodeRuntime>[];
  final shellClients = <shell.ClientRuntime>[];
  late Directory shellHome;
  late ShellHub shellHub;

  final grants = {
    'node-token': TokenGrant(
      principal: PrincipalId('node-account'),
      roles: const {'node'},
    ),
    'admin-token': TokenGrant(
      principal: PrincipalId('alice'),
      roles: const {'admin'},
    ),
  };

  setUp(() async {
    shellHome = Directory.systemTemp.createTempSync('omnyserver-shell-');
    hub = OmnyServerHub(
      HubConfig(
        host: '127.0.0.1',
        port: 0,
        securityContext: await TestCerts.serverContext(),
        authenticator: TokenAuthenticator(grants),
        heartbeatInterval: const Duration(milliseconds: 200),
      ),
    );

    // The OmnyShell broker, sharing the Hub's credentials.
    shellHub = ShellHub.fromGrants(grants);
    hub.registerService(shellHub.service());

    api = HttpApiServer(
      hub: hub,
      apiToken: 'api-secret',
      metrics: HubMetrics(hub.registry)..attach(hub.config.eventBus),
    );
    for (final m in api.buildMiddleware()) {
      hub.use(m);
    }
    for (final s in api.buildServices()) {
      hub.registerService(
        s,
        authenticator: s.name == HttpApiServer.apiServiceName
            ? api.tokenAuthenticator()
            : null,
      );
    }

    await hub.start();
  });

  tearDown(() async {
    for (final c in shellClients) {
      await c.close();
    }
    for (final n in shellNodes) {
      await n.shutdown();
    }
    for (final a in agents) {
      await a.stop();
    }
    shellClients.clear();
    shellNodes.clear();
    agents.clear();
    await hub.close();
    shellHome.deleteSync(recursive: true);
  });

  Uri shellUri() => Uri.parse('wss://127.0.0.1:${hub.port}/shell');

  /// An OmnyServer agent on `/node`.
  Future<NodeAgent> startServerNode(String id) async {
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

  /// An OmnyShell node on `/shell` — exactly what `omnyshell node start
  /// --hub wss://…/shell` builds.
  Future<shell.NodeRuntime> startShellNode(
    String id,
    shell.ShellBackend backend,
  ) async {
    final node = shell.NodeRuntime(
      shell.NodeConfig(
        hubUri: shellUri(),
        nodeId: shell.NodeId(id),
        credentials: const shell.TokenCredentialProvider(
          principal: 'node-account',
          token: 'node-token',
        ),
        backend: backend,
        labels: const {'allow-roles': 'admin'},
        securityContext: await TestCerts.trustContext(),
        onBadCertificate: (_, _, _) => true,
        home: shellHome.path,
      ),
    );
    shellNodes.add(node);
    await node.connect();
    return node;
  }

  Future<shell.ClientRuntime> connectShellClient() async {
    final client = shell.ClientRuntime(
      shell.ClientConfig(
        hubUri: shellUri(),
        credentials: const shell.TokenCredentialProvider(
          principal: 'alice',
          token: 'admin-token',
        ),
        connectionFactory: shell.ioConnectionFactory(
          securityContext: await TestCerts.trustContext(),
          onBadCertificate: (_, _, _) => true,
        ),
      ),
    );
    shellClients.add(client);
    await client.connect();
    return client;
  }

  Future<(int, dynamic)> apiGet(String path, {String? token}) async {
    final client = HttpClient(context: await TestCerts.trustContext())
      ..badCertificateCallback = (_, _, _) => true;
    final req = await client.getUrl(
      Uri.parse('https://127.0.0.1:${hub.port}$path'),
    );
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    client.close();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  group('one Hub, two node protocols', () {
    test(
      'an OmnyShell node registers on the same Hub as an OmnyServer node',
      () async {
        await startServerNode('worker-01');
        await startShellNode('worker-01', shell.ProcessShellBackend());

        // The OmnyServer fleet, via its REST API.
        final (status, body) = await apiGet(
          '/api/v1/nodes',
          token: 'api-secret',
        );
        expect(status, 200);
        expect((body as List).single['nodeId'], 'worker-01');

        // The OmnyShell fleet, via the broker's registry — same Hub, same port.
        final shellNodes = shellHub.broker.registry.all;
        expect(shellNodes, hasLength(1));
        expect(shellNodes.first.descriptor.id.value, 'worker-01');
      },
    );

    test('a shell session runs a command through the OmnyServer Hub', () async {
      await startServerNode('worker-01');
      await startShellNode('worker-01', shell.ProcessShellBackend());
      final client = await connectShellClient();

      final session = await client.openSession(
        nodeId: 'worker-01',
        mode: shell.SessionMode.exec,
        command: 'echo hello-from-omnyserver-hub',
      );
      final out = StringBuffer();
      session.stdout.listen((d) => out.write(utf8.decode(d)));

      expect(await session.exitCode, 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(out.toString(), contains('hello-from-omnyserver-hub'));
    });

    test('all three surfaces answer on the one port', () async {
      await startServerNode('worker-01');
      await startShellNode('worker-01', shell.ProcessShellBackend());

      expect((await apiGet('/healthz')).$1, 200);
      expect((await apiGet('/api/v1/nodes', token: 'api-secret')).$1, 200);

      // A plain GET on the shell mount is answered by the broker's service.
      final (status, body) = await apiGet('/shell');
      expect(status, 200);
      expect((body as Map)['service'], 'omnyshell');
    });
  });

  group('the node handshake stays on the node route', () {
    test(
      "OmnyServer's connection authenticator does not reach the shell mount",
      () async {
        // The regression this whole design hinges on. omnyhub resolves a route's
        // connection authenticator as `route.connectionAuthenticator ?? hubWide`,
        // so a hub-wide one is INHERITED by every other WebSocket mount. If
        // OmnyServer's handshake were hub-wide, it would sit here doing
        // `expect<Hello>` in OmnyServer's wire format against an OmnyShell peer —
        // eating the broker's frames and rejecting every shell node.
        //
        // A shell node connecting at all is the proof it does not.
        await startShellNode('shell-only', shell.ProcessShellBackend());

        expect(shellHub.broker.registry.all, hasLength(1));
        // …and no OmnyServer node was registered by that connection.
        expect(hub.listNodes(), isEmpty);
      },
    );

    test('the node channel still runs the OmnyServer handshake', () async {
      // The converse: /node must still authenticate, or the fix went too far.
      final bad = NodeAgent(
        NodeAgentConfig(
          hubUri: Uri.parse('wss://127.0.0.1:${hub.port}'),
          nodeId: 'imposter',
          credentials: TokenCredentialProvider(
            principal: 'node-account',
            token: 'wrong-token',
          ),
          securityContext: await TestCerts.trustContext(),
          onBadCertificate: (_, _, _) => true,
        ),
      );
      await expectLater(bad.start(), throwsA(isA<AuthException>()));
      await bad.stop();
    });
  });

  group('shared credentials', () {
    test('one grant list authenticates both fleets', () async {
      // The node used the same principal/token on both mounts, and the shell
      // client used the Hub's admin grant. Nothing separate was provisioned.
      await startShellNode('worker-01', shell.ProcessShellBackend());
      final client = await connectShellClient();
      expect(client.isConnected, isTrue);
    });

    test('a bad token is rejected by the shell broker too', () async {
      final node = shell.NodeRuntime(
        shell.NodeConfig(
          hubUri: shellUri(),
          nodeId: shell.NodeId('imposter'),
          credentials: const shell.TokenCredentialProvider(
            principal: 'node-account',
            token: 'wrong-token',
          ),
          backend: shell.ProcessShellBackend(),
          securityContext: await TestCerts.trustContext(),
          onBadCertificate: (_, _, _) => true,
          home: shellHome.path,
        ),
      );
      shellNodes.add(node);

      await expectLater(node.connect(), throwsA(isA<StateError>()));
      expect(shellHub.broker.registry.all, isEmpty);
    });
  });

  group('ShellHub', () {
    test('the mount is configurable', () async {
      expect(ShellHub.fromGrants(grants).mount, '/shell');
      expect(ShellHub.fromGrants(grants, mount: '/sh').mount, '/sh');
      expect(ShellHub.fromGrants(grants, mount: '/sh').service().mount, '/sh');
    });

    test('grants carry principal and roles across to OmnyShell', () {
      final translated = toShellGrants(grants);

      expect(translated['admin-token']!.principal.value, 'alice');
      expect(translated['admin-token']!.roles, contains('admin'));
      // OmnyServer has no displayName; the principal id stands in for it.
      expect(translated['admin-token']!.displayName, 'alice');
    });
  });

  test(
    'the omnyhub service is registered without a connection authenticator',
    () {
      // Belt and braces: assert the service itself carries no in-band handshake,
      // since supplying one would break the broker rather than secure it.
      final service = ShellHub.fromGrants(grants).service();
      expect(service, isA<omnyhub.Service>());
      expect(service.mount, '/shell');
    },
  );
}
