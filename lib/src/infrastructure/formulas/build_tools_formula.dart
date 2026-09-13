import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/standard_formulas.dart';
import 'command_formula.dart';
import 'package_formula.dart';

/// `gcc` and `make` — a node that can compile something.
///
/// Needed by more than it looks: native extensions, `./configure && make`, and
/// anything whose install script builds rather than downloads. A slim host has
/// neither, and the failure arrives deep inside someone else's build output.
///
/// Each distribution bundles them differently — Debian's `build-essential`
/// carries gcc, g++ and make together; Alpine's `build-base` is its
/// counterpart; Fedora names the two packages separately — so [PackageNames]
/// earns its keep here.
class BuildToolsFormula extends PackageFormula {
  /// Creates the formula, optionally over a custom executor.
  BuildToolsFormula({super.executor});

  @override
  FormulaSpec get spec => buildToolsSpec;

  @override
  PackageNames get packages => const PackageNames(
    apt: 'build-essential',
    apk: 'build-base',
    dnf: 'gcc make',
    // Deliberately no brew: on macOS these come from the Xcode command line
    // tools, and `xcode-select --install` opens a dialog on the machine. A
    // formula that cannot finish the job unattended should say it does not
    // support the platform rather than half-start something nobody is there to
    // click through.
  );

  @override
  CommandStep get verifyStep => const CommandStep('sh', [
    '-c',
    'command -v gcc >/dev/null 2>&1 && command -v make >/dev/null 2>&1 '
        '|| exit 1\n'
        'gcc --version 2>/dev/null | head -1 || true',
  ]);
}
