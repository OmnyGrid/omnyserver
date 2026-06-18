import '../../domain/formula/formula.dart';
import '../../infrastructure/formulas/command_executor.dart';
import '../../infrastructure/formulas/dart_formula.dart';
import '../../infrastructure/formulas/docker_formula.dart';

/// A catalogue of [Formula]s available on a node, keyed by formula id.
///
/// Operators register custom formulas here; the [standard] factory wires the
/// built-ins (Docker, Dart).
class FormulaRegistry {
  final Map<String, Formula> _formulas = {};

  /// Creates an empty registry.
  FormulaRegistry();

  /// Creates a registry pre-populated with the built-in formulas.
  factory FormulaRegistry.standard({
    CommandExecutor executor = const ProcessCommandExecutor(),
  }) {
    final registry = FormulaRegistry();
    registry
      ..register(DockerFormula(executor: executor))
      ..register(DartFormula(executor: executor));
    return registry;
  }

  /// Registers (or replaces) [formula].
  void register(Formula formula) => _formulas[formula.spec.id.value] = formula;

  /// The formula with [id], or `null`.
  Formula? byId(String id) => _formulas[id];

  /// All registered formulas.
  Iterable<Formula> get formulas => _formulas.values;
}
