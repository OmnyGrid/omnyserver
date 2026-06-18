import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart';

/// A fixed clock for deterministic tests.
class FixedClock implements Clock {
  /// The instant returned by [now].
  DateTime current;

  /// Creates a fixed clock at [current].
  FixedClock(this.current);

  @override
  DateTime now() => current.toUtc();
}

/// Generates dev TLS certificates into a shared temp dir (once per process) and
/// exposes server/trust [SecurityContext]s for the in-process cluster.
class TestCerts {
  static GeneratedCertificates? _certs;

  /// Generates (or reuses) the dev certificates and returns their paths.
  static Future<GeneratedCertificates> ensure() async {
    if (_certs != null) return _certs!;
    final dir = Directory.systemTemp.createTempSync('omnyserver-test-certs');
    _certs = await CertGenerator.generate(outputDir: dir.path, force: true);
    return _certs!;
  }

  /// The Hub server context (certificate chain + key).
  static Future<SecurityContext> serverContext() async {
    final certs = await ensure();
    return SecurityContext()
      ..useCertificateChain(certs.serverCert)
      ..usePrivateKey(certs.serverKey);
  }

  /// A client/agent trust context that trusts the dev CA.
  static Future<SecurityContext> trustContext() async {
    final certs = await ensure();
    return SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(certs.caCert);
  }
}

/// A running Hub plus helpers to attach node agents over real `wss`.
class TestCluster {
  /// The running Hub.
  final OmnyServerHub hub;

  /// The token store the Hub authenticates against.
  final Map<String, TokenGrant> tokens;

  final List<NodeAgent> _agents = [];

  TestCluster._(this.hub, this.tokens);

  /// The Hub's `wss://` URL.
  Uri get hubUri => Uri.parse('wss://127.0.0.1:${hub.port}');

  /// Starts a Hub on an ephemeral port with the given [tokens].
  static Future<TestCluster> start({
    Map<String, TokenGrant>? tokens,
    Clock? clock,
    Duration heartbeatTimeout = const Duration(seconds: 45),
    EventBus? eventBus,
    NodeRepository? nodeRepository,
    AuditRepository? auditRepository,
    MetricRepository? metricRepository,
  }) async {
    final grants =
        tokens ??
        {
          'admin-token': TokenGrant(
            principal: PrincipalId('alice'),
            roles: const {'admin'},
          ),
          'node-token': TokenGrant(
            principal: PrincipalId('node-account'),
            roles: const {'node'},
          ),
        };
    final hub = OmnyServerHub(
      HubConfig(
        host: '127.0.0.1',
        port: 0,
        securityContext: await TestCerts.serverContext(),
        authenticator: TokenAuthenticator(grants),
        heartbeatTimeout: heartbeatTimeout,
        clock: clock ?? const SystemClock(),
        eventBus: eventBus,
        nodeRepository: nodeRepository,
        auditRepository: auditRepository,
        metricRepository: metricRepository,
      ),
    );
    await hub.start();
    return TestCluster._(hub, grants);
  }

  /// Connects a node agent and awaits its registration.
  Future<NodeAgent> startNode({
    required String id,
    String token = 'node-token',
    String principal = 'node-account',
    Map<String, String> labels = const {},
    Duration heartbeatInterval = const Duration(milliseconds: 200),
    StatusProvider? statusProvider,
    CapabilityProvider? capabilityProvider,
    FormulaHandler? formulaHandler,
    PresetHandler? presetHandler,
    NodeControlHandler? nodeControlHandler,
  }) async {
    final agent = NodeAgent(
      NodeAgentConfig(
        hubUri: hubUri,
        nodeId: id,
        labels: labels,
        credentials: TokenCredentialProvider(
          principal: principal,
          token: token,
        ),
        securityContext: await TestCerts.trustContext(),
        onBadCertificate: (cert, host, port) => true,
        heartbeatInterval: heartbeatInterval,
        statusProvider: statusProvider,
        capabilityProvider: capabilityProvider,
        formulaHandler: formulaHandler,
        presetHandler: presetHandler,
        nodeControlHandler: nodeControlHandler,
      ),
    );
    _agents.add(agent);
    await agent.start();
    return agent;
  }

  /// Builds an unstarted agent (for negative auth tests).
  Future<NodeAgent> buildNode({
    required String id,
    required String token,
    String principal = 'node-account',
  }) async {
    final agent = NodeAgent(
      NodeAgentConfig(
        hubUri: hubUri,
        nodeId: id,
        credentials: TokenCredentialProvider(
          principal: principal,
          token: token,
        ),
        securityContext: await TestCerts.trustContext(),
        onBadCertificate: (cert, host, port) => true,
      ),
    );
    _agents.add(agent);
    return agent;
  }

  /// Stops all agents and the Hub.
  Future<void> dispose() async {
    for (final agent in _agents) {
      await agent.stop();
    }
    await hub.close();
  }
}
