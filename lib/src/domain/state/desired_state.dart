import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../entities/node_capabilities.dart';
import '../entities/preset.dart';
import '../value_objects/blueprint_id.dart';

/// What the Hub wants a node to be.
///
/// Two ways of saying it, and a node has one or the other:
///
/// * a **blueprint**, named here and resolved on demand — the richer answer,
///   because a blueprint composes shared presets, declares states rather than
///   actions, and can describe resources a formula step cannot;
/// * a list of [steps], the original form, kept working exactly as it was.
///
/// The blueprint is the direction of travel, but nothing forces a move: a node
/// declared by steps keeps its `DefaultStateReconciler` path, unchanged.
@immutable
class DesiredState {
  /// The steps that, when all converged, satisfy the desired state.
  final List<PresetStep> steps;

  /// The blueprint this node is assigned, when it is assigned one.
  ///
  /// Held as an id rather than a copy of the document: a blueprint is edited,
  /// and a node pinned to a snapshot of it would quietly stop tracking the
  /// thing an operator thinks they are editing.
  final BlueprintId? blueprint;

  /// Creates a desired state.
  const DesiredState(this.steps, {this.blueprint});

  /// An empty desired state.
  static const DesiredState empty = DesiredState(<PresetStep>[]);

  /// Builds a desired state from [presets] (steps concatenated in order).
  factory DesiredState.fromPresets(Iterable<Preset> presets) =>
      DesiredState([for (final p in presets) ...p.steps]);

  /// Assigns [blueprint] to a node.
  factory DesiredState.fromBlueprint(BlueprintId blueprint) =>
      DesiredState(const [], blueprint: blueprint);

  /// Whether this node is declared by a blueprint rather than by steps.
  bool get isBlueprint => blueprint != null;

  /// A one-line summary, for an audit entry or a CLI line.
  String get summary => blueprint != null
      ? 'blueprint ${blueprint!.value}'
      : '${steps.length} steps';

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'steps': steps.map((s) => s.toJson()).toList(),
    if (blueprint != null) 'blueprint': blueprint!.value,
  };

  /// Decodes from JSON.
  static DesiredState fromJson(Map<String, dynamic> json) {
    final blueprint = Json.optString(json, 'blueprint');
    return DesiredState(
      Json.optObjectList(json, 'steps').map(PresetStep.fromJson).toList(),
      blueprint: blueprint == null ? null : BlueprintId(blueprint),
    );
  }
}

/// The observed configuration of a node: what it currently advertises.
@immutable
class CurrentState {
  /// The node's currently detected capabilities.
  final NodeCapabilities capabilities;

  /// Creates a current state.
  const CurrentState({this.capabilities = NodeCapabilities.empty});
}
