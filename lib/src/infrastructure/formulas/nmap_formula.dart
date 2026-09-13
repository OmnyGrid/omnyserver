import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/standard_formulas.dart';
import 'command_formula.dart';
import 'package_formula.dart';

/// `nmap` — what a node can see of the network around it.
///
/// The view from inside the fleet, which is the one that answers "can this node
/// actually reach that port?" without guessing from the outside.
///
/// Worth installing deliberately rather than by default: a port scanner on a
/// server is a tool an intruder is glad to find, and on some networks running
/// one is itself an event. That it takes an explicit `formula run` — recorded
/// in the audit trail with the principal who asked — is the right shape for it.
class NmapFormula extends PackageFormula {
  /// Creates the formula, optionally over a custom executor.
  NmapFormula({super.executor});

  @override
  FormulaSpec get spec => nmapSpec;

  @override
  PackageNames get packages =>
      const PackageNames(apt: 'nmap', apk: 'nmap', dnf: 'nmap', brew: 'nmap');

  @override
  CommandStep get verifyStep => const CommandStep('nmap', ['--version']);
}
