@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

void main() {
  late TestCluster cluster;

  setUp(() async => cluster = await TestCluster.start());
  tearDown(() async => cluster.dispose());

  test('a node registers and appears online in the registry', () async {
    await cluster.startNode(id: 'worker-01', labels: {'env': 'test'});
    final nodes = cluster.hub.listNodes();
    expect(nodes, hasLength(1));
    expect(nodes.single.id.value, 'worker-01');
    expect(nodes.single.online, isTrue);
    expect(nodes.single.labels['env'], 'test');
  });

  test('heartbeats arrive and surface live status', () async {
    await cluster.startNode(id: 'worker-02');
    // Wait for at least one heartbeat (interval 200ms) to land status.
    await _eventually(() => cluster.hub.getStatus(NodeId('worker-02')) != null);
    final status = cluster.hub.getStatus(NodeId('worker-02'));
    expect(status, isNotNull);
    expect(status!.os.osName, isNotEmpty);
  });

  test('status is available immediately, without waiting for a heartbeat', () async {
    // Heartbeats are periodic, so the snapshot they carry is a full interval
    // away — on the production 15s cadence the Hub would report no status at all
    // for a node that just came up. The agent pushes one on registering instead.
    //
    // A long cadence is the whole point of this test: if it only passes because
    // a beat landed, it is not testing anything.
    final slow = await TestCluster.start(
      heartbeatInterval: const Duration(seconds: 30),
    );
    addTearDown(slow.dispose);

    await slow.startNode(id: 'worker-09');
    await _eventually(
      () => slow.hub.getStatus(NodeId('worker-09')) != null,
      timeout: const Duration(seconds: 5),
    );

    expect(slow.hub.getStatus(NodeId('worker-09'))!.os.osName, isNotEmpty);
  });

  test('an invalid token is rejected with an AuthException', () async {
    final agent = await cluster.buildNode(id: 'bad', token: 'wrong-token');
    await expectLater(agent.start(), throwsA(isA<AuthException>()));
    expect(agent.state, AgentState.authenticationFailed);
  });

  test('a node-control restart is acknowledged', () async {
    await cluster.startNode(
      id: 'worker-03',
      nodeControlHandler: (req) async => (true, 'restarting'),
    );
    await cluster.hub.restartNode(NodeId('worker-03'), principal: 'alice');
    // No exception ⇒ ack received.
    final audit = await cluster.hub.audit.recent();
    expect(audit.any((e) => e.action == 'node.restart'), isTrue);
  });

  test('emits NodeConnected and HeartbeatReceived events', () async {
    final events = <String>[];
    final sub = cluster.hub.events.listen((e) => events.add(e.type));
    await cluster.startNode(id: 'worker-04');
    await _eventually(() => events.contains('heartbeat.received'));
    expect(events, contains('node.connected'));
    await sub.cancel();
  });

  test('a disconnecting node is marked offline', () async {
    final agent = await cluster.startNode(id: 'worker-05');
    expect(cluster.hub.getNode(NodeId('worker-05'))!.online, isTrue);
    await agent.stop();
    await _eventually(
      () => cluster.hub.getNode(NodeId('worker-05'))?.online == false,
    );
    expect(cluster.hub.getNode(NodeId('worker-05'))!.online, isFalse);
  });
}

/// Polls [condition] until true or a timeout elapses.
Future<void> _eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('condition not met within $timeout');
}
