import '../../../domain/entities/audit_entry.dart';
import '../../../domain/entities/formula_spec.dart';
import '../../../domain/entities/node_descriptor.dart';
import '../../../domain/entities/preset.dart';
import '../../../domain/repository/repositories.dart';
import '../../../domain/value_objects/formula_id.dart';
import '../../../domain/value_objects/node_id.dart';
import '../../../domain/value_objects/preset_id.dart';

/// In-memory [NodeRepository]; data lives only for the process lifetime.
class MemoryNodeRepository implements NodeRepository {
  final Map<String, NodeDescriptor> _nodes = {};

  @override
  Future<void> save(NodeDescriptor node) async => _nodes[node.id.value] = node;

  @override
  Future<NodeDescriptor?> find(NodeId id) async => _nodes[id.value];

  @override
  Future<List<NodeDescriptor>> all() async => _nodes.values.toList();

  @override
  Future<bool> delete(NodeId id) async => _nodes.remove(id.value) != null;
}

/// In-memory [PresetRepository].
class MemoryPresetRepository implements PresetRepository {
  final Map<String, Preset> _presets = {};

  @override
  Future<void> save(Preset preset) async => _presets[preset.id.value] = preset;

  @override
  Future<Preset?> find(PresetId id) async => _presets[id.value];

  @override
  Future<List<Preset>> all() async => _presets.values.toList();

  @override
  Future<bool> delete(PresetId id) async => _presets.remove(id.value) != null;
}

/// In-memory [FormulaRepository].
class MemoryFormulaRepository implements FormulaRepository {
  final Map<String, FormulaSpec> _formulas = {};

  @override
  Future<void> save(FormulaSpec spec) async => _formulas[spec.id.value] = spec;

  @override
  Future<FormulaSpec?> find(FormulaId id) async => _formulas[id.value];

  @override
  Future<List<FormulaSpec>> all() async => _formulas.values.toList();

  @override
  Future<bool> delete(FormulaId id) async => _formulas.remove(id.value) != null;
}

/// In-memory [AuditRepository] keeping a bounded ring of recent entries.
class MemoryAuditRepository implements AuditRepository {
  final List<AuditEntry> _entries = [];

  /// The maximum number of entries retained.
  final int capacity;

  /// Creates an in-memory audit repository.
  MemoryAuditRepository({this.capacity = 10000});

  @override
  Future<void> append(AuditEntry entry) async {
    _entries.add(entry);
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
  }

  @override
  Future<List<AuditEntry>> recent({int limit = 100}) async {
    final out = _entries.reversed.take(limit).toList();
    return out;
  }
}

/// In-memory [MetricRepository] keeping a bounded ring of samples per node.
class MemoryMetricRepository implements MetricRepository {
  final Map<String, List<MetricSample>> _samples = {};

  /// The maximum number of samples retained per node.
  final int capacityPerNode;

  /// Creates an in-memory metric repository.
  MemoryMetricRepository({this.capacityPerNode = 1000});

  @override
  Future<void> record(MetricSample sample) async {
    final list = _samples.putIfAbsent(sample.nodeId.value, () => []);
    list.add(sample);
    if (list.length > capacityPerNode) {
      list.removeRange(0, list.length - capacityPerNode);
    }
  }

  @override
  Future<List<MetricSample>> recentFor(NodeId nodeId, {int limit = 100}) async {
    final list = _samples[nodeId.value] ?? const [];
    return list.reversed.take(limit).toList();
  }
}
