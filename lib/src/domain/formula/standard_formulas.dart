import '../entities/formula_spec.dart';
import '../value_objects/formula_id.dart';
import 'formula_action.dart';

/// What Docker's formula manages, and which actions it implements.
final FormulaSpec dockerSpec = FormulaSpec(
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

/// What the Dart formula manages, and which actions it implements.
final FormulaSpec dartSpec = FormulaSpec(
  id: FormulaId('dart'),
  name: 'Dart SDK',
  description: 'Dart software development kit.',
  actions: const {
    FormulaAction.install,
    FormulaAction.update,
    FormulaAction.uninstall,
    FormulaAction.verify,
  },
);

/// What the process-tools formula manages, and which actions it implements.
///
/// No start/stop/restart: there is no service here, only the two binaries the
/// node's own monitor needs in order to report a process table.
final FormulaSpec procpsSpec = FormulaSpec(
  id: FormulaId('procps'),
  name: 'Process tools',
  description:
      'The ps and top commands, which the node reports processes with.',
  actions: const {
    FormulaAction.install,
    FormulaAction.update,
    FormulaAction.uninstall,
    FormulaAction.verify,
  },
);

/// What the network-tools formula manages: `netstat` and `route`.
final FormulaSpec netToolsSpec = FormulaSpec(
  id: FormulaId('net-tools'),
  name: 'Network tools',
  description: 'The netstat and route commands.',
  actions: _toolActions,
);

/// What the DNS-tools formula manages: `nslookup`.
final FormulaSpec dnsUtilsSpec = FormulaSpec(
  id: FormulaId('dns-utils'),
  name: 'DNS tools',
  description: 'The nslookup command, for resolving names from the node.',
  actions: _toolActions,
);

/// What the build-tools formula manages: `gcc` and `make`.
final FormulaSpec buildToolsSpec = FormulaSpec(
  id: FormulaId('build-tools'),
  name: 'Build tools',
  description: 'A C toolchain: the gcc compiler and make.',
  actions: _toolActions,
);

/// What the nmap formula manages.
final FormulaSpec nmapSpec = FormulaSpec(
  id: FormulaId('nmap'),
  name: 'Nmap',
  description: 'The nmap network scanner, for the view from inside the fleet.',
  actions: _toolActions,
);

/// What a formula that installs commands can do: no service to start or stop.
const Set<FormulaAction> _toolActions = {
  FormulaAction.install,
  FormulaAction.update,
  FormulaAction.uninstall,
  FormulaAction.verify,
};

/// The formulas every node ships with.
///
/// These specs live in the domain, not on the `Formula` implementations that
/// execute them, because two very different things need them and only one can
/// run them. A **node** needs the executable formula; the **Hub** needs only the
/// description — to answer "what can I ask a node to do?" — and it has no
/// business importing a node's command runners to find out.
///
/// One definition, so a catalogue served by the Hub cannot drift from the
/// formulas a node actually implements.
final List<FormulaSpec> standardFormulaSpecs = [
  dockerSpec,
  dartSpec,
  procpsSpec,
  netToolsSpec,
  dnsUtilsSpec,
  buildToolsSpec,
  nmapSpec,
];
