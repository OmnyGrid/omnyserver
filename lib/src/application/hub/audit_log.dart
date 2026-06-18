import '../../domain/entities/audit_entry.dart';
import '../../domain/repository/repositories.dart';
import '../../shared/utils/clock.dart';
import '../../shared/utils/id_generator.dart';

/// Records security- and operationally-relevant actions to an
/// [AuditRepository], stamping each with a generated id and the current time.
class AuditLog {
  final AuditRepository _repository;

  /// The time source used to stamp entries.
  final Clock clock;

  /// The id generator used for entry ids.
  final IdGenerator ids;

  /// Creates an audit log backed by an [AuditRepository].
  AuditLog(
    this._repository, {
    this.clock = const SystemClock(),
    this.ids = const UuidGenerator(),
  });

  /// Appends an audit entry.
  Future<void> record({
    required String principal,
    required String action,
    required AuditOutcome outcome,
    String? target,
    String? detail,
  }) => _repository.append(
    AuditEntry(
      id: ids.next(),
      at: clock.now(),
      principal: principal,
      action: action,
      outcome: outcome,
      target: target,
      detail: detail,
    ),
  );

  /// The most recent entries, newest first.
  Future<List<AuditEntry>> recent({int limit = 100}) =>
      _repository.recent(limit: limit);
}
