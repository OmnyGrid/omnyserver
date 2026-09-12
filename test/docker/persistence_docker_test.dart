@TestOn('vm')
@Tags(['docker'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'fleet.dart';

/// What survives the Hub's process dying.
///
/// `--data-dir` exists so that restarting a Hub is an interruption rather than
/// an amnesia. Only a real restart shows it: the in-process suite constructs
/// repositories directly and never loses the isolate that holds them.
void main() {
  late OmnyFleet fleet;
  late Directory data;

  setUp(() async {
    if (await OmnyFleet.unavailableReason() != null) return;
    fleet = await OmnyFleet.start();
    data = Directory.systemTemp.createTempSync('omnyserver-fleet-data');
  });

  tearDown(() async {
    if (await OmnyFleet.unavailableReason() != null) return;
    await fleet.dispose();
    if (data.existsSync()) data.deleteSync(recursive: true);
  });

  test('a restarted Hub remembers the fleet and its credentials', () async {
    if (await skipWithoutDocker()) return;
    final hub = await fleet.startHub(dataDir: data);
    await fleet.startNode(id: 'worker-a', labels: const {'env': 'prod'});

    String? issuedToken;
    final admin = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await admin.get('/nodes') as List).length,
        (count) => count == 1,
        what: 'the node to register',
      );

      final grant =
          await admin.post('/grants', {
                'principal': 'bob',
                'roles': ['viewer'],
              })
              as Map;
      issuedToken = grant['token'] as String;

      await admin.post('/presets', {
        'id': 'docker-host',
        'name': 'Docker Host',
        'steps': [
          {'formula': 'docker', 'action': 'verify'},
        ],
      });
    } finally {
      admin.close();
    }

    // The Hub goes away entirely — not a reconnect, a new process.
    await fleet.stop(hub);
    await fleet.startHub(dataDir: data);

    final after = fleet.apiClient();
    try {
      final nodes = await fleet.eventually(
        () async => (await after.get('/nodes') as List).cast<Map>(),
        (nodes) => nodes.isNotEmpty,
        what: 'the restarted Hub to report the fleet it knew',
      );
      expect(nodes.single['nodeId'], 'worker-a');
      expect((nodes.single['labels'] as Map)['env'], 'prod');

      final presets = (await after.get('/presets') as List).cast<Map>();
      expect(presets.single['id'], 'docker-host');
    } finally {
      after.close();
    }

    // A credential issued before the restart still authenticates after it —
    // otherwise every `grant add` would be undone by a deploy.
    final asBob = fleet.apiClient(principal: 'bob', token: issuedToken);
    try {
      expect(await asBob.get('/presets'), hasLength(1));
    } finally {
      asBob.close();
    }
  });

  test('an ephemeral Hub deliberately forgets', () async {
    if (await skipWithoutDocker()) return;
    // The counterpart, and the reason --ephemeral is a flag rather than a
    // default: what it drops, it drops on purpose.
    final hub = await fleet.startHub();

    final admin = fleet.apiClient();
    try {
      await admin.post('/presets', {
        'id': 'docker-host',
        'name': 'Docker Host',
        'steps': const [],
      });
      expect(await admin.get('/presets'), hasLength(1));
    } finally {
      admin.close();
    }

    await fleet.stop(hub);
    await fleet.startHub();

    final after = fleet.apiClient();
    try {
      final presets = await fleet.eventually(
        () async => await after.get('/presets') as List,
        (presets) => true,
        what: 'the restarted Hub to answer',
      );
      expect(presets, isEmpty);
    } finally {
      after.close();
    }
  });

  test('a node outlives the Hub and re-registers itself', () async {
    if (await skipWithoutDocker()) return;
    // The node container is never touched here: only the Hub restarts. The
    // agent has to notice, back off, and come back on its own.
    final hub = await fleet.startHub(dataDir: data);
    await fleet.startNode(id: 'worker-a');

    final admin = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await admin.get('/nodes/worker-a') as Map)['online'],
        (online) => online == true,
        what: 'the node to register',
      );
    } finally {
      admin.close();
    }

    await fleet.stop(hub);
    await fleet.startHub(dataDir: data);

    final after = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await after.get('/nodes/worker-a') as Map)['online'],
        (online) => online == true,
        timeout: const Duration(seconds: 60),
        what: 'the node to reconnect to the new Hub',
      );
    } finally {
      after.close();
    }
  });
}
