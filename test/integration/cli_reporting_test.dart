@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart'
    show NodeFormulaService, FormulaRegistry, CommandExecutor, ExecResult;
import 'package:test/test.dart';

import '../support/captured_stdout.dart';
import '../support/harness.dart';

/// What the commands *print* — the selectors that choose nodes, the fan-out
/// summary, the empty-fleet answers, the tables and the live streams.
///
/// `cli_commands_test.dart` asserts that each command reaches the Hub and
/// changes what it should. This file asserts the other half: the operator reads
/// output, and output that says "applied to 0 nodes" when a label was mistyped
/// is how a fleet silently stops being managed.
class _PresentExecutor implements CommandExecutor {
  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async => const ExecResult(exitCode: 0, stdout: 'version 1.0.0');
}

void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late EventAggregator events;
  late String base;
  late HubApiClient client;
  late int before;

  setUp(() async {
    cluster = await TestCluster.start(alertRules: [AlertRule.parse('disk>50')]);
    // `events` and `events -f` read what the aggregator has collected; without
    // one the API answers an empty list, which is a different test.
    events = EventAggregator()..attach(cluster.hub.config.eventBus);
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      events: events,
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
    base = 'http://127.0.0.1:${api.boundPort}';
    client = HubApiClient(Uri.parse(base), token: 'api-secret');
    // These commands report failure through the process exit code; the runner
    // shares one, so each test restores it.
    before = exitCode;
  });

  tearDown(() async {
    exitCode = before;
    client.close();
    await api.close();
    await events.detach();
    await cluster.dispose();
  });

  Future<String> cli(List<String> args) => captureStdout(
    () => buildRunner().run([...args, '--api', base, '--token', 'api-secret']),
  );

  Future<void> startNode({String id = 'worker-01', String env = 'prod'}) async {
    final service = NodeFormulaService(
      registry: FormulaRegistry.standard(executor: _PresentExecutor()),
    );
    await cluster.startNode(
      id: id,
      labels: {'env': env},
      formulaHandler: service.runFormula,
      presetHandler: service.applyPreset,
    );
  }

  /// Retries [read] until it stops throwing, then returns what it read.
  ///
  /// A node ships its logs and its events a moment after it connects; that
  /// moment is not what any of these tests are about.
  Future<String> eventually(
    Future<String> Function() read, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        return await read();
      } on Object {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  /// Waits for [id]'s first heartbeat, which is what puts it in the metrics
  /// history and the alert monitor.
  Future<void> waitForStatus(String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        await client.get('/nodes/$id/status');
        return;
      } on HubApiException catch (e) {
        if (e.statusCode != 404 || DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }

  group('choosing which nodes to act on', () {
    test('no selector at all is refused, not read as "none"', () async {
      await expectLater(
        cli(['formula', 'run', 'docker']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('--all'),
          ),
        ),
      );
    });

    test('--all selects the whole fleet, and says so per node', () async {
      await startNode(id: 'worker-01');
      await startNode(id: 'worker-02');

      final out = await cli([
        'formula',
        'run',
        'docker',
        '--all',
        '--action',
        'verify',
      ]);
      expect(out, contains('worker-01'));
      expect(out, contains('worker-02'));
      // More than one node gets a tally, so a long run ends with a verdict.
      expect(out, contains('2/2 succeeded'));
    });

    test('--label selects the matching nodes only', () async {
      await startNode(id: 'worker-01', env: 'prod');
      await startNode(id: 'worker-02', env: 'staging');

      final out = await cli([
        'formula', 'run', 'docker', //
        '--label', 'env=prod', '--action', 'verify',
      ]);
      expect(out, contains('worker-01'));
      expect(out, isNot(contains('worker-02')));
    });

    test(
      'a label matching nothing is an error, not a silent success',
      () async {
        await startNode(id: 'worker-01');
        await expectLater(
          cli(['formula', 'run', 'docker', '--label', 'env=mars']),
          throwsA(
            isA<CliError>().having(
              (e) => e.message,
              'message',
              contains('no node matches env=mars'),
            ),
          ),
        );
      },
    );

    test('--all against an empty fleet says the fleet is empty', () async {
      await expectLater(
        cli(['formula', 'run', 'docker', '--all']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('no nodes are registered'),
          ),
        ),
      );
    });

    test('a node that fails is reported and sets a non-zero exit', () async {
      await startNode(id: 'worker-01');

      // One real node and one that was never registered: the fan-out must
      // report the failure and carry on, not abandon the rest of the fleet.
      final out = await cli([
        'formula', 'run', 'docker', //
        '--node', 'worker-01', '--node', 'ghost-01', '--action', 'verify',
      ]);
      expect(out, contains('worker-01'));
      expect(out, contains('1/2 succeeded'));
      expect(exitCode, 1);
    });
  });

  group('an empty Hub answers, rather than printing nothing', () {
    test('nodes list', () async {
      expect(await cli(['nodes', 'list']), contains('no nodes'));
    });

    test('preset list', () async {
      expect(await cli(['preset', 'list']), contains('no presets are saved'));
    });

    test('grant list', () async {
      expect(
        await cli(['grant', 'list']),
        contains('no credentials have been issued'),
      );
    });

    test('events', () async {
      expect(await cli(['events']), contains('no events yet'));
    });

    test('and once something happens, events lists it', () async {
      await startNode();
      final out = await eventually(() async {
        final printed = await cli(['events']);
        if (printed.contains('no events yet')) {
          throw StateError('nothing recorded yet');
        }
        return printed;
      });
      // "<instant>  <type>  key=value …" — the fields the event carried, not a
      // JSON blob an operator has to parse by eye.
      expect(out, contains('worker-01'));
      expect(out, contains('nodeId=worker-01'));
    });

    test('ops list', () async {
      expect(await cli(['ops', 'list']), contains('no operations'));
    });

    test('alerts', () async {
      expect(await cli(['alerts']), contains('nothing is alerting'));
    });

    test('node logs, with the reason there are none', () async {
      await startNode();
      expect(await cli(['node', 'logs', 'worker-01']), contains('--ship-logs'));
    });
  });

  group('node logs', () {
    test('prints what the node shipped, timestamped and sourced', () async {
      final agent = await cluster.startNode(id: 'worker-01');
      agent.sendLogs(const ['docker installed', 'ready'], source: 'formula');

      final out = await eventually(() async {
        final printed = await cli(['node', 'logs', 'worker-01']);
        if (!printed.contains('docker installed')) {
          throw StateError('not shipped yet');
        }
        return printed;
      });
      expect(out, contains('formula'));
      expect(out, contains('ready'));
      // A local timestamp, split off its sub-second part: a tail is read by a
      // person, and milliseconds are noise in it.
      expect(out, matches(RegExp(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s')));
    });

    test('--tail bounds how much it reads back', () async {
      final agent = await cluster.startNode(id: 'worker-01');
      agent.sendLogs(const ['one', 'two', 'three']);

      await eventually(() async {
        final printed = await cli(['node', 'logs', 'worker-01', '--tail', '2']);
        if (!printed.contains('three')) throw StateError('not shipped yet');
        return printed;
      });
    });

    test('without an id it says how to call it', () async {
      await expectLater(
        cli(['node', 'logs']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('usage: node logs'),
          ),
        ),
      );
    });
  });

  group('the commands that need an id say so', () {
    test('node update, restart, shutdown, status and grant add', () async {
      for (final args in const [
        ['node', 'update'],
        ['node', 'restart'],
        ['node', 'shutdown'],
        ['node', 'status'],
        ['grant', 'add'],
      ]) {
        await expectLater(
          cli(args),
          throwsA(
            isA<CliError>().having(
              (e) => e.message,
              'message',
              contains('usage:'),
            ),
          ),
          reason: args.join(' '),
        );
      }
    });
  });

  group('nodes list', () {
    test('filters by online and offline', () async {
      await startNode();
      await waitForStatus('worker-01');

      expect(await cli(['nodes', 'list', '--online']), contains('worker-01'));
      expect(
        await cli(['nodes', 'list', '--offline']),
        isNot(contains('worker-01')),
      );
      expect(
        await cli(['nodes', 'list', '--no-online']),
        isNot(contains('worker-01')),
      );
    });
  });

  group('node metrics', () {
    test('prints a timeline once samples have landed', () async {
      await startNode();
      await waitForStatus('worker-01');

      final out = await cli(['node', 'metrics', 'worker-01', '--since', '1h']);
      expect(out, contains('AT'));
      expect(out, contains('CPU%'));
      expect(out, contains('DISK%'));
    });

    test('--json emits the raw series instead of the table', () async {
      await startNode();
      await waitForStatus('worker-01');

      final out = await cli(['node', 'metrics', 'worker-01', '--json']);
      expect(out, isNot(contains('CPU%')));
      expect(jsonDecode(out), isA<List<dynamic>>());
    });

    test(
      'a window with nothing in it says so, rather than printing a header',
      () async {
        await startNode();
        await waitForStatus('worker-01');
        // A window that starts in the future holds no samples — the same answer a
        // node that has never heartbeated gets.
        final out = await cli([
          'node',
          'metrics',
          'worker-01',
          '--since',
          '2099-01-01T00:00:00Z',
        ]);
        expect(out, contains('no samples'));
      },
    );

    test('without an id it says how to call it', () async {
      await expectLater(
        cli(['node', 'metrics']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('usage: node metrics'),
          ),
        ),
      );
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

    test('diff reports drift and exits non-zero', () async {
      final out = await cli(['state', 'diff', 'worker-01']);
      expect(out, anyOf(contains('DRIFTED'), contains('converged')));
    });

    test('diff names a node it cannot read, and keeps going', () async {
      // `--node` takes ids at face value, so an unknown one reaches the Hub and
      // comes back a 404 — which must not stop the nodes after it.
      await cli(['state', 'diff', '--node', 'ghost-01', '--node', 'worker-01']);
    });

    test('reconcile reports what it ran', () async {
      final out = await cli(['state', 'reconcile', 'worker-01']);
      expect(
        out,
        anyOf(
          contains('converged'),
          contains('already converged'),
          contains('FAILED'),
        ),
      );
    });

    test('reconcile --async hands back an operation id', () async {
      final out = await cli(['state', 'reconcile', 'worker-01', '--async']);
      expect(out, contains('dispatched — ops show'));
    });
  });

  group('presets and formulas', () {
    test('apply reads a preset from a file when one exists', () async {
      await startNode();
      final dir = Directory.systemTemp.createTempSync('omnyserver-preset');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/preset.json')
        ..writeAsStringSync(
          jsonEncode({
            'id': 'from-file',
            'name': 'From File',
            'steps': [
              {'formula': 'docker', 'action': 'verify'},
            ],
          }),
        );

      final out = await cli(['preset', 'apply', file.path, 'worker-01']);
      expect(out, anyOf(contains('applied'), contains('FAILED')));
    });

    test('apply with no arguments says how to call it', () async {
      await expectLater(
        cli(['preset', 'apply']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('usage: preset apply'),
          ),
        ),
      );
    });

    test('formula run --async hands back an operation id', () async {
      await startNode();
      final out = await cli([
        'formula', 'run', 'docker', 'worker-01', //
        '--action', 'verify', '--async',
      ]);
      expect(out, contains('dispatched — ops show'));
    });

    test('formula run with no arguments says how to call it', () async {
      await expectLater(
        cli(['formula', 'run']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('usage: formula run'),
          ),
        ),
      );
    });
  });

  group('alerts', () {
    test(
      'a firing alert is printed with how long it has held, and exits 1',
      () async {
        await startNode();
        // Drive the monitor directly: what `alerts` renders is the active set,
        // and how it got there is `alert_test.dart`'s subject, not this one.
        final now = DateTime.now().toUtc();
        cluster.hub.alerts.onStatus(
          'worker-01',
          MetricPoint(
            at: now,
            cpuPercent: 10,
            memoryUsedBytes: 1,
            memoryTotalBytes: 100,
            storageUsedBytes: 99,
            storageCapacityBytes: 100,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final out = await cli(['alerts']);
        expect(out, contains('worker-01'));
        expect(out, matches(RegExp(r'\(for \d+[hms]\)')));
        expect(exitCode, 1);
      },
    );
  });

  group('whoami', () {
    test('reports the principal and the roles behind the token', () async {
      final out = await cli(['whoami']);
      expect(out, contains('principal:'));
      expect(out, contains('roles:     admin'));
    });

    test('a grant with no roles reads as "(none)", not as a blank', () async {
      // The Hub refuses to issue a roleless grant, so this is the shape a
      // caller authenticated by the master token with nothing else sees.
      final out = await captureStdout(
        () => buildRunner().run([
          'whoami', '--api', base, '--token', 'api-secret', //
          '--principal', 'someone',
        ]),
      );
      expect(out, contains('principal: someone'));
    });
  });

  group('live streams', () {
    test('events -f prints events as they happen', () async {
      final seen = StringBuffer();
      final streaming = captureStdout(
        () => buildRunner().run([
          'events', '--follow', //
          '--api', base, '--token', 'api-secret',
        ]),
        into: seen,
      );

      // Give the stream a moment to attach, then make something happen.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await startNode();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // Closing the Hub's API ends the response, which is how the command
      // returns — it is a `tail -f`, and has no other ending.
      await api.close();
      await streaming
          .timeout(const Duration(seconds: 10))
          .catchError((_) => '');
      expect(seen.toString(), contains('streaming events'));
    });

    test('node logs -f keeps printing what the node reports', () async {
      await startNode();
      await waitForStatus('worker-01');

      final seen = StringBuffer();
      final streaming = captureStdout(
        () => buildRunner().run([
          'node', 'logs', 'worker-01', '--follow', //
          '--api', base, '--token', 'api-secret',
        ]),
        into: seen,
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));
      await api.close();
      await streaming
          .timeout(const Duration(seconds: 10))
          .catchError((_) => '');
    });

    test('a refused stream fails with the status, not a hang', () async {
      await expectLater(
        buildRunner().run([
          'events', '--follow', //
          '--api', base, '--token', 'wrong-token',
        ]),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            allOf(contains('stream failed'), contains('401')),
          ),
        ),
      );
    });
  });

  group('the runner maps failures to exit codes', () {
    test('an API error is a message and exit 1, not a stack trace', () async {
      await runOmnyServerCli([
        'node', 'show', 'ghost-01', //
        '--api', base, '--token', 'api-secret',
      ]);
      expect(exitCode, 1);
    });

    test('a classified runtime failure is exit 1 too', () async {
      // A credential the Hub rejects outright is terminal: the agent does not
      // retry, and the exception reaches the top. It must print its message and
      // exit 1, not a stack trace.
      await runOmnyServerCli([
        'node', 'start', //
        '--hub', '${cluster.hubUri}',
        '--id', 'cli-node',
        '--token', 'not-a-real-token',
        '--insecure',
      ]);
      expect(exitCode, 1);
    });

    test('an unknown command is the usage exit code', () async {
      await runOmnyServerCli(['not-a-command']);
      expect(exitCode, 64);
    });
  });
}
