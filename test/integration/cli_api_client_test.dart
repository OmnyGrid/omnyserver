@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart'
    show NodeFormulaService, FormulaRegistry, CommandExecutor, ExecResult;
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
  test('the CLI API client lists nodes and runs a formula', () async {
    final cluster = await TestCluster.start();
    final api = HttpApiServer(hub: cluster.hub, host: '127.0.0.1', port: 0);
    await api.start();

    final service = NodeFormulaService(
      registry: FormulaRegistry.standard(executor: _PresentExecutor()),
    );
    await cluster.startNode(id: 'edge-01', formulaHandler: service.runFormula);

    final client = HubApiClient(Uri.parse('http://127.0.0.1:${api.boundPort}'));
    try {
      final nodes = (await client.get('/nodes') as List).cast<Map>();
      expect(nodes.single['nodeId'], 'edge-01');

      final result = await client.post('/nodes/edge-01/formula', {
        'formula': 'docker',
        'action': 'verify',
      });
      expect((result as Map)['result']['success'], isTrue);
    } finally {
      client.close();
      await api.close();
      await cluster.dispose();
    }
  });

  test('buildRunner registers the documented commands', () {
    final runner = buildRunner();
    expect(
      runner.commands.keys,
      containsAll(['hub', 'node', 'nodes', 'preset', 'formula', 'cert']),
    );
  });
}
