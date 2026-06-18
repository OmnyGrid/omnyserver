import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/formula_action.dart';
import '../../domain/value_objects/formula_id.dart';
import 'command_formula.dart';

/// The built-in Dart formula: installs and verifies the Dart SDK.
///
/// Verify probes `dart --version`. Install/update/uninstall use the platform
/// package manager. Dart has no long-running service, so start/stop/restart are
/// unsupported (reported as such).
class DartFormula extends CommandFormula {
  /// Creates a Dart formula.
  DartFormula({super.executor});

  @override
  FormulaSpec get spec => FormulaSpec(
    id: FormulaId('dart'),
    name: 'Dart SDK',
    description: 'Dart software development kit.',
    actions: const {
      FormulaAction.install,
      FormulaAction.update,
      FormulaAction.uninstall,
      FormulaAction.verify,
    },
  );

  @override
  CommandStep get verifyStep => const CommandStep('dart', ['--version']);

  @override
  CommandStep? stepFor(FormulaAction action, String osName) {
    switch (osName) {
      case 'macos':
        switch (action) {
          case FormulaAction.install:
            return const CommandStep('brew', ['install', 'dart-sdk']);
          case FormulaAction.update:
            return const CommandStep('brew', ['upgrade', 'dart-sdk']);
          case FormulaAction.uninstall:
            return const CommandStep('brew', ['uninstall', 'dart-sdk']);
          case FormulaAction.verify:
            return verifyStep;
          default:
            return null;
        }
      case 'linux':
        switch (action) {
          case FormulaAction.install:
            return const CommandStep('sh', [
              '-c',
              'apt-get update && apt-get install -y dart',
            ]);
          case FormulaAction.update:
            return const CommandStep('sh', [
              '-c',
              'apt-get update && apt-get install -y --only-upgrade dart',
            ]);
          case FormulaAction.uninstall:
            return const CommandStep('apt-get', ['remove', '-y', 'dart']);
          case FormulaAction.verify:
            return verifyStep;
          default:
            return null;
        }
      default:
        return null;
    }
  }
}
