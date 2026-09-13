import '../entities/formula_spec.dart';
import 'formula_action.dart';
import 'formula_context.dart';
import 'formula_result.dart';
import 'formula_status.dart';

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

  /// Reports what this formula manages, as it currently stands on the node.
  ///
  /// Answered from [validate] by default, which is all a formula that installs
  /// a command can honestly say: it is there or it is not. A formula that
  /// manages a *service* overrides this — "installed" is a poor answer about a
  /// daemon that is not running, and the dashboard shows this verbatim.
  ///
  /// A probe that throws is [FormulaStatus.unknown], never
  /// [FormulaStatus.absent]: a check that could not run has said nothing about
  /// whether the software is there, and the two are acted on differently.
  Future<FormulaStatusReport> status(FormulaContext context) async {
    try {
      final result = await validate(context);
      return FormulaStatusReport(
        formula: spec.id,
        status: result.valid ? FormulaStatus.installed : FormulaStatus.absent,
        version: result.detectedVersion,
        message: result.message,
        checkedAt: context.now(),
      );
    } on Object catch (e) {
      return FormulaStatusReport(
        formula: spec.id,
        status: FormulaStatus.unknown,
        message: 'status check failed: $e',
        checkedAt: context.now(),
      );
    }
  }

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
