// Starts a standalone Hub plus its REST HTTP API, then leaves them running.
// Point a Node agent at the printed WSS URL and query the API.
//
// Run with: dart run example/omnyserver_hub_example.dart
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('omnyserver-hub-example');
  final certs = await CertGenerator.generate(outputDir: dir.path, force: true);

  final hub = OmnyServerHub(
    HubConfig(
      host: '127.0.0.1',
      port: 8443,
      securityContext: SecurityContext()
        ..useCertificateChain(certs.serverCert)
        ..usePrivateKey(certs.serverKey),
      authenticator: TokenAuthenticator({
        'admin-token': TokenGrant(
          principal: PrincipalId('alice'),
          roles: const {'admin'},
        ),
        'node-token': TokenGrant(
          principal: PrincipalId('node-account'),
          roles: const {'node'},
        ),
      }),
      logger: print,
    ),
  );
  await hub.start();

  final events = EventAggregator()..attach(hub.config.eventBus);
  final metrics = HubMetrics(hub.registry)..attach(hub.config.eventBus);
  final api = HttpApiServer(
    hub: hub,
    apiToken: 'api-secret',
    events: events,
    metrics: metrics,
    host: '127.0.0.1',
    port: 8080,
  );
  await api.start();

  print('Hub WSS:  wss://127.0.0.1:${hub.port}');
  print('Hub API:  http://127.0.0.1:${api.boundPort}/api/v1/nodes');
  print('Metrics:  http://127.0.0.1:${api.boundPort}/metrics');
  print('CA cert:  ${certs.caCert}');
  print('Ctrl-C to stop.');
}
