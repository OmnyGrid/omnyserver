@TestOn('vm')
library;

import 'package:args/args.dart';
import 'package:omnyserver/omnyserver_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ArgResults _parse(List<String> argv) {
  final parser = ArgParser()
    ..addOption('data-dir')
    ..addFlag('ephemeral', negatable: false);
  return parser.parse(argv);
}

void main() {
  group('resolveDataDir', () {
    test('an explicit --data-dir wins, absolutized and normalized', () {
      expect(
        resolveDataDir(_parse(['--data-dir', 'state/../state'])),
        p.absolute('state'),
      );
    });

    test(
      'an explicit --data-dir wins over the system default too',
      () {
        expect(
          resolveDataDir(_parse(['--data-dir', '/srv/hub']), systemScope: true),
          '/srv/hub',
        );
      },
      testOn: '!windows',
    );

    test('falls back to the home root', () {
      expect(resolveDataDir(_parse([])), OmnyServerHome.resolve());
    });

    test('the system scope resolves machine-wide', () {
      expect(resolveDataDir(_parse([]), systemScope: true), systemDataDir());
      expect(systemDataDir(), '/var/lib/omnyserver');
    }, testOn: '!windows');

    // The whole point of --ephemeral: everything else always resolves a root,
    // because a Hub that silently keeps nothing is the footgun this replaces.
    test('--ephemeral resolves nothing', () {
      expect(resolveDataDir(_parse(['--ephemeral'])), isNull);
      expect(
        resolveDataDir(_parse(['--ephemeral']), systemScope: true),
        isNull,
      );
    });

    test('--ephemeral with --data-dir is contradictory', () {
      expect(
        () => resolveDataDir(_parse(['--ephemeral', '--data-dir', '/srv'])),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('not both'),
          ),
        ),
      );
    });

    test('an empty --data-dir is treated as absent', () {
      expect(
        resolveDataDir(_parse(['--data-dir', ''])),
        OmnyServerHome.resolve(),
      );
    });
  });

  group('hubDataDir', () {
    // The fleet data sits *under* the root, alongside — not mixed into — the
    // credentials and identity the root holds.
    test('puts the fleet data under hub/', () {
      expect(
        hubDataDir('/var/lib/omnyserver'),
        p.join('/var/lib/omnyserver', 'hub'),
      );
    });
  });

  group('resolveHubDataDir', () {
    // The asymmetry that makes the round-trip work: on `hub start`,
    // --data-dir names the Hub's own directory (as it always has), so it is
    // taken verbatim. Only the *default* is composed as <root>/hub.
    test('takes an explicit --data-dir verbatim', () {
      expect(
        resolveHubDataDir(_parse(['--data-dir', '/srv/hubdata'])),
        '/srv/hubdata',
      );
    }, testOn: '!windows');

    test('defaults to <root>/hub', () {
      expect(
        resolveHubDataDir(_parse([])),
        hubDataDir(OmnyServerHome.resolve()),
      );
    });

    test('--ephemeral resolves nothing', () {
      expect(resolveHubDataDir(_parse(['--ephemeral'])), isNull);
    });

    // The regression this exists for: `service install` bakes
    // `--data-dir <root>/hub` into the command, and `hub start` then parses it
    // back. If `hub start` composed <root>/hub a second time the Hub would
    // persist into `<root>/hub/hub` — a directory nobody asked for, and one
    // that silently orphans the data of every prior run.
    test(
      'round-trips what service install bakes in, without re-appending',
      () {
        const root = '/var/lib/omnyserver';
        final baked = hubDataDir(root); // what service install emits
        expect(
          resolveHubDataDir(_parse(['--data-dir', baked])),
          baked,
          reason: 'hub start must not append /hub to an explicit --data-dir',
        );
      },
      testOn: '!windows',
    );
  });
}
