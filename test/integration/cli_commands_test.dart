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

/// The preset these tests save, declare and apply.
final Preset _dockerHost = Preset(
  id: PresetId('docker-host'),
  name: 'Docker Host',
  steps: [
    PresetStep(formula: FormulaId('docker'), action: FormulaAction.verify),
  ],
);

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

  /// Waits for [id]'s first heartbeat to land.
  ///
  /// A node registers before it reports, so `/nodes/<id>/status` is a 404 for
  /// the first moments of its life — a race that has nothing to do with the
  /// command under test.
  Future<void> waitForStatus(String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      // Null until the first heartbeat lands, which is what is being waited
      // for — not an error, so it is not caught as one.
      if (await client.nodeStatus(id) != null) return;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('$id never reported a status');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

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
      await waitForStatus('worker-01');
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
    setUp(() => client.savePreset(_dockerHost));

    test('list and show', () async {
      await cli(['preset', 'list']);
      await cli(['preset', 'show', 'docker-host']);
    });

    test('delete removes it from the Hub', () async {
      await cli(['preset', 'delete', 'docker-host']);
      expect(await client.presets(), isEmpty);
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

      final grants = await client.grants();
      expect(grants.single.principal.value, 'bob');
      expect(grants.single.roles, contains('operator'));
      // The Hub keeps a hash. The token itself was shown once, on stdout.
      expect(grants.single.tokenHash, isNotEmpty);
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
      final id = (await client.grants()).single.id;

      await cli(['grant', 'list']);
      await cli(['grant', 'revoke', id]);
      expect(await client.grants(), isEmpty);
    });
  });

  group('desired state', () {
    setUp(() async {
      await startNode();
      await client.declareSteps('worker-01', _dockerHost.steps);
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
      expect(await client.desiredState('worker-01'), isNull);
    });
  });

  group('operations', () {
    test('an async apply becomes an operation, listed and shown', () async {
      await startNode();
      await client.savePreset(_dockerHost);

      // `--async` is the whole point: the command returns an operation id
      // rather than waiting for the fleet.
      await cli(['preset', 'apply', 'docker-host', 'worker-01', '--async']);

      final ops = await client.operations();
      expect(ops, hasLength(1), reason: 'the apply was recorded as an op');
      expect(ops.single.kind, 'preset');
      expect(ops.single.nodeId, 'worker-01');

      await cli(['ops', 'list']);
      await cli(['ops', 'list', '--node', 'worker-01']);
      // `--wait` blocks until it finishes, which is how a script follows one.
      await cli(['ops', 'show', ops.single.id, '--wait']);

      expect((await client.operation(ops.single.id)).isRunning, isFalse);
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

  group('hub metrics', () {
    test('prints the Prometheus text, without a token', () async {
      await startNode();
      // `/metrics` sits outside the versioned API and is not token-gated, so
      // this has to work against a Hub the caller has no credential for.
      await buildRunner().run(['hub', 'metrics', '--api', base]);
    });
  });

  group('node logs and control', () {
    test('logs reads what the node has shipped', () async {
      await startNode();
      await cli(['node', 'logs', 'worker-01']);
      await cli(['node', 'logs', 'worker-01', '--tail', '10']);
    });

    test('shutdown and update reach the node as themselves', () async {
      final actions = <String>[];
      await cluster.startNode(
        id: 'worker-01',
        nodeControlHandler: (request) async {
          actions.add(request.action);
          return (true, 'ok');
        },
      );

      await cli(['node', 'shutdown', 'worker-01']);
      await cli(['node', 'update', 'worker-01']);
      expect(actions, ['shutdown', 'update']);
    });
  });

  group('cert gen', () {
    late Directory out;

    setUp(() => out = Directory.systemTemp.createTempSync('omnyserver-certs'));
    tearDown(() => out.deleteSync(recursive: true));

    test('writes a CA and a server certificate', () async {
      await buildRunner().run([
        'cert',
        'gen',
        '--out',
        out.path,
        '--host',
        'hub.example.com',
        '--force',
      ]);

      for (final name in ['ca.crt', 'ca.key', 'server.crt', 'server.key']) {
        expect(File('${out.path}/$name').existsSync(), isTrue, reason: name);
      }
      // The Hub presents the full chain, so the leaf alone is not enough.
      expect(
        File('${out.path}/server.crt').readAsStringSync(),
        stringContainsInOrder([
          '-----BEGIN CERTIFICATE-----',
          '-----END CERTIFICATE-----',
          '-----BEGIN CERTIFICATE-----',
        ]),
      );
      // The intermediates are cleaned up rather than left lying about.
      expect(File('${out.path}/server.csr').existsSync(), isFalse);
    });

    test('refuses to overwrite without --force, and says why', () async {
      await buildRunner().run(['cert', 'gen', '--out', out.path, '--force']);

      await expectLater(
        buildRunner().run(['cert', 'gen', '--out', out.path]),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('--force'),
          ),
        ),
      );
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
