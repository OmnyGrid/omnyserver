import 'package:meta/meta.dart';

import '../entities/preset.dart';
import 'desired_state.dart';

/// The plan produced by reconciling a desired state against the current state:
/// the ordered steps that still need to run to converge.
@immutable
class Reconciliation {
  /// The steps that must be executed (already-satisfied steps are omitted).
  final List<PresetStep> actions;

  /// Human-readable notes about why each kept/dropped decision was made.
  final List<String> notes;

  /// Creates a reconciliation plan.
  const Reconciliation({this.actions = const [], this.notes = const []});

  /// Whether the node is already converged (nothing to do).
  bool get converged => actions.isEmpty;
}

/// Computes the [Reconciliation] needed to move a node from its current state
/// toward a desired state.
///
/// The default implementation is a conservative, capability-aware planner; it
/// is the designed seam for richer planners (dependency ordering, version
/// comparison, Kubernetes-style controllers) in the future.
abstract class StateReconciler {
  /// Plans the steps required to converge [current] toward [desired].
  Reconciliation reconcile(DesiredState desired, CurrentState current);
}
