@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart'
    show CommandExecutor, ExecResult, FormulaRegistry, NodeFormulaService;
import 'package:test/test.dart';

import '../support/harness.dart';

/// An executor for which every probe succeeds — the tool is already there.
///
/// The preset under test installs Docker. Run against the real
/// [ProcessCommandExecutor] that is not a figure of speech: the node shells out
/// to `brew install --cask docker` on macOS, or pipes `get.docker.com` into `sh`
/// on Linux, on whatever machine happens to be running the suite. It passed on
/// CI's Linux image only because Docker is preinstalled there, and timed out on
/// macOS, where it is not.
class _InstalledExecutor implements CommandExecutor {
  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async => const ExecResult(exitCode: 0, stdout: 'version 1.2.3');
}

/// The catalogue: what a node can be asked to do, and what has been saved to ask.
///
/// Two gaps this closes. A client had no way to *discover* the formulas a node
/// implements — it had to be told, out of band, what to type into a free-text
/// box, which is a client that gets it wrong. And `PresetRepository` existed,
/// with all three of its implementations, wired to nothing: every operator
/// shipped their own copy of a preset file, and the copies quietly diverged.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;

  const preset = {
    'id': 'docker-host',
    'name': 'Docker host',
    'description': 'What a docker host is here.',
    'steps': [
      {'formula': 'docker', 'action': 'install'},
    ],
  };

  setUp(() async {
    cluster = await TestCluster.start();
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
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

  group('the formula catalogue', () {
    test('lists the built-ins and the actions each implements', () async {
      final (status, body) = await send('GET', '/api/v1/formulas');
      expect(status, 200);

      final formulas = (body as List).cast<Map>();
      final ids = [for (final f in formulas) f['id']];
      expect(ids, containsAll(['docker', 'dart']));

      final docker = formulas.firstWhere((f) => f['id'] == 'docker');
      expect(docker['name'], 'Docker');
      // The actions are what a client offers instead of a free-text box.
      expect(docker['actions'], containsAll(['install', 'verify', 'restart']));
    });

    test(
      'what the Hub advertises is what a node actually implements',
      () async {
        // One definition, in the domain, read by both — so a catalogue cannot
        // promise a formula the nodes have never heard of.
        final specs = await cluster.hub.listFormulas();
        final node = FormulaRegistry.standard();

        for (final spec in specs) {
          // A site-registered spec has no built-in to compare against.
          final formula = node.byId(spec.id.value);
          if (formula == null) {
            continue;
          }
          expect(formula.spec.actions, spec.actions, reason: spec.id.value);
        }
      },
    );
  });

  group('the preset library', () {
    test('a saved preset can be listed, read back and deleted', () async {
      final (saved, _) = await send('POST', '/api/v1/presets', preset);
      expect(saved, 200);

      final (listed, list) = await send('GET', '/api/v1/presets');
      expect(listed, 200);
      expect((list as List).single['id'], 'docker-host');

      final (got, one) = await send('GET', '/api/v1/presets/docker-host');
      expect(got, 200);
      expect((one as Map)['name'], 'Docker host');

      final (deleted, _) = await send('DELETE', '/api/v1/presets/docker-host');
      expect(deleted, 200);

      final (gone, _) = await send('GET', '/api/v1/presets/docker-host');
      expect(gone, 404);
    });

    test('a saved preset is applied by id — no file to ship around', () async {
      // A real preset handler, so the steps actually run: a node without one
      // accepts the preset and quietly does nothing. The *executor* is faked,
      // though — the preset installs Docker, and a registry built on the real
      // one would run that install on whatever machine the suite is on.
      final service = NodeFormulaService(
        registry: FormulaRegistry.standard(executor: _InstalledExecutor()),
      );
      await cluster.startNode(
        id: 'worker-01',
        presetHandler: service.applyPreset,
        formulaHandler: service.runFormula,
      );
      await send('POST', '/api/v1/presets', preset);

      final (status, body) = await send('POST', '/api/v1/presets/apply', {
        'nodeId': 'worker-01',
        'presetId': 'docker-host',
      });

      expect(status, 200);
      expect((body as Map)['results'], isNotEmpty);
    });

    test(
      'applying a preset nobody saved is a 404, not a silent no-op',
      () async {
        await cluster.startNode(id: 'worker-01');
        final (status, _) = await send('POST', '/api/v1/presets/apply', {
          'nodeId': 'worker-01',
          'presetId': 'nothing-like-this',
        });
        expect(status, 404);
      },
    );

    test('an inline preset still works', () async {
      await cluster.startNode(id: 'worker-01');
      final (status, _) = await send('POST', '/api/v1/presets/apply', {
        'nodeId': 'worker-01',
        'preset': preset,
      });
      expect(status, 200);
    });

    test('naming neither is a 400', () async {
      await cluster.startNode(id: 'worker-01');
      final (status, body) = await send('POST', '/api/v1/presets/apply', {
        'nodeId': 'worker-01',
      });
      expect(status, 400);
      expect((body as Map)['error']['message'], contains('presetId'));
    });
  });
}
