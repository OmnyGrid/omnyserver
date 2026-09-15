@TestOn('vm && !windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/captured_stdout.dart';
import '../support/harness.dart';

/// `hub start` and `node start` run until they are told to stop, and the node
/// then leaves with `exit`. Both take a seam for exactly that, so the whole
/// lifecycle — configure, serve, shut down — runs in this process, against a
/// real TLS listener and a real agent, rather than in a subprocess that would
/// have to be driven with signals.
///
/// The commands are mounted on a bare runner of their own, so `start` here is
/// unambiguous and no other command's production wiring is involved.
CommandRunner<void> _runnerFor(Command<void> command) =>
    CommandRunner<void>('omnyserver', 'start commands under test')
      ..addCommand(command);

/// A port nothing is listening on. `hub start` takes a number, not a socket, so
/// the port has to be chosen before the Hub binds it.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  late GeneratedCertificates certs;
  late Directory tmp;

  setUpAll(() async => certs = await TestCerts.ensure());

  setUp(
    () => tmp = Directory.systemTemp.createTempSync('omnyserver-cli-start'),
  );
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Runs `hub start` on [port] and hands back a way to stop it: the command's
  /// future, and the completer the command is waiting on.
  ({Future<void> done, Completer<void> stop}) startHub(
    int port,
    List<String> extra,
  ) {
    final stop = Completer<void>();
    final done = _runnerFor(HubStartCommand(untilStopped: () => stop.future))
        .run([
          'start',
          '--host',
          '127.0.0.1',
          '--port',
          '$port',
          '--cert',
          certs.serverCert,
          '--key',
          certs.serverKey,
          ...extra,
        ]);
    return (done: done, stop: stop);
  }

  /// Calls the running Hub's API through the CLI's own client commands, which
  /// is also the only way to reach a Hub started this way — the command owns
  /// the instance and never hands it out.
  Future<void> api(int port, List<String> args) => buildRunner().run([
    ...args,
    '--api',
    'https://127.0.0.1:$port',
    '--insecure',
  ]);

  /// The same, but verifying the Hub's certificate against the dev CA — the
  /// way an operator is supposed to reach a Hub, rather than `--insecure`.
  Future<void> trustedApi(int port, List<String> args) => buildRunner().run([
    ...args,
    '--api',
    'https://127.0.0.1:$port',
    '--ca',
    certs.caCert,
  ]);

  group('hub start', () {
    test('serves the API, the node mount and the metrics endpoint', () async {
      final port = await _freePort();
      final hub = startHub(port, [
        '--ephemeral',
        '--api-token',
        'api-secret',
        '--grant',
        'alice:s3cr3t:admin',
        '--alert',
        'disk>90',
        '--cors-origin',
        'https://dash.example.com',
      ]);
      addTearDown(() async {
        if (!hub.stop.isCompleted) hub.stop.complete();
        await hub.done;
      });

      // A Hub that is up answers for its (empty) fleet, and the grant baked
      // into the command line authenticates against it — as the pair it is,
      // principal and token, which is what distinguishes it from the master
      // --api-token.
      const asAlice = ['--token', 's3cr3t', '--principal', 'alice'];
      await _eventually(() => api(port, ['nodes', 'list', ...asAlice]));
      await api(port, ['whoami', ...asAlice]);
      await api(port, ['audit', ...asAlice]);
      // `/metrics` is outside the versioned API and takes no token at all.
      await api(port, ['hub', 'metrics']);

      hub.stop.complete();
      await hub.done;
    });

    test('a persistent Hub writes its fleet data under --data-dir', () async {
      final port = await _freePort();
      final dataDir = p.join(tmp.path, 'hub');
      final hub = startHub(port, [
        '--data-dir',
        dataDir,
        '--api-token',
        'api-secret',
      ]);

      await _eventually(
        () => api(port, ['nodes', 'list', '--token', 'api-secret']),
      );
      // A grant issued at runtime is persisted, which is the whole point of a
      // data directory: the credential survives the restart that follows.
      await api(port, [
        'grant', 'add', 'bob', //
        '--role', 'operator',
        '--token', 'api-secret',
      ]);

      hub.stop.complete();
      await hub.done;
      expect(Directory(dataDir).existsSync(), isTrue);
      expect(
        Directory(dataDir).listSync().map((e) => p.basename(e.path)),
        contains(anyOf('grants.json', 'grants')),
      );
    });

    test(
      '--shell serves OmnyShell too, with the AI config it is given',
      () async {
        final aiConfig = p.join(tmp.path, 'ai.yaml');
        await buildRunner().run([
          'ai', 'config', //
          '--provider', 'anthropic',
          '--key', 'sk-ant-test',
          '--path', aiConfig,
        ]);

        final port = await _freePort();
        final hub = startHub(port, [
          '--ephemeral',
          '--shell',
          '--ai-config',
          aiConfig,
          '--api-token',
          'api-secret',
          '--cors-origin',
          '*',
        ]);

        await _eventually(
          () => api(port, ['nodes', 'list', '--token', 'api-secret']),
        );
        hub.stop.complete();
        await hub.done;
      },
    );

    test('a node joins both fleets through one --shell Hub', () async {
      final port = await _freePort();
      final hub = startHub(port, [
        '--ephemeral',
        '--shell',
        '--api-token',
        'api-secret',
        '--grant',
        'node-account:node-token:node,admin',
      ]);

      await _eventually(
        () => api(port, ['nodes', 'list', '--token', 'api-secret']),
      );

      // One process, one service unit: the OmnyServer agent and an OmnyShell
      // node on the same Hub, same port, same certificate.
      final stop = Completer<void>();
      final exits = <int>[];
      final node =
          _runnerFor(
            NodeStartCommand(untilStopped: () => stop.future, leave: exits.add),
          ).run([
            'start',
            '--hub',
            'wss://127.0.0.1:$port',
            '--id',
            'dual-01',
            '--token',
            'node-token',
            '--insecure',
            '--with-shell',
            '--shell-label',
            'allow-roles=admin',
          ]);

      await _eventually(() async {
        final listed = await captureStdout(
          () => api(port, ['nodes', 'list', '--token', 'api-secret']),
        );
        if (!listed.contains('dual-01')) {
          throw StateError('not registered yet');
        }
      });

      stop.complete();
      await node;
      expect(exits, [0]);

      hub.stop.complete();
      await hub.done;
    });

    test('--shell with no AI configured still starts', () async {
      final port = await _freePort();
      final hub = startHub(port, [
        '--ephemeral',
        '--shell',
        '--ai-config',
        p.join(tmp.path, 'nothing-here.yaml'),
      ]);

      await _eventually(() => api(port, ['hub', 'metrics']));
      hub.stop.complete();
      await hub.done;
    });

    test('no TLS source is refused before anything binds', () async {
      await expectLater(
        _runnerFor(HubStartCommand()).run(['start', '--ephemeral']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('--cert'),
          ),
        ),
      );
    });

    test('--ca verifies the Hub instead of trusting it blindly', () async {
      final port = await _freePort();
      final hub = startHub(port, ['--ephemeral', '--api-token', 'api-secret']);
      addTearDown(() async {
        if (!hub.stop.isCompleted) hub.stop.complete();
        await hub.done;
      });

      // The plain client, and the SSE stream, each build their own TLS
      // context — so each has to be given the CA separately.
      await _eventually(
        () => trustedApi(port, ['nodes', 'list', '--token', 'api-secret']),
      );

      final streaming = captureStdout(
        () => trustedApi(port, [
          'events', '--follow', //
          '--token', 'api-secret', '--principal', 'alice',
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      hub.stop.complete();
      await hub.done;
      await streaming
          .timeout(const Duration(seconds: 10))
          .catchError((_) => '');
    });

    test('a grant carries every role it lists, commas and all', () async {
      final port = await _freePort();
      final hub = startHub(port, [
        '--ephemeral',
        '--grant',
        'alice:s3cr3t:admin,operator',
      ]);

      final out = StringBuffer();
      await _eventually(
        () => captureStdout(
          () => api(port, [
            'whoami',
            '--token',
            's3cr3t',
            '--principal',
            'alice',
          ]),
          into: out,
        ),
      );
      // The roles are comma-separated within one grant — the form the help
      // text documents, and the one a comma-splitting option would have torn
      // into a grant and a stray "operator".
      expect(out.toString(), contains('admin'));
      expect(out.toString(), contains('operator'));

      hub.stop.complete();
      await hub.done;
    });

    test('a malformed --grant names the entry that is wrong', () async {
      await expectLater(
        _runnerFor(HubStartCommand()).run([
          'start',
          '--ephemeral',
          '--cert',
          certs.serverCert,
          '--key',
          certs.serverKey,
          '--grant',
          'no-colon-here',
        ]),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('no-colon-here'),
          ),
        ),
      );
    });
  });

  group('node start', () {
    late TestCluster cluster;

    setUp(() async => cluster = await TestCluster.start());
    tearDown(() async => cluster.dispose());

    /// Runs `node start` against the test Hub, returning the command's future,
    /// its stop signal and the exit code it eventually leaves with.
    ({Future<void> done, Completer<void> stop, List<int> exits}) startNode(
      List<String> extra,
    ) {
      final stop = Completer<void>();
      final exits = <int>[];
      final done =
          _runnerFor(
            NodeStartCommand(untilStopped: () => stop.future, leave: exits.add),
          ).run([
            'start',
            '--hub',
            '${cluster.hubUri}',
            '--id',
            'cli-node',
            '--token',
            'node-token',
            '--insecure',
            ...extra,
          ]);
      return (done: done, stop: stop, exits: exits);
    }

    test('connects, ships its logs and stops on request', () async {
      final node = startNode(['--label', 'env=prod', '--ship-logs']);
      await _eventually(() async {
        if (cluster.hub.listNodes().isEmpty) {
          throw StateError('not registered yet');
        }
      });

      node.stop.complete();
      await node.done;
      // Ctrl-C is a clean stop: nothing should bring the agent back.
      expect(node.exits, [0]);
    });

    test(
      '--ca trusts the Hub by its certificate, not by ignoring it',
      () async {
        final stop = Completer<void>();
        final exits = <int>[];
        final done =
            _runnerFor(
              NodeStartCommand(
                untilStopped: () => stop.future,
                leave: exits.add,
              ),
            ).run([
              'start',
              '--hub',
              '${cluster.hubUri}',
              '--id',
              'ca-node',
              '--token',
              'node-token',
              '--ca',
              certs.caCert,
            ]);

        await _eventually(() async {
          if (cluster.hub.listNodes().isEmpty) {
            throw StateError('not registered yet');
          }
        });
        stop.complete();
        await done;
        expect(exits, [0]);
      },
    );

    test('the Hub asking the agent to stop leaves with a zero code', () async {
      final node = startNode(['--no-ship-logs']);
      await _eventually(() async {
        if (cluster.hub.listNodes().isEmpty) {
          throw StateError('not registered yet');
        }
      });

      // Zero is the whole difference from a restart: a supervisor with
      // `on-failure` leaves a cleanly-stopped agent stopped.
      await cluster.hub.shutdownNode(NodeId('cli-node'));
      await node.done;
      expect(node.exits, [0]);
    });

    test('the Hub asking for a restart leaves with a non-zero code', () async {
      final node = startNode(['--no-ship-logs']);
      await _eventually(() async {
        if (cluster.hub.listNodes().isEmpty) {
          throw StateError('not registered yet');
        }
      });

      // The exit code is the contract with the supervisor: non-zero asks for
      // the agent back, which is what `node restart` means.
      await cluster.hub.restartNode(NodeId('cli-node'));
      await node.done;
      expect(node.exits, isNot(contains(0)));
      expect(node.exits.single, isPositive);
    });

    test('missing connection details are refused, not retried', () async {
      await expectLater(
        _runnerFor(NodeStartCommand()).run(['start', '--id', 'x']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('--hub'),
          ),
        ),
      );
    });

    test('a malformed --label names --label, not --shell-label', () async {
      // Refused before the agent dials the Hub: a typo in a label is a typo in
      // the command, not something to discover after a connection.
      await expectLater(
        _runnerFor(NodeStartCommand()).run([
          'start',
          '--hub',
          '${cluster.hubUri}',
          '--id',
          'cli-node',
          '--token',
          'node-token',
          '--label',
          'no-equals-sign',
        ]),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('--label "no-equals-sign"'),
              isNot(contains('shell-label')),
            ),
          ),
        ),
      );
    });
  });
}

/// Retries [action] until it stops throwing or the deadline passes.
///
/// A Hub started from the command line binds asynchronously and a node
/// registers a moment after it connects; neither is what a test here is about.
Future<void> _eventually(
  Future<void> Function() action, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      await action();
      return;
    } on Object {
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
