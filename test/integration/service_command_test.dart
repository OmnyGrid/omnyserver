@TestOn('vm && !windows')
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_service_manager/dart_service_manager.dart' as svc;
import 'package:omnyserver/omnyserver_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/captured_stdout.dart';

/// `omnyserver service …` installs the CLI as an OS service by reconstructing
/// its own `<role> start …` command line.
///
/// Every case here is a `--dry-run`, a read, or a validation failure, and the
/// manager's registry is pointed at a temp directory throughout — so nothing in
/// this file installs, starts or removes a service, or touches the developer's
/// real registry.
void main() {
  late Directory home;
  late String certPath;
  late String keyPath;

  setUp(() {
    home = Directory.systemTemp.createTempSync('omnyserver-service-test');
    certPath = p.join(home.path, 'server.crt');
    keyPath = p.join(home.path, 'server.key');
    // The Hub only *reads* these at start; --dry-run never opens them, but the
    // paths must exist for the reconstruction to be realistic.
    File(certPath).writeAsStringSync('cert');
    File(keyPath).writeAsStringSync('key');

    serviceStoragePaths = svc.StoragePaths(
      environment: {
        'HOME': home.path,
        'USERPROFILE': home.path,
        'XDG_DATA_HOME': p.join(home.path, '.local', 'share'),
        'LOCALAPPDATA': p.join(home.path, 'AppData', 'Local'),
      },
    );
  });

  tearDown(() {
    serviceStoragePaths = null;
    home.deleteSync(recursive: true);
  });

  Future<String> service(List<String> args) =>
      captureStdout(() => buildRunner().run(['service', ...args]));

  /// The options a Hub needs to pass validation.
  List<String> hubTls() => ['--cert', certPath, '--key', keyPath];

  /// A pub-cache snapshot a Dart VM install records ahead of its command.
  const snapshot =
      '/home/u/.pub-cache/global_packages/omnyserver/bin/'
      'omnyserver.dart-3.12.1.snapshot';

  /// Seeds an `omnyserver:hub` entry in the shape dart_service_manager 1.3.x
  /// wrote it: the runtime script inside `args`, and no `script` key.
  Future<void> seedLegacy({
    required String binary,
    required List<String> args,
  }) => svc.JsonServiceRegistry(serviceStoragePaths!.registryFile).upsert(
    svc.RegistryEntry.fromJson({
      'package': servicePackage,
      'service': 'hub',
      'platform': Platform.operatingSystem,
      'scope': 'user',
      'binary': binary,
      'installedAt': '2026-01-01T00:00:00.000Z',
      'status': 'running',
      'args': args,
      'restart': 'onFailure',
    }),
  );

  /// A rendered definition as plain words — markup dropped, whitespace
  /// collapsed — so a launchd plist (one `<string>` per argument) and a systemd
  /// `ExecStart=` line read the same.
  String flatten(String definition) => definition
      .replaceAll(RegExp('<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ');

  group('service install --dry-run', () {
    test('renders a hub definition without installing anything', () async {
      final out = await service([
        'install', 'hub', '--dry-run', //
        ...hubTls(),
        '--port', '9443',
        '--grant', 'alice:s3cr3t:admin',
        '--alert', 'disk>90',
        '--cors-origin', 'https://dash.example.com',
        '--shell',
        '--api-token', 'api-secret',
      ]);

      expect(out, stringContainsInOrder(['hub', 'start']));
      expect(out, contains(certPath));
      expect(out, contains('9443'));
      expect(out, contains('alice:s3cr3t:admin'));
      // The rule survives into the baked-in command line. How it is spelled is
      // the platform's business: a launchd plist is XML and escapes the `>`, a
      // systemd unit is not and does not.
      expect(out, anyOf(contains('disk>90'), contains('disk&gt;90')));
      expect(out, contains('--shell'));
      // The Hub's fleet data lands under the home root, in hub/ — and the root
      // is pinned in the environment, so a system service with no meaningful
      // $HOME still finds it.
      expect(out, contains(hubDataDir(OmnyServerHome.resolve())));
      expect(out, contains('OMNYSERVER_HOME'));
      // A dry run touches nothing.
      expect(out, isNot(contains('Installed and started')));

      // A crash is restarted; a clean exit is not, because that is how the
      // agent says it was told to stop (`node shutdown`). Each platform spells
      // it differently, and under the old `always` policy both spellings
      // restarted the agent regardless — undoing every shutdown.
      if (Platform.isMacOS) {
        expect(
          out,
          stringContainsInOrder(['KeepAlive', 'SuccessfulExit', '<false/>']),
          reason: 'launchd: keep it alive unless it exited successfully',
        );
      } else {
        expect(out, contains('Restart=on-failure'));
        expect(out, isNot(contains('Restart=always')));
      }
    });

    test('renders a node definition, flags and labels intact', () async {
      final out = await service([
        'install', 'node', '--dry-run', //
        '--hub', 'wss://hub:8443',
        '--id', 'web-01',
        '--token', 's3cr3t',
        '--ca', certPath,
        '--insecure',
        '--with-shell',
        '--no-ship-logs',
        '--label', 'env=prod',
        '--shell-label', 'allow-roles=admin',
      ]);

      expect(out, stringContainsInOrder(['node', 'start']));
      expect(out, contains('web-01'));
      expect(out, contains('--insecure'));
      expect(out, contains('--with-shell'));
      // A negatable flag is baked in explicitly in both directions, so the
      // installed service outlives a change to the default.
      expect(out, contains('--no-ship-logs'));
      expect(out, contains('env=prod'));
      expect(out, contains('allow-roles=admin'));
      // A CA is a file, so it is absolutized; a mount path is not a file.
      expect(out, contains(certPath));
    });

    test('--ephemeral bakes in no data dir at all', () async {
      final out = await service([
        'install',
        'hub',
        '--dry-run',
        '--ephemeral',
        ...hubTls(),
      ]);
      expect(out, contains('--ephemeral'));
      expect(out, isNot(contains('--data-dir')));
    });

    test(
      '--system installs machine-wide, under the machine data root',
      () async {
        final out = await service([
          'install',
          'hub',
          '--dry-run',
          '--system',
          '--verbose',
          ...hubTls(),
        ]);
        expect(out, contains(p.join(systemDataDir(), 'hub')));
      },
    );

    test(
      'an explicit --data-dir is used as the root, with hub/ under it',
      () async {
        final root = p.join(home.path, 'state');
        final out = await service([
          'install',
          'hub',
          '--dry-run',
          '--data-dir',
          root,
          ...hubTls(),
        ]);
        expect(out, contains(p.join(root, 'hub')));
        expect(out, contains('OMNYSERVER_HOME'));
      },
    );
  });

  group('validation', () {
    test('a hub with no TLS source is refused', () async {
      await expectLater(
        service(['install', 'hub', '--dry-run']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('--cert'),
          ),
        ),
      );
    });

    test('a node with no credentials is refused', () async {
      await expectLater(
        service(['install', 'node', '--dry-run', '--hub', 'wss://hub:8443']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('--token'),
          ),
        ),
      );
    });

    test(
      'a hub option on the node role names the option and the role',
      () async {
        await expectLater(
          service([
            'install', 'node', '--dry-run', //
            '--hub', 'wss://hub:8443', '--id', 'web-01', '--token', 's3cr3t',
            '--cert', certPath,
          ]),
          throwsA(
            isA<CliError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('--cert'),
                contains('hub option'),
                contains('node'),
              ),
            ),
          ),
        );
      },
    );

    test('several foreign options are listed together, in plural', () async {
      await expectLater(
        service([
          'install', 'hub', '--dry-run', ...hubTls(), //
          '--id', 'web-01', '--token', 's3cr3t',
        ]),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('--id'),
              contains('--token'),
              contains('are node options'),
            ),
          ),
        ),
      );
    });

    test('--data-dir and --ephemeral together are refused', () async {
      await expectLater(
        service([
          'install', 'hub', '--dry-run', ...hubTls(), //
          '--ephemeral', '--data-dir', home.path,
        ]),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('--ephemeral'),
          ),
        ),
      );
    });

    test('an unknown role says which ones exist', () async {
      await expectLater(
        service(['install', 'gateway']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('hub or node'),
          ),
        ),
      );
    });

    test('no role at all asks for one', () async {
      await expectLater(
        service(['status']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('specify a role'),
          ),
        ),
      );
    });

    test('an extra positional is refused rather than ignored', () async {
      await expectLater(
        service(['status', 'hub', 'and-then-some']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('and-then-some'),
          ),
        ),
      );
    });
  });

  group('against an empty registry', () {
    test('info reports the service is not installed', () async {
      expect(await service(['info', 'hub']), contains('hub: not installed'));
    });

    test('a bare reinstall has no config to reuse, and says so', () async {
      await expectLater(
        service(['reinstall', 'node']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('not installed'),
          ),
        ),
      );
    });

    test('reinstall with options builds a fresh descriptor instead', () async {
      final out = await service([
        'reinstall', 'node', '--dry-run', //
        '--hub', 'wss://hub:8443', '--id', 'web-01', '--token', 's3cr3t',
      ]);
      expect(out, contains('web-01'));
    });

    test(
      'the lifecycle commands fail with a message, not a stack trace',
      () async {
        for (final name in [
          'start',
          'stop',
          'restart',
          'status',
          'uninstall',
        ]) {
          await expectLater(
            service([name, 'hub']),
            throwsA(isA<CliError>()),
            reason: name,
          );
        }
      },
    );
  });

  group('service info', () {
    test('prints the recorded config and the native definition', () async {
      // Seed the registry rather than install for real: `info` is a read, and
      // what it reads is the registry entry an install would have written.
      await svc.JsonServiceRegistry(serviceStoragePaths!.registryFile).upsert(
        svc.RegistryEntry(
          packageName: servicePackage,
          serviceName: 'hub',
          platform: Platform.operatingSystem,
          scope: svc.ServiceScope.user,
          binaryPath: p.join(home.path, 'omnyserver'),
          installedAt: DateTime.utc(2026, 1, 1),
          arguments: const ['hub', 'start', '--ephemeral'],
          environment: {'OMNYSERVER_HOME': home.path},
          restart: svc.RestartPolicy.onFailure,
        ),
      );

      final out = await service(['info', 'hub']);
      expect(out, contains('Service "hub" (omnyserver:hub)'));
      expect(out, contains('scope:       user'));
      expect(out, contains('restart:     onFailure'));
      expect(out, contains('hub start --ephemeral'));
      expect(out, contains('OMNYSERVER_HOME=${home.path}'));
      expect(out, contains('definition (${Platform.operatingSystem}):'));
    });

    test('shows the script a Dart VM service runs', () async {
      await seedLegacy(
        binary: '/usr/lib/dart/bin/dart',
        args: [snapshot, 'hub', 'start', '--ephemeral'],
      );
      expect(
        await service(['info', 'hub']),
        contains('/usr/lib/dart/bin/dart $snapshot hub start --ephemeral'),
      );
    });
  });

  group('a bare reinstall with a stale runtime recorded', () {
    test('drops the snapshot a native-binary entry carried over', () async {
      // What a 0.17.0 `service reinstall` left once omnyserver ran as an app
      // bundle: the old pub-cache snapshot ahead of the command.
      await seedLegacy(
        binary:
            '/home/u/.local/state/Dart/install/app-bundles/omnyserver/'
            'hosted/0.17.0/bundle/bin/omnyserver',
        args: [snapshot, 'hub', 'start', '--ephemeral'],
      );
      final out = flatten(await service(['reinstall', 'hub', '--dry-run']));
      expect(out, contains('hub start --ephemeral'));
      expect(out, isNot(contains(snapshot)));
    });

    test('replaces the script of a Dart VM entry from 1.3.x', () async {
      await seedLegacy(
        binary: '/usr/lib/dart/bin/dart',
        args: [snapshot, 'hub', 'start', '--ephemeral'],
      );
      final out = flatten(await service(['reinstall', 'hub', '--dry-run']));
      expect(out, contains('hub start --ephemeral'));
      expect(out, isNot(contains(snapshot)));
    });
  });

  group('the reconstructed command line', () {
    /// Parses [args] the way the `service` parser does, without running it.
    ArgResults parse(List<String> args) =>
        ServiceInstallCommand().argParser.parse(args);

    test('a URL mount point is never absolutized into a file path', () {
      final out = serviceStartArgs(
        'hub',
        parse([
          '--cert', certPath, '--key', keyPath, //
          '--node-path', '/node', '--ephemeral',
        ]),
      );
      expect(out, containsAllInOrder(['--node-path', '/node']));
    });

    test('a node carries no --data-dir; its state rides in the home', () {
      final out = serviceStartArgs(
        'node',
        parse([
          '--hub',
          'wss://hub:8443',
          '--id',
          'web-01',
          '--token',
          's3cr3t',
        ]),
      );
      expect(out, isNot(contains('--data-dir')));
      expect(out.first, 'node');
      expect(out[1], 'start');
    });
  });
}
