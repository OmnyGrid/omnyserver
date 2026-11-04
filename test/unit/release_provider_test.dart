@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_node.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/bundles.dart';

/// A zip holding [files] and then [links], built by hand — see [rawZip].
List<int> zipWithLinks(Map<String, String> files, Map<String, String> links) =>
    rawZip([
      for (final e in files.entries) rawFile(e.key, e.value),
      for (final e in links.entries) rawLink(e.key, e.value),
    ]);

/// Serves fixture bundles, and counts what it was asked for.
class BundleServer {
  BundleServer._(this._server);

  final HttpServer _server;
  final Map<String, List<int>> bundles = {};
  final List<String> requested = [];
  final List<String?> authorizations = [];
  String? metadataToken;

  static Future<BundleServer> start() async {
    final server = BundleServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(server._handle);
    return server;
  }

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/');

  String url(String name) => base.resolve(name).toString();

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requested.add(request.uri.toString());
    authorizations.add(request.headers.value('authorization'));

    if (path.endsWith('/service-accounts/default/token')) {
      if (request.headers.value('metadata-flavor') != 'Google' ||
          metadataToken == null) {
        request.response.statusCode = 403;
      } else {
        request.response.write(jsonEncode({'access_token': metadataToken}));
      }
      await request.response.close();
      return;
    }

    // `download/storage/v1/b/<bucket>/o/<object>` — the GCS JSON API.
    final gcs = RegExp(r'^/download/storage/v1/b/([^/]+)/o/(.+)$');
    final match = gcs.firstMatch(path);
    final key = match == null
        ? path.substring(1)
        : 'gs/${match.group(1)}/${Uri.decodeComponent(match.group(2)!)}';
    final bytes = bundles[key];
    if (bytes == null) {
      request.response.statusCode = 404;
      request.response.write('no such object');
    } else {
      request.response.add(bytes);
    }
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late Directory sandbox;
  late BundleServer server;
  late List<List<String>> chmods;
  late ReleaseProvider provider;
  final context = FormulaContext(
    platform: PlatformInfo.local(agentVersion: omnyServerVersion),
  );

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('omnyserver-release');
    server = await BundleServer.start();
    chmods = [];
    provider = ReleaseProvider(
      allowedRoots: [sandbox.path],
      fetcher: ReleaseFetcher(
        storageBase: server.base,
        metadataBase: server.base,
      ),
      runProcess: (exe, args) async {
        chmods.add([exe, ...args]);
        return Process.run(exe, args);
      },
    );
  });

  tearDown(() async {
    await server.close();
    sandbox.deleteSync(recursive: true);
  });

  String root() => p.join(sandbox.path, 'app');

  ResolvedResource release(
    String version, {
    String? url,
    String? sha,
    Map<String, String> extra = const {},
    Ensure ensure = Ensure.present,
  }) => ResolvedResource(
    resource: Resource(
      id: ResourceId('release', 'app'),
      ensure: ensure,
      params: {
        'version': version,
        'url': ?url,
        'sha256': ?sha,
        'root': root(),
        ...extra,
      },
    ),
    origin: 'local',
  );

  /// Publishes a bundle at `app-<version>.zip` and returns its declaration.
  ResolvedResource publish(
    String version, {
    Map<String, String>? files,
    Map<String, int> modes = const {},
    Map<String, String> extra = const {},
  }) {
    final bytes = zipOf(
      files ?? {'bin/app': '#!/bin/sh\necho $version\n', 'VERSION': version},
      modes: modes,
    );
    server.bundles['app-$version.zip'] = bytes;
    return release(
      version,
      url: server.url('app-$version.zip'),
      sha: sha256Of(bytes),
      extra: extra,
    );
  }

  Future<ResourceState> read(ResolvedResource r) => provider.read(r, context);

  Future<ResourceChange> apply(ResolvedResource r) async =>
      provider.apply(r, await read(r), context);

  String currentTarget() => Link(p.join(root(), 'current')).targetSync();

  group('read', () {
    test('nothing installed is absent', () async {
      final state = await read(publish('1.0.0'));
      expect(state.status, FormulaStatus.absent);
      expect(provider.satisfies(publish('1.0.0'), state), isFalse);
    });

    test(
      'a real directory where the link goes is unknown, not absent',
      () async {
        Directory(p.join(root(), 'current')).createSync(recursive: true);
        final state = await read(publish('1.0.0'));
        expect(state.status, FormulaStatus.unknown);
        expect(state.message, contains('not a symlink'));
      },
    );

    test('a link to a directory with no marker is unknown', () async {
      Directory(p.join(root(), 'releases', 'x')).createSync(recursive: true);
      Link(p.join(root(), 'current')).createSync('releases/x');
      final state = await read(publish('1.0.0'));
      expect(state.status, FormulaStatus.unknown);
      expect(state.message, contains('no release marker'));
    });

    test('a root outside --allow-root cannot even be read', () async {
      final outside = ResolvedResource(
        resource: Resource(
          id: ResourceId('release', 'app'),
          params: {'version': '1', 'root': '/etc/somewhere'},
        ),
        origin: 'local',
      );
      expect(
        () => provider.read(outside, context),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('outside what this node allows'),
          ),
        ),
      );
    });

    test('an unsupported platform reports unknown', () async {
      final windows = ReleaseProvider(supported: false);
      final state = await windows.read(publish('1.0.0'), context);
      expect(state.status, FormulaStatus.unknown);
      final change = await windows.apply(publish('1.0.0'), state, context);
      expect(change.kind, ChangeKind.failed);
    });
  });

  group('install', () {
    test('downloads, verifies, unpacks and makes it current', () async {
      final r = publish('1.0.0');
      final change = await apply(r);

      expect(change.kind, ChangeKind.create, reason: change.reason);
      expect(change.reason, 'installed 1.0.0');
      expect(currentTarget(), 'releases/1.0.0');
      expect(
        File(p.join(root(), 'current', 'VERSION')).readAsStringSync(),
        '1.0.0',
      );

      final state = await read(r);
      expect(state.status, FormulaStatus.installed);
      expect(state.version, '1.0.0');
      expect(state.fingerprint, r.resource.params['sha256']);
      expect(provider.satisfies(r, state), isTrue);
      // Nothing temporary left behind.
      expect(
        Directory(root()).listSync().map((e) => p.basename(e.path)),
        unorderedEquals(['releases', 'current']),
      );
    });

    test('a sha256 mismatch installs nothing and leaves nothing', () async {
      final r = publish('1.0.0');
      final wrong = release(
        '1.0.0',
        url: r.resource.params['url'],
        sha: 'a' * 64,
      );
      final change = await apply(wrong);

      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('sha256 mismatch'));
      expect(
        Directory(p.join(root(), 'releases', '1.0.0')).existsSync(),
        isFalse,
      );
      expect(
        FileSystemEntity.typeSync(
          p.join(root(), 'current'),
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
      expect(
        Directory(
          root(),
        ).listSync().where((e) => p.basename(e.path).startsWith('.tmp')),
        isEmpty,
      );
    });

    test('a sha256 is required unless verification is waived', () async {
      final r = publish('1.0.0');
      final unverified = release('1.0.0', url: r.resource.params['url']);
      final refused = await apply(unverified);
      expect(refused.kind, ChangeKind.failed);
      expect(refused.reason, contains('needs a sha256'));

      final waived = release(
        '1.0.0',
        url: r.resource.params['url'],
        extra: {'verify': 'none'},
      );
      final change = await apply(waived);
      expect(change.kind, ChangeKind.create, reason: change.reason);
      // With no declared digest, the installed version alone converges.
      expect(provider.satisfies(waived, await read(waived)), isTrue);
    });

    test(
      'rejects a malformed sha256, a missing url and a bad version',
      () async {
        final r = publish('1.0.0');
        expect(
          (await apply(
            release('1.0.0', url: r.resource.params['url'], sha: 'xyz'),
          )).reason,
          contains('not a SHA-256 digest'),
        );
        expect(
          (await apply(release('1.0.0', sha: 'a' * 64))).reason,
          contains('needs a url'),
        );
        expect(
          (await apply(
            release('../evil', url: r.resource.params['url'], sha: 'a' * 64),
          )).reason,
          contains('not a valid name'),
        );
      },
    );

    test('an HTTP error says what was asked for and what came back', () async {
      final change = await apply(
        release('9.9.9', url: server.url('missing.zip'), sha: 'a' * 64),
      );
      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('HTTP 404'));
      expect(change.reason, contains('no such object'));
    });

    test('marks executables, from the zip and from the declaration', () async {
      final r = publish(
        '1.0.0',
        files: {
          'bin/app': 'app',
          'bin/helper': 'helper',
          'launcher': 'launcher',
          'lib/libfoo.so': 'lib',
          'README': 'readme',
        },
        modes: {'launcher': 0x1ed}, // 0755, as the zip recorded it
        extra: {'executables': 'bin/*'},
      );
      final change = await apply(r);
      expect(change.kind, ChangeKind.create, reason: change.reason);

      int mode(String rel) =>
          File(p.join(root(), 'current', rel)).statSync().mode & 0x1ff;
      expect(mode('bin/app') & 0x49, 0x49);
      expect(mode('bin/helper') & 0x49, 0x49);
      expect(mode('launcher') & 0x49, 0x49);
      expect(mode('lib/libfoo.so') & 0x49, 0);
      expect(mode('README') & 0x49, 0);
      // Batched: one chmod per distinct mode, not one per file.
      expect(chmods.length, lessThanOrEqualTo(2));
    });

    test('strip drops a bundle\'s top folder, when asked', () async {
      final r = publish(
        '1.0.0',
        files: {'app-1.0.0/bin/app': 'x', 'app-1.0.0/VERSION': '1.0.0'},
        extra: {'strip': '1'},
      );
      final change = await apply(r);
      expect(change.kind, ChangeKind.create, reason: change.reason);
      expect(File(p.join(root(), 'current', 'VERSION')).existsSync(), isTrue);
      expect(
        File(p.join(root(), 'current', 'bin', 'app')).existsSync(),
        isTrue,
      );
    });

    test('without strip, a bundle holding only bin/ keeps its bin/', () async {
      // The guess this replaces would have unpacked this as `app`, and every
      // `exec: …/current/bin/app` would have pointed at nothing.
      await apply(publish('1.0.0', files: {'bin/app': 'x'}));
      expect(
        File(p.join(root(), 'current', 'bin', 'app')).existsSync(),
        isTrue,
      );
    });

    test('a strip that is not a count is refused', () async {
      final change = await apply(publish('1.0.0', extra: {'strip': 'auto'}));
      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('strip-components'));
    });

    test('an entry escaping the release fails the apply', () async {
      final bytes = zipOf({'../../escaped': 'gotcha', 'ok': 'fine'});
      server.bundles['evil.zip'] = bytes;
      final change = await apply(
        release('1.0.0', url: server.url('evil.zip'), sha: sha256Of(bytes)),
      );
      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('escapes the release'));
      expect(File(p.join(sandbox.path, 'escaped')).existsSync(), isFalse);
    });

    test('a symlink pointing outside the release fails the apply', () async {
      final bytes = zipWithLinks({'ok': 'fine'}, {'passwd': '/etc/passwd'});
      server.bundles['link.zip'] = bytes;
      final change = await apply(
        release('1.0.0', url: server.url('link.zip'), sha: sha256Of(bytes)),
      );
      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('links outside the release'));
    });

    test('a symlink inside the release is kept', () async {
      final bytes = zipWithLinks(
        {'lib/libfoo.so.1': 'lib'},
        {'lib/libfoo.so': 'libfoo.so.1'},
      );
      server.bundles['ok.zip'] = bytes;
      final change = await apply(
        release('1.0.0', url: server.url('ok.zip'), sha: sha256Of(bytes)),
      );
      expect(change.kind, ChangeKind.create, reason: change.reason);
      expect(
        Link(p.join(root(), 'current', 'lib', 'libfoo.so')).targetSync(),
        'libfoo.so.1',
      );
    });

    test(
      'a chain of symlinks cannot carry a file out of the release',
      () async {
        // Each entry is inside the release on paper. Created in order, the
        // links resolve through each other until the file lands outside it —
        // the escape the review found, reproduced exactly.
        final bytes = rawZip([
          rawDir('x/'),
          rawDir('x/y/'),
          rawLink('x/y/z', '..'),
          rawLink('x/y/z/w', '../..'),
          rawLink('x/y/z/w/w2', '../..'),
          rawFile('x/y/z/w/w2/PWNED', 'owned'),
        ]);
        server.bundles['chain.zip'] = bytes;
        final change = await apply(
          release('1.0.0', url: server.url('chain.zip'), sha: sha256Of(bytes)),
        );

        expect(change.kind, ChangeKind.failed);
        expect(change.reason, contains('is inside the symlink "x/y/z"'));
        final everywhere = Directory(sandbox.path)
            .listSync(recursive: true, followLinks: false)
            .map((e) => p.basename(e.path));
        expect(everywhere, isNot(contains('PWNED')));
        expect(everywhere, isNot(contains('w2')));
        expect(everywhere, isNot(contains('w')));
      },
    );

    test(
      'a file inside a directory symlink is refused, even pointing in',
      () async {
        // `lib -> real` is harmless on its own; a file written as `lib/x` would
        // go through it. Refused, rather than reasoned about.
        final bytes = rawZip([
          rawDir('real/'),
          rawLink('lib', 'real'),
          rawFile('lib/x', 'through the link'),
        ]);
        server.bundles['through.zip'] = bytes;
        final change = await apply(
          release(
            '1.0.0',
            url: server.url('through.zip'),
            sha: sha256Of(bytes),
          ),
        );
        expect(change.kind, ChangeKind.failed);
        expect(change.reason, contains('inside the symlink "lib"'));
      },
    );

    test(
      'links are made after every file, whatever the archive order',
      () async {
        final bytes = rawZip([
          rawLink('bin/app', '../libexec/app'),
          rawFile('libexec/app', '#!/bin/sh\n'),
        ]);
        server.bundles['order.zip'] = bytes;
        final change = await apply(
          release('1.0.0', url: server.url('order.zip'), sha: sha256Of(bytes)),
        );
        expect(change.kind, ChangeKind.create, reason: change.reason);
        expect(
          File(p.join(root(), 'current', 'bin', 'app')).readAsStringSync(),
          '#!/bin/sh\n',
        );
      },
    );
  });

  group('upgrade', () {
    test('a new version replaces current and keeps the previous one', () async {
      await apply(publish('1.0.0'));
      final next = publish('1.1.0');
      expect(provider.satisfies(next, await read(next)), isFalse);

      final change = await apply(next);
      expect(change.kind, ChangeKind.update);
      expect(change.reason, 'installed 1.1.0 (was 1.0.0)');
      expect(currentTarget(), 'releases/1.1.0');
      expect(
        Directory(p.join(root(), 'releases', '1.0.0')).existsSync(),
        isTrue,
      );
    });

    test('a version already on disk is reused, not downloaded', () async {
      final v1 = publish('1.0.0');
      await apply(v1);
      await apply(publish('1.1.0'));
      final downloads = server.requested.length;

      final change = await apply(v1);
      expect(change.kind, ChangeKind.update, reason: change.reason);
      expect(currentTarget(), 'releases/1.0.0');
      expect(server.requested.length, downloads);
    });

    test('the same version rebuilt is redeployed', () async {
      await apply(publish('1.0.0'));
      final rebuilt = publish(
        '1.0.0',
        files: {'bin/app': 'rebuilt', 'VERSION': '1.0.0'},
      );
      expect(provider.satisfies(rebuilt, await read(rebuilt)), isFalse);
      final change = await apply(rebuilt);
      expect(change.kind, ChangeKind.update);
      expect(change.reason, 'reinstalled 1.0.0');
      expect(
        File(p.join(root(), 'current', 'bin', 'app')).readAsStringSync(),
        'rebuilt',
      );
    });

    test(
      'a rebuild goes beside the original, which a rollback restores',
      () async {
        // Replacing the original in place would leave `current` pointing at
        // nothing for a moment, and destroy the very build a rollback needs.
        final original = publish('1.0.0');
        await apply(original);
        final before = await read(original);
        final rebuilt = publish(
          '1.0.0',
          files: {'bin/app': 'rebuilt', 'VERSION': '1.0.0'},
        );
        await apply(rebuilt);

        expect(currentTarget(), startsWith('releases/1.0.0~'));
        expect(
          Directory(p.join(root(), 'releases', '1.0.0')).existsSync(),
          isTrue,
        );

        final reverted = await provider.revert(rebuilt, before, context);
        expect(reverted.kind, ChangeKind.update, reason: reverted.reason);
        expect(currentTarget(), 'releases/1.0.0');
        expect(
          File(p.join(root(), 'current', 'bin', 'app')).readAsStringSync(),
          '#!/bin/sh\necho 1.0.0\n',
        );
      },
    );

    test('a digest with surrounding whitespace still converges', () async {
      final r = publish('1.0.0');
      await apply(r);
      final padded = release(
        '1.0.0',
        url: r.resource.params['url'],
        sha: '${r.resource.params['sha256']!.toUpperCase()}\n',
      );
      expect(provider.satisfies(padded, await read(padded)), isTrue);
    });

    test('a real directory at current is refused before downloading', () async {
      Directory(p.join(root(), 'current')).createSync(recursive: true);
      final change = await apply(publish('1.0.0'));
      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('not a symlink — not touching it'));
      expect(server.requested, isEmpty);
    });

    test('old versions are pruned to keep, never below two', () async {
      for (final v in ['1.0.0', '1.1.0', '1.2.0', '1.3.0']) {
        await apply(publish(v, extra: {'keep': '1'}));
        // Distinct install times, so "newest" is well defined.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final left = Directory(
        p.join(root(), 'releases'),
      ).listSync().map((e) => p.basename(e.path)).toList()..sort();
      expect(left, ['1.2.0', '1.3.0']);
    });
  });

  group('revert', () {
    test(
      'goes back to the previous version and says so on the next read',
      () async {
        final v1 = publish('1.0.0');
        await apply(v1);
        final before = await read(v1);
        final v2 = publish('1.1.0');
        await apply(v2);

        final reverted = await provider.revert(v2, before, context);
        expect(reverted.kind, ChangeKind.update, reason: reverted.reason);
        expect(reverted.reason, 'back on 1.0.0');
        expect(currentTarget(), 'releases/1.0.0');

        final state = await read(v2);
        expect(state.version, '1.0.0');
        expect(state.message, contains('1.1.0 was rolled back at'));
        expect(provider.satisfies(v2, state), isFalse);

        // A later successful install clears the note.
        await apply(publish('1.2.0'));
        expect((await read(v2)).message, isNot(contains('rolled back')));
      },
    );

    test(
      'the build rolled back from is not deployed again by itself',
      () async {
        // An apply on a timer would otherwise reinstall it, fail the same
        // health check, and roll back — an outage every interval.
        final v1 = publish('1.0.0');
        await apply(v1);
        final before = await read(v1);
        final bad = publish('1.1.0');
        await apply(bad);
        await provider.revert(bad, before, context);

        final again = await apply(bad);
        expect(again.kind, ChangeKind.failed);
        expect(again.reason, contains('not retried: 1.1.0 was rolled back'));
        expect(currentTarget(), 'releases/1.0.0');

        // A fixed build of the same version is a different digest: it goes.
        final fixed = publish(
          '1.1.0',
          files: {'bin/app': 'fixed', 'VERSION': '1.1.0'},
        );
        final change = await apply(fixed);
        expect(change.kind, ChangeKind.update, reason: change.reason);
        expect(
          File(p.join(root(), 'current', 'bin', 'app')).readAsStringSync(),
          'fixed',
        );
      },
    );

    test('deleting the record lets the same build be tried again', () async {
      final v1 = publish('1.0.0');
      await apply(v1);
      final before = await read(v1);
      final bad = publish('1.1.0');
      await apply(bad);
      await provider.revert(bad, before, context);

      File(p.join(root(), ReleaseProvider.rolledBackFile)).deleteSync();
      final change = await apply(bad);
      expect(change.kind, ChangeKind.update, reason: change.reason);
      expect(currentTarget(), 'releases/1.1.0');
    });

    test('with nothing before, there is nothing to roll back to', () async {
      final v1 = publish('1.0.0');
      final before = await read(v1);
      await apply(v1);
      final reverted = await provider.revert(v1, before, context);
      expect(reverted.kind, ChangeKind.failed);
      expect(reverted.reason, contains('nothing to roll back to'));
    });

    test('a previous version no longer on disk cannot be restored', () async {
      final v1 = publish('1.0.0');
      await apply(v1);
      final before = await read(v1);
      await apply(publish('1.1.0'));
      Directory(
        p.join(root(), 'releases', '1.0.0'),
      ).deleteSync(recursive: true);

      final reverted = await provider.revert(v1, before, context);
      expect(reverted.kind, ChangeKind.failed);
      expect(reverted.reason, contains('no longer on disk'));
    });
  });

  group('through the planner', () {
    test(
      'a release dropped from the blueprint is removed from its own root',
      () async {
        // The root is not the default `/opt/app`: only the ledger knows where
        // the release went once the blueprint stops saying.
        final planner = NodeBlueprintService(
          providers: ProviderRegistry.of([provider]),
        );
        ResolvedBlueprint bp(List<ResolvedResource> resources) =>
            ResolvedBlueprint(
              blueprint: BlueprintId('app'),
              hash: 'sha256:${resources.length}',
              resources: resources,
            );

        final installed = await planner.apply(
          BlueprintApplyRequest(
            requestId: 'a',
            blueprint: bp([publish('1.0.0')]),
          ),
        );
        expect(installed.success, isTrue, reason: '${installed.changes}');
        expect(Directory(root()).existsSync(), isTrue);

        final removed = await planner.apply(
          BlueprintApplyRequest(requestId: 'b', blueprint: bp(const [])),
        );
        expect(removed.success, isTrue, reason: '${removed.changes}');
        expect(removed.changes.single.kind, ChangeKind.remove);
        expect(Directory(root()).existsSync(), isFalse);
      },
    );
  });

  group('absent', () {
    test('removes every release it installed, and only those', () async {
      await apply(publish('1.0.0'));
      await apply(publish('1.1.0'));
      final foreign = File(p.join(root(), 'releases', 'notes.txt'))
        ..writeAsStringSync('mine');

      final gone = release('1.1.0', ensure: Ensure.absent);
      final change = await apply(gone);
      expect(change.kind, ChangeKind.remove);
      expect(foreign.existsSync(), isTrue);
      expect(
        FileSystemEntity.typeSync(
          p.join(root(), 'current'),
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
      expect(provider.satisfies(gone, await read(gone)), isTrue);
    });

    test('an empty root is removed as well', () async {
      await apply(publish('1.0.0'));
      await apply(release('1.0.0', ensure: Ensure.absent));
      expect(Directory(root()).existsSync(), isFalse);
    });
  });

  group('root', () {
    test('defaults to /opt/<name>, and the filesystem root is refused', () {
      final open = ReleaseProvider();
      final r = ResolvedResource(
        resource: Resource(id: ResourceId('release', 'myapp')),
        origin: 'local',
      );
      expect(open.rootOf(r), '/opt/myapp');

      ResolvedResource at(String root) => ResolvedResource(
        resource: Resource(
          id: ResourceId('release', 'x'),
          params: {'root': root},
        ),
        origin: 'local',
      );
      expect(() => open.rootOf(at('/')), throwsArgumentError);
      expect(() => open.rootOf(at('relative/dir')), throwsArgumentError);
    });

    test('an empty allow-list allows nothing, and says how to fix it', () {
      final closed = ReleaseProvider(allowedRoots: const []);
      expect(
        () => closed.rootOf(publish('1.0.0')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('--allow-root'),
          ),
        ),
      );
    });
  });

  group('sources', () {
    test('gs:// goes through the JSON API with the metadata token', () async {
      final bytes = zipOf({'VERSION': '2.0.0'});
      server.bundles['gs/my-bucket/apps/app-2.0.0.zip'] = bytes;
      server.metadataToken = 'vm-token';

      final change = await apply(
        release(
          '2.0.0',
          url: 'gs://my-bucket/apps/app-2.0.0.zip',
          sha: sha256Of(bytes),
        ),
      );
      expect(change.kind, ChangeKind.create, reason: change.reason);
      expect(
        server.requested.last,
        contains('/o/apps%2Fapp-2.0.0.zip?alt=media'),
      );
      expect(server.authorizations.last, 'Bearer vm-token');
    });

    test('a refused metadata token fails the apply', () async {
      server.bundles['gs/b/app.zip'] = zipOf({'x': 'y'});
      final change = await apply(
        release('1.0.0', url: 'gs://b/app.zip', sha: 'a' * 64),
      );
      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('metadata server refused a token'));
    });

    test('bearer-file: reads the token from a file', () async {
      final tokenFile = File(p.join(sandbox.path, 'token'))
        ..writeAsStringSync('file-token\n');
      final r = publish(
        '1.0.0',
        extra: {'auth': 'bearer-file:${tokenFile.path}'},
      );
      final change = await apply(r);
      expect(change.kind, ChangeKind.create, reason: change.reason);
      expect(server.authorizations.last, 'Bearer file-token');
    });

    test('an unknown auth or scheme is refused', () async {
      final r = publish('1.0.0', extra: {'auth': 'magic'});
      expect((await apply(r)).reason, contains('unknown auth "magic"'));
      expect(
        (await apply(
          release('1.0.0', url: 'ftp://x/y.zip', sha: 'a' * 64),
        )).reason,
        contains('unsupported release url'),
      );
    });
  });
}
