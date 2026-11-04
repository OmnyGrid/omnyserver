@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_service_manager/dart_service_manager.dart' as dsm;
import 'package:omnyserver/omnyserver_node.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// An init system that keeps its units in memory — the one seam
/// `dart_service_manager` offers below its registry.
class FakeDriver implements dsm.PlatformServiceDriver {
  final Map<String, dsm.ServiceStatus> statuses = {};
  final List<String> calls = [];

  String _key(dsm.ServiceDescriptor s) => s.qualifiedName;

  @override
  String get platform => 'linux';

  @override
  bool get supportsPauseResume => false;

  @override
  bool get supportsEnvironmentFile => true;

  @override
  String render(dsm.ServiceDescriptor s) =>
      'ExecStart=${s.executablePath} ${s.arguments.join(' ')}';

  @override
  Future<void> install(dsm.ServiceDescriptor s) async {
    calls.add('install ${_key(s)}');
    statuses.putIfAbsent(_key(s), () => dsm.ServiceStatus.installed);
  }

  @override
  Future<void> uninstall(dsm.ServiceDescriptor s) async {
    calls.add('uninstall ${_key(s)}');
    statuses.remove(_key(s));
  }

  @override
  Future<void> start(dsm.ServiceDescriptor s) async {
    calls.add('start ${_key(s)}');
    statuses[_key(s)] = dsm.ServiceStatus.running;
  }

  @override
  Future<void> stop(dsm.ServiceDescriptor s) async {
    calls.add('stop ${_key(s)}');
    statuses[_key(s)] = dsm.ServiceStatus.stopped;
  }

  @override
  Future<void> pause(dsm.ServiceDescriptor s) async {}

  @override
  Future<void> resume(dsm.ServiceDescriptor s) async {}

  @override
  Future<void> restart(dsm.ServiceDescriptor s) async {
    calls.add('restart ${_key(s)}');
    statuses[_key(s)] = dsm.ServiceStatus.running;
  }

  @override
  Future<dsm.ServiceStatus> status(dsm.ServiceDescriptor s) async =>
      statuses[_key(s)] ?? dsm.ServiceStatus.unknown;
}

void main() {
  group('DsmServiceBackend', () {
    late Directory dir;
    late FakeDriver driver;
    late DsmServiceBackend backend;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omnyserver-dsm');
      driver = FakeDriver();
      backend = DsmServiceBackend(
        manager: dsm.DartServiceManager(
          resolver: dsm.PackageResolver(workingDirectory: dir),
          manifestLoader: const dsm.ManifestLoader(),
          compiler: dsm.ServiceCompiler(
            outputDirectory: dir.path,
            processRunner: const dsm.SystemProcessRunner(),
          ),
          registry: dsm.JsonServiceRegistry(p.join(dir.path, 'registry.json')),
          driver: driver,
        ),
      );
    });

    tearDown(() => dir.deleteSync(recursive: true));

    dsm.ServiceDescriptor unit({List<String> args = const ['-v']}) =>
        dsm.ServiceDescriptor(
          packageName: DsmServiceBackend.managedPackage,
          serviceName: 'api',
          executablePath: '/opt/app/current/bin/api',
          arguments: args,
          environment: const {'TZ': 'UTC'},
          workingDirectory: '/opt/app/current',
          restart: dsm.RestartPolicy.onFailure,
        );

    test('nothing installed describes as null', () async {
      expect(await backend.describe('api'), isNull);
    });

    test(
      'installs under its own package, and describes what it recorded',
      () async {
        await backend.install(unit());
        expect(driver.calls, ['install omnyserver-managed:api']);

        final installed = (await backend.describe('api'))!;
        expect(installed.executable, '/opt/app/current/bin/api');
        expect(installed.arguments, ['-v']);
        expect(installed.environment, {'TZ': 'UTC'});
        expect(installed.workingDirectory, '/opt/app/current');
        expect(installed.restart, dsm.RestartPolicy.onFailure);
        expect(installed.status, dsm.ServiceStatus.installed);
        expect(
          ServiceProvider.fingerprintOf(installed),
          ServiceProvider.fingerprintOf(InstalledService.of(unit())),
          reason: 'what the registry gives back must fingerprint as declared',
        );
      },
    );

    test('drives the lifecycle through the manager', () async {
      await backend.install(unit());
      await backend.start('api');
      expect(
        (await backend.describe('api'))!.status,
        dsm.ServiceStatus.running,
      );

      await backend.reconfigure(unit(args: ['-vv']));
      expect((await backend.describe('api'))!.arguments, ['-vv']);
      // Reconfiguring a running unit restarts it onto the new definition.
      expect(driver.calls, contains('restart omnyserver-managed:api'));

      await backend.restart('api');
      await backend.stop('api');
      expect(
        (await backend.describe('api'))!.status,
        dsm.ServiceStatus.stopped,
      );

      await backend.uninstall('api');
      expect(await backend.describe('api'), isNull);
    });
  });

  group('DefaultHealthProbe', () {
    const probe = DefaultHealthProbe(
      attemptTimeout: Duration(milliseconds: 500),
    );
    late HttpServer server;
    late int answer;

    setUp(() async {
      answer = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/hang') {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        request.response.statusCode = answer;
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    test('nothing to check is healthy', () async {
      expect(const HealthCheck().isEmpty, isTrue);
      expect(await probe.check(const HealthCheck()), isNull);
    });

    test('a 2xx is healthy, anything else says what it got', () async {
      expect(await probe.check(HealthCheck(url: at('/health'))), isNull);
      answer = 503;
      expect(
        await probe.check(HealthCheck(url: at('/health'))),
        contains('answered HTTP 503'),
      );
    });

    test('a service that does not answer in time is not healthy', () async {
      expect(
        await probe.check(HealthCheck(url: at('/hang'))),
        contains('did not answer within'),
      );
    });

    test('nothing listening is not healthy', () async {
      final url = at('/health');
      await server.close(force: true);
      expect(await probe.check(HealthCheck(url: url)), contains('failed'));
    });

    test('a command passes on exit 0 and fails with its exit code', () async {
      expect(await probe.check(const HealthCheck(command: 'exit 0')), isNull);
      expect(
        await probe.check(const HealthCheck(command: 'exit 3')),
        contains('exited 3'),
      );
    });

    test('a command that hangs is reported, and killed', () async {
      final hang = Platform.isWindows ? 'ping -n 30 127.0.0.1' : 'sleep 30';
      final started = DateTime.now();
      expect(
        await probe.check(HealthCheck(command: hang)),
        contains('did not finish'),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 10)),
      );
    });

    test('describes itself for the log', () {
      expect(HealthCheck(url: at('/h')).toString(), startsWith('GET http://'));
      expect(const HealthCheck(command: 'true').toString(), 'command `true`');
    });
  });
}
