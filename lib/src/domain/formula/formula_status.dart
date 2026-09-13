import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../value_objects/formula_id.dart';

/// What a formula found when it looked at the thing it manages.
///
/// Deliberately coarser than a service manager's own vocabulary. A node may be
/// running systemd, launchd, OpenRC or nothing at all, and a dashboard that
/// showed each one's words would be showing the operator the node's plumbing
/// instead of its state. These are the distinctions an operator acts on.
enum FormulaStatus {
  /// Nobody has looked, or the check itself could not run.
  ///
  /// Not the same as [absent]: a probe that failed to execute has said nothing
  /// about whether the software is there, and reporting "not installed" on that
  /// basis invites an install that overwrites a working one.
  unknown,

  /// Not on this node.
  absent,

  /// On this node, and that is all this formula manages.
  ///
  /// The honest answer for a formula that installs commands — `nmap` is either
  /// there or it is not; it has no running state to report.
  installed,

  /// Installed, and its service is running.
  running,

  /// Installed, and its service is not running.
  ///
  /// Covers stopped, paused and never-started alike: each one means the
  /// software is there and doing nothing, and the operator's move is the same.
  stopped,

  /// Installed, its service is meant to be running, and it is unhealthy.
  failed;

  /// Parses a wire name, defaulting to [unknown] — the honest answer for a
  /// word this version does not know.
  static FormulaStatus parse(String value) => FormulaStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => FormulaStatus.unknown,
  );

  /// Whether the software is on the node at all.
  ///
  /// [unknown] is not present *and* not absent, so it answers `false` here and
  /// a caller that needs the distinction has to ask for it.
  bool get isPresent => this != unknown && this != absent;
}

/// One formula's answer about itself, on one node.
@immutable
class FormulaStatusReport {
  /// Which formula this is about.
  final FormulaId formula;

  /// What it found.
  final FormulaStatus status;

  /// The version detected, when the software could say.
  final String? version;

  /// A short human-readable note — what the probe saw, or why it could not.
  final String message;

  /// When the node looked.
  final DateTime checkedAt;

  /// Creates a status report.
  FormulaStatusReport({
    required this.formula,
    required this.status,
    required this.checkedAt,
    this.version,
    this.message = '',
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'formula': formula.value,
    'status': status.name,
    if (version != null) 'version': version,
    if (message.isNotEmpty) 'message': message,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
  };

  /// Decodes from JSON.
  static FormulaStatusReport fromJson(Map<String, dynamic> json) =>
      FormulaStatusReport(
        formula: FormulaId(Json.requireString(json, 'formula')),
        status: FormulaStatus.parse(Json.optString(json, 'status') ?? ''),
        version: Json.optString(json, 'version'),
        message: Json.optString(json, 'message') ?? '',
        checkedAt:
            Json.optTimestamp(json, 'checkedAt') ?? DateTime.now().toUtc(),
      );

  @override
  String toString() => 'FormulaStatusReport(${formula.value}: ${status.name})';
}
