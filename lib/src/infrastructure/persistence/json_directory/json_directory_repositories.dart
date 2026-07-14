import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../domain/entities/audit_entry.dart';
import '../../../domain/entities/formula_spec.dart';
import '../../../domain/entities/node_descriptor.dart';
import '../../../domain/entities/node_status.dart';
import '../../../domain/entities/preset.dart';
import '../../../domain/repository/repositories.dart';
import '../../../shared/json/json_codec_helpers.dart';
import '../../../domain/state/desired_state.dart';
import '../../../domain/value_objects/formula_id.dart';
import '../../../domain/value_objects/node_id.dart';
import '../../../domain/value_objects/preset_id.dart';

/// Shared helpers for directory-backed JSON repositories.
///
/// Entity ids are validated tokens (`[A-Za-z0-9_.-]`), so they are safe to use
/// directly as file names. Each collection lives in its own sub-directory; logs
/// (audit, metrics) are append-only JSONL files.
class _JsonDir {
  final Directory dir;

  _JsonDir(String path, String name) : dir = Directory(p.join(path, name)) {
    dir.createSync(recursive: true);
  }

  File _file(String id) => File(p.join(dir.path, '$id.json'));

  void writeObject(String id, Map<String, dynamic> json) => _file(
    id,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));

  Map<String, dynamic>? readObject(String id) {
    final file = _file(id);
    if (!file.existsSync()) return null;
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  List<Map<String, dynamic>> readAll() {
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)
        .toList();
  }

  bool deleteObject(String id) {
    final file = _file(id);
    if (!file.existsSync()) return false;
    file.deleteSync();
    return true;
  }
}

/// JSON-directory [NodeRepository] (`<root>/nodes/<id>.json`).
class JsonNodeRepository implements NodeRepository {
  final _JsonDir _store;

  /// Creates a node repository rooted at [path].
  JsonNodeRepository(String path) : _store = _JsonDir(path, 'nodes');

  @override
  Future<void> save(NodeDescriptor node) async =>
      _store.writeObject(node.id.value, node.toJson());

  @override
  Future<NodeDescriptor?> find(NodeId id) async {
    final json = _store.readObject(id.value);
    return json == null ? null : NodeDescriptor.fromJson(json);
  }

  @override
  Future<List<NodeDescriptor>> all() async =>
      _store.readAll().map(NodeDescriptor.fromJson).toList();

  @override
  Future<bool> delete(NodeId id) async => _store.deleteObject(id.value);
}

/// JSON-directory [PresetRepository] (`<root>/presets/<id>.json`).
class JsonPresetRepository implements PresetRepository {
  final _JsonDir _store;

  /// Creates a preset repository rooted at [path].
  JsonPresetRepository(String path) : _store = _JsonDir(path, 'presets');

  @override
  Future<void> save(Preset preset) async =>
      _store.writeObject(preset.id.value, preset.toJson());

  @override
  Future<Preset?> find(PresetId id) async {
    final json = _store.readObject(id.value);
    return json == null ? null : Preset.fromJson(json);
  }

  @override
  Future<List<Preset>> all() async =>
      _store.readAll().map(Preset.fromJson).toList();

  @override
  Future<bool> delete(PresetId id) async => _store.deleteObject(id.value);
}

/// JSON-directory [DesiredStateRepository] (`<root>/desired/<node>.json`).
class JsonDesiredStateRepository implements DesiredStateRepository {
  final _JsonDir _store;

  /// Creates a desired-state repository rooted at [path].
  JsonDesiredStateRepository(String path) : _store = _JsonDir(path, 'desired');

  @override
  Future<void> save(NodeId nodeId, DesiredState state) async => _store
      .writeObject(nodeId.value, {'nodeId': nodeId.value, ...state.toJson()});

  @override
  Future<DesiredState?> find(NodeId nodeId) async {
    final json = _store.readObject(nodeId.value);
    return json == null ? null : DesiredState.fromJson(json);
  }

  @override
  Future<Map<String, DesiredState>> all() async => {
    for (final json in _store.readAll())
      Json.requireString(json, 'nodeId'): DesiredState.fromJson(json),
  };

  @override
  Future<bool> delete(NodeId nodeId) async => _store.deleteObject(nodeId.value);
}

/// JSON-directory [FormulaRepository] (`<root>/formulas/<id>.json`).
class JsonFormulaRepository implements FormulaRepository {
  final _JsonDir _store;

  /// Creates a formula repository rooted at [path].
  JsonFormulaRepository(String path) : _store = _JsonDir(path, 'formulas');

  @override
  Future<void> save(FormulaSpec spec) async =>
      _store.writeObject(spec.id.value, spec.toJson());

  @override
  Future<FormulaSpec?> find(FormulaId id) async {
    final json = _store.readObject(id.value);
    return json == null ? null : FormulaSpec.fromJson(json);
  }

  @override
  Future<List<FormulaSpec>> all() async =>
      _store.readAll().map(FormulaSpec.fromJson).toList();

  @override
  Future<bool> delete(FormulaId id) async => _store.deleteObject(id.value);
}

/// JSON-lines [AuditRepository] (`<root>/audit.jsonl`, append-only).
class JsonAuditRepository implements AuditRepository {
  final File _file;

  /// Creates an audit repository rooted at [path].
  JsonAuditRepository(String path) : _file = File(p.join(path, 'audit.jsonl')) {
    _file.parent.createSync(recursive: true);
  }

  @override
  Future<void> append(AuditEntry entry) async => _file.writeAsStringSync(
    '${jsonEncode(entry.toJson())}\n',
    mode: FileMode.append,
  );

  @override
  Future<List<AuditEntry>> recent({int limit = 100}) async {
    if (!_file.existsSync()) return const [];
    final lines = _file.readAsLinesSync().where((l) => l.trim().isNotEmpty);
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

  /// Creates a metric repository rooted at [path].
  JsonMetricRepository(String path)
    : _dir = Directory(p.join(path, 'metrics')) {
    _dir.createSync(recursive: true);
  }

  File _fileFor(String nodeId) => File(p.join(_dir.path, '$nodeId.jsonl'));

  @override
  Future<void> record(MetricSample sample) async {
    final json = {
      'at': sample.at.toUtc().toIso8601String(),
      'status': sample.status.toJson(),
    };
    _fileFor(
      sample.nodeId.value,
    ).writeAsStringSync('${jsonEncode(json)}\n', mode: FileMode.append);
  }

  @override
  Future<List<MetricSample>> recentFor(
    NodeId nodeId, {
    int limit = 100,
    DateTime? since,
  }) async {
    final file = _fileFor(nodeId.value);
    if (!file.existsSync()) return const [];
    final lines = file.readAsLinesSync().where((l) => l.trim().isNotEmpty);
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
