@TestOn('vm')
library;

import 'package:omnyhub/omnyhub.dart' as omnyhub;
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// What a node does with an operation the Hub sends it — including the ones it
/// was not configured for.
///
/// A node that cannot serve a request must answer saying so. Silence is the bad
/// outcome: the Hub waits out its timeout and the operator learns nothing about
/// why, which is indistinguishable from a node that has gone away.
void main() {
  late TestCluster cluster;

  setUp(() async => cluster = await TestCluster.start());
  tearDown(() => cluster.dispose());

  group('running a command on a node', () {
    test('returns the command output and its exit code', () async {
      await cluster.startNode(id: 'worker-01');

      final result = await cluster.hub.runCommand(
        NodeId('worker-01'),
        'echo',
        args: const ['hello'],
      );
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'hello');
    });

    test('a non-zero exit is reported, not raised', () async {
      await cluster.startNode(id: 'worker-01');

      final result = await cluster.hub.runCommand(
        NodeId('worker-01'),
        'sh',
        args: const ['-c', 'echo bad >&2; exit 3'],
      );
      expect(result.exitCode, 3);
      expect(result.stderr.trim(), 'bad');
    });

    // `echo` and `sh` are POSIX executables; on Windows the first is a shell
    // builtin and the second is absent, so `Process.run` cannot reach either.
  }, testOn: '!windows');

  group('running a command on a node', () {
    test('a command that does not exist comes back as 127, with why', () async {
      await cluster.startNode(id: 'worker-01');

      // The node cannot run it, and says so in the result rather than letting
      // the failure surface as a dead request.
      final result = await cluster.hub.runCommand(
        NodeId('worker-01'),
        'definitely-not-a-real-binary-xyz',
      );
      expect(result.exitCode, 127);
      expect(result.stderr, contains('failed to run command'));
    });
  });

  group('a node with no formula engine', () {
    test(
      'reports the formula as unsupported rather than failing silently',
      () async {
        // No formulaHandler: this node manages nothing.
        await cluster.startNode(id: 'bare-01');

        final reply = await cluster.hub.runFormula(
          NodeId('bare-01'),
          'docker',
          FormulaAction.verify,
        );
        expect(reply.result.success, isFalse);
        expect(reply.result.message, contains('not configured'));
        expect(reply.result.formula, 'docker');
        expect(reply.result.action, FormulaAction.verify);
      },
    );

    test(
      'reports an empty formula status, which is the truthful answer',
      () async {
        await cluster.startNode(id: 'bare-01');
        final statuses = await cluster.hub.formulaStatus(NodeId('bare-01'));
        expect(statuses, isEmpty);
      },
    );
  });

  group('node control', () {
    test('a handler that refuses is surfaced as a failed operation', () async {
      await cluster.startNode(
        id: 'worker-01',
        nodeControlHandler: (request) async => (false, 'busy installing'),
      );

      await expectLater(
        cluster.hub.restartNode(NodeId('worker-01')),
        throwsA(
          isA<OperationException>().having(
            (e) => e.message,
            'message',
            contains('busy installing'),
          ),
        ),
      );
    });

    test(
      'a node with no control handler acknowledges without acting',
      () async {
        await cluster.startNode(id: 'worker-01');
        await cluster.hub.shutdownNode(NodeId('worker-01'));
        // It is still there: an acknowledgement is not an action.
        expect(
          cluster.hub.listNodes().map((n) => n.id.value),
          contains('worker-01'),
        );
      },
    );

    test('control of an unknown node names the node', () async {
      await expectLater(
        cluster.hub.restartNode(NodeId('ghost-01')),
        throwsA(
          isA<NodeUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('ghost-01'),
          ),
        ),
      );
    });
  });

  group('the agent as an object', () {
    test(
      'a display name is used where it is set, and the id otherwise',
      () async {
        final named = NodeAgent(
          NodeAgentConfig(
            hubUri: cluster.hubUri,
            nodeId: 'worker-01',
            displayName: 'Web Frontend 01',
            credentials: TokenCredentialProvider(
              principal: 'node-account',
              token: 'node-token',
            ),
            securityContext: await TestCerts.trustContext(),
            onBadCertificate: (cert, host, port) => true,
          ),
        );
        addTearDown(named.stop);
        await named.start();

        final descriptor = cluster.hub.getNode(NodeId('worker-01'))!;
        expect(descriptor.displayName, 'Web Frontend 01');
      },
    );

    test('its state transitions are observable, and end at offline', () async {
      final agent = await cluster.buildNode(
        id: 'worker-01',
        token: 'node-token',
      );
      final seen = <AgentState>[];
      final sub = agent.states.listen(seen.add);
      addTearDown(sub.cancel);

      await agent.start();
      expect(agent.isConnected, isTrue);
      expect(agent.state, AgentState.connected);

      await agent.stop();
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains(AgentState.connected));
      expect(seen.last, AgentState.offline);
    });

    test('starting an already-started agent is a programming error', () async {
      final agent = await cluster.buildNode(
        id: 'worker-01',
        token: 'node-token',
      );
      addTearDown(agent.stop);
      await agent.start();

      expect(agent.start, throwsA(isA<StateError>()));
    });
  });

  group('the Hub refuses to be reconfigured while it is serving', () {
    test('services, middleware and outer middleware alike', () async {
      final hub = cluster.hub;
      expect(
        () => hub.registerService(
          omnyhub.RouterService(name: 'late', mount: '/late'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(() => hub.use((inner) => inner), throwsA(isA<StateError>()));
      expect(() => hub.useOuter((inner) => inner), throwsA(isA<StateError>()));
    });
  });
}
