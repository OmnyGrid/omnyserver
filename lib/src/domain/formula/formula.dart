import '../entities/formula_spec.dart';
import 'formula_action.dart';
import 'formula_context.dart';
import 'formula_result.dart';

/// An operational procedure that manages a piece of software on a node
/// (install / update / start / stop / restart / uninstall / verify).
///
/// Formulas are the unit of work a preset composes. They are expected to be
/// **idempotent** (running `install` when already installed should report
/// `changed: false`), **cross-platform aware** (inspect [FormulaContext.platform]),
/// and **safe to validate** at any time via [validate].
abstract class Formula {
  /// The static metadata describing this formula.
  FormulaSpec get spec;

  /// Installs the managed software.
  Future<FormulaResult> install(FormulaContext context);

  /// Updates the managed software toward the target version.
  Future<FormulaResult> update(FormulaContext context);

  /// Starts the managed service.
  Future<FormulaResult> start(FormulaContext context);

  /// Stops the managed service.
  Future<FormulaResult> stop(FormulaContext context);

  /// Restarts the managed service.
  Future<FormulaResult> restart(FormulaContext context);

  /// Uninstalls the managed software.
  Future<FormulaResult> uninstall(FormulaContext context);

  /// Validates that the managed software is present and healthy.
  Future<ValidationResult> validate(FormulaContext context);

  /// Dispatches the given [action] to the matching method.
  Future<FormulaResult> run(FormulaAction action, FormulaContext context) {
    switch (action) {
      case FormulaAction.install:
        return install(context);
      case FormulaAction.update:
        return update(context);
      case FormulaAction.start:
        return start(context);
      case FormulaAction.stop:
        return stop(context);
      case FormulaAction.restart:
        return restart(context);
      case FormulaAction.uninstall:
        return uninstall(context);
      case FormulaAction.verify:
        return validate(context).then(
          (v) => FormulaResult(
            formula: spec.id.value,
            action: FormulaAction.verify,
            success: v.valid,
            changed: false,
            message: v.message,
            finishedAt: context.now(),
          ),
        );
    }
  }
}

/// Optional mixin for formulas that can roll back a failed action.
abstract mixin class Rollbackable {
  /// Attempts to undo the effects of a failed [action].
  Future<FormulaResult> rollback(FormulaAction action, FormulaContext context);
}
