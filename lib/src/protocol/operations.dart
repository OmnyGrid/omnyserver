import '../domain/entities/node_status.dart';
import '../domain/entities/preset.dart';
import '../domain/entities/service_descriptor.dart';
import '../domain/formula/formula_action.dart';
import '../domain/formula/formula_result.dart';
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

  /// Hub → node: apply a preset.
  static const String preset = 'op.preset.apply';

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
