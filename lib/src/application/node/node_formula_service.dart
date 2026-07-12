import '../../domain/entities/platform_info.dart';
import '../../domain/formula/formula_context.dart';
import '../../domain/formula/formula_result.dart';
import '../../protocol/operations.dart';
import '../../shared/utils/clock.dart';
import '../../version.dart';
import 'formula_registry.dart';

/// Executes formula and preset operations on a node, against a
/// [FormulaRegistry]. Supplies the `formulaHandler` / `presetHandler` an agent
/// plugs into its config.
class NodeFormulaService {
  /// The catalogue of formulas this node can run.
  final FormulaRegistry registry;

  /// The agent version (reported in the formula context platform).
  final String agentVersion;

  /// Time source.
  final Clock clock;

  /// Optional sink for streamed formula log lines.
  final void Function(String line)? onLog;

  /// Creates a node formula service.
  NodeFormulaService({
    required this.registry,
    this.agentVersion = omnyServerVersion,
    this.clock = const SystemClock(),
    this.onLog,
  });

  FormulaContext _context({
    String? targetVersion,
    Map<String, String> parameters = const {},
  }) => FormulaContext(
    platform: PlatformInfo.local(agentVersion: agentVersion),
    targetVersion: targetVersion,
    parameters: parameters,
    clock: clock,
    log: onLog,
  );

  /// Runs a single formula action, returning its result.
  Future<FormulaResult> runFormula(FormulaRun request) async {
    final formula = registry.byId(request.formula);
    if (formula == null) {
      return FormulaResult(
        formula: request.formula,
        action: request.action,
        success: false,
        message: 'unknown formula "${request.formula}"',
        finishedAt: clock.now(),
      );
    }
    return formula.run(
      request.action,
      _context(targetVersion: request.version, parameters: request.parameters),
    );
  }

  /// Applies a preset by running its steps in order; success requires every
  /// step to succeed.
  Future<PresetApplyResult> applyPreset(PresetApply request) async {
    final results = <FormulaResult>[];
    var allOk = true;
    for (final step in request.preset.steps) {
      final formula = registry.byId(step.formula.value);
      if (formula == null) {
        results.add(
          FormulaResult(
            formula: step.formula.value,
            action: step.action,
            success: false,
            message: 'unknown formula "${step.formula.value}"',
            finishedAt: clock.now(),
          ),
        );
        allOk = false;
        continue;
      }
      final result = await formula.run(
        step.action,
        _context(targetVersion: step.version),
      );
      results.add(result);
      if (!result.success) allOk = false;
    }
    return PresetApplyResult(
      requestId: request.requestId,
      success: allOk,
      results: results,
    );
  }
}
