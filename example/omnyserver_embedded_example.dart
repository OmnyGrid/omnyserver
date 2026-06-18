// Embeds a Hub and a Node agent in a single process over WSS, then queries the
// node's live status — the smallest end-to-end OmnyServer demo.
//
// Run with: dart run example/omnyserver_embedded_example.dart
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart';

Future<void> main() async {
  // 1. Generate throwaway dev certificates.
  final dir = Directory.systemTemp.createTempSync('omnyserver-example');
  final certs = await CertGenerator.generate(outputDir: dir.path, force: true);

  // 2. Start a Hub with a single token grant.
  final hub = OmnyServerHub(
    HubConfig(
      host: '127.0.0.1',
      port: 0,
      securityContext: SecurityContext()
        ..useCertificateChain(certs.serverCert)
        ..usePrivateKey(certs.serverKey),
      authenticator: TokenAuthenticator({
        'node-token': TokenGrant(
          principal: PrincipalId('node-account'),
          roles: const {'node'},
        ),
      }),
      logger: (m) => print('[hub] $m'),
    ),
  );
  await hub.start();
  print('Hub listening on wss://127.0.0.1:${hub.port}');

  // 3. Connect a Node agent that reports real system status and capabilities.
  final agent = NodeAgent(
    NodeAgentConfig(
      hubUri: Uri.parse('wss://127.0.0.1:${hub.port}'),
      nodeId: 'demo-node',
      credentials: const TokenCredentialProvider(
        principal: 'node-account',
        token: 'node-token',
      ),
      securityContext: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(certs.caCert),
      onBadCertificate: (cert, host, port) => true,
      heartbeatInterval: const Duration(seconds: 1),
      statusProvider: const SystemMonitor().snapshot,
      capabilityProvider: CapabilityScanner.standard().scan,
    ),
  );
  await agent.start();
  print('Node "demo-node" registered.');

  // 4. Wait for the first heartbeat, then print the live status.
  await Future<void>.delayed(const Duration(seconds: 2));
  final status = hub.getStatus(NodeId('demo-node'));
  final node = hub.getNode(NodeId('demo-node'));
  print('OS:    ${status?.os.osName} ${status?.os.osVersion}');
  print(
    'CPU:   ${status?.cpu.coreCount} cores, '
    '${status?.cpu.usagePercent.toStringAsFixed(1)}% used',
  );
  print(
    'Caps:  ${node?.capabilities.capabilities.map((c) => c.name).join(', ')}',
  );

  await agent.stop();
  await hub.close();
  dir.deleteSync(recursive: true);
}
