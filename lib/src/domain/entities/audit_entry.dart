import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

/// The outcome of an audited operation.
enum AuditOutcome {
  /// The operation completed successfully.
  success,

  /// The operation was attempted but failed.
  failure,

  /// The operation was denied by authorization.
  denied;

  /// Parses a wire name, defaulting to [failure].
  static AuditOutcome parse(String value) => AuditOutcome.values.firstWhere(
    (o) => o.name == value,
    orElse: () => AuditOutcome.failure,
  );
}

/// An immutable record of a security- or operationally-relevant action, for
/// the audit trail (who did what, to which target, with what outcome).
@immutable
class AuditEntry {
  /// A unique id for this entry.
  final String id;

  /// When the action occurred (UTC).
  final DateTime at;

  /// The principal that performed the action (or `system`).
  final String principal;

  /// The action performed (e.g. `node.restart`, `preset.apply`).
  final String action;

  /// The target of the action (e.g. a node id), if any.
  final String? target;

  /// The outcome.
  final AuditOutcome outcome;

  /// Free-form detail (e.g. an error message).
  final String? detail;

  /// Creates an audit entry.
  const AuditEntry({
    required this.id,
    required this.at,
    required this.principal,
    required this.action,
    required this.outcome,
    this.target,
    this.detail,
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'principal': principal,
    'action': action,
    if (target != null) 'target': target,
    'outcome': outcome.name,
    if (detail != null) 'detail': detail,
  };

  /// Decodes from JSON.
  static AuditEntry fromJson(Map<String, dynamic> json) => AuditEntry(
    id: Json.requireString(json, 'id'),
    at: Json.requireTimestamp(json, 'at'),
    principal: Json.requireString(json, 'principal'),
    action: Json.requireString(json, 'action'),
    target: Json.optString(json, 'target'),
    outcome: AuditOutcome.parse(Json.optString(json, 'outcome') ?? 'failure'),
    detail: Json.optString(json, 'detail'),
  );
}
