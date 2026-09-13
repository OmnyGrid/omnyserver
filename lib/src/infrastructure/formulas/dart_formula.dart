import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/standard_formulas.dart';
import '../../domain/formula/formula_action.dart';
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
  FormulaSpec get spec => dartSpec;

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
              '$_addAptRepository\napt-get install -y dart',
            ]);
          case FormulaAction.update:
            return const CommandStep('sh', [
              '-c',
              '$_addAptRepository\napt-get install -y --only-upgrade dart',
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

  /// Adds Google's apt repository, which is where the Dart SDK actually lives.
  ///
  /// Neither Debian nor Ubuntu carries a `dart` package, so
  /// `apt-get install dart` on a stock host has only ever produced
  /// `E: Unable to locate package dart`. This is the sequence dart.dev
  /// documents, and it is worth being explicit about what it does: it installs
  /// Google's signing key into the host's trusted keyring and adds a source
  /// list. Everything apt installs afterwards trusts that key too.
  ///
  /// Idempotent — the repository is written once, and re-running only refreshes
  /// the package lists.
  ///
  /// `set -e` and the deliberate absence of pipelines are the point: a failed
  /// download must fail the step. Piping the key straight into `gpg` would
  /// dearmor an empty file happily and leave a keyring that quietly verifies
  /// nothing, and the failure would surface much later as a signature error.
  static const String _addAptRepository = '''
set -e
if [ ! -f /etc/apt/sources.list.d/dart_stable.list ]; then
  apt-get update
  apt-get install -y --no-install-recommends apt-transport-https wget gpg
  wget -qO /tmp/dart-signing-key.pub https://dl-ssl.google.com/linux/linux_signing_key.pub
  gpg --dearmor -o /usr/share/keyrings/dart.gpg < /tmp/dart-signing-key.pub
  rm -f /tmp/dart-signing-key.pub
  echo "deb [signed-by=/usr/share/keyrings/dart.gpg] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main" > /etc/apt/sources.list.d/dart_stable.list
fi
apt-get update''';
}
