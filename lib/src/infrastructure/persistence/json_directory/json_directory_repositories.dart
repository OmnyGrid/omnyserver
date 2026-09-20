import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../domain/blueprint/blueprint.dart';
import '../../../domain/entities/audit_entry.dart';
import '../../../domain/entities/formula_spec.dart';
import '../../../domain/entities/grant.dart';
import '../../../domain/entities/node_descriptor.dart';
import '../../../domain/entities/node_status.dart';
import '../../../domain/entities/preset.dart';
import '../../../domain/repository/repositories.dart';
import '../../../shared/json/json_codec_helpers.dart';
import '../../../domain/state/desired_state.dart';
import '../../../domain/value_objects/blueprint_id.dart';
import '../../../domain/value_objects/formula_id.dart';
import '../../../domain/value_objects/node_id.dart';
import '../../../domain/value_objects/preset_id.dart';

/// Chains writes so that their open/write/close sequences cannot interleave.
///
/// Sync I/O used to give this for free: nothing else could run between a
/// write's open and its close. Async writes can interleave — two overlapping
/// whole-file writes to one path could tear it, and two appends could land out
/// of order — so a write is queued behind the ones already issued rather than
/// merely started.
class _WriteQueue {
  Future<void> _tail = Future.value();

  /// Runs [action] once every write already queued here has finished.
  Future<T> add<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    // The queue only orders writes; a failure belongs to its own caller, so it
    // is swallowed here rather than poisoning the tail for everyone after it.
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// Shared helpers for directory-backed JSON repositories.
///
/// Entity ids are validated tokens (`[A-Za-z0-9_.-]`), so they are safe to use
/// directly as file names. Each collection lives in its own sub-directory; logs
/// (audit, metrics) are append-only JSONL files.
///
/// The I/O is asynchronous throughout. Every repository method here implements a
/// `Future`-returning interface and is called from the Hub's request handlers,
/// so a `…Sync` call would block the single isolate that is also serving every
/// other connection — `all()` over a fleet directory is one blocking read per
/// node.
class _JsonDir {
  final Directory dir;

  final _writes = _WriteQueue();

  _JsonDir(String path, String name) : dir = Directory(p.join(path, name)) {
    // A constructor cannot await, and this runs once, when the repository is
    // wired up rather than per request.
    dir.createSync(recursive: true);
  }

  File _file(String id) => File(p.join(dir.path, '$id.json'));

  Future<void> writeObject(String id, Map<String, dynamic> json) => _writes.add(
    () => _file(
      id,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(json)),
  );

  Future<Map<String, dynamic>?> readObject(String id) async {
    final file = _file(id);
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> readAll() async {
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    // Read them concurrently, and tolerate one being deleted between the
    // listing and its read — a concurrent `delete` should not fail a listing.
    final contents = await Future.wait(
      files.map(
        (f) => f.readAsString().then<String?>((s) => s, onError: (_) => null),
      ),
    );
    return [
      for (final content in contents)
        if (content != null) jsonDecode(content) as Map<String, dynamic>,
    ];
  }

  Future<bool> deleteObject(String id) => _writes.add(() async {
    final file = _file(id);
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  });
}

/// JSON-directory [NodeRepository] (`<root>/nodes/<id>.json`).
class JsonNodeRepository implements NodeRepository {
  final _JsonDir _store;

  /// Creates a node repository rooted at [path].
  JsonNodeRepository(String path) : _store = _JsonDir(path, 'nodes');

  @override
  Future<void> save(NodeDescriptor node) =>
      _store.writeObject(node.id.value, node.toJson());

  @override
  Future<NodeDescriptor?> find(NodeId id) async {
    final json = await _store.readObject(id.value);
    return json == null ? null : NodeDescriptor.fromJson(json);
  }

  @override
  Future<List<NodeDescriptor>> all() async =>
      (await _store.readAll()).map(NodeDescriptor.fromJson).toList();

  @override
  Future<bool> delete(NodeId id) => _store.deleteObject(id.value);
}

/// JSON-directory [PresetRepository] (`<root>/presets/<id>.json`).
class JsonPresetRepository implements PresetRepository {
  final _JsonDir _store;

  /// Creates a preset repository rooted at [path].
  JsonPresetRepository(String path) : _store = _JsonDir(path, 'presets');

  @override
  Future<void> save(Preset preset) =>
      _store.writeObject(preset.id.value, preset.toJson());

  @override
  Future<Preset?> find(PresetId id) async {
    final json = await _store.readObject(id.value);
    return json == null ? null : Preset.fromJson(json);
  }

  @override
  Future<List<Preset>> all() async =>
      (await _store.readAll()).map(Preset.fromJson).toList();

  @override
  Future<bool> delete(PresetId id) => _store.deleteObject(id.value);
}

/// JSON-directory [BlueprintRepository] (`<root>/blueprints/<id>.json`).
///
/// The file holds the parsed blueprint *and* the bytes it was authored in, so a
/// YAML blueprint survives a round trip through this directory as the YAML
/// somebody wrote. Both are written from one parse and neither is edited on its
/// own, so they cannot come to disagree.
class JsonBlueprintRepository implements BlueprintRepository {
  final _JsonDir _store;

  /// Creates a blueprint repository rooted at [path].
  JsonBlueprintRepository(String path) : _store = _JsonDir(path, 'blueprints');

  @override
  Future<void> save(Blueprint blueprint) =>
      _store.writeObject(blueprint.id.value, blueprint.toJson());

  @override
  Future<Blueprint?> find(BlueprintId id) async {
    final json = await _store.readObject(id.value);
    return json == null ? null : Blueprint.fromJson(json);
  }

  @override
  Future<List<Blueprint>> all() async =>
      (await _store.readAll()).map(Blueprint.fromJson).toList();

  @override
  Future<bool> delete(BlueprintId id) => _store.deleteObject(id.value);
}

/// JSON-directory [GrantRepository] (`<root>/grants/<id>.json`).
///
/// A file per grant, holding a hash rather than a token — so this directory is
/// not a list of passwords, and losing it costs you the ability to revoke, not
/// the secrecy of what you issued.
class JsonGrantRepository implements GrantRepository {
  final _JsonDir _store;

  /// Creates a grant repository rooted at [path].
  JsonGrantRepository(String path) : _store = _JsonDir(path, 'grants');

  @override
  Future<void> save(Grant grant) =>
      _store.writeObject(grant.id, grant.toJson());

  @override
  Future<Grant?> find(String id) async {
    final json = await _store.readObject(id);
    return json == null ? null : Grant.fromJson(json);
  }

  @override
  Future<Grant?> findByTokenHash(String tokenHash) async {
    for (final json in await _store.readAll()) {
      final grant = Grant.fromJson(json);
      if (grant.tokenHash == tokenHash) return grant;
    }
    return null;
  }

  @override
  Future<List<Grant>> all() async =>
      (await _store.readAll()).map(Grant.fromJson).toList();

  @override
  Future<bool> delete(String id) => _store.deleteObject(id);
}

/// JSON-directory [DesiredStateRepository] (`<root>/desired/<node>.json`).
class JsonDesiredStateRepository implements DesiredStateRepository {
  final _JsonDir _store;

  /// Creates a desired-state repository rooted at [path].
  JsonDesiredStateRepository(String path) : _store = _JsonDir(path, 'desired');

  @override
  Future<void> save(NodeId nodeId, DesiredState state) => _store.writeObject(
    nodeId.value,
    {'nodeId': nodeId.value, ...state.toJson()},
  );

  @override
  Future<DesiredState?> find(NodeId nodeId) async {
    final json = await _store.readObject(nodeId.value);
    return json == null ? null : DesiredState.fromJson(json);
  }

  @override
  Future<Map<String, DesiredState>> all() async => {
    for (final json in await _store.readAll())
      Json.requireString(json, 'nodeId'): DesiredState.fromJson(json),
  };

  @override
  Future<bool> delete(NodeId nodeId) => _store.deleteObject(nodeId.value);
}

/// JSON-directory [FormulaRepository] (`<root>/formulas/<id>.json`).
class JsonFormulaRepository implements FormulaRepository {
  final _JsonDir _store;

  /// Creates a formula repository rooted at [path].
  JsonFormulaRepository(String path) : _store = _JsonDir(path, 'formulas');

  @override
  Future<void> save(FormulaSpec spec) =>
      _store.writeObject(spec.id.value, spec.toJson());

  @override
  Future<FormulaSpec?> find(FormulaId id) async {
    final json = await _store.readObject(id.value);
    return json == null ? null : FormulaSpec.fromJson(json);
  }

  @override
  Future<List<FormulaSpec>> all() async =>
      (await _store.readAll()).map(FormulaSpec.fromJson).toList();

  @override
  Future<bool> delete(FormulaId id) => _store.deleteObject(id.value);
}

/// JSON-lines [AuditRepository] (`<root>/audit.jsonl`, append-only).
class JsonAuditRepository implements AuditRepository {
  final File _file;

  /// An audit log whose entries land out of order is worse than one that makes
  /// its writer wait, so appends are queued.
  final _writes = _WriteQueue();

  /// Creates an audit repository rooted at [path].
  JsonAuditRepository(String path) : _file = File(p.join(path, 'audit.jsonl')) {
    _file.parent.createSync(recursive: true);
  }

  @override
  Future<void> append(AuditEntry entry) => _writes.add(
    () => _file.writeAsString(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
    ),
  );

  @override
  Future<List<AuditEntry>> recent({int limit = 100}) async {
    if (!await _file.exists()) return const [];
    final lines = (await _file.readAsLines()).where((l) => l.trim().isNotEmpty);
    return lines
        .map((l) => AuditEntry.fromJson(jsonDecode(l) as Map<String, dynamic>))
        .toList()
        .reversed
        .take(limit)
        .toList();
  }
}

/// JSON-lines [MetricRepository] (`<root>/metrics/<nodeId>.jsonl`).
class JsonMetricRepository implements MetricRepository {
  final Directory _dir;

  /// Samples are appended in arrival order, as they were when the write was
  /// synchronous — `recentFor` reads the tail of the file and trusts it.
  final _writes = _WriteQueue();

  /// Creates a metric repository rooted at [path].
  JsonMetricRepository(String path)
    : _dir = Directory(p.join(path, 'metrics')) {
    _dir.createSync(recursive: true);
  }

  File _fileFor(String nodeId) => File(p.join(_dir.path, '$nodeId.jsonl'));

  @override
  Future<void> record(MetricSample sample) {
    final json = {
      'at': sample.at.toUtc().toIso8601String(),
      'status': sample.status.toJson(),
    };
    return _writes.add(
      () => _fileFor(
        sample.nodeId.value,
      ).writeAsString('${jsonEncode(json)}\n', mode: FileMode.append),
    );
  }

  @override
  Future<List<MetricSample>> recentFor(
    NodeId nodeId, {
    int limit = 100,
    DateTime? since,
  }) async {
    final file = _fileFor(nodeId.value);
    if (!await file.exists()) return const [];
    final lines = (await file.readAsLines()).where((l) => l.trim().isNotEmpty);
    return lines
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .map(
          (j) => MetricSample(
            nodeId: nodeId,
            at: DateTime.parse(j['at'] as String),
            status: NodeStatus.fromJson(j['status'] as Map<String, dynamic>),
          ),
        )
        .where((s) => since == null || !s.at.isBefore(since))
        .toList()
        .reversed
        .take(limit)
        .toList();
  }
}
