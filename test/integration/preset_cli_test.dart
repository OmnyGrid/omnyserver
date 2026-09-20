@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart'
    show NodeFormulaService, FormulaRegistry, CommandExecutor, ExecResult;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/harness.dart';

/// Answers every probe as "already there", so a preset step succeeds without
/// touching the host — and remembers what it was asked to run, which is how a
/// test tells "the step reached the node" from "the call returned quietly".
class _RecordingExecutor implements CommandExecutor {
  final List<String> calls = [];

  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    calls.add([executable, ...args].join(' '));
    return const ExecResult(exitCode: 0, stdout: 'version 1.0.0');
  }
}

/// The commands under test read a preset from a path the user typed, so the
/// file on disk — not a fixture object — is the input that matters.
const _preset = {
  'id': 'docker-host',
  'name': 'Docker Host',
  'description': 'docker, verified',
  'steps': [
    {'formula': 'docker', 'action': 'verify'},
  ],
};

void main() {
  late Directory dir;
  late String presetPath;
  late TestCluster cluster;
  late HttpApiServer api;
  late String base;
  late HubApiClient client;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('omnyserver-preset-cli');
    presetPath = p.join(dir.path, 'preset.json');
    File(presetPath).writeAsStringSync(jsonEncode(_preset));

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
    dir.deleteSync(recursive: true);
  });

  /// Runs the real CLI in this isolate, against the Hub started above.
  Future<void> cli(List<String> args) =>
      buildRunner().run([...args, '--api', base, '--token', 'api-secret']);

  group('preset save', () {
    test('reads the file and saves what it holds on the Hub', () async {
      await cli(['preset', 'save', presetPath]);

      final saved = await client.presets();
      expect(saved.single.id.value, 'docker-host');

      final one = await client.preset('docker-host');
      expect(one.name, 'Docker Host');
      expect(one.steps.single.formula.value, 'docker');
    });

    test('a path that does not exist is a clear error, not a crash', () async {
      final missing = p.join(dir.path, 'nope.json');
      await expectLater(
        cli(['preset', 'save', missing]),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('preset file not found'),
          ),
        ),
      );
    });

    test('no argument at all prints the usage', () async {
      await expectLater(
        cli(['preset', 'save']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('usage: preset save'),
          ),
        ),
      );
    });
  });

  group('preset apply', () {
    late _RecordingExecutor executor;

    /// A node that can actually run a preset step, so an apply is observable at
    /// the far end rather than only at the API.
    Future<void> startExecutingNode() async {
      executor = _RecordingExecutor();
      final service = NodeFormulaService(
        registry: FormulaRegistry.standard(executor: executor),
      );
      await cluster.startNode(
        id: 'edge-01',
        formulaHandler: service.runFormula,
        presetHandler: service.applyPreset,
      );
    }

    test('applies a preset read from a file', () async {
      await startExecutingNode();

      // The file branch: the argument exists on disk, so the preset travels
      // with the request instead of being looked up by id.
      await cli(['preset', 'apply', presetPath, 'edge-01']);

      // CLI -> Hub -> node -> formula -> the host. Without this the command
      // could return happily having run nothing at all.
      expect(executor.calls, isNotEmpty);
      expect(executor.calls.first, contains('docker'));
    });

    test('applies a preset saved on the Hub, by id', () async {
      await startExecutingNode();
      await cli(['preset', 'save', presetPath]);

      // The other branch of the same argument: not a path, so it is an id —
      // the form worth using, since everyone resolves it to the same preset.
      await cli(['preset', 'apply', 'docker-host', 'edge-01']);

      expect(executor.calls, isNotEmpty);
      expect(executor.calls.first, contains('docker'));
    });

    test('an id that names no saved preset fails visibly', () async {
      await startExecutingNode();
      // Restored so one failing case cannot colour the whole test process.
      final before = exitCode;
      addTearDown(() => exitCode = before);

      // A fan-out does not throw — it reports each node and carries on, since
      // one bad node should not abandon the rest. The exit code is what is
      // left for a script to read, so that is the contract worth pinning.
      await cli(['preset', 'apply', 'no-such-preset', 'edge-01']);

      expect(exitCode, 1);
      expect(executor.calls, isEmpty, reason: 'nothing should have run');
    });
  });

  group('state set', () {
    test('declares the file-s preset as a node-s desired state', () async {
      await cluster.startNode(id: 'edge-01');
      await cli(['state', 'set', presetPath, 'edge-01']);

      // The preset is flattened into the steps the node is declared to hold.
      final desired = (await client.desiredState('edge-01'))!;
      expect(desired.steps.single.formula.value, 'docker');
      expect(desired.steps.single.action, FormulaAction.verify);
    });

    test('a path that does not exist is a clear error', () async {
      await cluster.startNode(id: 'edge-01');
      await expectLater(
        cli(['state', 'set', p.join(dir.path, 'nope.json'), 'edge-01']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('preset file not found'),
          ),
        ),
      );
    });

    test('no argument at all prints the usage', () async {
      await expectLater(
        cli(['state', 'set']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('usage: state set'),
          ),
        ),
      );
    });
  });
}
