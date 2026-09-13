@TestOn('vm')
@Tags(['docker'])
@Timeout(Duration(minutes: 10))
library;

import 'package:test/test.dart';

import 'fleet.dart';

/// A Hub and several node containers on one network: the cases that only exist
/// once the fleet is spread across machines.
void main() {
  late OmnyFleet fleet;

  setUp(() async {
    if (await OmnyFleet.unavailableReason() != null) return;
    fleet = await OmnyFleet.start();
  });

  tearDown(() async {
    if (await OmnyFleet.unavailableReason() != null) return;
    await fleet.dispose();
  });

  test('two nodes on separate hosts join one fleet', () async {
    if (await skipWithoutDocker()) return;
    await fleet.startHub();
    await fleet.startNode(id: 'worker-a');
    await fleet.startNode(id: 'worker-b');

    final client = fleet.apiClient();
    try {
      final nodes = await fleet.eventually(
        () async => (await client.get('/nodes') as List).cast<Map>(),
        (nodes) => nodes.length == 2 && nodes.every((n) => n['online'] == true),
        what: 'both nodes to register',
      );

      expect(
        nodes.map((n) => n['nodeId']),
        containsAll(['worker-a', 'worker-b']),
      );
      // Each node reported its own host, not the Hub's.
      final hostnames = <String>{
        for (final node in nodes)
          ((node['platform'] as Map)['hostname'] as String),
      };
      expect(hostnames, hasLength(2));
    } finally {
      client.close();
    }
  });

  test('labels select a subset of the fleet', () async {
    if (await skipWithoutDocker()) return;
    await fleet.startHub();
    await fleet.startNode(id: 'prod-01', labels: const {'env': 'prod'});
    await fleet.startNode(id: 'staging-01', labels: const {'env': 'staging'});

    final client = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await client.get('/nodes') as List).length,
        (count) => count == 2,
        what: 'both nodes to register',
      );

      final prod = (await client.get('/nodes?label=env%3Dprod') as List)
          .cast<Map>();
      expect(prod.single['nodeId'], 'prod-01');
    } finally {
      client.close();
    }
  });

  test('a node advertises what its own host actually has', () async {
    if (await skipWithoutDocker()) return;
    // The same binary on two different hosts: one image carries the Dart SDK,
    // the other carries nothing. Capability detection has to tell them apart,
    // which is something no in-process test can show.
    await fleet.startHub();
    await fleet.startNode(id: 'bare-01');
    await fleet.startNode(id: 'sdk-01', sdk: true);

    final client = fleet.apiClient();
    try {
      final capabilities = await fleet.eventually(
        () async {
          final nodes = (await client.get('/nodes') as List).cast<Map>();
          return {
            for (final node in nodes)
              node['nodeId'] as String: [
                // `capabilities` is the NodeCapabilities object, which holds
                // the list under a key of the same name.
                for (final c
                    in ((node['capabilities'] as Map?)?['capabilities']
                            as List? ??
                        const []))
                  (c as Map)['name'] as String,
              ],
          };
        },
        // Wait for the SDK node to have reported something, not merely for
        // both to be listed: capabilities arrive with the registration, and
        // reading them a moment early would make this pass by accident.
        (found) => found.length == 2 && found['sdk-01']!.isNotEmpty,
        what: 'both nodes to report their capabilities',
      );

      expect(capabilities['sdk-01'], contains('dart'));
      expect(
        capabilities['bare-01'],
        isNot(contains('dart')),
        reason: 'the slim image has no Dart SDK to find',
      );
    } finally {
      client.close();
    }
  });

  test('a node that goes away is seen to go, and seen to come back', () async {
    if (await skipWithoutDocker()) return;
    await fleet.startHub();
    final node = await fleet.startNode(id: 'worker-a');

    final client = fleet.apiClient();
    try {
      Future<bool?> online() async =>
          ((await client.get('/nodes/worker-a') as Map)['online'] as bool?);

      await fleet.eventually(online, (up) => up == true, what: 'the node');

      // Killing the container is the case a loopback test cannot stage: the
      // socket dies with the process, on the far side of a real network.
      await fleet.stop(node);
      await fleet.eventually(
        online,
        (up) => up == false,
        what: 'the Hub to notice the node left',
      );

      await fleet.startNode(id: 'worker-a');
      await fleet.eventually(
        online,
        (up) => up == true,
        what: 'the node to come back',
      );
    } finally {
      client.close();
    }
  });

  test('an operator on a third host drives the fleet', () async {
    if (await skipWithoutDocker()) return;
    // No test process in the loop: a container running the same CLI an
    // operator would, against the Hub over TLS, from somewhere else entirely.
    await fleet.startHub();
    await fleet.startNode(id: 'worker-a', labels: const {'env': 'prod'});

    final client = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await client.get('/nodes') as List).length,
        (count) => count == 1,
        what: 'the node to register',
      );
    } finally {
      client.close();
    }

    final listed = await fleet.runCli(['nodes', 'list']);
    expect(listed, contains('worker-a'));

    final whoami = await fleet.runCli(['whoami']);
    expect(whoami, contains('alice'));
  });

  test('a formula runs on the node, not on the Hub', () async {
    if (await skipWithoutDocker()) return;
    // `dart verify` succeeds only where a Dart SDK is installed. Run against
    // both hosts, the answers have to differ — which is the proof that the work
    // happened on the node's own machine.
    await fleet.startHub();
    await fleet.startNode(id: 'sdk-01', sdk: true);
    await fleet.startNode(id: 'bare-01');

    final client = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await client.get('/nodes') as List).length,
        (count) => count == 2,
        what: 'both nodes to register',
      );

      final onSdk =
          await client.post('/nodes/sdk-01/formula', {
                'formula': 'dart',
                'action': 'verify',
              })
              as Map;
      expect((onSdk['result'] as Map)['success'], isTrue);

      final onBare =
          await client.post('/nodes/bare-01/formula', {
                'formula': 'dart',
                'action': 'verify',
              })
              as Map;
      expect(
        (onBare['result'] as Map)['success'],
        isFalse,
        reason: 'there is no Dart SDK on the slim image',
      );
    } finally {
      client.close();
    }
  });

  test('restart and shutdown stop the agent, and say so differently', () async {
    if (await skipWithoutDocker()) return;
    // These used to be acknowledged and dropped: the API answered "restarting"
    // and the agent carried on as if nothing had been asked. What separates
    // them now is the exit code the agent leaves with — that is what a
    // supervisor reads to decide whether to bring it back — so the exit code
    // is what this asserts, on a real process rather than a fake handler.
    await fleet.startHub();
    final restarting = await fleet.startNode(id: 'worker-a');
    final stopping = await fleet.startNode(id: 'worker-b');

    final client = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await client.get('/nodes') as List).length,
        (count) => count == 2,
        what: 'both nodes to register',
      );

      // Answered before the agent goes: an operator should see a confirmation,
      // not a dropped connection.
      final reply = await client.post('/nodes/worker-a/restart') as Map;
      expect(reply['status'], 'restarting');

      await client.post('/nodes/worker-b/shutdown');

      expect(
        await restarting.waitExit(),
        75,
        reason: 'non-zero, so `restart: on-failure` starts the agent again',
      );
      expect(
        await stopping.waitExit(),
        0,
        reason: 'a clean exit, so the same policy leaves it stopped',
      );
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('installing the process tools fills in the process table', () async {
    if (await skipWithoutDocker()) return;
    // The monitor reports processes by shelling out to `ps`, and degrades to an
    // empty list without it — so a node on a slim image reports its CPU and
    // memory perfectly well and no processes at all. This is the one case where
    // a formula's effect is visible in the node's own status afterwards, and it
    // needs a real host with a real package manager to show.
    await fleet.startHub();
    await fleet.startNode(id: 'bare-01');

    final client = fleet.apiClient();
    try {
      Future<int> processCount() async {
        final status = await client.get('/nodes/bare-01/status') as Map;
        // Absent rather than empty when there is nothing to report.
        return (status['processes'] as List? ?? const []).length;
      }

      await fleet.eventually(
        () async => (await client.get('/nodes') as List).length,
        (count) => count == 1,
        what: 'the node to register',
      );
      // Wait for a status to exist at all before reading what is in it.
      await fleet.eventually(
        () async => client.get('/nodes/bare-01/status'),
        (_) => true,
        what: 'the node-s first status report',
      );
      expect(
        await processCount(),
        0,
        reason: 'the slim image has no ps for the monitor to call',
      );

      final applied =
          await client.post('/nodes/bare-01/formula', {
                'formula': 'procps',
                'action': 'install',
              })
              as Map;
      final result = applied['result'] as Map;
      expect(result['success'], isTrue, reason: '${result['message']}');
      expect(result['changed'], isTrue);

      // The next heartbeat carries a status gathered with a `ps` that now
      // exists — nothing had to restart for it.
      final count = await fleet.eventually(
        processCount,
        (count) => count > 0,
        what: 'the node to start reporting processes',
      );
      expect(count, greaterThan(0));

      // Asking again is a no-op rather than a second install.
      final again =
          await client.post('/nodes/bare-01/formula', {
                'formula': 'procps',
                'action': 'install',
              })
              as Map;
      expect((again['result'] as Map)['changed'], isFalse);
      expect((again['result'] as Map)['message'], contains('already'));
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
