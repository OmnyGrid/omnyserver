@TestOn('vm && !windows')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Drives the real CLI as a subprocess, with the service registry pointed at an
/// isolated [home] — `dart_service_manager`'s `StoragePaths` reads `HOME` and
/// `XDG_DATA_HOME`, so this keeps the tests off the developer's real registry.
///
/// Every case here is a `--dry-run` or a validation failure: nothing in this
/// file ever installs a service for real.
Future<ProcessResult> _omnyserver(List<String> args, {required String home}) =>
    Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/omnyserver.dart', ...args],
      environment: {
        'HOME': home,
        'XDG_DATA_HOME': p.join(home, '.local', 'share'),
        'OMNYSERVER_HOME': p.join(home, '.omnyserver'),
      },
      // Keep the parent's PATH etc.; only the home-ish vars are overridden.
      includeParentEnvironment: true,
    );

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
  });

  tearDown(() => home.deleteSync(recursive: true));

  group('service install --dry-run', () {
    test('renders a hub definition without installing anything', () async {
      final result = await _omnyserver([
        'service', 'install', 'hub', '--dry-run', //
        '--cert', certPath,
        '--key', keyPath,
        '--port', '9443',
        '--grant', 'alice:s3cr3t:admin',
      ], home: home.path);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final out = result.stdout as String;
      expect(out, contains('hub'));
      expect(out, contains('start'));
      expect(out, contains(certPath));
      expect(out, contains('9443'));
      expect(out, contains('alice:s3cr3t:admin'));
      // The Hub's fleet data lands under the home root, in hub/.
      expect(out, contains(p.join(home.path, '.omnyserver', 'hub')));
      // A dry run touches nothing.
      expect(out, isNot(contains('Installed and started')));
    });

    test('absolutizes a relative cert against the cwd', () async {
      final result = await _omnyserver([
        'service', 'install', 'hub', '--dry-run', //
        '--cert', 'certs/server.crt',
        '--key', 'certs/server.key',
      ], home: home.path);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout as String, contains(p.absolute('certs/server.crt')));
    });

    test('renders a node definition, honouring --no-ship-logs', () async {
      final result = await _omnyserver([
        'service', 'install', 'node', '--dry-run', //
        '--hub', 'wss://hub:8443',
        '--id', 'web-01',
        '--token', 's3cr3t',
        '--no-ship-logs',
        '--label', 'env=prod',
      ], home: home.path);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final out = result.stdout as String;
      expect(out, contains('wss://hub:8443'));
      expect(out, contains('web-01'));
      expect(out, contains('env=prod'));
      expect(out, contains('--no-ship-logs'));
    });

    test('--ephemeral bakes in no data dir', () async {
      final result = await _omnyserver([
        'service', 'install', 'hub', '--dry-run', '--ephemeral', //
        '--cert', certPath,
        '--key', keyPath,
      ], home: home.path);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final out = result.stdout as String;
      expect(out, contains('--ephemeral'));
      expect(out, isNot(contains('--data-dir')));
      expect(out, isNot(contains('OMNYSERVER_HOME')));
    });
  });

  group('validation', () {
    Future<void> expectFailure(List<String> args, Matcher message) async {
      final result = await _omnyserver(args, home: home.path);
      expect(result.exitCode, isNot(0));
      expect(result.stderr as String, message);
    }

    test('a hub with no TLS source', () async {
      await expectFailure([
        'service',
        'install',
        'hub',
      ], contains('--cert and --key are required'));
    });

    test('a node with no credentials', () async {
      await expectFailure([
        'service',
        'install',
        'node',
        '--id',
        'web-01',
      ], contains('--hub, --id and --token are required'));
    });

    test('a hub option on the node role', () async {
      await expectFailure([
        'service', 'install', 'node', //
        '--hub', 'wss://hub:8443', '--id', 'a', '--token', 't',
        '--cert', certPath,
      ], contains('--cert is a hub option'));
    });

    test('an unknown role', () async {
      await expectFailure([
        'service',
        'install',
        'gateway',
      ], contains('unknown role'));
    });

    test('no role at all', () async {
      await expectFailure(['service', 'status'], contains('specify a role'));
    });
  });

  group('against an empty registry', () {
    test('info reports the service is not installed', () async {
      final result = await _omnyserver([
        'service',
        'info',
        'node',
      ], home: home.path);
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout as String, contains('node: not installed'));
    });

    test('a bare reinstall has no config to reuse', () async {
      final result = await _omnyserver([
        'service',
        'reinstall',
        'hub',
      ], home: home.path);
      expect(result.exitCode, isNot(0));
      expect(result.stderr as String, contains('is not installed'));
    });
  });
}
