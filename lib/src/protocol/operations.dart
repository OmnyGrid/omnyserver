import '../domain/blueprint/resolved_blueprint.dart';
import '../domain/blueprint/resource_change.dart';
import '../domain/blueprint/resource_state.dart';
import '../domain/entities/node_status.dart';
import '../domain/entities/preset.dart';
import '../domain/entities/service_descriptor.dart';
import '../domain/formula/formula_action.dart';
import '../domain/formula/formula_result.dart';
import '../domain/formula/formula_status.dart';
import '../shared/json/json_codec_helpers.dart';

/// The operations the Hub invokes on a node, and the results it gets back.
///
/// These are **payloads, not control messages**: each rides inside an omnyhub
/// `NodeRequest`/`NodeResponse` (for calls that need an answer) or `NodeNotify`
/// (for one-way pushes), which own the envelope, the correlation id, the timeout
/// and the failure-on-disconnect. Each type's [Operations] action name is the
/// `action` string on that envelope.
///
/// They keep their `requestId` field. It duplicates the envelope's correlation
/// id and the transport no longer reads it — but it is part of the handler
/// signatures applications implement (`FormulaHandler`, `ServiceHandler`, …) and
/// of the JSON the HTTP API returns, so it stays.
class Operations {
  const Operations._();

  /// Hub → node: run a shell command.
  static const String command = 'op.command.request';

  /// Hub → node: run a formula action.
  static const String formula = 'op.formula.run';

  /// Hub → node: report the state of the formulas the node carries.
  static const String formulaStatus = 'op.formula.status';

  /// Hub → node: apply a preset.
  static const String preset = 'op.preset.apply';

  /// Hub → node: work out what applying a blueprint would change.
  static const String blueprintPlan = 'op.blueprint.plan';

  /// Hub → node: apply a blueprint.
  static const String blueprintApply = 'op.blueprint.apply';

  /// Hub → node: control an OS service.
  static const String service = 'op.service.control';

  /// Hub → node: restart / shutdown / update the node.
  static const String control = 'op.node.control';

  /// Node → hub: a live status snapshot (one-way).
  static const String status = 'node.status';

  /// Node → hub: a batch of log lines (one-way).
  static const String logs = 'node.logs';
}

/// Hub → node: run a shell command.
final class CommandRequest {
  /// Correlation id.
  final String requestId;

  /// The executable.
  final String command;

  /// Arguments.
  final List<String> args;

  /// Creates a command request.
  const CommandRequest({
    required this.requestId,
    required this.command,
    this.args = const [],
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'command': command,
    if (args.isNotEmpty) 'args': args,
  };

  /// Decodes from JSON.
  static CommandRequest fromJson(Map<String, dynamic> d) => CommandRequest(
    requestId: Json.requireString(d, 'requestId'),
    command: Json.requireString(d, 'command'),
    args: Json.optStringList(d, 'args'),
  );
}

/// Node → Hub: the result of a [CommandRequest].
final class CommandResult {
  /// Correlation id.
  final String requestId;

  /// The process exit code.
  final int exitCode;

  /// Captured stdout.
  final String stdout;

  /// Captured stderr.
  final String stderr;

  /// Creates a command result.
  const CommandResult({
    required this.requestId,
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'exitCode': exitCode,
    if (stdout.isNotEmpty) 'stdout': stdout,
    if (stderr.isNotEmpty) 'stderr': stderr,
  };

  /// Decodes from JSON.
  static CommandResult fromJson(Map<String, dynamic> d) => CommandResult(
    requestId: Json.requireString(d, 'requestId'),
    exitCode: Json.optInt(d, 'exitCode', 0) ?? 0,
    stdout: Json.optString(d, 'stdout') ?? '',
    stderr: Json.optString(d, 'stderr') ?? '',
  );
}

/// Hub → node: run a formula action.
final class FormulaRun {
  /// Correlation id.
  final String requestId;

  /// The formula id.
  final String formula;

  /// The action to run.
  final FormulaAction action;

  /// The target version, if pinned.
  final String? version;

  /// Extra parameters.
  final Map<String, String> parameters;

  /// Creates a formula-run request.
  const FormulaRun({
    required this.requestId,
    required this.formula,
    required this.action,
    this.version,
    this.parameters = const {},
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'formula': formula,
    'action': action.name,
    if (version != null) 'version': version,
    if (parameters.isNotEmpty) 'parameters': parameters,
  };

  /// Decodes from JSON.
  static FormulaRun fromJson(Map<String, dynamic> d) => FormulaRun(
    requestId: Json.requireString(d, 'requestId'),
    formula: Json.requireString(d, 'formula'),
    action: FormulaAction.parse(Json.requireString(d, 'action')),
    version: Json.optString(d, 'version'),
    parameters: Json.optStringMap(d, 'parameters'),
  );
}

/// Node → Hub: the final result of a [FormulaRun].
final class FormulaRunResult {
  /// Correlation id.
  final String requestId;

  /// The structured result.
  final FormulaResult result;

  /// Creates a formula-run result.
  const FormulaRunResult({required this.requestId, required this.result});

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'result': result.toJson(),
  };

  /// Decodes from JSON.
  static FormulaRunResult fromJson(Map<String, dynamic> d) => FormulaRunResult(
    requestId: Json.requireString(d, 'requestId'),
    result: FormulaResult.fromJson(Json.asObject(d['result'], 'result')),
  );
}

/// Hub → node: report the state of the formulas this node carries.
///
/// One request for the whole registry rather than one per formula. A dashboard
/// showing a node's software asks about all of it at once, and a node with a
/// dozen formulas would otherwise be a dozen round trips over a link that may
/// be a continent away.
final class FormulaStatusRequest {
  /// Correlation id.
  final String requestId;

  /// The formula ids to report on; empty means everything the node has.
  ///
  /// Empty is the usual case, and the reason this is a node-side question at
  /// all: the Hub's catalogue is what nodes *can* run, and a node may carry a
  /// site-registered formula the Hub has never heard of.
  final List<String> formulas;

  /// Creates a formula-status request.
  const FormulaStatusRequest({
    required this.requestId,
    this.formulas = const [],
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    if (formulas.isNotEmpty) 'formulas': formulas,
  };

  /// Decodes from JSON.
  static FormulaStatusRequest fromJson(Map<String, dynamic> d) =>
      FormulaStatusRequest(
        requestId: Json.requireString(d, 'requestId'),
        formulas: Json.optStringList(d, 'formulas'),
      );
}

/// Node → Hub: what each formula found when it looked at itself.
final class FormulaStatusResult {
  /// Correlation id.
  final String requestId;

  /// One report per formula asked about.
  final List<FormulaStatusReport> reports;

  /// Creates a formula-status result.
  const FormulaStatusResult({required this.requestId, this.reports = const []});

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'reports': [for (final report in reports) report.toJson()],
  };

  /// Decodes from JSON.
  static FormulaStatusResult fromJson(Map<String, dynamic> d) =>
      FormulaStatusResult(
        requestId: Json.requireString(d, 'requestId'),
        reports: [
          for (final report in Json.optObjectList(d, 'reports'))
            FormulaStatusReport.fromJson(report),
        ],
      );
}

/// Hub → node: apply a preset (a bundle of formula steps).
final class PresetApply {
  /// Correlation id.
  final String requestId;

  /// The preset to apply.
  final Preset preset;

  /// Creates a preset-apply request.
  const PresetApply({required this.requestId, required this.preset});

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'preset': preset.toJson(),
  };

  /// Decodes from JSON.
  static PresetApply fromJson(Map<String, dynamic> d) => PresetApply(
    requestId: Json.requireString(d, 'requestId'),
    preset: Preset.fromJson(Json.asObject(d['preset'], 'preset')),
  );
}

/// Node → Hub: the result of applying a preset.
final class PresetApplyResult {
  /// Correlation id.
  final String requestId;

  /// Whether all steps succeeded.
  final bool success;

  /// Per-step results.
  final List<FormulaResult> results;

  /// Creates a preset-apply result.
  const PresetApplyResult({
    required this.requestId,
    required this.success,
    this.results = const [],
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'success': success,
    'results': results.map((r) => r.toJson()).toList(),
  };

  /// Decodes from JSON.
  static PresetApplyResult fromJson(Map<String, dynamic> d) =>
      PresetApplyResult(
        requestId: Json.requireString(d, 'requestId'),
        success: Json.optBool(d, 'success'),
        results: Json.optObjectList(
          d,
          'results',
        ).map(FormulaResult.fromJson).toList(),
      );
}

/// Hub → node: work out what applying this blueprint would change.
///
/// The Hub sends a **resolved** blueprint — includes flattened, variables
/// substituted, resources ordered — so the node never learns what a preset is
/// or what a variable was. Planning happens here, on the machine, because that
/// is the only place the current state actually is: a plan built from what the
/// Hub last heard is a plan built from intentions.
final class BlueprintPlanRequest {
  /// Correlation id.
  final String requestId;

  /// What the node should be.
  final ResolvedBlueprint blueprint;

  /// Creates a plan request.
  const BlueprintPlanRequest({
    required this.requestId,
    required this.blueprint,
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'blueprint': blueprint.toJson(),
  };

  /// Decodes from JSON.
  static BlueprintPlanRequest fromJson(Map<String, dynamic> d) =>
      BlueprintPlanRequest(
        requestId: Json.requireString(d, 'requestId'),
        blueprint: ResolvedBlueprint.fromJson(
          Json.asObject(d['blueprint'], 'blueprint'),
        ),
      );
}

/// Node → Hub: what the node would have to change, or did.
///
/// One type for both the plan and the report, because they are the same
/// statement at two times — "create formula:docker", then whether it worked.
final class BlueprintPlanResult {
  /// Correlation id.
  final String requestId;

  /// The changes, in the order they would be (or were) made.
  final List<ResourceChange> changes;

  /// What the node read, per resource.
  ///
  /// Carried alongside the changes so the Hub can show an operator what a node
  /// *is*, not only what would move — a converged blueprint with an empty plan
  /// would otherwise report nothing at all.
  final List<ResourceState> states;

  /// The resolved hash the node has recorded as applied, if any.
  ///
  /// Empty when the node has never applied this blueprint. Compared against the
  /// Hub's current resolution, this answers "is this node on the blueprint it
  /// was assigned" with no further reads.
  final String appliedHash;

  /// Notes worth showing: a provider the node does not have, a skipped branch.
  final List<String> notes;

  /// Creates a plan result.
  const BlueprintPlanResult({
    required this.requestId,
    this.changes = const [],
    this.states = const [],
    this.appliedHash = '',
    this.notes = const [],
  });

  /// Whether the node already matches: nothing left that would change it.
  ///
  /// A `ChangeKind.unknown` is deliberately **not** converged. A resource whose
  /// state could not be read has not agreed to anything, and a plan that called
  /// that convergence would report a blind node as healthy.
  bool get converged =>
      !changes.any((c) => c.kind.isWork || c.kind == ChangeKind.unknown);

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'converged': converged,
    'changes': [for (final c in changes) c.toJson()],
    'states': [for (final s in states) s.toJson()],
    if (appliedHash.isNotEmpty) 'appliedHash': appliedHash,
    if (notes.isNotEmpty) 'notes': notes,
  };

  /// Decodes from JSON.
  ///
  /// `converged` is written for a reader but never read back: it is derived, and
  /// trusting a transmitted copy would let a node claim convergence its own
  /// changes contradict.
  static BlueprintPlanResult fromJson(Map<String, dynamic> d) =>
      BlueprintPlanResult(
        requestId: Json.requireString(d, 'requestId'),
        changes: Json.optObjectList(
          d,
          'changes',
        ).map(ResourceChange.fromJson).toList(),
        states: Json.optObjectList(
          d,
          'states',
        ).map(ResourceState.fromJson).toList(),
        appliedHash: Json.optString(d, 'appliedHash') ?? '',
        notes: Json.optStringList(d, 'notes'),
      );
}

/// Hub → node: make it so.
final class BlueprintApplyRequest {
  /// Correlation id.
  final String requestId;

  /// What the node should be.
  final ResolvedBlueprint blueprint;

  /// Whether to plan without touching anything.
  ///
  /// A dry run runs the *same* code as a real one and stops before the writes.
  /// A dry run that ran different code would be a dry run that lies.
  final bool dryRun;

  /// Whether to remove resources that were already correct before this system
  /// first ran.
  ///
  /// Off by default. If nginx was on this box a year before anyone wrote a
  /// blueprint, unassigning must not uninstall it.
  final bool purgeAdopted;

  /// Creates an apply request.
  const BlueprintApplyRequest({
    required this.requestId,
    required this.blueprint,
    this.dryRun = false,
    this.purgeAdopted = false,
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'blueprint': blueprint.toJson(),
    if (dryRun) 'dryRun': true,
    if (purgeAdopted) 'purgeAdopted': true,
  };

  /// Decodes from JSON.
  static BlueprintApplyRequest fromJson(Map<String, dynamic> d) =>
      BlueprintApplyRequest(
        requestId: Json.requireString(d, 'requestId'),
        blueprint: ResolvedBlueprint.fromJson(
          Json.asObject(d['blueprint'], 'blueprint'),
        ),
        dryRun: Json.optBool(d, 'dryRun'),
        purgeAdopted: Json.optBool(d, 'purgeAdopted'),
      );
}

/// Node → Hub: what the apply did.
final class BlueprintApplyResult {
  /// Correlation id.
  final String requestId;

  /// Whether every change that was attempted worked.
  final bool success;

  /// What happened, per resource, in the order it was attempted.
  final List<ResourceChange> changes;

  /// The hash now recorded in the node's ledger.
  final String appliedHash;

  /// Notes worth showing.
  final List<String> notes;

  /// Creates an apply result.
  const BlueprintApplyResult({
    required this.requestId,
    required this.success,
    this.changes = const [],
    this.appliedHash = '',
    this.notes = const [],
  });

  /// What was actually changed — the count worth reporting to an operator.
  int get changed => changes.where((c) => c.kind.isWork).length;

  /// What was not attempted because something it required failed.
  int get skipped => changes.where((c) => c.kind == ChangeKind.skipped).length;

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'success': success,
    'changed': changed,
    'skipped': skipped,
    'changes': [for (final c in changes) c.toJson()],
    if (appliedHash.isNotEmpty) 'appliedHash': appliedHash,
    if (notes.isNotEmpty) 'notes': notes,
  };

  /// Decodes from JSON.
  static BlueprintApplyResult fromJson(Map<String, dynamic> d) =>
      BlueprintApplyResult(
        requestId: Json.requireString(d, 'requestId'),
        success: Json.optBool(d, 'success'),
        changes: Json.optObjectList(
          d,
          'changes',
        ).map(ResourceChange.fromJson).toList(),
        appliedHash: Json.optString(d, 'appliedHash') ?? '',
        notes: Json.optStringList(d, 'notes'),
      );
}

/// Hub → node: control an OS service.
final class ServiceControl {
  /// Correlation id.
  final String requestId;

  /// The service name.
  final String service;

  /// The action (`install`, `start`, `stop`, `restart`, `uninstall`).
  final String action;

  /// Creates a service-control request.
  const ServiceControl({
    required this.requestId,
    required this.service,
    required this.action,
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'service': service,
    'action': action,
  };

  /// Decodes from JSON.
  static ServiceControl fromJson(Map<String, dynamic> d) => ServiceControl(
    requestId: Json.requireString(d, 'requestId'),
    service: Json.requireString(d, 'service'),
    action: Json.requireString(d, 'action'),
  );
}

/// Node → Hub: the result of a [ServiceControl].
final class ServiceControlResult {
  /// Correlation id.
  final String requestId;

  /// Whether it succeeded.
  final bool success;

  /// The resulting service descriptor, if available.
  final ServiceDescriptor? descriptor;

  /// A message (especially on failure).
  final String message;

  /// Creates a service-control result.
  const ServiceControlResult({
    required this.requestId,
    required this.success,
    this.descriptor,
    this.message = '',
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'success': success,
    if (descriptor != null) 'descriptor': descriptor!.toJson(),
    if (message.isNotEmpty) 'message': message,
  };

  /// Decodes from JSON.
  static ServiceControlResult fromJson(Map<String, dynamic> d) {
    final desc = d['descriptor'];
    return ServiceControlResult(
      requestId: Json.requireString(d, 'requestId'),
      success: Json.optBool(d, 'success'),
      descriptor: desc == null
          ? null
          : ServiceDescriptor.fromJson(Json.asObject(desc, 'descriptor')),
      message: Json.optString(d, 'message') ?? '',
    );
  }
}

/// Hub → node: a node-level control request (restart / shutdown / update).
final class NodeControl {
  /// Correlation id.
  final String requestId;

  /// The control action (`restart`, `shutdown`, `update`).
  final String action;

  /// Extra parameters (e.g. `target` for updates).
  final Map<String, String> parameters;

  /// Creates a node-control request.
  const NodeControl({
    required this.requestId,
    required this.action,
    this.parameters = const {},
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'action': action,
    if (parameters.isNotEmpty) 'parameters': parameters,
  };

  /// Decodes from JSON.
  static NodeControl fromJson(Map<String, dynamic> d) => NodeControl(
    requestId: Json.requireString(d, 'requestId'),
    action: Json.requireString(d, 'action'),
    parameters: Json.optStringMap(d, 'parameters'),
  );
}

/// A generic acknowledgement for a request that has no richer result type.
final class OperationAck {
  /// Correlation id.
  final String requestId;

  /// Whether the operation succeeded.
  final bool success;

  /// A message (especially on failure).
  final String message;

  /// Creates an ack.
  const OperationAck({
    required this.requestId,
    required this.success,
    this.message = '',
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'success': success,
    if (message.isNotEmpty) 'message': message,
  };

  /// Decodes from JSON.
  static OperationAck fromJson(Map<String, dynamic> d) => OperationAck(
    requestId: Json.requireString(d, 'requestId'),
    success: Json.optBool(d, 'success'),
    message: Json.optString(d, 'message') ?? '',
  );
}

/// Node → Hub: a live status snapshot, pushed one-way.
final class StatusReport {
  /// The reporting node's id.
  final String nodeId;

  /// The snapshot.
  final NodeStatus status;

  /// Creates a status report.
  const StatusReport({required this.nodeId, required this.status});

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'status': status.toJson(),
  };

  /// Decodes from JSON.
  static StatusReport fromJson(Map<String, dynamic> d) => StatusReport(
    nodeId: Json.requireString(d, 'nodeId'),
    status: NodeStatus.fromJson(Json.asObject(d['status'], 'status')),
  );
}

/// Node → Hub: a batch of log lines, pushed one-way.
final class LogBatch {
  /// The reporting node's id.
  final String nodeId;

  /// The log source (`system`, `agent`, `formula`).
  final String source;

  /// The lines.
  final List<String> lines;

  /// Creates a log batch.
  const LogBatch({
    required this.nodeId,
    this.source = 'agent',
    this.lines = const [],
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'source': source,
    'lines': lines,
  };

  /// Decodes from JSON.
  static LogBatch fromJson(Map<String, dynamic> d) => LogBatch(
    nodeId: Json.requireString(d, 'nodeId'),
    source: Json.optString(d, 'source') ?? 'agent',
    lines: Json.optStringList(d, 'lines'),
  );
}
