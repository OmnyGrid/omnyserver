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

  test('node status authenticates with --principal and --token', () async {
    // What `omnyserver node status worker-01 --principal alice --token
    // admin-token` sends: the Hub's own grant, not its master API token.
    final cluster = await TestCluster.start();
    final api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
    await cluster.startNode(id: 'worker-01');

    final base = Uri.parse('http://127.0.0.1:${api.boundPort}');
    final alice = HubApiClient(base, principal: 'alice', token: 'admin-token');
    final node = HubApiClient(
      base,
      principal: 'node-account',
      token: 'node-token',
    );
    try {
      // A node's status lands with its first heartbeat, so 404 until then; any
      // other failure (401/403) is the auth answer this test is about.
      final status = await _untilPresent(
        () => alice.get('/nodes/worker-01/status'),
      );
      expect((status as Map)['os'], isNotNull);

      // The same command with a node's grant: authenticated, but not an
      // operator — the node fleet cannot inspect itself through the API.
      await expectLater(
        node.get('/nodes/worker-01/status'),
        throwsA(
          isA<HubApiException>().having((e) => e.statusCode, 'status', 403),
        ),
      );
    } finally {
      alice.close();
      node.close();
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
    // Every API command takes a grant credential, not just the API token.
    for (final command in ['status', 'restart']) {
      final options =
          runner.commands['node']!.subcommands[command]!.argParser.options;
      expect(options, contains('principal'), reason: 'node $command');
      expect(options, contains('token'), reason: 'node $command');
    }
  });
}

/// Retries [request] while the resource is merely absent (404), so a test can
/// wait for a node's first heartbeat without swallowing an auth failure.
Future<dynamic> _untilPresent(
  Future<dynamic> Function() request, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      return await request();
    } on HubApiException catch (e) {
      if (e.statusCode != 404 || DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
}
