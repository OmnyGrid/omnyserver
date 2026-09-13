import '../../domain/formula/formula.dart';
import '../../domain/formula/formula_action.dart';
import '../../domain/formula/formula_context.dart';
import '../../domain/formula/formula_result.dart';
import '../../domain/formula/formula_status.dart';
import 'command_executor.dart';

/// A platform command template: the executable and args to run for an action on
/// a given OS family.
class CommandStep {
  /// The executable.
  final String executable;

  /// The arguments.
  final List<String> args;

  /// Creates a command step.
  const CommandStep(this.executable, this.args);
}

/// A reusable base for formulas whose actions are platform-specific shell
/// commands (the common case for installing/managing software).
///
/// Subclasses provide a verify probe and per-action command templates keyed by
/// OS family. Install is made **idempotent**: if [validate] already passes, it
/// reports `changed: false` without running the install command.
abstract class CommandFormula extends Formula {
  /// Runs the underlying commands.
  final CommandExecutor executor;

  /// Creates a command formula with [executor].
  CommandFormula({this.executor = const ProcessCommandExecutor()});

  /// The verify probe (e.g. `docker --version`).
  CommandStep get verifyStep;

  /// A regex capturing the version from the verify output.
  RegExp get versionPattern => RegExp(r'(\d+\.\d+(?:\.\d+)?)');

  /// Returns the command template for [action] on [osName], or `null` if the
  /// action is unsupported on that platform.
  CommandStep? stepFor(FormulaAction action, String osName);

  /// The probe that says whether what this formula manages is *running*, or
  /// `null` when it manages nothing that runs.
  ///
  /// Null is the right answer for most formulas: `nmap` is a command, and a
  /// command that is installed is the whole story. A formula that manages a
  /// daemon supplies one, and [statusFrom] turns its exit into a status.
  CommandStep? statusStepFor(String osName) => null;

  /// Maps a [statusStepFor] probe's outcome to a status.
  ///
  /// The default reads a zero exit as running and anything else as stopped,
  /// which is what a well-behaved `… info` or `… is-active` probe reports.
  /// Override where a tool distinguishes "not running" from "broken".
  FormulaStatus statusFrom(ExecResult result) =>
      result.ok ? FormulaStatus.running : FormulaStatus.stopped;

  /// Present first, running second.
  ///
  /// The order matters: a stopped daemon and an uninstalled one both fail the
  /// running probe, and calling the second one "stopped" would send an operator
  /// to a start button for software that is not there.
  @override
  Future<FormulaStatusReport> status(FormulaContext context) async {
    final present = await validate(context);
    if (!present.valid) {
      return FormulaStatusReport(
        formula: spec.id,
        status: FormulaStatus.absent,
        message: present.message,
        checkedAt: context.now(),
      );
    }

    final step = statusStepFor(context.platform.osName);
    if (step == null) {
      return FormulaStatusReport(
        formula: spec.id,
        status: FormulaStatus.installed,
        version: present.detectedVersion,
        message: present.message,
        checkedAt: context.now(),
      );
    }

    final probe = await executor.run(step.executable, step.args);
    final detail = (probe.ok ? probe.stdout : probe.stderr).trim();
    return FormulaStatusReport(
      formula: spec.id,
      status: statusFrom(probe),
      version: present.detectedVersion,
      // One line: this is a badge's tooltip, not a log. The log is what
      // `verify` is for.
      message: detail.isEmpty ? present.message : detail.split('\n').first,
      checkedAt: context.now(),
    );
  }

  @override
  Future<ValidationResult> validate(FormulaContext context) async {
    final result = await executor.run(verifyStep.executable, verifyStep.args);
    if (!result.ok) {
      return ValidationResult.fail('${spec.name} not found');
    }
    final match = versionPattern.firstMatch(
      '${result.stdout}\n${result.stderr}',
    );
    return ValidationResult.ok(version: match?.group(1));
  }

  @override
  Future<FormulaResult> install(FormulaContext context) async {
    final current = await validate(context);
    if (current.valid) {
      return _result(
        FormulaAction.install,
        success: true,
        changed: false,
        message:
            '${spec.name} already installed'
            '${current.detectedVersion != null ? ' (${current.detectedVersion})' : ''}',
        context: context,
      );
    }
    return _runAction(FormulaAction.install, context);
  }

  @override
  Future<FormulaResult> update(FormulaContext context) =>
      _runAction(FormulaAction.update, context);

  @override
  Future<FormulaResult> start(FormulaContext context) =>
      _runAction(FormulaAction.start, context);

  @override
  Future<FormulaResult> stop(FormulaContext context) =>
      _runAction(FormulaAction.stop, context);

  @override
  Future<FormulaResult> restart(FormulaContext context) =>
      _runAction(FormulaAction.restart, context);

  @override
  Future<FormulaResult> uninstall(FormulaContext context) async {
    final current = await validate(context);
    if (!current.valid) {
      return _result(
        FormulaAction.uninstall,
        success: true,
        changed: false,
        message: '${spec.name} not installed',
        context: context,
      );
    }
    return _runAction(FormulaAction.uninstall, context);
  }

  Future<FormulaResult> _runAction(
    FormulaAction action,
    FormulaContext context,
  ) async {
    final step = stepFor(action, context.platform.osName);
    if (step == null) {
      return _result(
        action,
        success: false,
        message:
            '${spec.name} ${action.name} not supported on ${context.platform.osName}',
        context: context,
      );
    }
    context.log(
      '${spec.name}: running ${step.executable} ${step.args.join(' ')}',
    );
    final result = await executor.run(step.executable, step.args);
    for (final line in result.stdout.split('\n')) {
      if (line.trim().isNotEmpty) context.log(line);
    }
    return _result(
      action,
      success: result.ok,
      changed: result.ok,
      message: result.ok
          ? '${spec.name} ${action.name} succeeded'
          : '${spec.name} ${action.name} failed: ${result.stderr.trim()}',
      context: context,
    );
  }

  FormulaResult _result(
    FormulaAction action, {
    required bool success,
    required FormulaContext context,
    bool changed = false,
    String message = '',
  }) => FormulaResult(
    formula: spec.id.value,
    action: action,
    success: success,
    changed: changed,
    message: message,
    finishedAt: context.now(),
  );
}
