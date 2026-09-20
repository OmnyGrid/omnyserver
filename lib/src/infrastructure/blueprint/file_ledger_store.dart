import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../application/node/node_blueprint_service.dart';
import '../../domain/blueprint/ledger.dart';

/// Keeps a node's ledger on disk, one file per blueprint, under
/// `<data-dir>/blueprints/<id>.json`.
///
/// This is what makes cleanup survive a restart. The in-memory default forgets
/// what the node owned, so the first plan after a reboot sees every resource as
/// something that was already there and will not remove anything — safe, but it
/// means a blueprint can never really be unassigned.
///
/// Writes are chained the way the Hub's JSON repositories chain theirs: an apply
/// writes the ledger once at the end, but a node can be asked to apply two
/// blueprints at once, and two interleaved open/write/close sequences on the
/// same file produce a truncated one.
class FileLedgerStore implements LedgerStore {
  /// The directory holding the ledger files.
  final Directory directory;

  Future<void> _tail = Future.value();

  /// Creates a store rooted at [path] (the node's data directory).
  FileLedgerStore(String path)
    : directory = Directory(p.join(path, 'blueprints')) {
    directory.createSync(recursive: true);
  }

  File _fileFor(String blueprint) =>
      File(p.join(directory.path, '$blueprint.json'));

  @override
  Future<Ledger?> read(String blueprint) async {
    final file = _fileFor(blueprint);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return Ledger.fromJson(decoded.cast<String, dynamic>());
    } on Object {
      // A truncated or hand-edited ledger reads as "we own nothing", which is
      // the safe direction: the node will adopt what it finds rather than delete
      // things on the strength of a file it could not parse.
      return null;
    }
  }

  @override
  Future<void> write(Ledger ledger) => _chain(
    () => _fileFor(ledger.blueprint.value).writeAsString(
      const JsonEncoder.withIndent('  ').convert(ledger.toJson()),
    ),
  );

  @override
  Future<void> clear(String blueprint) => _chain(() async {
    final file = _fileFor(blueprint);
    if (file.existsSync()) await file.delete();
  });

  Future<void> _chain(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    // Swallow on the tail only, so one failed write does not poison every write
    // queued behind it. The caller still sees its own failure.
    _tail = next.catchError((Object _) {});
    return next;
  }
}
