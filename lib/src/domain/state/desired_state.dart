import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../entities/node_capabilities.dart';
import '../entities/preset.dart';

/// The target configuration the Hub wants a node to reach: an ordered list of
/// formula steps (typically expanded from one or more presets).
@immutable
class DesiredState {
  /// The steps that, when all converged, satisfy the desired state.
  final List<PresetStep> steps;

  /// Creates a desired state.
  const DesiredState(this.steps);

  /// An empty desired state.
  static const DesiredState empty = DesiredState(<PresetStep>[]);

  /// Builds a desired state from [presets] (steps concatenated in order).
  factory DesiredState.fromPresets(Iterable<Preset> presets) =>
      DesiredState([for (final p in presets) ...p.steps]);

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'steps': steps.map((s) => s.toJson()).toList(),
  };

  /// Decodes from JSON.
  static DesiredState fromJson(Map<String, dynamic> json) => DesiredState(
    Json.optObjectList(json, 'steps').map(PresetStep.fromJson).toList(),
  );
}

/// The observed configuration of a node: what it currently advertises.
@immutable
class CurrentState {
  /// The node's currently detected capabilities.
  final NodeCapabilities capabilities;

  /// Creates a current state.
  const CurrentState({this.capabilities = NodeCapabilities.empty});
}
