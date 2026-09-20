@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart'
    show
        CommandExecutor,
        CommandFormula,
        CommandStep,
        ExecResult,
        FormulaProvider,
        FormulaRegistry,
        NodeBlueprintService,
        ProviderRegistry;
import 'package:test/test.dart';

import '../support/harness.dart';

/// A fake shell that remembers what it was told to install.
///
/// The node under test runs the **real** formula engine — `FormulaProvider` over
/// a real `FormulaRegistry` — so the only thing faked is the shell. Anything
/// less would test a mock of the thing that matters; anything more would run
/// `apt-get` on whatever machine the suite is on.
///
/// Remembering is the part that earns its keep. A stateless fake would report
/// every tool absent forever, so a node could never converge and half these
/// tests would pass for the wrong reason — the plan would keep saying `create`
/// and nobody would notice the apply had not worked.
///
/// Scoped to formulas whose probe is `<tool> --version` and whose install names
/// the tool, which is what makes "did this get installed?" answerable without
/// teaching the fake every package name on Debian.
class _ScriptedExecutor implements CommandExecutor {
  _ScriptedExecutor({Set<String> installed = const {}})
    : installed = {...installed};

  /// The tools this machine currently has.
  final Set<String> installed;

  /// Every command line this executor was asked to run.
  final List<String> calls = [];

  static const Set<String> _known = {'dart', 'nmap', 'docker', 'build-tools'};

  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    final line = '$executable ${args.join(' ')}';
    calls.add(line);

    // The verify probe: `dart --version`, `nmap --version`, `docker --version`.
    if (args.length == 1 && args.first == '--version') {
      return installed.contains(executable)
          ? ExecResult(exitCode: 0, stdout: '$executable version 1.2.3')
          : const ExecResult(exitCode: 127, stderr: 'not found');
    }

    // Anything else is an install or an uninstall, and it works. Which tool it
    // was is read off the command line — every install step names what it is
    // installing.
    final touched = _known.where(line.contains);
    final removing = line.contains('remove') || line.contains('uninstall');
    for (final tool in touched) {
      if (removing) {
        installed.remove(tool);
      } else {
        installed.add(tool);
      }
    }
    return const ExecResult(exitCode: 0, stdout: 'done');
  }
}

/// A real `CommandFormula` that works on every platform.
///
/// The built-in formulas deliberately have no Windows steps — `apt-get` is not
/// a thing there — so a test that used them would converge on Linux and macOS
/// and never on Windows, which says nothing about blueprints. These are real
/// formulas over the real engine, differing only in that the platform is not a
/// variable.
///
/// That the *built-ins* work through `FormulaProvider` is proven where it can
/// only be proven: on a real Linux host, in `test/docker/`.
class _AnywhereFormula extends CommandFormula {
  _AnywhereFormula(this.tool, {required super.executor});

  final String tool;

  @override
  FormulaSpec get spec => FormulaSpec(
    id: FormulaId(tool),
    name: tool,
    actions: const {
      FormulaAction.install,
      FormulaAction.update,
      FormulaAction.uninstall,
      FormulaAction.verify,
    },
  );

  @override
  CommandStep get verifyStep => CommandStep(tool, const ['--version']);

  @override
  CommandStep? stepFor(FormulaAction action, String osName) => switch (action) {
    FormulaAction.verify => verifyStep,
    FormulaAction.install ||
    FormulaAction.update => CommandStep('install-$tool', const []),
    FormulaAction.uninstall => CommandStep('remove-$tool', const []),
    // No service: start/stop/restart are genuinely unsupported, as they are for
    // every command formula the node ships.
    _ => null,
  };
}

/// Blueprints end to end: saved on the Hub, resolved from shared presets,
/// assigned to a node, planned by that node and applied.
///
/// A real Hub over real WSS with a real agent, so what is exercised is the
/// whole path — resolve, dispatch, provider, ledger — rather than the pieces
/// agreeing with each other in isolation.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late _ScriptedExecutor executor;

  setUp(() async {
    cluster = await TestCluster.start();
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
    executor = _ScriptedExecutor();
  });

  tearDown(() async {
    await api.close();
    await cluster.dispose();
  });

  Future<(int, dynamic)> send(
    String method,
    String path, [
    Object? body,
  ]) async {
    final client = HttpClient();
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    req.headers.set('authorization', 'Bearer api-secret');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    client.close();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  /// Starts a node running the real formula engine over the scripted shell.
  Future<NodeBlueprintService> startNode({String id = 'worker-01'}) async {
    final registry = FormulaRegistry();
    for (final tool in const ['dart', 'nmap', 'docker', 'build-tools']) {
      registry.register(_AnywhereFormula(tool, executor: executor));
    }
    final service = NodeBlueprintService(
      providers: ProviderRegistry.of([FormulaProvider(registry: registry)]),
    );
    await cluster.startNode(
      id: id,
      blueprintPlanHandler: service.plan,
      blueprintApplyHandler: service.apply,
    );
    return service;
  }

  Future<void> savePreset(String id, List<Map<String, String>> steps) async {
    final (status, _) = await send('POST', '/api/v1/presets', {
      'id': id,
      'name': id,
      'steps': steps,
    });
    expect(status, 200);
  }

  Future<void> saveBlueprint(Map<String, dynamic> blueprint) async {
    final (status, body) = await send('POST', '/api/v1/blueprints', blueprint);
    expect(status, 200, reason: '$body');
  }

  Future<Map> drift(String node) async {
    final (status, body) = await send('GET', '/api/v1/nodes/$node/drift');
    expect(status, 200, reason: '$body');
    return body as Map;
  }

  Future<Map> reconcile(String node, [Object? body]) async {
    final (status, reply) = await send(
      'POST',
      '/api/v1/nodes/$node/reconcile',
      body ?? const <String, dynamic>{},
    );
    expect(status, 200, reason: '$reply');
    return reply as Map;
  }

  group('saving a blueprint', () {
    test(
      'one that could never apply is refused while it is being written',
      () async {
        // The Hub resolves before it stores. A cycle caught here is a 400 with
        // the file still open; the same cycle caught on a node is a failure half
        // way through changing a real machine.
        final (status, body) = await send('POST', '/api/v1/blueprints', {
          'blueprint': 'broken',
          'name': 'Broken',
          'resources': [
            {
              'type': 'formula',
              'name': 'dart',
              'requires': ['formula:nmap'],
            },
            {
              'type': 'formula',
              'name': 'nmap',
              'requires': ['formula:dart'],
            },
          ],
        });

        expect(status, 400);
        expect((body as Map)['error']['message'], contains('dependency cycle'));
        final (listed, list) = await send('GET', '/api/v1/blueprints');
        expect(listed, 200);
        expect(list, isEmpty, reason: 'a refused blueprint must not be stored');
      },
    );

    test('an include naming a preset nobody saved is refused', () async {
      final (status, body) = await send('POST', '/api/v1/blueprints', {
        'blueprint': 'web',
        'name': 'Web',
        'includes': ['ghost'],
      });

      expect(status, 400);
      expect((body as Map)['error']['message'], contains('ghost'));
    });

    test('it can be listed, read back and deleted', () async {
      await saveBlueprint({
        'blueprint': 'builder',
        'name': 'Build host',
        'resources': [
          {'type': 'formula', 'name': 'nmap', 'ensure': 'installed'},
        ],
      });

      final (listed, list) = await send('GET', '/api/v1/blueprints');
      expect(listed, 200);
      expect((list as List).single['blueprint'], 'builder');

      final (got, one) = await send('GET', '/api/v1/blueprints/builder');
      expect(got, 200);
      expect((one as Map)['name'], 'Build host');

      final (deleted, _) = await send('DELETE', '/api/v1/blueprints/builder');
      expect(deleted, 200);

      final (gone, _) = await send('GET', '/api/v1/blueprints/builder');
      expect(gone, 404);
    });
  });

  group('resolution', () {
    test(
      'a blueprint made of presets flattens, and says what came from where',
      () async {
        await savePreset('dev-tools', [
          {'formula': 'dart', 'action': 'install'},
          {'formula': 'build-tools', 'action': 'install'},
        ]);
        await saveBlueprint({
          'blueprint': 'builder',
          'name': 'Build host',
          'includes': ['dev-tools'],
          'resources': [
            {'type': 'formula', 'name': 'nmap', 'ensure': 'installed'},
          ],
        });

        final (status, body) = await send(
          'GET',
          '/api/v1/blueprints/builder/resolved',
        );
        expect(status, 200);

        final resolved = body as Map;
        final resources = (resolved['resources'] as List).cast<Map>();
        expect(
          [for (final r in resources) '${r['type']}:${r['name']}'],
          ['formula:dart', 'formula:build-tools', 'formula:nmap'],
        );
        expect(resources.first['origin'], 'preset:dev-tools');
        expect(resources.last['origin'], 'local');
        expect(resolved['hash'], startsWith('sha256:'));
      },
    );

    test('editing a shared preset re-resolves everything including it', () async {
      // Includes follow the current preset. This is the sharing dividend and
      // the sharing hazard in one: a fix to a base preset reaches every machine
      // built on it, and so does a mistake.
      await savePreset('dev-tools', [
        {'formula': 'dart', 'action': 'install'},
      ]);
      await saveBlueprint({
        'blueprint': 'builder',
        'name': 'Build host',
        'includes': ['dev-tools'],
      });

      final (_, before) = await send(
        'GET',
        '/api/v1/blueprints/builder/resolved',
      );

      await savePreset('dev-tools', [
        {'formula': 'dart', 'action': 'install'},
        {'formula': 'net-tools', 'action': 'install'},
      ]);

      final (_, after) = await send(
        'GET',
        '/api/v1/blueprints/builder/resolved',
      );

      expect((after as Map)['hash'], isNot((before as Map)['hash']));
      expect((after['resources'] as List), hasLength(2));
    });
  });

  group('assigning, planning and applying', () {
    Map<String, dynamic> builder() => {
      'blueprint': 'builder',
      'name': 'Build host',
      'includes': ['dev-tools'],
      'resources': [
        {'type': 'formula', 'name': 'nmap', 'ensure': 'installed'},
      ],
    };

    Future<void> setUpBuilder() async {
      await savePreset('dev-tools', [
        {'formula': 'dart', 'action': 'install'},
      ]);
      await saveBlueprint(builder());
      await startNode();
      final (status, _) = await send(
        'PUT',
        '/api/v1/nodes/worker-01/desired-state',
        {'blueprint': 'builder'},
      );
      expect(status, 200);
    }

    test('assigning a blueprint nobody saved is a 404', () async {
      await cluster.startNode(id: 'worker-01');
      final (status, _) = await send(
        'PUT',
        '/api/v1/nodes/worker-01/desired-state',
        {'blueprint': 'nothing-like-this'},
      );
      expect(status, 404);
    });

    test(
      'an unmanaged node is drifted, and the node is what answers',
      () async {
        await setUpBuilder();

        final report = await drift('worker-01');
        expect(report['converged'], isFalse);
        expect(report['blueprint'], 'builder');

        final changes = (report['changes'] as List).cast<Map>();
        expect([for (final c in changes) c['kind']], ['create', 'create']);
        expect(changes.first['origin'], 'preset:dev-tools');
        expect(changes.last['origin'], 'local');

        // The node was genuinely asked: the version probes ran on its executor.
        expect(executor.calls, contains('dart --version'));
      },
    );

    test('applying converges it, and applying again does nothing', () async {
      // Idempotence, over the wire, through a real agent. Everything else
      // depends on this: if applying twice did the work twice, drift could not
      // be the same comparison with the apply left off.
      await setUpBuilder();

      final first = await reconcile('worker-01');
      expect(first['success'], isTrue);
      expect(first['changed'], 2);
      expect(first['appliedHash'], startsWith('sha256:'));

      expect((await drift('worker-01'))['converged'], isTrue);

      final second = await reconcile('worker-01');
      expect(second['changed'], 0);
      expect(second['success'], isTrue);
    });

    test('a dry run reports the work and leaves the node alone', () async {
      await setUpBuilder();

      final dry = await reconcile('worker-01', {'dryRun': true});
      expect(
        [for (final c in (dry['changes'] as List).cast<Map>()) c['kind']],
        ['create', 'create'],
      );
      expect(dry['notes'], contains('dry run: nothing was changed'));

      expect(
        (await drift('worker-01'))['converged'],
        isFalse,
        reason: 'a dry run must not have changed anything',
      );
    });

    test(
      'a resource dropped from the blueprint is removed from the node',
      () async {
        // The ledger's whole reason to exist. The document no longer mentions
        // nmap, so the document cannot ask for it to go.
        await setUpBuilder();
        await reconcile('worker-01');

        await saveBlueprint({
          'blueprint': 'builder',
          'name': 'Build host',
          'includes': ['dev-tools'],
        });

        final report = await drift('worker-01');
        expect(report['converged'], isFalse);

        final removal = (report['changes'] as List).cast<Map>().singleWhere(
          (c) => c['kind'] == 'remove',
        );
        expect(removal['resource'], 'formula:nmap');
        expect(removal['origin'], 'ledger');

        await reconcile('worker-01');
        expect((await drift('worker-01'))['converged'], isTrue);
      },
    );

    test(
      'editing an included preset drifts the node without a re-save',
      () async {
        await setUpBuilder();
        await reconcile('worker-01');
        expect((await drift('worker-01'))['converged'], isTrue);

        await savePreset('dev-tools', [
          {'formula': 'dart', 'action': 'install'},
          {'formula': 'docker', 'action': 'install'},
        ]);

        final report = await drift('worker-01');
        expect(report['converged'], isFalse);
        expect(
          (report['changes'] as List)
              .cast<Map>()
              .where((c) => c['kind'] == 'create')
              .single['resource'],
          'formula:docker',
        );
      },
    );

    test('an async apply lands in the operations tray', () async {
      await setUpBuilder();

      final (status, body) = await send(
        'POST',
        '/api/v1/nodes/worker-01/reconcile',
        {'async': true},
      );

      expect(status, 202);
      expect((body as Map)['kind'], 'blueprint');
      expect(body['summary'], 'builder');
    });
  });

  group('the preset path is untouched', () {
    test('a node declared by steps still plans Hub-side, offline', () async {
      // The reconciler answers from advertised capabilities, so it works with
      // no node attached at all. Blueprints did not take that away.
      await cluster.startNode(id: 'worker-01');
      final (declared, _) = await send(
        'PUT',
        '/api/v1/nodes/worker-01/desired-state',
        {
          'steps': [
            {'formula': 'docker', 'action': 'install'},
          ],
        },
      );
      expect(declared, 200);

      final report = await drift('worker-01');
      expect(report['converged'], isFalse);
      expect((report['actions'] as List).single['formula'], 'docker');
      expect(
        report['changes'],
        anyOf(isNull, isEmpty),
        reason: 'a step-declared node answers in actions, not changes',
      );
    });
  });
}
