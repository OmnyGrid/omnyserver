@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/bundles.dart';
import '../support/captured_stdout.dart';
import '../support/fake_service_backend.dart';
import '../support/harness.dart';

/// Healthy when the current release says so in its `HEALTH` file — so one
/// bundle can be built to deploy cleanly and another to fail its check.
class ReleaseHealth implements HealthProbe {
  ReleaseHealth(this.root);

  final String root;
  int checks = 0;

  @override
  Future<String?> check(HealthCheck check) async {
    checks++;
    final file = File(p.join(root, 'current', 'HEALTH'));
    final said = file.existsSync() ? file.readAsStringSync().trim() : 'missing';
    return said == 'ok' ? null : 'GET /health answered $said';
  }
}

/// The deploy a CI job runs — `blueprint apply --set version=… --wait` — end to
/// end and in-process: a real Hub, a real HTTP API, a real node agent over
/// `wss`, the real release provider unpacking real zips into a real directory,
/// and the CLI exactly as a pipeline calls it. Only the OS service manager is
/// a fake, because systemd is not something a test suite should drive.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late HubApiClient client;
  late HttpServer bundles;
  late Directory sandbox;
  late FakeBackend services;
  late ReleaseHealth health;
  late String base;
  final shas = <String, String>{};

  String root() => p.join(sandbox.path, 'app');

  /// Publishes `app-<version>.zip`, healthy or not.
  void publish(String version, {bool healthy = true}) {
    final bytes = zipOf({
      'bin/api': '#!/bin/sh\n',
      'VERSION': version,
      'HEALTH': healthy ? 'ok' : '500',
    });
    _served[version] = bytes;
    shas[version] = sha256Of(bytes);
  }

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('omnyserver-deploy');
    bundles = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    bundles.listen((request) async {
      final version = RegExp(
        r'app-(.+)\.zip$',
      ).firstMatch(request.uri.path)?.group(1);
      final bytes = version == null ? null : _served[version];
      if (bytes == null) {
        request.response.statusCode = 404;
      } else {
        request.response.add(bytes);
      }
      await request.response.close();
    });

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

    services = FakeBackend();
    health = ReleaseHealth(root());
    final planner = NodeBlueprintService(
      providers: ProviderRegistry.of([
        ReleaseProvider(allowedRoots: [sandbox.path]),
        ServiceProvider(
          backend: services,
          probe: health,
          allowedRoots: [sandbox.path],
          runningAsRoot: true,
          canSwitchUser: false,
          delay: (_) async {},
        ),
      ]),
    );
    await cluster.startNode(
      id: 'app-01',
      labels: {'app': 'demo'},
      capabilityProvider: () async => NodeCapabilities([planner.capability]),
      blueprintPlanHandler: planner.plan,
      blueprintApplyHandler: planner.apply,
    );
    // The descriptor carries the capability only once it has been scanned.
    await _until(
      () =>
          cluster.hub
              .getNode(NodeId('app-01'))
              ?.capabilities
              .named('blueprint') !=
          null,
    );

    final url = 'http://127.0.0.1:${bundles.port}/app-\${version}.zip';
    await client.saveBlueprint(
      Blueprint.fromJson({
        'blueprint': 'app',
        'name': 'Demo app',
        'vars': {'version': '0.0.0', 'sha256': ''},
        'resources': [
          {
            'type': 'release',
            'name': 'app',
            'version': r'${version}',
            'url': url,
            'sha256': r'${sha256}',
            'root': root(),
            'executables': 'bin/*',
          },
          {
            'type': 'service',
            'name': 'app-api',
            'ensure': 'running',
            'restartOn': ['release:app'],
            'exec': p.join(root(), 'current', 'bin', 'api'),
            'health_cmd': 'true',
            'health_timeout': '3',
            'health_interval': '1',
          },
        ],
      }),
    );
  });

  tearDown(() async {
    client.close();
    await api.close();
    await cluster.dispose();
    await bundles.close(force: true);
    sandbox.deleteSync(recursive: true);
    _served.clear();
    shas.clear();
    exitCode = 0;
  });

  Future<String> cli(List<String> args) => captureStdout(
    () => buildRunner().run([...args, '--api', base, '--token', 'api-secret']),
  );

  String current() => Link(p.join(root(), 'current')).targetSync();

  List<String> setVersion(String v) => [
    '--set',
    'version=$v',
    '--set',
    'sha256=${shas[v]}',
  ];

  test('first deploy, upgrade, idempotent re-apply, then a rollback', () async {
    publish('1.0.0');
    publish('1.1.0');
    publish('1.2.0', healthy: false);

    // Assign with the first version; nothing runs yet.
    final assigned = await cli([
      'blueprint',
      'assign',
      'app',
      'app-01',
      ...setVersion('1.0.0'),
    ]);
    expect(assigned, contains('assigned app (sha256='));
    expect(services.calls, isEmpty);

    // First deploy.
    var out = await cli(['blueprint', 'apply', 'app-01', '--wait']);
    expect(exitCode, 0, reason: out);
    expect(out, contains('applied — 2 changed'));
    expect(current(), 'releases/1.0.0');
    expect(services.calls, ['install app-api', 'start app-api']);

    // Upgrade: the release changes, so the service is restarted onto it.
    services.calls.clear();
    out = await cli([
      'blueprint',
      'apply',
      'app-01',
      '--wait',
      ...setVersion('1.1.0'),
    ]);
    expect(exitCode, 0, reason: out);
    expect(out, contains('installed 1.1.0 (was 1.0.0)'));
    expect(out, contains('restarted: release:app changed'));
    expect(current(), 'releases/1.1.0');
    expect(services.calls, ['restart app-api']);

    // The version is stored on the assignment: a plain apply — what a timer
    // runs — keeps the node on 1.1.0 and changes nothing.
    services.calls.clear();
    out = await cli(['blueprint', 'apply', 'app-01']);
    expect(exitCode, 0, reason: out);
    expect(out, contains('applied — 0 changed'));
    expect(current(), 'releases/1.1.0');
    expect(services.calls, isEmpty);
    expect((await client.desiredState('app-01'))!.vars['version'], '1.1.0');

    // A broken release: installed, the service fails its check, and the node
    // is put back on 1.1.0. The pipeline goes red.
    out = await cli([
      'blueprint',
      'apply',
      'app-01',
      '--wait',
      ...setVersion('1.2.0'),
    ]);
    expect(exitCode, 1, reason: out);
    expect(out, contains('FAILED'));
    expect(out, contains('rolled back (back on 1.1.0)'));
    expect(out, contains('restarted on the previous version'));
    expect(current(), 'releases/1.1.0');

    // And the next plan says so, rather than claiming convergence.
    exitCode = 0;
    out = await cli(['blueprint', 'plan', 'app-01']);
    expect(exitCode, 2, reason: out);
    expect(out, contains('1.2.0 was rolled back at'));

    // The failed deploy is a failed operation, too.
    final ops = await client.operations();
    expect(ops.first.status, OperationStatus.failed);
    expect(ops.first.error, contains('release:app'));
  });

  test('--output json prints one parseable object per node', () async {
    publish('1.0.0');
    await client.assignBlueprint(
      'app-01',
      'app',
      vars: {'version': '1.0.0', 'sha256': shas['1.0.0']!},
    );
    final out = await cli([
      'blueprint',
      'apply',
      'app-01',
      '--wait',
      '--output',
      'json',
    ]);
    expect(exitCode, 0, reason: out);
    final line = jsonDecode(out.trim()) as Map<String, dynamic>;
    expect(line['node'], 'app-01');
    expect((line['operation'] as Map)['status'], 'succeeded');
  });

  test(
    'a node that was never allowed the provider is refused up front',
    () async {
      // A second node with formulas only: the Hub knows from its capability that
      // it has no release provider, and says how to fix it.
      final formulasOnly = NodeBlueprintService(
        providers: ProviderRegistry.of([
          FormulaProvider(registry: FormulaRegistry.standard()),
        ]),
      );
      await cluster.startNode(
        id: 'plain-01',
        capabilityProvider: () async =>
            NodeCapabilities([formulasOnly.capability]),
        blueprintPlanHandler: formulasOnly.plan,
        blueprintApplyHandler: formulasOnly.apply,
      );
      await _until(
        () =>
            cluster.hub
                .getNode(NodeId('plain-01'))
                ?.capabilities
                .named('blueprint') !=
            null,
      );
      await client.assignBlueprint('plain-01', 'app');

      final out = await captureStdout(
        () => IOOverrides.runZoned(
          () => buildRunner().run([
            'blueprint',
            'apply',
            'plain-01',
            '--api',
            base,
            '--token',
            'api-secret',
          ]),
          stderr: () => BufferedStdout(_stderr),
        ),
      );
      expect(exitCode, 1, reason: out);
      expect(
        _stderr.toString(),
        allOf(
          contains('has no release, service provider'),
          contains('--allow-provider release,service'),
        ),
      );
      _stderr.clear();
    },
  );

  test(
    'a --wait that outlasts --timeout exits 3, distinct from a failure',
    () async {
      // A bundle that never finishes downloading: the server holds it open.
      publish('1.0.0');
      final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      slow.listen((request) async {
        request.response.add([0x50, 0x4b]);
        await request.response.flush();
        await Future<void>.delayed(const Duration(seconds: 4));
        await request.response.close();
      });
      addTearDown(() => slow.close(force: true));

      await client.saveBlueprint(
        Blueprint.fromJson({
          'blueprint': 'slow',
          'name': 'slow',
          'resources': [
            {
              'type': 'release',
              'name': 'slow',
              'version': '1',
              'url': 'http://127.0.0.1:${slow.port}/app-1.zip',
              'verify': 'none',
              'root': p.join(sandbox.path, 'slow'),
            },
          ],
        }),
      );
      await client.assignBlueprint('app-01', 'slow');

      final out = await cli([
        'blueprint',
        'apply',
        'app-01',
        '--wait',
        '--timeout',
        '1s',
      ]);
      expect(exitCode, BlueprintApplyCommand.timedOutExitCode, reason: out);
      expect(out, contains('TIMED OUT after 1s — still running on the node'));
    },
  );
}

final Map<String, List<int>> _served = {};
final StringBuffer _stderr = StringBuffer();

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within 10s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
