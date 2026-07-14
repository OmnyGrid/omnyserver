import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../entities/preset.dart';
import 'state_reconciler.dart';

/// How far a node has drifted from what it was declared to be — the wire form of
/// a [Reconciliation].
///
/// `Reconciliation` is the planner's own type, and a client has no planner: it
/// has an answer, decoded off the API. This is that answer, so the dashboard and
/// the CLI read the same shape rather than each picking at raw JSON.
@immutable
class Drift {
  /// The node this is about.
  final String nodeId;

  /// Whether the node still is what it was declared to be.
  final bool converged;

  /// What would have to run to make the declaration true again. Empty when
  /// [converged] — which is the useful answer.
  final List<PresetStep> actions;

  /// Why the planner kept or dropped each step.
  final List<String> notes;

  /// Creates a drift report.
  const Drift({
    required this.nodeId,
    required this.converged,
    this.actions = const [],
    this.notes = const [],
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'converged': converged,
    'actions': [for (final step in actions) step.toJson()],
    'notes': notes,
  };

  /// Decodes from JSON.
  static Drift fromJson(Map<String, dynamic> json) => Drift(
    nodeId: Json.requireString(json, 'nodeId'),
    converged: Json.optBool(json, 'converged'),
    actions: Json.optObjectList(
      json,
      'actions',
    ).map(PresetStep.fromJson).toList(),
    notes: Json.optStringList(json, 'notes'),
  );
}
