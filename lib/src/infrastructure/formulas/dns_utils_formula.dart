import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/standard_formulas.dart';
import 'command_formula.dart';
import 'package_formula.dart';

/// `nslookup` — asking a node what it thinks a name resolves to.
///
/// Worth having on a fleet that addresses everything by name: when a node
/// cannot reach the Hub, whether it can resolve the Hub's name is the first
/// thing that separates a DNS problem from a network one. The answer has to
/// come from the node, since the resolver it uses is the node's.
class DnsUtilsFormula extends PackageFormula {
  /// Creates the formula, optionally over a custom executor.
  DnsUtilsFormula({super.executor});

  @override
  FormulaSpec get spec => dnsUtilsSpec;

  @override
  PackageNames get packages => const PackageNames(
    // `dnsutils` is a transitional package on current Debian, pulling
    // `bind9-dnsutils`; it is still the name that works across releases.
    apt: 'dnsutils',
    apk: 'bind-tools',
    dnf: 'bind-utils',
    // macOS ships nslookup in /usr/bin.
  );

  @override
  CommandStep get verifyStep => const CommandStep('sh', [
    '-c',
    'command -v nslookup >/dev/null 2>&1 || exit 1\n'
        'nslookup -version 2>/dev/null | head -1 || true',
  ]);
}
