import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/formula_action.dart';
import '../../domain/value_objects/formula_id.dart';
import 'command_formula.dart';

/// The built-in Docker formula: installs and manages the Docker engine.
///
/// Verify probes `docker --version`. Lifecycle actions use the platform's
/// service manager / package manager. Install is idempotent (a host that
/// already has Docker reports `changed: false`).
class DockerFormula extends CommandFormula {
  /// Creates a Docker formula.
  DockerFormula({super.executor});

  @override
  FormulaSpec get spec => FormulaSpec(
    id: FormulaId('docker'),
    name: 'Docker',
    description: 'Docker container engine.',
    actions: const {
      FormulaAction.install,
      FormulaAction.update,
      FormulaAction.start,
      FormulaAction.stop,
      FormulaAction.restart,
      FormulaAction.uninstall,
      FormulaAction.verify,
    },
  );

  @override
  CommandStep get verifyStep => const CommandStep('docker', ['--version']);

  @override
  CommandStep? stepFor(FormulaAction action, String osName) {
    switch (osName) {
      case 'linux':
        switch (action) {
          case FormulaAction.install:
            return const CommandStep('sh', [
              '-c',
              'curl -fsSL https://get.docker.com | sh',
            ]);
          case FormulaAction.update:
            return const CommandStep('sh', [
              '-c',
              'apt-get update && apt-get install -y docker-ce',
            ]);
          case FormulaAction.start:
            return const CommandStep('systemctl', ['start', 'docker']);
          case FormulaAction.stop:
            return const CommandStep('systemctl', ['stop', 'docker']);
          case FormulaAction.restart:
            return const CommandStep('systemctl', ['restart', 'docker']);
          case FormulaAction.uninstall:
            return const CommandStep('sh', [
              '-c',
              'apt-get remove -y docker-ce docker-ce-cli',
            ]);
          case FormulaAction.verify:
            return verifyStep;
        }
      case 'macos':
        switch (action) {
          case FormulaAction.install:
            return const CommandStep('brew', ['install', '--cask', 'docker']);
          case FormulaAction.uninstall:
            return const CommandStep('brew', ['uninstall', '--cask', 'docker']);
          case FormulaAction.update:
            return const CommandStep('brew', ['upgrade', '--cask', 'docker']);
          default:
            return null;
        }
      default:
        return null;
    }
  }
}
