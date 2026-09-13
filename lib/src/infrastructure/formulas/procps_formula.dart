import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/formula_action.dart';
import '../../domain/formula/standard_formulas.dart';
import 'command_formula.dart';

/// Installs the process tools — `ps` and `top` — on a node.
///
/// Less cosmetic than it sounds: the agent's own monitor reports the process
/// table by shelling out to `ps`, and degrades to an empty list when it is
/// missing. A slim container image typically has neither, so a node on one
/// reports its CPU and memory perfectly well and no processes at all. This is
/// the formula that fills that in.
///
/// On Linux the package is named differently by each family, and the manager
/// has to be chosen on the host rather than here — `stepFor` is told the OS,
/// not the distribution — so the step is one script that picks whichever of
/// `apt-get`, `apk` or `dnf` it finds. macOS ships both tools as part of the
/// system, so there is nothing to install and nothing that should be removed.
class ProcpsFormula extends CommandFormula {
  /// Creates the formula, optionally over a custom [executor].
  ProcpsFormula({super.executor});

  @override
  FormulaSpec get spec => procpsSpec;

  /// Both tools have to be there, and the version is reported when the host's
  /// `ps` is one that can say (procps-ng can; BSD and busybox cannot, and are
  /// not wrong to refuse `--version`).
  @override
  CommandStep get verifyStep => const CommandStep('sh', [
    '-c',
    'command -v ps >/dev/null 2>&1 && command -v top >/dev/null 2>&1 || exit 1\n'
        'ps --version 2>/dev/null || true',
  ]);

  @override
  CommandStep? stepFor(FormulaAction action, String osName) {
    if (action == FormulaAction.verify) return verifyStep;
    // Elsewhere — macOS included — the tools are part of the system. Install
    // never reaches here (the base class short-circuits once verify passes),
    // and uninstall reporting "not supported" is the right answer for a
    // formula asked to remove /bin/ps.
    if (osName != 'linux') return null;

    return switch (action) {
      FormulaAction.install => const CommandStep('sh', ['-c', _install]),
      FormulaAction.update => const CommandStep('sh', ['-c', _update]),
      FormulaAction.uninstall => const CommandStep('sh', ['-c', _uninstall]),
      _ => null,
    };
  }

  static const String _install = '''
if command -v apt-get >/dev/null 2>&1; then
  apt-get update && apt-get install -y procps
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache procps
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y procps-ng
else
  echo "no supported package manager (apt-get, apk or dnf)" >&2
  exit 1
fi''';

  static const String _update = '''
if command -v apt-get >/dev/null 2>&1; then
  apt-get update && apt-get install -y --only-upgrade procps
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache --upgrade procps
elif command -v dnf >/dev/null 2>&1; then
  dnf upgrade -y procps-ng
else
  echo "no supported package manager (apt-get, apk or dnf)" >&2
  exit 1
fi''';

  static const String _uninstall = '''
if command -v apt-get >/dev/null 2>&1; then
  apt-get remove -y procps
elif command -v apk >/dev/null 2>&1; then
  apk del procps
elif command -v dnf >/dev/null 2>&1; then
  dnf remove -y procps-ng
else
  echo "no supported package manager (apt-get, apk or dnf)" >&2
  exit 1
fi''';
}
