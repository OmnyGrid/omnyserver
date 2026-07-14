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
final List<FormulaSpec> standardFormulaSpecs = [dockerSpec, dartSpec];
