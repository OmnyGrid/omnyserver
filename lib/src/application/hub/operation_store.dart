import '../../domain/entities/operation.dart';

/// The operations the Hub is running, and the last few it ran.
///
/// Bounded and in memory, like the log tail: an operation is a *handle on work in
/// flight*, and what it leaves behind — the formula that ran, whether it worked,
/// who asked — is already in the audit trail and the event stream, which are the
/// things that persist. Keeping every operation forever would be a second, worse
/// copy of both.
class OperationStore {
  /// How many finished operations to keep. Running ones are never evicted.
  final int capacity;

  final Map<String, Operation> _operations = {};

  /// Creates a store retaining [capacity] finished operations.
  OperationStore({this.capacity = 200});

  /// Records or replaces [operation].
  void put(Operation operation) {
    _operations[operation.id] = operation;
    _evict();
  }

  /// The operation with [id], or `null`.
  Operation? find(String id) => _operations[id];

  /// Every known operation, newest first; optionally only those for [nodeId], or
  /// only those still running.
  List<Operation> all({String? nodeId, bool runningOnly = false}) {
    final matches = _operations.values.where(
      (o) =>
          (nodeId == null || o.nodeId == nodeId) &&
          (!runningOnly || o.isRunning),
    );
    return matches.toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  /// Drops the oldest *finished* operations beyond the cap.
  ///
  /// Never a running one: an operation nobody can ask about any more is worse
  /// than useless — it is work happening that the operator has been given no way
  /// to see.
  void _evict() {
    final finished = _operations.values.where((o) => !o.isRunning).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final excess = finished.length - capacity;
    for (var i = 0; i < excess; i++) {
      _operations.remove(finished[i].id);
    }
  }
}
