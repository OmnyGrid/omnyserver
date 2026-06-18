import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import 'formula_action.dart';

/// The result of validating a formula's managed software.
@immutable
class ValidationResult {
  /// Whether the managed software is present and healthy.
  final bool valid;

  /// The detected version, if any.
  final String? detectedVersion;

  /// A human-readable explanation (especially when [valid] is false).
  final String message;

  /// Creates a validation result.
  const ValidationResult({
    required this.valid,
    this.detectedVersion,
    this.message = '',
  });

  /// A passing validation result.
  factory ValidationResult.ok({String? version, String message = 'ok'}) =>
      ValidationResult(valid: true, detectedVersion: version, message: message);

  /// A failing validation result.
  factory ValidationResult.fail(String message) =>
      ValidationResult(valid: false, message: message);

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'valid': valid,
    if (detectedVersion != null) 'detectedVersion': detectedVersion,
    'message': message,
  };

  /// Decodes from JSON.
  static ValidationResult fromJson(Map<String, dynamic> json) =>
      ValidationResult(
        valid: Json.optBool(json, 'valid'),
        detectedVersion: Json.optString(json, 'detectedVersion'),
        message: Json.optString(json, 'message') ?? '',
      );
}

/// The structured outcome of running a single formula action.
@immutable
class FormulaResult {
  /// The formula id this result belongs to.
  final String formula;

  /// The action that was run.
  final FormulaAction action;

  /// Whether the action succeeded.
  final bool success;

  /// Whether the action changed system state (false ⇒ already converged;
  /// the basis for idempotent presets).
  final bool changed;

  /// A human-readable summary.
  final String message;

  /// Captured output / log lines.
  final List<String> logs;

  /// When the action finished (UTC).
  final DateTime finishedAt;

  /// Creates a formula result.
  const FormulaResult({
    required this.formula,
    required this.action,
    required this.success,
    required this.finishedAt,
    this.changed = false,
    this.message = '',
    this.logs = const [],
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'formula': formula,
    'action': action.name,
    'success': success,
    'changed': changed,
    'message': message,
    if (logs.isNotEmpty) 'logs': logs,
    'finishedAt': finishedAt.toUtc().toIso8601String(),
  };

  /// Decodes from JSON.
  static FormulaResult fromJson(Map<String, dynamic> json) => FormulaResult(
    formula: Json.requireString(json, 'formula'),
    action: FormulaAction.parse(Json.requireString(json, 'action')),
    success: Json.optBool(json, 'success'),
    changed: Json.optBool(json, 'changed'),
    message: Json.optString(json, 'message') ?? '',
    logs: Json.optStringList(json, 'logs'),
    finishedAt: Json.requireTimestamp(json, 'finishedAt'),
  );
}
