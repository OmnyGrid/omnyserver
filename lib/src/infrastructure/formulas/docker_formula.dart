import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/standard_formulas.dart';
import '../../domain/formula/formula_action.dart';
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
  // Defined in the domain, so the Hub can serve a catalogue of what nodes can
  // do without importing the code that does it.
  FormulaSpec get spec => dockerSpec;

  @override
  CommandStep get verifyStep => const CommandStep('docker', ['--version']);

  /// The daemon, not the CLI.
  ///
  /// `docker --version` answers from the client binary alone and says nothing
  /// about whether anything is running — it prints a version perfectly happily
  /// on a host whose daemon is stopped. `docker info` has to reach the daemon,
  /// so it is the question worth asking, and its server version is what the
  /// badge shows.
  @override
  CommandStep? statusStepFor(String osName) =>
      const CommandStep('docker', ['info', '--format', '{{.ServerVersion}}']);

  @override
  CommandStep? stepFor(FormulaAction action, String osName) {
    switch (osName) {
      case 'linux':
        switch (action) {
          case FormulaAction.install:
            return const CommandStep('sh', ['-c', _installScript]);
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

  /// Fetches Docker's install script and runs it — in two steps, deliberately.
  ///
  /// `curl -fsSL https://get.docker.com | sh` reports the exit status of `sh`,
  /// not of `curl`. On a host with no curl — a slim image, most of them — that
  /// pipeline printed `curl: not found` and **exited 0**: `sh` read an empty
  /// script and succeeded. The formula then reported Docker installed, the Hub
  /// recorded it, and drift reconciliation agreed there was nothing to do. A
  /// network failure or a 404 looked exactly the same.
  ///
  /// Fetching to a file first means a failed download fails the step, and a
  /// host with no downloader is told so instead of being congratulated.
  static const String _installScript = '''
set -e
script=\$(mktemp)
trap 'rm -f "\$script"' EXIT
if command -v curl >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o "\$script"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "\$script" https://get.docker.com
else
  echo "docker install needs curl or wget to fetch https://get.docker.com" >&2
  exit 1
fi
sh "\$script"''';
}
