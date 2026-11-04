@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/captured_stdout.dart';
import '../support/harness.dart';

/// The Hub and CLI surface a deploy pipeline stands on: per-node vars, what a
/// dispatched operation reports, how long the Hub waits, which nodes it will
/// send a blueprint to, and the exit codes a CI job reads.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late HubApiClient client;
  late String base;

  final app = Blueprint.fromJson({
    'blueprint': 'app',
    'name': 'App',
    'vars': {'version': '1.0.0', 'channel': 'stable'},
    'resources': [
      {
        'type': 'formula',
        'name': 'dart',
        'ensure': 'installed',
        'version': r'${version}',
      },
    ],
  });

  /// A planner whose single formula installs, or fails, on demand.
  BlueprintApplyResult answer(BlueprintApplyRequest r, {bool success = true}) =>
      BlueprintApplyResult(
        requestId: r.requestId,
        success: success,
        changes: [
          for (final res in r.blueprint.resources)
            ResourceChange(
              id: res.id,
              kind: success ? ChangeKind.update : ChangeKind.failed,
              reason: success
                  ? 'installed ${res.resource.version}'
                  : 'the package server said no',
            ),
        ],
        appliedHash: r.blueprint.hash,
      );

  Future<void> startApi({
    Duration requestTimeout = const Duration(seconds: 30),
    Duration operationTimeout = const Duration(minutes: 30),
  }) async {
    cluster = await TestCluster.start(
      requestTimeout: requestTimeout,
      operationTimeout: operationTimeout,
    );
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
    base = 'http://127.0.0.1:${api.boundPort}';
    client = HubApiClient(Uri.parse(base), token: 'api-secret');
    await client.saveBlueprint(app);
  }

  tearDown(() async {
    client.close();
    await api.close();
    await cluster.dispose();
    exitCode = 0;
    cliEnvironment = () => Platform.environment;
  });

  Future<String> cli(List<String> args, {bool flags = true}) => captureStdout(
    () => buildRunner().run([
      ...args,
      if (flags) ...['--api', base, '--token', 'api-secret'],
    ]),
  );

  group('per-node vars', () {
    final sent = <ResolvedBlueprint>[];

    setUp(() async {
      sent.clear();
      await startApi();
      await cluster.startNode(
        id: 'n1',
        blueprintApplyHandler: (r) async {
          sent.add(r.blueprint);
          return answer(r);
        },
      );
    });

    test(
      'are stored on the assignment and resolved into what is sent',
      () async {
        await client.assignBlueprint('n1', 'app', vars: {'version': '2.0.0'});
        await client.reconcile('n1');
        expect(sent.single.resources.single.resource.version, '2.0.0');

        final resolved = await client.resolvedBlueprint('app', node: 'n1');
        expect(resolved.resources.single.resource.version, '2.0.0');
        expect(
          (await client.resolvedBlueprint(
            'app',
          )).resources.single.resource.version,
          '1.0.0',
        );
      },
    );

    test('re-assigning the same blueprint without vars keeps them', () async {
      await client.assignBlueprint('n1', 'app', vars: {'version': '2.0.0'});
      await client.assignBlueprint('n1', 'app');
      expect((await client.desiredState('n1'))!.vars, {'version': '2.0.0'});

      // Sent explicitly, they replace.
      await client.assignBlueprint('n1', 'app', vars: {'channel': 'beta'});
      expect((await client.desiredState('n1'))!.vars, {'channel': 'beta'});
    });

    test('reconcile merges --set and --unset, and stores them', () async {
      await client.assignBlueprint(
        'n1',
        'app',
        vars: {'version': '2.0.0', 'channel': 'beta'},
      );
      await client.reconcile('n1', vars: {'version': '3.0.0'});
      expect((await client.desiredState('n1'))!.vars, {
        'version': '3.0.0',
        'channel': 'beta',
      });
      await client.reconcile('n1', unset: ['channel']);
      expect((await client.desiredState('n1'))!.vars, {'version': '3.0.0'});
      expect(sent.last.resources.single.resource.version, '3.0.0');
    });

    test('an undeclared var is a 400 naming the ones that exist', () async {
      await client.assignBlueprint('n1', 'app');
      await expectLater(
        client.reconcile('n1', vars: {'verison': '2'}),
        throwsA(
          isA<HubApiException>()
              .having((e) => e.statusCode, 'status', 400)
              .having(
                (e) => e.message,
                'message',
                contains('it declares channel, version'),
              ),
        ),
      );
      await expectLater(
        client.assignBlueprint('n1', 'app', vars: {'nope': '1'}),
        throwsA(isA<HubApiException>()),
      );
    });

    test('vars with a dry run, or with no blueprint, are refused', () async {
      await client.assignBlueprint('n1', 'app');
      await expectLater(
        client.reconcile('n1', dryRun: true, vars: {'version': '2'}),
        throwsA(
          isA<HubApiException>().having((e) => e.statusCode, 'status', 400),
        ),
      );
      await client.undeclare('n1');
      await client.declareSteps('n1', [PresetStep(formula: FormulaId('dart'))]);
      await expectLater(
        client.reconcile('n1', vars: {'version': '2'}),
        throwsA(
          isA<HubApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });

    test('resolved for a node not on that blueprint is a 404', () async {
      await expectLater(
        client.resolvedBlueprint('app', node: 'n1'),
        throwsA(
          isA<HubApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });

    test('the CLI sets, unsets and shows them', () async {
      await cli(['blueprint', 'assign', 'app', 'n1', '--set', 'version=4.0.0']);
      expect((await client.desiredState('n1'))!.vars, {'version': '4.0.0'});

      final shown = await cli(['blueprint', 'resolved', 'app', '--node', 'n1']);
      expect(shown, contains('vars on n1: version=4.0.0'));

      final out = await cli([
        'blueprint',
        'apply',
        'n1',
        '--set',
        'channel=beta',
        '--unset',
        'version',
      ]);
      expect(exitCode, 0, reason: out);
      expect((await client.desiredState('n1'))!.vars, {'channel': 'beta'});
    });

    test(
      'the CLI refuses a malformed --set, and --set with --dry-run',
      () async {
        await client.assignBlueprint('n1', 'app');
        await expectLater(
          cli(['blueprint', 'apply', 'n1', '--set', 'version']),
          throwsA(isA<CliError>()),
        );
        await expectLater(
          cli(['blueprint', 'apply', 'n1', '--dry-run', '--set', 'version=2']),
          throwsA(isA<CliError>()),
        );
        await expectLater(
          cli(['blueprint', 'apply', 'n1', '--async', '--wait']),
          throwsA(isA<CliError>()),
        );
        await expectLater(
          cli(['blueprint', 'apply', 'n1', '--follow-logs']),
          throwsA(isA<CliError>()),
        );
        await expectLater(
          cli(['blueprint', 'apply', 'n1', '--wait', '--timeout', 'soon']),
          throwsA(isA<CliError>()),
        );
      },
    );
  });

  group('exit codes', () {
    setUp(() async {
      await startApi();
      await cluster.startNode(
        id: 'n1',
        blueprintApplyHandler: (r) async => answer(r, success: false),
        presetHandler: (r) async => PresetApplyResult(
          requestId: r.requestId,
          success: false,
          results: [
            FormulaResult(
              formula: 'dart',
              action: FormulaAction.install,
              success: false,
              finishedAt: DateTime.now().toUtc(),
              message: 'nope',
            ),
          ],
        ),
        formulaHandler: (r) async => FormulaResult(
          formula: r.formula,
          action: r.action,
          success: false,
          finishedAt: DateTime.now().toUtc(),
          message: 'not on this platform',
        ),
      );
      await client.assignBlueprint('n1', 'app');
    });

    test('a failed blueprint apply exits 1, and says what failed', () async {
      final out = await cli(['blueprint', 'apply', 'n1']);
      expect(exitCode, 1);
      expect(out, contains('FAILED'));
      expect(out, contains('formula:dart  — the package server said no'));
    });

    test('so does a failed --wait, and the operation is failed', () async {
      final out = await cli(['blueprint', 'apply', 'n1', '--wait']);
      expect(exitCode, 1, reason: out);
      final op = (await client.operations()).first;
      expect(op.status, OperationStatus.failed);
      expect(op.error, 'formula:dart: the package server said no');

      exitCode = 0;
      await cli(['ops', 'show', op.id, '--wait']);
      expect(exitCode, 1);
    });

    test('state reconcile, formula run and preset apply exit 1 too', () async {
      await cli(['state', 'reconcile', 'n1']);
      expect(exitCode, 1);

      exitCode = 0;
      final run = await cli(['formula', 'run', 'dart', 'n1']);
      expect(exitCode, 1, reason: run);
      expect(run, contains('dart verify: FAILED'));

      exitCode = 0;
      await client.savePreset(
        Preset(
          id: PresetId('p'),
          name: 'p',
          steps: [PresetStep(formula: FormulaId('dart'))],
        ),
      );
      await cli(['preset', 'apply', 'p', 'n1']);
      expect(exitCode, 1);
    });

    test('a failed async formula run is a failed operation', () async {
      final op = await client.runFormulaAsync(
        'n1',
        formula: 'dart',
        action: FormulaAction.install,
      );
      var done = op;
      while (done.isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        done = await client.operation(op.id);
      }
      expect(done.status, OperationStatus.failed);
      expect(done.error, 'not on this platform');
    });
  });

  group('how long the Hub waits', () {
    test('a dispatched apply outlives the request timeout', () async {
      await startApi(
        requestTimeout: const Duration(milliseconds: 300),
        operationTimeout: const Duration(seconds: 10),
      );
      await cluster.startNode(
        id: 'slow',
        blueprintApplyHandler: (r) async {
          await Future<void>.delayed(const Duration(milliseconds: 900));
          return answer(r);
        },
      );
      await client.assignBlueprint('slow', 'app');

      // Held open over HTTP, it times out — that is the request timeout's job.
      await expectLater(
        client.reconcile('slow'),
        throwsA(isA<HubApiException>()),
      );

      // Dispatched, it is given the operation timeout, and finishes.
      final out = await cli(['blueprint', 'apply', 'slow', '--wait']);
      expect(exitCode, 0, reason: out);
      expect(out, contains('applied — 1 changed'));
    });
  });

  group('which nodes a blueprint is sent to', () {
    setUp(() => startApi());

    Blueprint restarting() => Blueprint.fromJson({
      'blueprint': 'svc',
      'name': 'svc',
      'resources': [
        {'type': 'formula', 'name': 'dart'},
        {
          'type': 'service',
          'name': 'api',
          'ensure': 'running',
          'exec': '/opt/x',
          'restartOn': ['formula:dart'],
        },
      ],
    });

    test('a node from before restartOn is refused one that uses it', () async {
      await cluster.startNode(
        id: 'old',
        blueprintApplyHandler: (r) async => answer(r),
      );
      await client.saveBlueprint(restarting());
      await client.assignBlueprint('old', 'svc');
      await expectLater(
        client.reconcile('old'),
        throwsA(
          isA<HubApiException>().having(
            (e) => e.message,
            'message',
            contains('does not support restartOn'),
          ),
        ),
      );
    });

    test('a node whose provider cannot restart is refused', () async {
      // Advertises a `service` provider that is not refreshable.
      await cluster.startNode(
        id: 'odd',
        capabilityProvider: () async => const NodeCapabilities([
          Capability(
            kind: CapabilityKind.custom,
            name: 'blueprint',
            details: {
              'providers': 'formula,service',
              'refreshable': '',
              'features': 'restartOn,rollback',
            },
          ),
        ]),
        blueprintApplyHandler: (r) async => answer(r),
      );
      await _until(
        () =>
            cluster.hub
                .getNode(NodeId('odd'))
                ?.capabilities
                .named('blueprint') !=
            null,
      );
      await client.saveBlueprint(restarting());
      await client.assignBlueprint('odd', 'svc');
      await expectLater(
        client.reconcile('odd'),
        throwsA(
          isA<HubApiException>().having(
            (e) => e.message,
            'message',
            contains('cannot restart a "service"'),
          ),
        ),
      );
    });
  });

  group('the connection, from the environment', () {
    setUp(() async {
      await startApi();
      await cluster.startNode(
        id: 'n1',
        blueprintApplyHandler: (r) async => answer(r),
      );
    });

    test(
      'OMNYSERVER_API and OMNYSERVER_TOKEN stand in for the flags',
      () async {
        cliEnvironment = () => {
          'OMNYSERVER_API': base,
          'OMNYSERVER_TOKEN': 'api-secret',
        };
        final out = await cli(['nodes', 'list'], flags: false);
        expect(out, contains('n1'));
      },
    );

    test('a flag wins over the environment', () async {
      cliEnvironment = () => {
        'OMNYSERVER_API': 'http://127.0.0.1:1',
        'OMNYSERVER_TOKEN': 'wrong',
      };
      final out = await cli(['nodes', 'list']);
      expect(out, contains('n1'));
    });

    test('the token never appears in --help', () async {
      cliEnvironment = () => {'OMNYSERVER_TOKEN': 'super-secret'};
      // Usage goes through `print`, not `stdout`.
      final printed = StringBuffer();
      await runZoned(
        () => buildRunner().run(['nodes', 'list', '--help']),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.writeln(line),
        ),
      );
      final help = printed.toString();
      expect(help, contains('OMNYSERVER_TOKEN'));
      expect(help, isNot(contains('super-secret')));
    });
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within 10s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
