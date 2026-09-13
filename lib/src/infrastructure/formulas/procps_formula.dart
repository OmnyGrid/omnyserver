import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/standard_formulas.dart';
import 'command_formula.dart';
import 'package_formula.dart';

/// Installs the process tools — `ps` and `top` — on a node.
///
/// Less cosmetic than it sounds: the agent's own monitor reports the process
/// table by shelling out to `ps`, and degrades to an empty list when it is
/// missing. A slim container image typically has neither, so a node on one
/// reports its CPU and memory perfectly well and no processes at all. This is
/// the formula that fills that in.
///
/// macOS ships both as part of the system, so there is no `brew` package here:
/// install short-circuits on a passing verify, and uninstall correctly reports
/// that removing `/bin/ps` is not something this formula does.
class ProcpsFormula extends PackageFormula {
  /// Creates the formula, optionally over a custom [executor].
  ProcpsFormula({super.executor});

  @override
  FormulaSpec get spec => procpsSpec;

  @override
  PackageNames get packages => const PackageNames(
    apt: 'procps',
    apk: 'procps',
    // The Red Hat side calls it procps-ng.
    dnf: 'procps-ng',
  );

  /// Both tools have to be there, and the version is reported when the host's
  /// `ps` is one that can say (procps-ng can; BSD and busybox cannot, and are
  /// not wrong to refuse `--version`).
  @override
  CommandStep get verifyStep => const CommandStep('sh', [
    '-c',
    'command -v ps >/dev/null 2>&1 && command -v top >/dev/null 2>&1 || exit 1\n'
        'ps --version 2>/dev/null || true',
  ]);
}
