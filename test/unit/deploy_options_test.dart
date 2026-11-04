@TestOn('vm')
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_node.dart'
    show FormulaRegistry, ReleaseProvider, ServiceProvider;
import 'package:test/test.dart';

import '../support/harness.dart';

/// The flags a deploy adds to `hub start`, `node start` and the client
/// commands — and that `service install` bakes into a unit.
void main() {
  ArgParser serviceParser() {
    final parser = ArgParser();
    addServiceRoleOptions(parser);
    parser.addFlag('system', negatable: false);
    return parser;
  }

  ArgResults nodeArgs(List<String> extra) {
    final parser = ArgParser();
    addNodeStartOptions(parser);
    return parser.parse([
      '--hub',
      'wss://h',
      '--id',
      'n',
      '--token',
      't',
      ...extra,
    ]);
  }

  ArgResults hubArgs(List<String> extra) {
    final parser = ArgParser();
    addHubStartOptions(parser);
    return parser.parse(extra);
  }

  group('--allow-provider and --allow-root', () {
    test('are off by default, and a node offers formulas only', () {
      final args = nodeArgs([]);
      expect(() => validateNodeProviderArgs(args), returnsNormally);
      final providers = nodeProviders(FormulaRegistry.standard());
      expect([for (final p in providers.providers) p.type], ['formula']);
    });

    test('add exactly the providers named, confined to the roots', () {
      final providers = nodeProviders(
        FormulaRegistry.standard(),
        allow: ['release'],
        roots: ['/opt/app'],
      );
      expect(
        [for (final p in providers.providers) p.type],
        ['formula', 'release'],
      );
      final release = providers.byType('release')! as ReleaseProvider;
      expect(release.allowedRoots, ['/opt/app']);
    });

    test('a provider with no root to confine it is refused', () {
      expect(
        () =>
            validateNodeProviderArgs(nodeArgs(['--allow-provider', 'release'])),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('needs at least one --allow-root'),
          ),
        ),
      );
    });

    test('a relative root, or the filesystem root, is refused', () {
      expect(
        () => validateNodeProviderArgs(nodeArgs(['--allow-root', 'opt/app'])),
        throwsA(isA<CliError>()),
      );
      expect(
        () => validateNodeProviderArgs(nodeArgs(['--allow-root', '/'])),
        throwsA(isA<CliError>()),
      );
    });

    test('an unknown provider is a usage error', () {
      expect(
        () => nodeArgs(['--allow-provider', 'shell']),
        throwsA(isA<ArgParserException>()),
      );
    });

    test('service install bakes them into the unit', () {
      final args = serviceParser().parse([
        '--hub',
        'wss://hub:8443',
        '--id',
        'n',
        '--token',
        't',
        '--allow-provider',
        'release,service',
        '--allow-root',
        '/opt/app',
      ]);
      final argv = serviceStartArgs('node', args);
      expect(argv, containsAllInOrder(['--allow-provider', 'release']));
      expect(argv, containsAllInOrder(['--allow-provider', 'service']));
      expect(argv, containsAllInOrder(['--allow-root', '/opt/app']));
    });

    test('and service install refuses them for a hub', () {
      final args = serviceParser().parse([
        '--cert',
        'c',
        '--key',
        'k',
        '--allow-root',
        '/opt/app',
      ]);
      expect(() => rejectForeignOptions('hub', args), throwsA(isA<CliError>()));
    });

    test('the service provider is confined too', () {
      final providers = nodeProviders(
        FormulaRegistry.standard(),
        allow: ['service'],
        roots: ['/opt/app'],
      );
      // Built lazily against the real platform: only its configuration is
      // checked here, never systemd.
      final service = providers.byType('service')! as ServiceProvider;
      expect(service.allowedRoots, ['/opt/app']);
    }, testOn: 'linux || mac-os');
  });

  group('--operation-timeout', () {
    test('reads seconds, minutes and hours', () {
      expect(parseOperationTimeout(hubArgs([])), const Duration(minutes: 30));
      expect(
        parseOperationTimeout(hubArgs(['--operation-timeout', '90'])),
        const Duration(seconds: 90),
      );
      expect(
        parseOperationTimeout(hubArgs(['--operation-timeout', '45m'])),
        const Duration(minutes: 45),
      );
      expect(
        parseOperationTimeout(hubArgs(['--operation-timeout', '2h'])),
        const Duration(hours: 2),
      );
    });

    test('refuses nonsense and zero', () {
      for (final bad in ['soon', '0', '-5m', '1d']) {
        expect(
          () => parseOperationTimeout(hubArgs(['--operation-timeout', bad])),
          throwsA(isA<CliError>()),
          reason: bad,
        );
      }
    });

    test('is baked into a hub unit only when it differs from the default', () {
      final dir = Directory.systemTemp.createTempSync('omnyserver-optime');
      addTearDown(() => dir.deleteSync(recursive: true));
      List<String> unit(List<String> extra) => serviceStartArgs(
        'hub',
        serviceParser().parse([
          '--cert',
          'c',
          '--key',
          'k',
          '--data-dir',
          dir.path,
          ...extra,
        ]),
      );
      expect(unit([]), isNot(contains('--operation-timeout')));
      expect(
        unit(['--operation-timeout', '2h']),
        containsAllInOrder(['--operation-timeout', '2h']),
      );
    });
  });

  group('ApiConnection', () {
    ArgResults clientArgs(List<String> argv) {
      final parser = ArgParser()
        ..addOption('api')
        ..addOption('token')
        ..addOption('principal')
        ..addOption('ca')
        ..addFlag('insecure');
      return parser.parse(argv);
    }

    test('falls back to the environment, then to the default', () {
      final none = ApiConnection.from(clientArgs([]), const {});
      expect(none.api.toString(), defaultApiUrl);
      expect(none.token, isNull);
      expect(none.securityContext, isNull);

      final env = ApiConnection.from(clientArgs([]), {
        'OMNYSERVER_API': 'https://hub.example:8443',
        'OMNYSERVER_TOKEN': 'from-env',
        'OMNYSERVER_PRINCIPAL': 'ci',
      });
      expect(env.api.host, 'hub.example');
      expect(env.token, 'from-env');
      expect(env.principal, 'ci');
    });

    test('an empty variable is no value at all', () {
      final c = ApiConnection.from(clientArgs([]), {'OMNYSERVER_TOKEN': ''});
      expect(c.token, isNull);
    });

    test('takes the CA from a path or from the PEM itself', () async {
      final certs = await TestCerts.ensure();
      final fromPath = ApiConnection.from(clientArgs([]), {
        'OMNYSERVER_CA': certs.caCert,
      });
      expect(fromPath.securityContext, isNotNull);

      final fromPem = ApiConnection.from(clientArgs([]), {
        'OMNYSERVER_CA_PEM': File(certs.caCert).readAsStringSync(),
      });
      expect(fromPem.securityContext, isNotNull);
    });
  });
}
