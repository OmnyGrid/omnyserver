@TestOn('vm')
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:omnyserver/omnyserver_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The parser `service install` uses: the union of both roles' start options.
ArgParser _serviceParser() {
  final parser = ArgParser();
  addServiceRoleOptions(parser);
  parser.addFlag('system', negatable: false);
  return parser;
}

ArgResults _parse(List<String> argv) => _serviceParser().parse(argv);

/// The value emitted for `--name`, or null when the option is absent.
String? _valueOf(List<String> argv, String name) {
  final i = argv.indexOf('--$name');
  return i == -1 ? null : argv[i + 1];
}

/// Every value emitted for a repeatable `--name`.
List<String> _valuesOf(List<String> argv, String name) => [
  for (var i = 0; i < argv.length - 1; i++)
    if (argv[i] == '--$name') argv[i + 1],
];

void main() {
  group('the merged service parser', () {
    // `shell-path` is declared by both roles and `ArgParser` throws on a
    // duplicate name. Because ServiceCommand() is built inside buildRunner(),
    // a duplicate would take down *every* omnyserver command, not just this
    // one — so this is the canary for that whole class of mistake.
    test('constructs without a duplicate-option error', () {
      expect(_serviceParser, returnsNormally);
      expect(buildRunner, returnsNormally);
    });

    test('exposes service with all nine subcommands', () {
      final service = buildRunner().commands['service']!;
      expect(service.subcommands.keys, hasLength(9));
      expect(
        service.subcommands.keys,
        containsAll([
          'install',
          'reinstall',
          'reconfigure',
          'uninstall',
          'start',
          'stop',
          'restart',
          'status',
          'info',
        ]),
      );
    });
  });

  group('serviceStartArgs — hub', () {
    test('starts with the role and start, and carries the defaults', () {
      final argv = serviceStartArgs(
        'hub',
        _parse(['--cert', 'a.crt', '--key', 'a.key']),
      );
      expect(argv.take(2), ['hub', 'start']);
      expect(_valueOf(argv, 'host'), '0.0.0.0');
      expect(_valueOf(argv, 'port'), '8443');
    });

    // Normalized as well as absolutized: the baked-in command must carry a
    // native path, so a `certs/a.crt` typed on Windows lands in the unit as
    // `…\certs\a.crt`, not the half-converted `…\certs/a.crt`.
    test('absolutizes and normalizes the filesystem paths', () {
      final argv = serviceStartArgs(
        'hub',
        _parse(['--cert', 'certs/a.crt', '--key', 'certs/a.key']),
      );
      expect(_valueOf(argv, 'cert'), p.normalize(p.absolute('certs/a.crt')));
      expect(_valueOf(argv, 'key'), p.normalize(p.absolute('certs/a.key')));
      expect(p.isAbsolute(_valueOf(argv, 'cert')!), isTrue);
      expect(
        _valueOf(argv, 'cert'),
        isNot(contains('/')),
        skip: !Platform.isWindows,
      );
    });

    // --node-path and --shell-path look like paths but are HTTP mount points.
    // Absolutizing them bakes `--node-path /home/you/omnyserver/node` into the
    // unit and the Hub serves nodes on a nonsense route.
    test('leaves URL mount paths alone', () {
      final argv = serviceStartArgs(
        'hub',
        _parse(['--cert', 'a.crt', '--key', 'a.key']),
      );
      expect(_valueOf(argv, 'node-path'), '/node');
      expect(_valueOf(argv, 'shell-path'), '/shell');
    });

    test('leaves cors origins alone', () {
      final argv = serviceStartArgs(
        'hub',
        _parse([
          '--cert', 'a.crt', '--key', 'a.key', //
          '--cors-origin', 'https://omnygrid.github.io',
        ]),
      );
      expect(_valueOf(argv, 'cors-origin'), 'https://omnygrid.github.io');
    });

    test('repeats multi-options, preserving values with spaces', () {
      final argv = serviceStartArgs(
        'hub',
        _parse([
          '--cert', 'a.crt', '--key', 'a.key', //
          '--grant', 'alice:s3cr3t:admin',
          '--grant', 'bob:t0k3n:viewer',
          '--alert', 'cpu>95 for 5m',
        ]),
      );
      expect(_valuesOf(argv, 'grant'), [
        'alice:s3cr3t:admin',
        'bob:t0k3n:viewer',
      ]);
      // A value with spaces stays one argv element — the drivers render the
      // vector, so nothing re-splits it.
      expect(_valuesOf(argv, 'alert'), ['cpu>95 for 5m']);
    });

    test('emits --shell only when asked', () {
      final without = serviceStartArgs(
        'hub',
        _parse(['--cert', 'a.crt', '--key', 'a.key']),
      );
      expect(without, isNot(contains('--shell')));

      final with_ = serviceStartArgs(
        'hub',
        _parse(['--cert', 'a.crt', '--key', 'a.key', '--shell']),
      );
      expect(with_, contains('--shell'));
    });

    test('defaults the data dir under the home root', () {
      final argv = serviceStartArgs(
        'hub',
        _parse(['--cert', 'a.crt', '--key', 'a.key']),
      );
      expect(_valueOf(argv, 'data-dir'), hubDataDir(OmnyServerHome.resolve()));
    });

    test('--system defaults the data dir machine-wide', () {
      final argv = serviceStartArgs(
        'hub',
        _parse(['--cert', 'a.crt', '--key', 'a.key', '--system']),
      );
      expect(_valueOf(argv, 'data-dir'), hubDataDir(systemDataDir()));
    }, testOn: '!windows');

    test('an explicit data dir wins, absolutized', () {
      final argv = serviceStartArgs(
        'hub',
        _parse([
          '--cert', 'a.crt', '--key', 'a.key', //
          '--data-dir', 'state', '--system',
        ]),
      );
      expect(_valueOf(argv, 'data-dir'), hubDataDir(p.absolute('state')));
    });

    test('--ephemeral is passed through instead of a data dir', () {
      final argv = serviceStartArgs(
        'hub',
        _parse(['--cert', 'a.crt', '--key', 'a.key', '--ephemeral']),
      );
      expect(argv, contains('--ephemeral'));
      expect(argv, isNot(contains('--data-dir')));
    });
  });

  group('serviceStartArgs — node', () {
    ArgResults nodeArgs([List<String> extra = const []]) => _parse([
      '--hub', 'wss://hub:8443', //
      '--id', 'web-01',
      '--token', 's3cr3t',
      ...extra,
    ]);

    test('carries the connection options, leaving the hub URI alone', () {
      final argv = serviceStartArgs('node', nodeArgs());
      expect(argv.take(2), ['node', 'start']);
      expect(_valueOf(argv, 'hub'), 'wss://hub:8443');
      expect(_valueOf(argv, 'id'), 'web-01');
      expect(_valueOf(argv, 'token'), 's3cr3t');
      expect(_valueOf(argv, 'principal'), 'node-account');
    });

    test('absolutizes and normalizes --ca', () {
      final argv = serviceStartArgs('node', nodeArgs(['--ca', 'certs/ca.crt']));
      expect(_valueOf(argv, 'ca'), p.normalize(p.absolute('certs/ca.crt')));
    });

    test('repeats labels', () {
      final argv = serviceStartArgs(
        'node',
        nodeArgs(['--label', 'env=prod', '--label', 'region=eu']),
      );
      expect(_valuesOf(argv, 'label'), ['env=prod', 'region=eu']);
    });

    // --ship-logs is negatable and defaults to true, so it must be emitted
    // explicitly in both directions: a service installed with --no-ship-logs
    // has to keep shipping nothing even if that default ever flips.
    test('emits --ship-logs explicitly, in both directions', () {
      expect(serviceStartArgs('node', nodeArgs()), contains('--ship-logs'));

      final off = serviceStartArgs('node', nodeArgs(['--no-ship-logs']));
      expect(off, contains('--no-ship-logs'));
      expect(off, isNot(contains('--ship-logs')));
    });

    test('emits --insecure and --with-shell only when asked', () {
      expect(
        serviceStartArgs('node', nodeArgs()),
        isNot(anyOf(contains('--insecure'), contains('--with-shell'))),
      );
      final on = serviceStartArgs(
        'node',
        nodeArgs(['--insecure', '--with-shell']),
      );
      expect(on, contains('--insecure'));
      expect(on, contains('--with-shell'));
    });

    test('never emits --data-dir: node start has no such option', () {
      final argv = serviceStartArgs('node', nodeArgs(['--data-dir', 'state']));
      expect(argv, isNot(contains('--data-dir')));
    });
  });

  group('requireRole', () {
    test('accepts hub and node', () {
      expect(requireRole(_parse(['hub'])), 'hub');
      expect(requireRole(_parse(['node'])), 'node');
    });

    test('rejects a missing, unknown or extra role', () {
      expect(
        () => requireRole(_parse([])),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('specify a role'),
          ),
        ),
      );
      expect(
        () => requireRole(_parse(['gateway'])),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('unknown role'),
          ),
        ),
      );
      expect(
        () => requireRole(_parse(['hub', 'node'])),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('unexpected arguments'),
          ),
        ),
      );
    });
  });

  group('rejectForeignOptions', () {
    test('rejects a hub option on the node role', () {
      expect(
        () => rejectForeignOptions('node', _parse(['--cert', 'a.crt'])),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            allOf(contains('--cert'), contains('hub option')),
          ),
        ),
      );
    });

    test('rejects a node option on the hub role', () {
      expect(
        () => rejectForeignOptions('hub', _parse(['--id', 'web-01'])),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            allOf(contains('--id'), contains('node option')),
          ),
        ),
      );
    });

    test('names every offender', () {
      expect(
        () => rejectForeignOptions(
          'hub',
          _parse(['--id', 'web-01', '--token', 't']),
        ),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            allOf(contains('--id'), contains('--token'), contains('options')),
          ),
        ),
      );
    });

    test('accepts the shared options', () {
      expect(
        () => rejectForeignOptions(
          'hub',
          _parse(['--shell-path', '/sh', '--data-dir', 'state']),
        ),
        returnsNormally,
      );
    });
  });

  group('serviceDescriptor', () {
    ArgResults hubArgs([List<String> extra = const []]) =>
        _parse(['--cert', 'certs/a.crt', '--key', 'certs/a.key', ...extra]);

    test('installs this executable under the omnyserver package', () {
      final d = serviceDescriptor('hub', hubArgs());
      expect(d.packageName, 'omnyserver');
      expect(d.serviceName, 'hub');
      expect(d.qualifiedName, 'omnyserver:hub');
      expect(d.restart.name, 'always');
      // Under the JIT, forCurrentExecutable prepends the script — so the
      // reconstructed argv is a suffix, not the whole vector.
      expect(d.arguments, containsAllInOrder(['hub', 'start']));
    });

    test('--system selects the system scope', () {
      expect(serviceDescriptor('hub', hubArgs()).scope.name, 'user');
      expect(
        serviceDescriptor('hub', hubArgs(['--system'])).scope.name,
        'system',
      );
    });

    test('pins OMNYSERVER_HOME for both roles', () {
      expect(
        serviceDescriptor('hub', hubArgs()).environment['OMNYSERVER_HOME'],
        OmnyServerHome.resolve(),
      );
      final node = serviceDescriptor(
        'node',
        _parse(['--hub', 'wss://h:1', '--id', 'a', '--token', 't']),
      );
      expect(node.environment['OMNYSERVER_HOME'], OmnyServerHome.resolve());
    });

    test('--ephemeral pins no home', () {
      final d = serviceDescriptor('hub', hubArgs(['--ephemeral']));
      expect(d.environment, isEmpty);
    });

    test('rejects a hub with no TLS source', () {
      expect(
        () => serviceDescriptor('hub', _parse([])),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('--cert and --key are required'),
          ),
        ),
      );
    });

    test('rejects a hub given both TLS sources', () {
      expect(
        () => serviceDescriptor(
          'hub',
          _parse(['--cert', 'a.crt', '--key', 'a.key', '--tls-dir', 'tls']),
        ),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('not both'),
          ),
        ),
      );
    });

    test('rejects a --tls-dir missing its pems', () {
      final dir = Directory.systemTemp.createTempSync('omnyserver-tls');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(
        () => serviceDescriptor('hub', _parse(['--tls-dir', dir.path])),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('fullchain.pem and privkey.pem'),
          ),
        ),
      );
    });

    test('rejects a node with no credentials', () {
      expect(
        () => serviceDescriptor('node', _parse(['--id', 'web-01'])),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('--hub, --id and --token are required'),
          ),
        ),
      );
    });
  });
}
