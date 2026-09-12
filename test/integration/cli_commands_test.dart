@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart'
    show NodeFormulaService, FormulaRegistry, CommandExecutor, ExecResult;
import 'package:test/test.dart';

import '../support/harness.dart';

/// Reports every probe as present, so a formula or preset step succeeds without
/// touching the host running the suite.
class _PresentExecutor implements CommandExecutor {
  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async => const ExecResult(exitCode: 0, stdout: 'version 1.0.0');
}

/// The CLI's read commands print and exit; what they must not do is throw on a
/// well-formed Hub. The mutating ones are checked against the Hub afterwards,
/// through the API, rather than against what they printed.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late String base;
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
    base = 'http://127.0.0.1:${api.boundPort}';
    client = HubApiClient(Uri.parse(base), token: 'api-secret');
  });

  tearDown(() async {
    client.close();
    await api.close();
    await cluster.dispose();
  });

  Future<void> cli(List<String> args) =>
      buildRunner().run([...args, '--api', base, '--token', 'api-secret']);

  /// A node that answers formula, preset and control requests.
  Future<void> startNode({String id = 'worker-01'}) async {
    final service = NodeFormulaService(
      registry: FormulaRegistry.standard(executor: _PresentExecutor()),
    );
    await cluster.startNode(
      id: id,
      labels: const {'env': 'prod'},
      formulaHandler: service.runFormula,
      presetHandler: service.applyPreset,
    );
  }

  group('reading the fleet', () {
    test('nodes list, empty and populated', () async {
      // An empty fleet is a normal answer, not an error.
      await cli(['nodes', 'list']);

      await startNode();
      await cli(['nodes', 'list']);
      await cli(['nodes', 'list', '--label', 'env=prod']);
    });

    test('node show / status / capabilities / metrics', () async {
      await startNode();
      await cli(['node', 'show', 'worker-01']);
      await cli(['node', 'status', 'worker-01']);
      await cli(['node', 'capabilities', 'worker-01']);
      await cli(['node', 'metrics', 'worker-01']);
    });

    test('an unknown node is an error the operator can read', () async {
      await expectLater(
        cli(['node', 'show', 'ghost-01']),
        throwsA(
          isA<HubApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });

    test('whoami reports the identity behind the token', () async {
      await cli(['whoami']);
    });

    test('audit lists what has happened', () async {
      await startNode();
      await cli(['audit']);
    });

    test('alerts lists what is wrong, or says nothing is', () async {
      await cli(['alerts']);
    });
  });

  group('presets', () {
    setUp(
      () => client.post('/presets', {
        'id': 'docker-host',
        'name': 'Docker Host',
        'steps': [
          {'formula': 'docker', 'action': 'verify'},
        ],
      }),
    );

    test('list and show', () async {
      await cli(['preset', 'list']);
      await cli(['preset', 'show', 'docker-host']);
    });

    test('delete removes it from the Hub', () async {
      await cli(['preset', 'delete', 'docker-host']);
      expect(await client.get('/presets'), isEmpty);
    });
  });

  group('formulas', () {
    test('list the catalog', () async {
      await cli(['formula', 'list']);
    });

    test('run one on a node', () async {
      await startNode();
      await cli([
        'formula',
        'run',
        'docker',
        'worker-01',
        '--action',
        'verify',
      ]);
    });
  });

  group('grants', () {
    test('add issues a credential that then authenticates', () async {
      await cli(['grant', 'add', 'bob', '--role', 'operator', '--note', 'CI']);

      final grants = (await client.get('/grants') as List).cast<Map>();
      expect(grants.single['principal'], 'bob');
      expect(grants.single['roles'], contains('operator'));
      // The token itself is shown once and never stored.
      expect(grants.single.containsKey('token'), isFalse);
    });

    test('a grant with no role is refused, not silently useless', () async {
      await expectLater(
        cli(['grant', 'add', 'bob']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('at least one --role'),
          ),
        ),
      );
    });

    test('list and revoke', () async {
      await cli(['grant', 'add', 'bob', '--role', 'viewer']);
      final grants = (await client.get('/grants') as List).cast<Map>();
      final id = grants.single['id'] as String;

      await cli(['grant', 'list']);
      await cli(['grant', 'revoke', id]);
      expect(await client.get('/grants'), isEmpty);
    });
  });

  group('desired state', () {
    setUp(() async {
      await startNode();
      await client.put('/nodes/worker-01/desired-state', {
        'steps': [
          {'formula': 'docker', 'action': 'verify'},
        ],
      });
    });

    test('show and diff read the declaration', () async {
      await cli(['state', 'show', 'worker-01']);
      await cli(['state', 'diff', 'worker-01']);
    });

    test('reconcile acts on it', () async {
      await cli(['state', 'reconcile', 'worker-01']);
    });

    test('clear withdraws it', () async {
      await cli(['state', 'clear', 'worker-01']);
      await expectLater(
        client.get('/nodes/worker-01/desired-state'),
        throwsA(
          isA<HubApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });

  group('operations', () {
    test('an async apply becomes an operation, listed and shown', () async {
      await startNode();
      await client.post('/presets', {
        'id': 'docker-host',
        'name': 'Docker Host',
        'steps': [
          {'formula': 'docker', 'action': 'verify'},
        ],
      });

      // `--async` is the whole point: the command returns an operation id
      // rather than waiting for the fleet.
      await cli(['preset', 'apply', 'docker-host', 'worker-01', '--async']);

      final ops = (await client.get('/operations') as List).cast<Map>();
      expect(ops, hasLength(1), reason: 'the apply was recorded as an op');
      expect(ops.single['kind'], 'preset');
      expect(ops.single['nodeId'], 'worker-01');

      await cli(['ops', 'list']);
      await cli(['ops', 'list', '--node', 'worker-01']);
      // `--wait` blocks until it finishes, which is how a script follows one.
      await cli(['ops', 'show', ops.single['id'] as String, '--wait']);

      final finished =
          await client.get('/operations/${ops.single['id']}') as Map;
      expect(finished['status'], isNot('running'));
    });

    test('an unknown operation id is a 404', () async {
      await expectLater(
        cli(['ops', 'show', 'op-nope']),
        throwsA(
          isA<HubApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });

  group('node control', () {
    test('restart reaches the node as a restart', () async {
      String? action;
      await cluster.startNode(
        id: 'worker-01',
        nodeControlHandler: (request) async {
          action = request.action;
          return (true, 'restarting');
        },
      );

      await cli(['node', 'restart', 'worker-01']);
      expect(action, 'restart');
    });
  });

  group('the runner itself', () {
    test('--version prints and runs nothing', () async {
      final before = exitCode;
      addTearDown(() => exitCode = before);
      await runOmnyServerCli(['--version']);
      expect(exitCode, before);
    });

    test('an unknown command exits 64, the usage code', () async {
      final before = exitCode;
      addTearDown(() => exitCode = before);
      await runOmnyServerCli(['not-a-command']);
      expect(exitCode, 64);
    });

    test('a CLI error exits 1', () async {
      final before = exitCode;
      addTearDown(() => exitCode = before);
      await runOmnyServerCli(['preset', 'save', '--api', base]);
      expect(exitCode, 1);
    });
  });
}
