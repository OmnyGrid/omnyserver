@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart'
    show
        FormulaProvider,
        FormulaRegistry,
        NodeBlueprintService,
        ProviderRegistry;
import 'package:test/test.dart';

import '../support/captured_stdout.dart';
import '../support/harness.dart';

/// The shared preset the blueprints below include.
final Preset _devTools = Preset(
  id: PresetId('dev-tools'),
  name: 'Dev tools',
  steps: [PresetStep(formula: FormulaId('dart'))],
);

/// The blueprint CLI, driven through the real `buildRunner()` against a real
/// Hub — the same path an operator's shell takes, one seam shorter.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late HubApiClient client;
  late Directory workspace;
  late String base;

  setUp(() async {
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
    workspace = Directory.systemTemp.createTempSync('omnyserver-blueprints');
  });

  tearDown(() async {
    client.close();
    await api.close();
    await cluster.dispose();
    workspace.deleteSync(recursive: true);
    exitCode = 0;
  });

  Future<void> cli(List<String> args) =>
      buildRunner().run([...args, '--api', base, '--token', 'api-secret']);

  File write(String name, String content) =>
      File('${workspace.path}/$name')..writeAsStringSync(content);

  group('saving', () {
    test(
      'a YAML blueprint is saved, and read back as the YAML written',
      () async {
        // The format rule, end to end. An operator who writes YAML — comments and
        // all — should get their own file back, not a re-rendering of it.
        const source = '''
# Everything a build host needs.
blueprint: builder
name: Build host
includes:
  - dev-tools          # shared with the web servers
resources:
  - type: formula
    name: nmap
    ensure: installed
''';
        await client.savePreset(_devTools);
        write('builder.yaml', source);

        final saved = await captureStdout(
          () => cli(['blueprint', 'save', '${workspace.path}/builder.yaml']),
        );
        expect(saved, contains('saved "builder" (1 includes, 1 resources)'));

        final shown = await captureStdout(
          () => cli(['blueprint', 'show', 'builder']),
        );
        expect(shown, contains('# Everything a build host needs.'));
        expect(shown, contains('# shared with the web servers'));
        expect(shown, source);
      },
    );

    test('a JSON blueprint stays JSON', () async {
      write('web.json', '{"blueprint": "web", "name": "Web", "resources": []}');

      await captureStdout(
        () => cli(['blueprint', 'save', '${workspace.path}/web.json']),
      );
      final shown = await captureStdout(
        () => cli(['blueprint', 'show', 'web']),
      );

      expect(shown, contains('"blueprint": "web"'));
    });

    test('a malformed file is a local error naming the file', () async {
      // Caught before the request, so the message points at the file rather
      // than coming back as a 400 from a Hub that only ever saw the bytes.
      write('bad.yaml', 'blueprint: [unclosed');

      await expectLater(
        cli(['blueprint', 'save', '${workspace.path}/bad.yaml']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            allOf(contains('bad.yaml'), contains('not valid YAML')),
          ),
        ),
      );
    });

    test('a file that does not exist says so', () async {
      await expectLater(
        cli(['blueprint', 'save', '${workspace.path}/nothing.yaml']),
        throwsA(isA<CliError>()),
      );
    });
  });

  group('listing and resolving', () {
    setUp(() async {
      await client.savePreset(_devTools);
      write('builder.yaml', '''
blueprint: builder
name: Build host
includes: [dev-tools]
resources:
  - { type: formula, name: nmap, ensure: installed }
''');
      await captureStdout(
        () => cli(['blueprint', 'save', '${workspace.path}/builder.yaml']),
      );
    });

    test('list shows what is saved', () async {
      final out = await captureStdout(() => cli(['blueprint', 'list']));
      expect(out, contains('ID              INCLUDES  RESOURCES  NAME'));
      expect(out, contains('builder'));
      expect(out, contains('Build host'));
    });

    test('an empty Hub says how to fill it', () async {
      await captureStdout(() => cli(['blueprint', 'delete', 'builder']));
      final out = await captureStdout(() => cli(['blueprint', 'list']));
      expect(out, contains('no blueprints are saved'));
    });

    test('resolved shows the flattened list and where each came from', () async {
      // The answer to "this blueprint is made of four presets and is not doing
      // what I expected".
      final out = await captureStdout(
        () => cli(['blueprint', 'resolved', 'builder']),
      );

      expect(out, contains('sha256:'));
      expect(out, contains('formula:dart'));
      expect(out, contains('preset:dev-tools'));
      expect(out, contains('formula:nmap'));
      expect(out, contains('local'));
    });
  });

  group('assigning and planning', () {
    setUp(() async {
      write('bare.yaml', '''
blueprint: bare
name: Bare
resources:
  - { type: formula, name: nmap, ensure: installed }
''');
      await captureStdout(
        () => cli(['blueprint', 'save', '${workspace.path}/bare.yaml']),
      );
    });

    test('assign says plainly that nothing has run', () async {
      // An operator who expects this to have changed the machine will otherwise
      // wonder why it is unchanged.
      await cluster.startNode(id: 'worker-01');

      final out = await captureStdout(
        () => cli(['blueprint', 'assign', 'bare', 'worker-01']),
      );

      expect(out, contains('assigned bare'));
      expect(out, contains('nothing has run'));
    });

    test('plan exits 2 when a node has drifted, so CI can read it', () async {
      final service = NodeBlueprintService(
        providers: ProviderRegistry.of([
          FormulaProvider(registry: FormulaRegistry()),
        ]),
      );
      await cluster.startNode(
        id: 'worker-01',
        blueprintPlanHandler: service.plan,
        blueprintApplyHandler: service.apply,
      );
      await captureStdout(
        () => cli(['blueprint', 'assign', 'bare', 'worker-01']),
      );

      final out = await captureStdout(
        () => cli(['blueprint', 'plan', 'worker-01']),
      );

      expect(out, contains('has drifted from bare'));
      expect(out, contains('formula:nmap'));
      expect(
        exitCode,
        2,
        reason: 'a distinct code, so a pipeline need not parse the output',
      );
    });
  });
}
