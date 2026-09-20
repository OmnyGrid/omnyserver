@TestOn('vm')
@Tags(['docker'])
@Timeout(Duration(minutes: 10))
library;

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:test/test.dart';

import 'fleet.dart';

/// The shared preset the blueprint below includes.
Preset _devTools(List<String> formulas) => Preset(
  id: PresetId('dev-tools'),
  name: 'Dev tools',
  steps: [for (final f in formulas) PresetStep(formula: FormulaId(f))],
);

/// A blueprint that includes it, plus whatever it declares of its own.
Blueprint _builder(List<String> formulas) => Blueprint(
  id: BlueprintId('builder'),
  name: 'Build host',
  includes: [PresetId('dev-tools')],
  resources: [
    for (final f in formulas)
      Resource(id: ResourceId('formula', f), ensure: Ensure.installed),
  ],
);

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
        client.nodes,
        (nodes) => nodes.length == 2 && nodes.every((n) => n.online),
        what: 'both nodes to register',
      );

      expect(
        nodes.map((n) => n.id.value),
        containsAll(['worker-a', 'worker-b']),
      );
      // Each node reported its own host, not the Hub's.
      final hostnames = {for (final node in nodes) node.platform.hostname};
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
        () async => (await client.nodes()).length,
        (count) => count == 2,
        what: 'both nodes to register',
      );

      final prod = await client.nodes(labels: ['env=prod']);
      expect(prod.single.id.value, 'prod-01');
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
        () async => {
          for (final node in await client.nodes())
            node.id.value: [
              for (final c in node.capabilities.capabilities) c.name,
            ],
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
      Future<bool> online() async => (await client.node('worker-a')).online;

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
        () async => (await client.nodes()).length,
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
        () async => (await client.nodes()).length,
        (count) => count == 2,
        what: 'both nodes to register',
      );

      final onSdk = await client.runFormula(
        'sdk-01',
        formula: 'dart',
        action: FormulaAction.verify,
      );
      expect(onSdk.result.success, isTrue);

      final onBare = await client.runFormula(
        'bare-01',
        formula: 'dart',
        action: FormulaAction.verify,
      );
      expect(
        onBare.result.success,
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
        () async => (await client.nodes()).length,
        (count) => count == 2,
        what: 'both nodes to register',
      );

      // Answered before the agent goes: an operator should see a confirmation,
      // not a dropped connection. Returning normally *is* the confirmation —
      // anything from 400 up would have thrown.
      await client.restartAgent('worker-a');
      await client.stopAgent('worker-b');

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

  test('a formula run can be watched on the node log, tagged', () async {
    if (await skipWithoutDocker()) return;
    // What the dashboard's Log button reads. The node tags each line with the
    // run that produced it and ships it to the Hub, so one run can be picked
    // out of a stream carrying everything the node says. Only a real agent
    // shipping to a real Hub proves the chain, since every link is a different
    // process.
    await fleet.startHub();
    await fleet.startNode(id: 'bare-01');

    final client = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await client.nodes()).length,
        (count) => count == 1,
        what: 'the node to register',
      );

      final result = (await client.runFormula(
        'bare-01',
        formula: 'procps',
        action: FormulaAction.install,
      )).result;
      expect(result.success, isTrue, reason: result.message);

      // The result keeps its own copy, so a run nobody watched is still
      // readable afterwards.
      expect(result.logs, isNotEmpty);
      expect(result.logs.first, contains('running'));

      // And the same output reached the Hub, tagged with exactly the string a
      // client builds from the operation's summary.
      final shipped = await fleet.eventually(
        () async => [
          for (final line in await client.logs('bare-01'))
            if (line.message.contains('[procps install]')) line.message,
        ],
        (lines) => lines.isNotEmpty,
        what: 'the run output to reach the Hub',
      );
      expect(shipped.length, greaterThan(1));
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the dart formula installs a Dart SDK that then runs', () async {
    if (await skipWithoutDocker()) return;
    // A formula step can name a package that does not exist and nothing will
    // say so until someone tries it on a real host: `apt-get install -y dart`
    // answered "E: Unable to locate package dart" on every Debian and Ubuntu
    // there has ever been, because the SDK lives in Google's own repository.
    // Only an actual install catches that, so this does one.
    await fleet.startHub();
    await fleet.startNode(id: 'bare-01');

    final client = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await client.nodes()).length,
        (count) => count == 1,
        what: 'the node to register',
      );

      final before = await client.runFormula(
        'bare-01',
        formula: 'dart',
        action: FormulaAction.verify,
      );
      expect(before.result.success, isFalse);

      final installed = await client.runFormula(
        'bare-01',
        formula: 'dart',
        action: FormulaAction.install,
      );
      expect(
        installed.result.success,
        isTrue,
        reason: installed.result.message,
      );
      expect(installed.result.changed, isTrue);

      // Installed, and the node can now prove it — the claim the Hub records.
      final after = await client.runFormula(
        'bare-01',
        formula: 'dart',
        action: FormulaAction.verify,
      );
      expect(after.result.success, isTrue);

      // And asking again changes nothing, rather than re-adding the repository.
      final again = await client.runFormula(
        'bare-01',
        formula: 'dart',
        action: FormulaAction.install,
      );
      expect(again.result.changed, isFalse);
      expect(again.result.message, contains('already'));
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a blueprint makes a real machine what it says', () async {
    if (await skipWithoutDocker()) return;
    // Everything else about blueprints is tested against fakes. This is the one
    // that can be wrong in a way nothing else catches: a plan that reads a real
    // machine, an apply that changes it, and a second plan that agrees the work
    // is done.
    await fleet.startHub();
    await fleet.startNode(id: 'bare-01');

    final client = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await client.nodes()).length,
        (count) => count == 1,
        what: 'the node to register',
      );

      // A shared preset, and a blueprint built from it plus one of its own.
      await client.savePreset(_devTools(['build-tools']));
      await client.saveBlueprint(_builder(['nmap']));
      await client.assignBlueprint('bare-01', 'builder');

      Future<Drift> plan() async => (await client.drift('bare-01'))!;

      // What the *machine* says, probed on the host itself — `gcc --version`,
      // `nmap --version` — rather than what the Hub believes about it.
      Future<Map<String, String>> onTheBox() async => {
        for (final report in await client.formulaStatus('bare-01'))
          report.formula.value: report.status.name,
      };

      // 1. Drifted, and the node is what said so — each change naming which
      //    document asked for it.
      final before = await plan();
      expect(before.converged, isFalse);
      expect(before.blueprint, 'builder');
      expect(
        {for (final c in before.changes) c.id.toString(): c.origin},
        {'formula:build-tools': 'preset:dev-tools', 'formula:nmap': 'local'},
      );

      expect(
        (await onTheBox())['nmap'],
        'absent',
        reason: 'nothing has been applied yet',
      );

      // 2. Apply, and the tools genuinely arrive on the host.
      final applied = await client.reconcile('bare-01');
      expect(applied.success, isTrue, reason: '${applied.changes}');
      expect(applied.changed, 2);

      final after = await onTheBox();
      expect(after['nmap'], 'installed');
      expect(after['build-tools'], 'installed');

      // 3. Converged, and applying again does nothing. This is the property the
      //    whole design rests on: if applying twice did the work twice, drift
      //    could not be the same comparison with the apply left off.
      expect((await plan()).converged, isTrue);
      expect((await client.reconcile('bare-01')).changed, 0);

      // 4. Drop nmap from the blueprint. The document no longer mentions it, so
      //    only the node's ledger can ask for its removal.
      await client.saveBlueprint(_builder(const []));

      final trimmed = await plan();
      expect(trimmed.converged, isFalse);
      final removal = trimmed.changes.singleWhere(
        (c) => c.kind == ChangeKind.remove,
      );
      expect(removal.id.toString(), 'formula:nmap');
      expect(removal.origin, 'ledger');

      await client.reconcile('bare-01');
      expect(
        (await onTheBox())['nmap'],
        'absent',
        reason: 'the ledger asked for it to go, and it went',
      );

      // 5. Edit the shared preset. The blueprint is not re-saved and nobody
      //    touches the node, and it drifts anyway — includes follow the preset.
      await client.savePreset(_devTools(['build-tools', 'net-tools']));

      final propagated = await plan();
      expect(propagated.converged, isFalse);
      expect(
        propagated.changes
            .singleWhere((c) => c.kind == ChangeKind.create)
            .id
            .toString(),
        'formula:net-tools',
      );
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a node reports what it actually has, before and after', () async {
    if (await skipWithoutDocker()) return;
    // The point of asking the node rather than reading the Hub's history: only
    // a real host can be wrong about this. Two images, the same question — the
    // slim one has no Dart and the SDK one does, and neither has a Docker
    // daemon, which is exactly the case a version probe gets wrong.
    await fleet.startHub();
    await fleet.startNode(id: 'bare-01');
    await fleet.startNode(id: 'sdk-01', sdk: true);

    final client = fleet.apiClient();
    try {
      await fleet.eventually(
        () async => (await client.nodes()).length,
        (count) => count == 2,
        what: 'both nodes to register',
      );

      Future<Map<String, String>> statusOf(String node) async => {
        for (final report in await client.formulaStatus(node))
          report.formula.value: report.status.name,
      };

      final bare = await statusOf('bare-01');
      final sdk = await statusOf('sdk-01');

      expect(bare['dart'], 'absent');
      expect(sdk['dart'], 'installed', reason: 'the SDK image ships one');

      // Not "stopped": neither container has a Docker daemon *or* the client,
      // and a node with nothing installed should not send an operator looking
      // for a start button.
      expect(bare['docker'], 'absent');

      // Now install something, and watch the same endpoint change its mind.
      final installed = await client.runFormula(
        'bare-01',
        formula: 'nmap',
        action: FormulaAction.install,
      );
      expect(
        installed.result.success,
        isTrue,
        reason: installed.result.message,
      );

      final after = await statusOf('bare-01');
      expect(after['nmap'], 'installed');
      expect(after['dart'], 'absent', reason: 'nothing else moved');
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

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
      // Null until the node's first heartbeat; -1 says "no status yet", which
      // is not the same as "a status reporting no processes".
      Future<int> processCount() async =>
          (await client.nodeStatus('bare-01'))?.processes.length ?? -1;

      await fleet.eventually(
        () async => (await client.nodes()).length,
        (count) => count == 1,
        what: 'the node to register',
      );
      // Wait for a status to exist at all before reading what is in it.
      await fleet.eventually(
        processCount,
        (count) => count >= 0,
        what: 'the node-s first status report',
      );
      expect(
        await processCount(),
        0,
        reason: 'the slim image has no ps for the monitor to call',
      );

      final result = (await client.runFormula(
        'bare-01',
        formula: 'procps',
        action: FormulaAction.install,
      )).result;
      expect(result.success, isTrue, reason: result.message);
      expect(result.changed, isTrue);

      // The next heartbeat carries a status gathered with a `ps` that now
      // exists — nothing had to restart for it.
      final count = await fleet.eventually(
        processCount,
        (count) => count > 0,
        what: 'the node to start reporting processes',
      );
      expect(count, greaterThan(0));

      // Asking again is a no-op rather than a second install.
      final again = await client.runFormula(
        'bare-01',
        formula: 'procps',
        action: FormulaAction.install,
      );
      expect(again.result.changed, isFalse);
      expect(again.result.message, contains('already'));
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
