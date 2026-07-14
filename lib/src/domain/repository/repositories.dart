import '../entities/audit_entry.dart';
import '../entities/formula_spec.dart';
import '../entities/grant.dart';
import '../entities/node_descriptor.dart';
import '../entities/node_status.dart';
import '../entities/preset.dart';
import '../state/desired_state.dart';
import '../value_objects/formula_id.dart';
import '../value_objects/node_id.dart';
import '../value_objects/preset_id.dart';

/// Persists the Hub's view of registered nodes.
///
/// All repositories are async (so SQLite / network backends fit) and are the
/// designed seam for the in-memory, JSON-directory and SQLite implementations.
abstract class NodeRepository {
  /// Inserts or replaces [node].
  Future<void> save(NodeDescriptor node);

  /// Returns the node with [id], or `null`.
  Future<NodeDescriptor?> find(NodeId id);

  /// Returns all known nodes.
  Future<List<NodeDescriptor>> all();

  /// Deletes the node with [id]; returns true if a node was removed.
  Future<bool> delete(NodeId id);
}

/// Persists the credentials the Hub has issued.
///
/// Grants carry a token *hash*, never a token — see [Grant] — so this store can
/// be a plain file on disk without being a list of passwords.
abstract class GrantRepository {
  /// Inserts or replaces [grant].
  Future<void> save(Grant grant);

  /// The grant whose token hashes to [tokenHash], or `null`.
  Future<Grant?> findByTokenHash(String tokenHash);

  /// The grant with [id], or `null`.
  Future<Grant?> find(String id);

  /// Every issued grant.
  Future<List<Grant>> all();

  /// Revokes the grant with [id]; returns true if one was removed.
  Future<bool> delete(String id);
}

/// Persists the state each node is *supposed* to be in.
///
/// The Hub's other repositories record what happened; this one records what is
/// meant to be true. The difference between the two is drift, and being able to
/// ask for it — rather than re-applying a preset and hoping — is the whole point
/// of declaring a state at all.
abstract class DesiredStateRepository {
  /// Sets the state [nodeId] should converge to.
  Future<void> save(NodeId nodeId, DesiredState state);

  /// The state [nodeId] should be in, or `null` if none was ever declared.
  Future<DesiredState?> find(NodeId nodeId);

  /// Every declared state, by node id.
  Future<Map<String, DesiredState>> all();

  /// Stops expecting anything of [nodeId]; returns true if it had a state.
  Future<bool> delete(NodeId nodeId);
}

/// Persists [Preset]s.
abstract class PresetRepository {
  /// Inserts or replaces [preset].
  Future<void> save(Preset preset);

  /// Returns the preset with [id], or `null`.
  Future<Preset?> find(PresetId id);

  /// Returns all presets.
  Future<List<Preset>> all();

  /// Deletes the preset with [id]; returns true if removed.
  Future<bool> delete(PresetId id);
}

/// Persists [FormulaSpec]s (formula catalogue).
abstract class FormulaRepository {
  /// Inserts or replaces [spec].
  Future<void> save(FormulaSpec spec);

  /// Returns the formula spec with [id], or `null`.
  Future<FormulaSpec?> find(FormulaId id);

  /// Returns all formula specs.
  Future<List<FormulaSpec>> all();

  /// Deletes the formula spec with [id]; returns true if removed.
  Future<bool> delete(FormulaId id);
}

/// Persists the audit trail.
abstract class AuditRepository {
  /// Appends [entry] to the trail.
  Future<void> append(AuditEntry entry);

  /// Returns the most recent entries, newest first, up to [limit].
  Future<List<AuditEntry>> recent({int limit = 100});
}

/// A persisted, timestamped metric sample for a node.
class MetricSample {
  /// The node the sample belongs to.
  final NodeId nodeId;

  /// When the sample was captured.
  final DateTime at;

  /// The status snapshot.
  final NodeStatus status;

  /// Creates a metric sample.
  const MetricSample({
    required this.nodeId,
    required this.at,
    required this.status,
  });
}

/// Persists historical metric samples for nodes.
abstract class MetricRepository {
  /// Records a [sample].
  Future<void> record(MetricSample sample);

  /// Returns recent samples for [nodeId], newest first, up to [limit].
  ///
  /// [since] bounds the window: only samples captured at or after it are
  /// returned. Applied *before* [limit], so "the last hour" is the last hour and
  /// not the newest [limit] samples that happen to fall in it.
  Future<List<MetricSample>> recentFor(
    NodeId nodeId, {
    int limit = 100,
    DateTime? since,
  });
}
