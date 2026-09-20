@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_node.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The node's record of what it owns, on disk.
///
/// The in-memory store forgets it, and a node that forgets what it installed
/// adopts everything it finds on the next plan and will never remove any of it
/// — safe, and it means a blueprint can never really be unassigned. So this
/// file is what makes cleanup survive a reboot, and every one of these tests is
/// about it still being right afterwards.
void main() {
  late Directory root;
  late FileLedgerStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('omny-ledger-');
    store = FileLedgerStore(root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  final at = DateTime.utc(2026, 9, 20, 11, 30);

  Ledger ledger({
    String blueprint = 'web-server',
    String hash = 'sha256:abc',
    Set<String> owned = const {'formula:nmap'},
    Set<String> adopted = const {},
  }) => Ledger(
    blueprint: BlueprintId(blueprint),
    hash: hash,
    appliedAt: at,
    entries: {
      for (final id in {...owned, ...adopted})
        ResourceId.parse(id): LedgerEntry(
          id: ResourceId.parse(id),
          ensure: Ensure.installed,
          origin: 'local',
          adopted: adopted.contains(id),
        ),
    },
  );

  group('round-tripping', () {
    test('a ledger written comes back the same', () async {
      await store.write(
        ledger(owned: {'formula:nmap'}, adopted: {'formula:dart'}),
      );

      final read = await store.read('web-server');

      expect(read, isNotNull);
      expect(read!.blueprint.value, 'web-server');
      expect(read.hash, 'sha256:abc');
      expect(read.appliedAt, at);
      expect(read.entries, hasLength(2));
      // The adopted flag is the one field that must survive: it is the
      // difference between removing something on uninstall and leaving alone
      // what the machine had before anybody wrote a blueprint.
      expect(read.entries[ResourceId.parse('formula:dart')]!.adopted, isTrue);
      expect(read.entries[ResourceId.parse('formula:nmap')]!.adopted, isFalse);
    });

    test('a blueprint nobody has applied has no ledger, and that is not an '
        'error', () async {
      expect(await store.read('never-applied'), isNull);
    });

    test('each blueprint keeps its own file', () async {
      // A node may be asked to hold more than one, and mixing their records
      // would have one blueprint uninstalling another blueprint's software.
      await store.write(ledger(blueprint: 'web-server', owned: {'formula:a'}));
      await store.write(ledger(blueprint: 'build-host', owned: {'formula:b'}));

      expect((await store.read('web-server'))!.entries.keys.single.name, 'a');
      expect((await store.read('build-host'))!.entries.keys.single.name, 'b');
    });

    test('writing again replaces rather than appends', () async {
      await store.write(ledger(owned: {'formula:a', 'formula:b'}));
      await store.write(ledger(hash: 'sha256:def', owned: {'formula:a'}));

      final read = await store.read('web-server');
      expect(read!.hash, 'sha256:def');
      expect(read.entries.keys.map((e) => e.name), ['a']);
    });

    test('the file is written where a human can read it', () async {
      // Indented JSON at a predictable path, because the first thing anybody
      // does when a node removes the wrong thing is go and look at this file.
      await store.write(ledger());

      final file = File(p.join(root.path, 'blueprints', 'web-server.json'));
      expect(file.existsSync(), isTrue);
      final text = file.readAsStringSync();
      expect(text, contains('\n  '));
      expect(jsonDecode(text), isA<Map<String, dynamic>>());
    });
  });

  group('a file it cannot trust', () {
    // All three read as "we own nothing", which is the safe direction: the node
    // adopts what it finds rather than deleting things on the strength of a
    // file it could not parse. The alternative — throwing — takes the node out
    // of service over a single corrupt byte.
    test('truncated JSON is not an exception', () async {
      await store.write(ledger());
      final file = File(p.join(root.path, 'blueprints', 'web-server.json'));
      final text = file.readAsStringSync();
      file.writeAsStringSync(text.substring(0, text.length ~/ 2));

      expect(await store.read('web-server'), isNull);
    });

    test('valid JSON that is not a ledger is not an exception', () async {
      File(
        p.join(root.path, 'blueprints', 'web-server.json'),
      ).writeAsStringSync('[1, 2, 3]');

      expect(await store.read('web-server'), isNull);
    });

    test('an object missing what a ledger needs is not an exception', () async {
      File(
        p.join(root.path, 'blueprints', 'web-server.json'),
      ).writeAsStringSync('{"hello": "world"}');

      expect(await store.read('web-server'), isNull);
    });
  });

  group('clearing', () {
    test('removes the record, and reads as never applied afterwards', () async {
      await store.write(ledger());
      await store.clear('web-server');

      expect(await store.read('web-server'), isNull);
      expect(
        File(p.join(root.path, 'blueprints', 'web-server.json')).existsSync(),
        isFalse,
      );
    });

    test('clearing one nobody applied is a no-op, not a failure', () async {
      await expectLater(store.clear('never-applied'), completes);
    });

    test('leaves the other blueprints alone', () async {
      await store.write(ledger(blueprint: 'web-server'));
      await store.write(ledger(blueprint: 'build-host'));

      await store.clear('web-server');

      expect(await store.read('build-host'), isNotNull);
    });
  });

  group('concurrent writes', () {
    test(
      'interleaved writes leave a whole file, not a truncated one',
      () async {
        // The reason writes are chained. A node can be asked to apply two
        // blueprints at once, and two open/write/close sequences interleaved on
        // one file produce a file that is neither — which then reads as "we own
        // nothing" and quietly loses everything the node was tracking.
        await Future.wait([
          for (var i = 0; i < 20; i++)
            store.write(
              ledger(
                hash: 'sha256:$i',
                owned: {for (var j = 0; j <= i; j++) 'formula:f$j'},
              ),
            ),
        ]);

        final read = await store.read('web-server');
        expect(read, isNotNull, reason: 'the file was left unparseable');
        // Whichever write landed last, the file holds exactly that one.
        final index = int.parse(read!.hash.split(':').last);
        expect(read.entries, hasLength(index + 1));
      },
    );

    test('a failed write does not poison the ones queued behind it', () async {
      // The tail swallows, so the next write still runs; the caller still sees
      // its own failure. A ledger directory that has gone away underneath the
      // store is how that happens for real — someone cleaning a data dir while
      // the agent is up.
      Directory(p.join(root.path, 'blueprints')).deleteSync(recursive: true);
      await expectLater(
        store.write(ledger()),
        throwsA(isA<FileSystemException>()),
      );

      Directory(p.join(root.path, 'blueprints')).createSync(recursive: true);
      await store.write(ledger(blueprint: 'web-server'));
      expect(await store.read('web-server'), isNotNull);
    });
  });

  test('a ledger file cannot be written outside its directory', () {
    // Not the store's doing — the id refuses it first. Worth pinning here,
    // because this is the only thing standing between a blueprint id and a
    // path, and the store joins it straight onto one.
    expect(() => BlueprintId('../../etc/passwd'), throwsA(isA<Exception>()));
    expect(() => BlueprintId('no/such/dir'), throwsA(isA<Exception>()));
    expect(() => BlueprintId(''), throwsA(isA<Exception>()));
  });

  test('the directory is created, so a fresh node can write straight away', () {
    final fresh = Directory.systemTemp.createTempSync('omny-ledger-fresh-');
    addTearDown(() => fresh.deleteSync(recursive: true));

    FileLedgerStore(p.join(fresh.path, 'data'));

    expect(
      Directory(p.join(fresh.path, 'data', 'blueprints')).existsSync(),
      isTrue,
    );
  });
}
