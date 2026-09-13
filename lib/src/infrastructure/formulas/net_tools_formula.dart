import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/standard_formulas.dart';
import 'command_formula.dart';
import 'package_formula.dart';

/// `netstat` and `route` — what is listening, and where traffic goes.
///
/// The first two questions asked of a server that is not answering. Debian
/// dropped them from the default install years ago in favour of `ss` and
/// `ip route`, so a slim host has neither, and an operator who reaches for
/// `netstat` finds nothing there.
class NetToolsFormula extends PackageFormula {
  /// Creates the formula, optionally over a custom executor.
  NetToolsFormula({super.executor});

  @override
  FormulaSpec get spec => netToolsSpec;

  @override
  PackageNames get packages => const PackageNames(
    apt: 'net-tools',
    apk: 'net-tools',
    dnf: 'net-tools',
    // macOS ships both in /usr/sbin, and they are not Homebrew's to replace.
  );

  @override
  CommandStep get verifyStep => const CommandStep('sh', [
    '-c',
    'command -v netstat >/dev/null 2>&1 && command -v route >/dev/null 2>&1 '
        '|| exit 1\n'
        // net-tools answers `--version` on Linux; macOS's netstat does not, and
        // the probe must not fail over a version it cannot have.
        'netstat --version 2>/dev/null | head -1 || true',
  ]);
}
