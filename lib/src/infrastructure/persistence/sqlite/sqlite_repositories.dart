import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../../domain/entities/audit_entry.dart';
import '../../../domain/entities/formula_spec.dart';
import '../../../domain/entities/node_descriptor.dart';
import '../../../domain/entities/node_status.dart';
import '../../../domain/entities/preset.dart';
import '../../../domain/repository/repositories.dart';
import '../../../domain/state/desired_state.dart';
import '../../../domain/value_objects/formula_id.dart';
import '../../../domain/value_objects/node_id.dart';
import '../../../domain/value_objects/preset_id.dart';

/// Opens (or creates) a SQLite database and provides the repository
/// implementations backed by it.
///
/// Entities are stored as their JSON document in a `data` column keyed by id,
/// which keeps the schema stable as the models evolve while still giving
/// durable, queryable, single-file storage. The database is opened on a file
/// path, or in-memory for tests.
class SqliteStore {
  /// The underlying database handle.
  final Database db;

  SqliteStore._(this.db) {
    _migrate();
  }

  /// Opens a database at [path] (created if missing).
  factory SqliteStore.open(String path) => SqliteStore._(sqlite3.open(path));

  /// Opens an in-memory database (data lost on [close]).
  factory SqliteStore.inMemory() => SqliteStore._(sqlite3.openInMemory());

  void _migrate() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS presets (id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS formulas (id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS desired (
        node_id TEXT PRIMARY KEY, data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS audit (
        id TEXT PRIMARY KEY, at TEXT NOT NULL, data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS metrics (
        node_id TEXT NOT NULL, at TEXT NOT NULL, data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS metrics_node_at ON metrics (node_id, at);
    ''');
  }

  /// Closes the database.
  void close() => db.dispose();

  /// The node repository.
  late final SqliteNodeRepository nodes = SqliteNodeRepository(db);

  /// The preset repository.
  late final SqlitePresetRepository presets = SqlitePresetRepository(db);

  /// The formula repository.
  late final SqliteFormulaRepository formulas = SqliteFormulaRepository(db);

  /// The desired-state repository.
  late final SqliteDesiredStateRepository desired =
      SqliteDesiredStateRepository(db);

  /// The audit repository.
  late final SqliteAuditRepository audit = SqliteAuditRepository(db);

  /// The metric repository.
  late final SqliteMetricRepository metrics = SqliteMetricRepository(db);
}

/// SQLite-backed [NodeRepository].
class SqliteNodeRepository implements NodeRepository {
  /// The database handle.
  final Database db;

  /// Creates the repository.
  SqliteNodeRepository(this.db);

  @override
  Future<void> save(NodeDescriptor node) async => db.execute(
    'INSERT OR REPLACE INTO nodes (id, data) VALUES (?, ?)',
    [node.id.value, jsonEncode(node.toJson())],
  );

  @override
  Future<NodeDescriptor?> find(NodeId id) async {
    final rows = db.select('SELECT data FROM nodes WHERE id = ?', [id.value]);
    if (rows.isEmpty) return null;
    return NodeDescriptor.fromJson(
      jsonDecode(rows.first['data'] as String) as Map<String, dynamic>,
    );
  }

  @override
  Future<List<NodeDescriptor>> all() async => db
      .select('SELECT data FROM nodes')
      .map(
        (r) => NodeDescriptor.fromJson(
          jsonDecode(r['data'] as String) as Map<String, dynamic>,
        ),
      )
      .toList();

  @override
  Future<bool> delete(NodeId id) async {
    db.execute('DELETE FROM nodes WHERE id = ?', [id.value]);
    return db.updatedRows > 0;
  }
}

/// SQLite-backed [PresetRepository].
class SqlitePresetRepository implements PresetRepository {
  /// The database handle.
  final Database db;

  /// Creates the repository.
  SqlitePresetRepository(this.db);

  @override
  Future<void> save(Preset preset) async => db.execute(
    'INSERT OR REPLACE INTO presets (id, data) VALUES (?, ?)',
    [preset.id.value, jsonEncode(preset.toJson())],
  );

  @override
  Future<Preset?> find(PresetId id) async {
    final rows = db.select('SELECT data FROM presets WHERE id = ?', [id.value]);
    if (rows.isEmpty) return null;
    return Preset.fromJson(
      jsonDecode(rows.first['data'] as String) as Map<String, dynamic>,
    );
  }

  @override
  Future<List<Preset>> all() async => db
      .select('SELECT data FROM presets')
      .map(
        (r) => Preset.fromJson(
          jsonDecode(r['data'] as String) as Map<String, dynamic>,
        ),
      )
      .toList();

  @override
  Future<bool> delete(PresetId id) async {
    db.execute('DELETE FROM presets WHERE id = ?', [id.value]);
    return db.updatedRows > 0;
  }
}

/// SQLite-backed [DesiredStateRepository].
class SqliteDesiredStateRepository implements DesiredStateRepository {
  /// The database handle.
  final Database db;

  /// Creates the repository.
  SqliteDesiredStateRepository(this.db);

  @override
  Future<void> save(NodeId nodeId, DesiredState state) async => db.execute(
    'INSERT OR REPLACE INTO desired (node_id, data) VALUES (?, ?)',
    [nodeId.value, jsonEncode(state.toJson())],
  );

  @override
  Future<DesiredState?> find(NodeId nodeId) async {
    final rows = db.select('SELECT data FROM desired WHERE node_id = ?', [
      nodeId.value,
    ]);
    if (rows.isEmpty) return null;
    return DesiredState.fromJson(
      jsonDecode(rows.first['data'] as String) as Map<String, dynamic>,
    );
  }

  @override
  Future<Map<String, DesiredState>> all() async => {
    for (final row in db.select('SELECT node_id, data FROM desired'))
      row['node_id'] as String: DesiredState.fromJson(
        jsonDecode(row['data'] as String) as Map<String, dynamic>,
      ),
  };

  @override
  Future<bool> delete(NodeId nodeId) async {
    db.execute('DELETE FROM desired WHERE node_id = ?', [nodeId.value]);
    return db.updatedRows > 0;
  }
}

/// SQLite-backed [FormulaRepository].
class SqliteFormulaRepository implements FormulaRepository {
  /// The database handle.
  final Database db;

  /// Creates the repository.
  SqliteFormulaRepository(this.db);

  @override
  Future<void> save(FormulaSpec spec) async => db.execute(
    'INSERT OR REPLACE INTO formulas (id, data) VALUES (?, ?)',
    [spec.id.value, jsonEncode(spec.toJson())],
  );

  @override
  Future<FormulaSpec?> find(FormulaId id) async {
    final rows = db.select('SELECT data FROM formulas WHERE id = ?', [
      id.value,
    ]);
    if (rows.isEmpty) return null;
    return FormulaSpec.fromJson(
      jsonDecode(rows.first['data'] as String) as Map<String, dynamic>,
    );
  }

  @override
  Future<List<FormulaSpec>> all() async => db
      .select('SELECT data FROM formulas')
      .map(
        (r) => FormulaSpec.fromJson(
          jsonDecode(r['data'] as String) as Map<String, dynamic>,
        ),
      )
      .toList();

  @override
  Future<bool> delete(FormulaId id) async {
    db.execute('DELETE FROM formulas WHERE id = ?', [id.value]);
    return db.updatedRows > 0;
  }
}

/// SQLite-backed [AuditRepository].
class SqliteAuditRepository implements AuditRepository {
  /// The database handle.
  final Database db;

  /// Creates the repository.
  SqliteAuditRepository(this.db);

  @override
  Future<void> append(AuditEntry entry) async => db.execute(
    'INSERT OR REPLACE INTO audit (id, at, data) VALUES (?, ?, ?)',
    [entry.id, entry.at.toUtc().toIso8601String(), jsonEncode(entry.toJson())],
  );

  @override
  Future<List<AuditEntry>> recent({int limit = 100}) async => db
      .select('SELECT data FROM audit ORDER BY at DESC LIMIT ?', [limit])
      .map(
        (r) => AuditEntry.fromJson(
          jsonDecode(r['data'] as String) as Map<String, dynamic>,
        ),
      )
      .toList();
}

/// SQLite-backed [MetricRepository].
class SqliteMetricRepository implements MetricRepository {
  /// The database handle.
  final Database db;

  /// Creates the repository.
  SqliteMetricRepository(this.db);

  @override
  Future<void> record(MetricSample sample) async =>
      db.execute('INSERT INTO metrics (node_id, at, data) VALUES (?, ?, ?)', [
        sample.nodeId.value,
        sample.at.toUtc().toIso8601String(),
        jsonEncode(sample.status.toJson()),
      ]);

  @override
  Future<List<MetricSample>> recentFor(
    NodeId nodeId, {
    int limit = 100,
    DateTime? since,
  }) async => db
      .select(
        'SELECT at, data FROM metrics WHERE node_id = ?'
        '${since == null ? '' : ' AND at >= ?'}'
        ' ORDER BY at DESC LIMIT ?',
        [
          nodeId.value,
          // `at` is stored as an ISO-8601 UTC string, which sorts and compares
          // lexicographically in the same order as the instants themselves.
          if (since != null) since.toUtc().toIso8601String(),
          limit,
        ],
      )
      .map(
        (r) => MetricSample(
          nodeId: nodeId,
          at: DateTime.parse(r['at'] as String),
          status: NodeStatus.fromJson(
            jsonDecode(r['data'] as String) as Map<String, dynamic>,
          ),
        ),
      )
      .toList();
}
