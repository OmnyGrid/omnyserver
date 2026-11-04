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

  /// This node's values for the [blueprint]'s `vars`, overriding the
  /// blueprint's own defaults.
  ///
  /// Kept *on the assignment*, not passed with one apply. An override that
  /// lasted a single run would be undone by the next one: `apply --set
  /// version=1.0.141` followed by a plain `apply` — or a reconcile on a timer —
  /// would quietly put production back on whatever version the blueprint
  /// document names. Stored here, the node stays on what it was last told until
  /// it is told something else.
  ///
  /// Only names the blueprint declares may be overridden; the Hub refuses the
  /// rest, so a typo is an error rather than a variable nothing reads.
  final Map<String, String> vars;

  /// Creates a desired state.
  const DesiredState(this.steps, {this.blueprint, this.vars = const {}});

  /// An empty desired state.
  static const DesiredState empty = DesiredState(<PresetStep>[]);

  /// Builds a desired state from [presets] (steps concatenated in order).
  factory DesiredState.fromPresets(Iterable<Preset> presets) =>
      DesiredState([for (final p in presets) ...p.steps]);

  /// Assigns [blueprint] to a node, with this node's [vars].
  factory DesiredState.fromBlueprint(
    BlueprintId blueprint, {
    Map<String, String> vars = const {},
  }) => DesiredState(const [], blueprint: blueprint, vars: vars);

  /// Whether this node is declared by a blueprint rather than by steps.
  bool get isBlueprint => blueprint != null;

  /// A one-line summary, for an audit entry or a CLI line.
  String get summary {
    if (blueprint == null) return '${steps.length} steps';
    if (vars.isEmpty) return 'blueprint ${blueprint!.value}';
    final keys = vars.keys.toList()..sort();
    final set = [for (final k in keys) '$k=${vars[k]}'].join(', ');
    return 'blueprint ${blueprint!.value} ($set)';
  }

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'steps': steps.map((s) => s.toJson()).toList(),
    if (blueprint != null) 'blueprint': blueprint!.value,
    if (vars.isNotEmpty) 'vars': vars,
  };

  /// Decodes from JSON.
  static DesiredState fromJson(Map<String, dynamic> json) {
    final blueprint = Json.optString(json, 'blueprint');
    return DesiredState(
      Json.optObjectList(json, 'steps').map(PresetStep.fromJson).toList(),
      blueprint: blueprint == null ? null : BlueprintId(blueprint),
      vars: Json.optStringMap(json, 'vars'),
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
