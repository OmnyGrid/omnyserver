import '../../domain/entities/platform_info.dart';
import '../../domain/formula/formula_action.dart';
import '../../domain/formula/formula_context.dart';
import '../../domain/formula/formula_result.dart';
import '../../domain/formula/formula_status.dart';
import '../../domain/value_objects/formula_id.dart';
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

  /// Where a formula's output goes as it is produced.
  ///
  /// Wired to the agent's own logger, so it reaches the Hub through the node
  /// log stream and an operator can watch an install happen instead of waiting
  /// to be told how it went. Each line is tagged with the run that produced it
  /// — `[dart install] …` — because the stream carries everything the node
  /// says, and a reader needs to pick one run out of it.
  final void Function(String line)? onLog;

  /// How many lines a single run keeps in its result.
  ///
  /// The tail, not the head: when an install fails after four hundred lines of
  /// `apt-get`, the interesting ones are at the end. The live stream is not
  /// capped — this is only what a finished result carries around.
  static const int logLimit = 200;

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
    void Function(String line)? log,
  }) => FormulaContext(
    platform: PlatformInfo.local(agentVersion: agentVersion),
    targetVersion: targetVersion,
    parameters: parameters,
    clock: clock,
    log: log ?? onLog,
  );

  /// Tags a run's output for the live stream, and keeps its tail for the result.
  _RunLog _runLog(String formula, FormulaAction action) =>
      _RunLog(tag: runTag(formula, action), sink: onLog, limit: logLimit);

  /// The prefix every line of a run carries on the node log stream.
  ///
  /// Public because it is a wire format in all but name: a client filtering the
  /// stream for one run has to build the same string.
  static String runTag(String formula, FormulaAction action) =>
      '[$formula ${action.name}]';

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
    final log = _runLog(request.formula, request.action);
    final result = await formula.run(
      request.action,
      _context(
        targetVersion: request.version,
        parameters: request.parameters,
        log: log.add,
      ),
    );
    return result.withLogs(log.lines);
  }

  /// Reports what each formula finds when it looks at itself.
  ///
  /// Sequential, not concurrent: these probes shell out, and a node with a
  /// dozen formulas firing a dozen processes at once on a small box is a
  /// noticeable spike for a panel refresh. They are quick — a version flag and
  /// an `info` — so in order is fast enough.
  ///
  /// A formula the node does not have is reported as
  /// [FormulaStatus.unknown] rather than omitted: a caller that asked about it
  /// by name is owed an answer, and a silently missing row reads as "still
  /// loading".
  Future<FormulaStatusResult> reportStatus(FormulaStatusRequest request) async {
    final wanted = request.formulas.isEmpty
        ? [for (final formula in registry.formulas) formula.spec.id.value]
        : request.formulas;

    final reports = <FormulaStatusReport>[];
    for (final id in wanted) {
      final formula = registry.byId(id);
      if (formula == null) {
        reports.add(
          FormulaStatusReport(
            formula: FormulaId(id),
            status: FormulaStatus.unknown,
            message: 'this node has no formula "$id"',
            checkedAt: clock.now(),
          ),
        );
        continue;
      }
      reports.add(await formula.status(_context()));
    }

    return FormulaStatusResult(
      requestId: request.requestId,
      reports: reports
        ..sort((a, b) => a.formula.value.compareTo(b.formula.value)),
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
      final log = _runLog(step.formula.value, step.action);
      final result = await formula.run(
        step.action,
        _context(targetVersion: step.version, log: log.add),
      );
      results.add(result.withLogs(log.lines));
      if (!result.success) allOk = false;
    }
    return PresetApplyResult(
      requestId: request.requestId,
      success: allOk,
      results: results,
    );
  }
}

/// One run's output: tagged and forwarded live, tail kept for the result.
class _RunLog {
  _RunLog({required this.tag, required this.sink, required this.limit});

  /// The prefix that identifies this run on the shared node log stream.
  final String tag;

  /// The agent's logger, when the node was wired with one.
  final void Function(String line)? sink;

  /// How many lines the result keeps.
  final int limit;

  final List<String> _tail = [];
  int _dropped = 0;

  /// Forwards [line] to the live stream, and remembers it.
  void add(String line) {
    sink?.call('$tag $line');
    _tail.add(line);
    if (_tail.length > limit) {
      _tail.removeAt(0);
      _dropped++;
    }
  }

  /// The tail, said plainly when there is more that was not kept — a result
  /// that silently starts in the middle reads like the beginning.
  List<String> get lines => _dropped == 0
      ? List.unmodifiable(_tail)
      : List.unmodifiable([
          '… $_dropped earlier lines not kept; the full output went to the '
              'node log',
          ..._tail,
        ]);
}
