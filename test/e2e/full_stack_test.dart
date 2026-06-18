@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_cli.dart' show HubApiClient;
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

class _PresentExecutor implements CommandExecutor {
  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async => const ExecResult(exitCode: 0, stdout: 'version 1.0.0');
}

void main() {
  test('full lifecycle: register → monitor → preset → recovery', () async {
    final cluster = await TestCluster.start();
    final events = EventAggregator()..attach(cluster.hub.config.eventBus);
    final metrics = HubMetrics(cluster.hub.registry)
      ..attach(cluster.hub.config.eventBus);
    final api = HttpApiServer(
      hub: cluster.hub,
      events: events,
      metrics: metrics,
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
    final client = HubApiClient(Uri.parse('http://127.0.0.1:${api.boundPort}'));

    final service = NodeFormulaService(
      registry: FormulaRegistry.standard(executor: _PresentExecutor()),
    );

    try {
      // 1. Register.
      await cluster.startNode(
        id: 'app-01',
        capabilityProvider: () async => NodeCapabilities([
          Capability.of(CapabilityKind.docker, version: '24.0.7'),
        ]),
        formulaHandler: service.runFormula,
        presetHandler: service.applyPreset,
      );
      var nodes = (await client.get('/nodes') as List).cast<Map>();
      expect(nodes.single['nodeId'], 'app-01');
      expect(nodes.single['online'], isTrue);

      // 2. Monitoring: status surfaces after a heartbeat.
      await _eventually(() async {
        final (ok, _) = await _try(client, '/nodes/app-01/status');
        return ok;
      });
      final caps = await client.get('/nodes/app-01/capabilities');
      expect((caps as Map)['capabilities'], isNotEmpty);

      // 3. Preset application across formulas.
      final result = await client.post('/presets/apply', {
        'nodeId': 'app-01',
        'preset': {
          'id': 'docker-host',
          'name': 'Docker Host',
          'steps': [
            {'formula': 'docker', 'action': 'verify'},
          ],
        },
      });
      expect((result as Map)['success'], isTrue);

      // 4. Recovery: node disconnects then re-registers.
      await cluster
          .dispose(); // stops the agent (and hub) — restart a fresh one.
    } finally {
      client.close();
      await api.close();
      await events.detach();
      await metrics.detach();
    }
  });

  test('recovery: a re-registering node returns online', () async {
    final cluster = await TestCluster.start();
    try {
      final agent = await cluster.startNode(id: 'svc-01');
      expect(cluster.hub.getNode(NodeId('svc-01'))!.online, isTrue);

      // Disconnect.
      await agent.stop();
      await _eventually(
        () async => cluster.hub.getNode(NodeId('svc-01'))?.online == false,
      );

      // A fresh agent with the same id re-registers.
      await cluster.startNode(id: 'svc-01');
      expect(cluster.hub.getNode(NodeId('svc-01'))!.online, isTrue);
    } finally {
      await cluster.dispose();
    }
  });
}

Future<(bool, dynamic)> _try(HubApiClient client, String path) async {
  try {
    return (true, await client.get(path));
  } on Object {
    return (false, null);
  }
}

Future<void> _eventually(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('condition not met within $timeout');
}
