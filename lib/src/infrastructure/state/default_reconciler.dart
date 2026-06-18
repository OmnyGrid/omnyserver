import '../../domain/entities/preset.dart';
import '../../domain/formula/formula_action.dart';
import '../../domain/state/desired_state.dart';
import '../../domain/state/state_reconciler.dart';

/// The default capability-aware [StateReconciler].
///
/// For each desired step it drops the step when the target state is already
/// satisfied — an `install`/`verify` whose capability the node already
/// advertises — and keeps everything else (updates, lifecycle actions, missing
/// capabilities). This yields an idempotent convergence plan.
class DefaultStateReconciler implements StateReconciler {
  /// Creates a default reconciler.
  const DefaultStateReconciler();

  @override
  Reconciliation reconcile(DesiredState desired, CurrentState current) {
    final actions = <PresetStep>[];
    final notes = <String>[];
    for (final step in desired.steps) {
      final present = current.capabilities.hasNamed(step.formula.value);
      final satisfiesByPresence =
          step.action == FormulaAction.install ||
          step.action == FormulaAction.verify;
      if (present && satisfiesByPresence) {
        notes.add('skip ${step.formula.value}: already present');
      } else {
        actions.add(step);
        notes.add('run ${step.formula.value}:${step.action.name}');
      }
    }
    return Reconciliation(actions: actions, notes: notes);
  }
}
