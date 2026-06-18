import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../formula/formula_action.dart';
import '../value_objects/formula_id.dart';
import '../value_objects/preset_id.dart';

/// A reference to a formula within a preset: which formula, which action to
/// drive, and an optional pinned version.
@immutable
class PresetStep {
  /// The formula to run.
  final FormulaId formula;

  /// The action to apply (defaults to `install`, which is idempotent for
  /// well-behaved formulas).
  final FormulaAction action;

  /// The target version, if pinned.
  final String? version;

  /// Creates a preset step.
  const PresetStep({
    required this.formula,
    this.action = FormulaAction.install,
    this.version,
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'formula': formula.value,
    'action': action.name,
    if (version != null) 'version': version,
  };

  /// Decodes from JSON.
  static PresetStep fromJson(Map<String, dynamic> json) => PresetStep(
    formula: FormulaId(Json.requireString(json, 'formula')),
    action: FormulaAction.parse(Json.optString(json, 'action') ?? 'install'),
    version: Json.optString(json, 'version'),
  );
}

/// A named desired-configuration bundle: an ordered list of formula steps that
/// move a server toward a target state. Presets are designed to be idempotent.
@immutable
class Preset {
  /// The preset identity.
  final PresetId id;

  /// A human-friendly name.
  final String name;

  /// A short description.
  final String description;

  /// The ordered steps applied to converge a node to this preset.
  final List<PresetStep> steps;

  /// Creates a preset.
  const Preset({
    required this.id,
    required this.name,
    this.description = '',
    this.steps = const [],
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'id': id.value,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    'steps': steps.map((s) => s.toJson()).toList(),
  };

  /// Decodes from JSON.
  static Preset fromJson(Map<String, dynamic> json) => Preset(
    id: PresetId(Json.requireString(json, 'id')),
    name: Json.optString(json, 'name') ?? Json.requireString(json, 'id'),
    description: Json.optString(json, 'description') ?? '',
    steps: Json.optObjectList(json, 'steps').map(PresetStep.fromJson).toList(),
  );

  @override
  String toString() => 'Preset(${id.value}, ${steps.length} steps)';
}
