import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../blueprint/resource_change.dart';
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
  ///
  /// Only ever filled for a node declared by preset steps.
  final List<PresetStep> actions;

  /// What would have to change, for a node declared by a blueprint.
  ///
  /// Carried alongside [actions] rather than replacing it, so a client written
  /// against the preset shape keeps working and one that understands blueprints
  /// gets the richer answer. Exactly one of the two is ever non-empty.
  final List<ResourceChange> changes;

  /// The blueprint this node is assigned, when it is assigned one.
  final String? blueprint;

  /// The resolved hash the node reports having applied.
  ///
  /// Empty when it has never applied one.
  final String appliedHash;

  /// The hash of the blueprint as the Hub resolves it now.
  ///
  /// Together with [appliedHash] this answers a question no amount of reading
  /// resources can: whether the node is on an *older revision* of the
  /// blueprint. That is not the same as having drifted from the current one —
  /// somebody edited the document, or a preset it includes — and it deserves a
  /// different sentence in front of an operator.
  final String expectedHash;

  /// Whether the node has applied a different resolution than the current one.
  ///
  /// False when it has never applied anything: that is "nothing has run here",
  /// not "something older has".
  bool get stale =>
      appliedHash.isNotEmpty &&
      expectedHash.isNotEmpty &&
      appliedHash != expectedHash;

  /// Why the planner kept or dropped each step.
  final List<String> notes;

  /// Creates a drift report.
  const Drift({
    required this.nodeId,
    required this.converged,
    this.actions = const [],
    this.changes = const [],
    this.blueprint,
    this.appliedHash = '',
    this.expectedHash = '',
    this.notes = const [],
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'converged': converged,
    'actions': [for (final step in actions) step.toJson()],
    if (changes.isNotEmpty)
      'changes': [for (final change in changes) change.toJson()],
    if (blueprint != null) 'blueprint': blueprint,
    if (appliedHash.isNotEmpty) 'appliedHash': appliedHash,
    if (expectedHash.isNotEmpty) 'expectedHash': expectedHash,
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
    changes: Json.optObjectList(
      json,
      'changes',
    ).map(ResourceChange.fromJson).toList(),
    blueprint: Json.optString(json, 'blueprint'),
    appliedHash: Json.optString(json, 'appliedHash') ?? '',
    expectedHash: Json.optString(json, 'expectedHash') ?? '',
    notes: Json.optStringList(json, 'notes'),
  );
}
