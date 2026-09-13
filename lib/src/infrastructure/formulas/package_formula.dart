import '../../domain/entities/formula_spec.dart';
import '../../domain/formula/formula_action.dart';
import '../../domain/value_objects/formula_id.dart';
import 'command_formula.dart';

/// The package that carries a formula's commands, named per package manager.
///
/// The same software is called different things by different distributions —
/// `procps` and `procps-ng`, `dnsutils` and `bind-tools` — and a formula that
/// only knows Debian's name is a formula that only works on Debian.
///
/// A `null` means "this manager has no package for it", and the formula says so
/// rather than guessing at a name.
class PackageNames {
  /// Debian and Ubuntu.
  final String? apt;

  /// Alpine.
  final String? apk;

  /// Fedora, RHEL and their relatives.
  final String? dnf;

  /// Homebrew, on macOS. `null` where the commands are part of the system —
  /// `netstat` and `nslookup` ship with macOS, and are nobody's to uninstall.
  final String? brew;

  /// Names a package across the managers that carry it.
  const PackageNames({this.apt, this.apk, this.dnf, this.brew});
}

/// A formula whose whole job is "make these commands exist".
///
/// Everything such a formula does is decided by two things: how to tell whether
/// the commands are already there, and what the package is called. This holds
/// the rest — picking the package manager *on the host*, because `stepFor` is
/// told the OS and not the distribution, and failing honestly where there is no
/// manager it knows.
///
/// Subclasses supply [spec], [verifyStep] and [packages]. A formula that
/// manages a *service* wants more than this: start, stop and restart are not
/// package operations, and `DockerFormula` is written out by hand for that
/// reason.
abstract class PackageFormula extends CommandFormula {
  /// Creates a package-backed formula.
  PackageFormula({super.executor});

  /// What the package is called, per manager.
  PackageNames get packages;

  @override
  CommandStep? stepFor(FormulaAction action, String osName) {
    if (action == FormulaAction.verify) return verifyStep;

    return switch (osName) {
      'linux' => _linuxStep(action),
      'macos' => _brewStep(action),
      // An OS with no packaging story here. `install` never reaches this when
      // the commands are already present — the base class short-circuits on a
      // passing verify — so what is reported is the truth: not supported here.
      _ => null,
    };
  }

  CommandStep? _linuxStep(FormulaAction action) {
    final script = switch (action) {
      FormulaAction.install => _script('install'),
      FormulaAction.update => _script('update'),
      FormulaAction.uninstall => _script('uninstall'),
      _ => null,
    };
    return script == null ? null : CommandStep('sh', ['-c', script]);
  }

  CommandStep? _brewStep(FormulaAction action) {
    final name = packages.brew;
    // No brew package means the commands are part of macOS. Installing is a
    // no-op the base class already handles; removing them is not this
    // formula's business.
    if (name == null) return null;
    return switch (action) {
      FormulaAction.install => CommandStep('brew', ['install', name]),
      FormulaAction.update => CommandStep('brew', ['upgrade', name]),
      FormulaAction.uninstall => CommandStep('brew', ['uninstall', name]),
      _ => null,
    };
  }

  /// The one script, branching on whichever manager the host turns out to have.
  ///
  /// `set -e` throughout: a step that runs on after `apt-get update` fails
  /// reports whatever its last command did, which is how an install comes back
  /// successful having installed nothing.
  String _script(String operation) {
    final branches = <String>[
      if (packages.apt case final name?)
        _branch('apt-get', switch (operation) {
          'install' => 'apt-get update && apt-get install -y $name',
          'update' =>
            'apt-get update && apt-get install -y --only-upgrade $name',
          _ => 'apt-get remove -y $name',
        }),
      if (packages.apk case final name?)
        _branch('apk', switch (operation) {
          'install' => 'apk add --no-cache $name',
          'update' => 'apk add --no-cache --upgrade $name',
          _ => 'apk del $name',
        }),
      if (packages.dnf case final name?)
        _branch('dnf', switch (operation) {
          'install' => 'dnf install -y $name',
          'update' => 'dnf upgrade -y $name',
          _ => 'dnf remove -y $name',
        }),
    ];
    if (branches.isEmpty) return '';

    final managers = [
      if (packages.apt != null) 'apt-get',
      if (packages.apk != null) 'apk',
      if (packages.dnf != null) 'dnf',
    ].join(', ');

    return 'set -e\n'
        '${branches.join('el')}'
        'else\n'
        '  echo "${spec.name}: no supported package manager ($managers)" >&2\n'
        '  exit 1\n'
        'fi';
  }

  String _branch(String manager, String command) =>
      'if command -v $manager >/dev/null 2>&1; then\n  $command\n';
}

/// The specs of package-backed formulas share a shape: the commands they
/// provide, and no service to start or stop.
FormulaSpec packageSpec({
  required String id,
  required String name,
  required String description,
}) => FormulaSpec(
  id: FormulaId(id),
  name: name,
  description: description,
  actions: const {
    FormulaAction.install,
    FormulaAction.update,
    FormulaAction.uninstall,
    FormulaAction.verify,
  },
);
