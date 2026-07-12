// Starts a standalone Hub — the node control channel and the REST API on one
// TLS port — then leaves it running. Point a Node agent at the printed WSS URL
// and query the API.
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

  // Mount the REST API on the Hub's own listener, so nodes and operators share
  // one TLS port: nodes upgrade to a WebSocket on /node, operators call /api/v1.
  final events = EventAggregator()..attach(hub.config.eventBus);
  final metrics = HubMetrics(hub.registry)..attach(hub.config.eventBus);
  final api = HttpApiServer(
    hub: hub,
    apiToken: 'api-secret',
    events: events,
    metrics: metrics,
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

  print('Hub nodes: wss://127.0.0.1:${hub.port}/node');
  print('Hub API:   https://127.0.0.1:${hub.port}/api/v1/nodes');
  print('Metrics:   https://127.0.0.1:${hub.port}/metrics');
  print('CA cert:   ${certs.caCert}');
  print('Ctrl-C to stop.');
}
