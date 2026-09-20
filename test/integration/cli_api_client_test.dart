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

/// [HubApiClient], against a real Hub.
///
/// Every method here decodes a reply the Hub actually produced, which is the
/// only way to catch the failure that matters: a field the API names one way
/// and the client reads another. A fixture would agree with whatever the client
/// expects, and go on agreeing after the Hub changed.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late HubApiClient client;

  setUp(() async {
    cluster = await TestCluster.start();
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
    client = HubApiClient(
      Uri.parse('http://127.0.0.1:${api.boundPort}'),
      token: 'api-secret',
    );
  });

  tearDown(() async {
    client.close();
    await api.close();
    await cluster.dispose();
  });

  group('reading the fleet', () {
    test('nodes and a formula run come back as entities', () async {
      final service = NodeFormulaService(
        registry: FormulaRegistry.standard(executor: _PresentExecutor()),
      );
      await cluster.startNode(
        id: 'edge-01',
        formulaHandler: service.runFormula,
      );

      final nodes = await client.nodes();
      expect(nodes.single.id.value, 'edge-01');
      expect(nodes.single.online, isTrue);

      final reply = await client.runFormula(
        'edge-01',
        formula: 'docker',
        action: FormulaAction.verify,
      );
      expect(reply.result.success, isTrue);
    });

    test('the catalogue decodes, actions and all', () async {
      final formulas = await client.formulas();
      final docker = formulas.firstWhere((f) => f.id.value == 'docker');
      expect(docker.actions, contains(FormulaAction.restart));
    });

    test('an unknown node is a 404, not a decode failure', () async {
      await expectLater(
        client.node('ghost'),
        throwsA(
          isA<HubApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });

  group('absence is a value, not an exception', () {
    // Only where absence is ordinary. A caller made to catch a `404` will
    // sooner or later catch the wrong one — the node that does not exist, say,
    // rather than the status that has not arrived.
    test('a node that has not heartbeated has no status', () async {
      await cluster.startNode(id: 'worker-01');
      // Either null (not yet) or a real status (already arrived); what must
      // not happen is a throw.
      expect(await client.nodeStatus('worker-01'), anyOf(isNull, isNotNull));
    });

    test('a node nobody declared anything about has no drift', () async {
      await cluster.startNode(id: 'worker-01');
      expect(await client.drift('worker-01'), isNull);
      expect(await client.desiredState('worker-01'), isNull);
    });

    test('and it fills in once something is declared', () async {
      await cluster.startNode(id: 'worker-01');
      await client.declareSteps('worker-01', [
        PresetStep(formula: FormulaId('docker')),
      ]);

      expect((await client.desiredState('worker-01'))!.steps, hasLength(1));
      expect((await client.drift('worker-01'))!.converged, isFalse);

      await client.undeclare('worker-01');
      expect(await client.drift('worker-01'), isNull);
    });
  });

  group('the query string', () {
    test('reaches the Hub as a query, not as part of the path', () async {
      // `Uri.replace(path:)` percent-encodes a `?`, which buried the whole
      // query inside the path and made `/nodes/x/metrics?since=1h` match no
      // route at all — a 404 for every parameterised endpoint.
      await cluster.startNode(id: 'worker-01');
      expect(await client.metrics('worker-01', limit: 1), isA<List>());
    });

    test('repeated selectors stay repeated, and all must match', () async {
      // Collapsing `label=a&label=b` into one comma-joined value would widen
      // the selection silently — the worst direction for a fleet command.
      await cluster.startNode(
        id: 'prod-eu',
        labels: const {'env': 'prod', 'region': 'eu'},
      );
      await cluster.startNode(
        id: 'prod-us',
        labels: const {'env': 'prod', 'region': 'us'},
      );

      expect(await client.nodes(labels: ['env=prod']), hasLength(2));
      final both = await client.nodes(labels: ['env=prod', 'region=eu']);
      expect(both.single.id.value, 'prod-eu');
    });

    test('a selector value with an = in it survives encoding', () async {
      await cluster.startNode(id: 'tagged', labels: const {'note': 'a=b'});
      final matched = await client.nodes(labels: ['note=a=b']);
      expect(matched.single.id.value, 'tagged');
    });
  });

  group('converging', () {
    test('a preset declaration reports its steps, counted', () async {
      // The Hub answers `/reconcile` in two shapes. This is the preset one: a
      // list of step results and no counts, so `ConvergeResult` derives them.
      final service = NodeFormulaService(
        registry: FormulaRegistry.standard(executor: _PresentExecutor()),
      );
      await cluster.startNode(
        id: 'worker-01',
        formulaHandler: service.runFormula,
        presetHandler: service.applyPreset,
      );
      await client.declareSteps('worker-01', [
        PresetStep(formula: FormulaId('dart')),
      ]);

      final result = await client.reconcile('worker-01');
      expect(result.success, isTrue);
      expect(result.results, isNotEmpty);
      expect(
        result.changes,
        isEmpty,
        reason: 'exactly one shape is ever filled',
      );
    });

    test('applying a preset needs exactly one of id or document', () async {
      // Sending both, or neither, is a caller mistake that the Hub would answer
      // with a 400 after a round trip. Caught here, with the argument names.
      await cluster.startNode(id: 'worker-01');
      expect(
        () => client.applyPreset('worker-01'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => client.applyPreset(
          'worker-01',
          presetId: 'x',
          preset: Preset(id: PresetId('x'), name: 'x'),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('credentials', () {
    test('an issued grant carries its token, once', () async {
      final issued = await client.issueGrant(
        principal: 'ci',
        roles: const {'viewer'},
        note: 'a test',
      );

      expect(issued.grant.principal.value, 'ci');
      expect(issued.grant.roles, contains('viewer'));
      expect(issued.token, isNotEmpty);

      // The list carries the hash, never the token.
      final listed = await client.grants();
      expect(listed.single.id, issued.id);
      expect(listed.single.tokenHash, isNot(issued.token));

      await client.revokeGrant(issued.id);
      expect(await client.grants(), isEmpty);
    });

    test('whoami reports the roles the Hub resolved', () async {
      final me = await client.whoami();
      expect(me.authenticated, isTrue);
      expect(me.canOperate, isTrue);
    });
  });

  group('who may do what', () {
    test(
      'a node credential is authenticated but cannot read the fleet',
      () async {
        // What `omnyserver node status worker-01 --principal … --token …` sends:
        // the Hub's own grant, not its master API token.
        await cluster.startNode(id: 'worker-01');
        final base = Uri.parse('http://127.0.0.1:${api.boundPort}');
        final node = HubApiClient(
          base,
          principal: 'node-account',
          token: 'node-token',
        );
        try {
          await expectLater(
            node.nodeStatus('worker-01'),
            throwsA(
              isA<HubApiException>().having((e) => e.statusCode, 'status', 403),
            ),
          );
        } finally {
          node.close();
        }
      },
    );

    test('a grant reads the fleet as itself', () async {
      await cluster.startNode(id: 'worker-01');
      final base = Uri.parse('http://127.0.0.1:${api.boundPort}');
      final alice = HubApiClient(
        base,
        principal: 'alice',
        token: 'admin-token',
      );
      try {
        expect((await alice.whoami()).principal, 'alice');
        expect(await alice.nodes(), hasLength(1));
      } finally {
        alice.close();
      }
    });
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
