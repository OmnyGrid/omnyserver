@TestOn('vm')
library;

import 'dart:async';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// A node that authenticates but is refused registration used to retry in total
/// silence — the exact failure that took a live packet-trace to diagnose. The
/// Hub sends the reason as an error frame; the runtime now has a real logger, so
/// it reaches the operator.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  test('a node refused registration is told why, and keeps retrying', () async {
    // A grant that can connect but lacks the `node` role — exactly the
    // misconfiguration from the field (roles: {server} instead of {node}).
    final cluster = await TestCluster.start(
      tokens: {
        'server-token': TokenGrant(
          principal: PrincipalId('server-node'),
          roles: const {'server'},
        ),
      },
    );
    addTearDown(cluster.dispose);

    final lines = <String>[];
    final agent = NodeAgent(
      NodeAgentConfig(
        hubUri: cluster.hubUri,
        nodeId: 'sites-menuici',
        credentials: TokenCredentialProvider(
          principal: 'server-node',
          token: 'server-token',
        ),
        securityContext: await TestCerts.trustContext(),
        onBadCertificate: (cert, host, port) => true,
        reconnect: const ReconnectPolicy(
          initial: Duration(milliseconds: 20),
          max: Duration(milliseconds: 40),
        ),
        logger: lines.add,
      ),
    );
    addTearDown(agent.stop);

    // A forbidden registration is not terminal (the chosen behaviour: keep
    // retrying so it recovers when the grant is fixed), so start() never
    // returns — do not await it.
    unawaited(agent.start().catchError((Object _) {}));

    await _until(() => lines.any((l) => l.contains('may not register')));

    final output = lines.join('\n');
    expect(
      output,
      contains('sites-menuici'),
      reason: 'the node names itself in the refusal',
    );
    expect(output, contains('may not register'));
    expect(agent.isConnected, isFalse, reason: 'it is refused, not registered');
  });

  test('the Hub logs the refusal on its own side too', () async {
    final hubLog = <String>[];
    final cluster = await TestCluster.start(
      tokens: {
        'server-token': TokenGrant(
          principal: PrincipalId('server-node'),
          roles: const {'server'},
        ),
      },
      logger: hubLog.add,
    );
    addTearDown(cluster.dispose);

    final agent = NodeAgent(
      NodeAgentConfig(
        hubUri: cluster.hubUri,
        nodeId: 'sites-menuici',
        credentials: TokenCredentialProvider(
          principal: 'server-node',
          token: 'server-token',
        ),
        securityContext: await TestCerts.trustContext(),
        onBadCertificate: (cert, host, port) => true,
        reconnect: const ReconnectPolicy(
          initial: Duration(milliseconds: 20),
          max: Duration(milliseconds: 40),
        ),
      ),
    );
    addTearDown(agent.stop);
    unawaited(agent.start().catchError((Object _) {}));

    await _until(() => hubLog.any((l) => l.contains('refused registration')));
    expect(
      hubLog.firstWhere((l) => l.contains('refused registration')),
      contains('server-node'),
    );
  });
}
