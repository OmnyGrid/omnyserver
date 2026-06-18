part of 'control_message.dart';

/// The role a connecting party announces in its [Hello].
enum PeerRole {
  /// A node agent connecting to the Hub.
  node,

  /// An operator client / API consumer.
  client;

  /// Parses a wire name, defaulting to [client].
  static PeerRole parse(String value) =>
      PeerRole.values.firstWhere((r) => r.name == value, orElse: () => client);
}

// ---------------------------------------------------------------------------
// Handshake & authentication.
// ---------------------------------------------------------------------------

/// First message a peer sends after connecting: announces role and protocol.
final class Hello extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'hello';

  /// The peer's role.
  final PeerRole role;

  /// The protocol version the peer speaks (`major.minor`).
  final String protocolVersion;

  /// The peer's software version.
  final String agentVersion;

  /// The peer's content-derived uid, if it has one.
  final String? uid;

  /// Creates a hello.
  const Hello({
    required this.role,
    required this.protocolVersion,
    required this.agentVersion,
    this.uid,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'role': role.name,
    'protocolVersion': protocolVersion,
    'agentVersion': agentVersion,
    if (uid != null) 'uid': uid,
  };

  /// Decodes from JSON.
  static Hello fromJson(int? channel, Map<String, dynamic> d) => Hello(
    role: PeerRole.parse(Json.requireString(d, 'role')),
    protocolVersion: Json.optString(d, 'protocolVersion') ?? '1.0',
    agentVersion: Json.optString(d, 'agentVersion') ?? '',
    uid: Json.optString(d, 'uid'),
  );
}

/// Hub → peer: a nonce the peer must sign (public-key auth) and echo.
final class AuthChallenge extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'auth.challenge';

  /// A base64 random nonce.
  final String nonce;

  /// Creates an auth challenge.
  const AuthChallenge(this.nonce);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'nonce': nonce};

  /// Decodes from JSON.
  static AuthChallenge fromJson(int? channel, Map<String, dynamic> d) =>
      AuthChallenge(Json.requireString(d, 'nonce'));
}

/// Peer → Hub: the credential answering an [AuthChallenge].
final class AuthSubmit extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'auth.submit';

  /// The presented credential.
  final Credential credential;

  /// Creates an auth submit.
  const AuthSubmit(this.credential);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => credential.toJson();

  /// Decodes from JSON.
  static AuthSubmit fromJson(int? channel, Map<String, dynamic> d) =>
      AuthSubmit(
        Credential(
          principal: Json.requireString(d, 'principal'),
          token: Json.optString(d, 'token'),
          publicKey: Json.optString(d, 'publicKey'),
          signature: Json.optString(d, 'signature'),
        ),
      );
}

/// Hub → peer: authentication succeeded.
final class AuthOk extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'auth.ok';

  /// The resolved principal id.
  final String principalId;

  /// The roles granted.
  final List<String> roles;

  /// Creates an auth-ok.
  const AuthOk({required this.principalId, this.roles = const []});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'principalId': principalId,
    if (roles.isNotEmpty) 'roles': roles,
  };

  /// Decodes from JSON.
  static AuthOk fromJson(int? channel, Map<String, dynamic> d) => AuthOk(
    principalId: Json.requireString(d, 'principalId'),
    roles: Json.optStringList(d, 'roles'),
  );
}

/// Hub → peer: authentication failed.
final class AuthFail extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'auth.fail';

  /// A human-readable reason.
  final String reason;

  /// Creates an auth-fail.
  const AuthFail(this.reason);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'reason': reason};

  /// Decodes from JSON.
  static AuthFail fromJson(int? channel, Map<String, dynamic> d) =>
      AuthFail(Json.optString(d, 'reason') ?? 'authentication failed');
}

// ---------------------------------------------------------------------------
// Node lifecycle & monitoring.
// ---------------------------------------------------------------------------

/// Node → Hub: register (or refresh) this node's descriptor and capabilities.
final class NodeRegister extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'node.register';

  /// The node descriptor (identity, platform, capabilities, labels).
  final NodeDescriptor descriptor;

  /// Creates a register message.
  const NodeRegister(this.descriptor);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'descriptor': descriptor.toJson()};

  /// Decodes from JSON.
  static NodeRegister fromJson(int? channel, Map<String, dynamic> d) =>
      NodeRegister(
        NodeDescriptor.fromJson(Json.asObject(d['descriptor'], 'descriptor')),
      );
}

/// Hub → node: registration accepted.
final class NodeRegistered extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'node.registered';

  /// The registered node id.
  final String nodeId;

  /// Creates a registered message.
  const NodeRegistered(this.nodeId);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'nodeId': nodeId};

  /// Decodes from JSON.
  static NodeRegistered fromJson(int? channel, Map<String, dynamic> d) =>
      NodeRegistered(Json.requireString(d, 'nodeId'));
}

/// Node → Hub: a heartbeat (liveness + optional status snapshot).
final class NodeHeartbeat extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'node.heartbeat';

  /// The heartbeat payload.
  final Heartbeat heartbeat;

  /// Creates a heartbeat message.
  const NodeHeartbeat(this.heartbeat);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => heartbeat.toJson();

  /// Decodes from JSON.
  static NodeHeartbeat fromJson(int? channel, Map<String, dynamic> d) =>
      NodeHeartbeat(Heartbeat.fromJson(d));
}

/// Hub → node: heartbeat acknowledged.
final class NodeHeartbeatAck extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'node.heartbeat.ack';

  /// The acknowledged sequence number.
  final int sequence;

  /// Creates an ack.
  const NodeHeartbeatAck(this.sequence);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'sequence': sequence};

  /// Decodes from JSON.
  static NodeHeartbeatAck fromJson(int? channel, Map<String, dynamic> d) =>
      NodeHeartbeatAck(Json.optInt(d, 'sequence', 0) ?? 0);
}

/// Node → Hub: a full live status snapshot (out of band from heartbeats).
final class StatusReport extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'node.status';

  /// The reporting node id.
  final String nodeId;

  /// The status snapshot.
  final NodeStatus status;

  /// Creates a status report.
  const StatusReport({required this.nodeId, required this.status});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'status': status.toJson(),
  };

  /// Decodes from JSON.
  static StatusReport fromJson(int? channel, Map<String, dynamic> d) =>
      StatusReport(
        nodeId: Json.requireString(d, 'nodeId'),
        status: NodeStatus.fromJson(Json.asObject(d['status'], 'status')),
      );
}

/// Node → Hub: a batch of log lines (system / agent / formula logs).
final class LogBatch extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'node.logs';

  /// The reporting node id.
  final String nodeId;

  /// The log source (`system`, `agent`, `formula`).
  final String source;

  /// The log lines.
  final List<String> lines;

  /// Creates a log batch.
  const LogBatch({
    required this.nodeId,
    required this.source,
    required this.lines,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'source': source,
    'lines': lines,
  };

  /// Decodes from JSON.
  static LogBatch fromJson(int? channel, Map<String, dynamic> d) => LogBatch(
    nodeId: Json.requireString(d, 'nodeId'),
    source: Json.optString(d, 'source') ?? 'agent',
    lines: Json.optStringList(d, 'lines'),
  );
}

// ---------------------------------------------------------------------------
// Keepalive.
// ---------------------------------------------------------------------------

/// A keepalive ping. The peer echoes the [token] in a [Pong].
final class Ping extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'ping';

  /// An opaque correlation token.
  final String token;

  /// Creates a ping.
  const Ping(this.token);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'token': token};

  /// Decodes from JSON.
  static Ping fromJson(int? channel, Map<String, dynamic> d) =>
      Ping(Json.optString(d, 'token') ?? '');
}

/// The reply to a [Ping].
final class Pong extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'pong';

  /// The echoed correlation token.
  final String token;

  /// Creates a pong.
  const Pong(this.token);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'token': token};

  /// Decodes from JSON.
  static Pong fromJson(int? channel, Map<String, dynamic> d) =>
      Pong(Json.optString(d, 'token') ?? '');
}

// ---------------------------------------------------------------------------
// Discovery (Hub answers; clients/API ask).
// ---------------------------------------------------------------------------

/// Client → Hub: list all registered nodes.
final class NodeListRequest extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'nodes.list.request';

  /// Correlation id.
  final String requestId;

  /// Creates the request.
  const NodeListRequest(this.requestId);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'requestId': requestId};

  /// Decodes from JSON.
  static NodeListRequest fromJson(int? channel, Map<String, dynamic> d) =>
      NodeListRequest(Json.requireString(d, 'requestId'));
}

/// Hub → client: the list of registered nodes.
final class NodeListResponse extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'nodes.list.response';

  /// Correlation id.
  final String requestId;

  /// The node descriptors.
  final List<NodeDescriptor> nodes;

  /// Creates the response.
  const NodeListResponse({required this.requestId, required this.nodes});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'nodes': nodes.map((n) => n.toJson()).toList(),
  };

  /// Decodes from JSON.
  static NodeListResponse fromJson(int? channel, Map<String, dynamic> d) =>
      NodeListResponse(
        requestId: Json.requireString(d, 'requestId'),
        nodes: Json.optObjectList(
          d,
          'nodes',
        ).map(NodeDescriptor.fromJson).toList(),
      );
}

// ---------------------------------------------------------------------------
// Operations (Hub → node) and their results (node → Hub).
// ---------------------------------------------------------------------------

/// Hub → node: run a shell command.
final class CommandRequest extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.command.request';

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

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'command': command,
    if (args.isNotEmpty) 'args': args,
  };

  /// Decodes from JSON.
  static CommandRequest fromJson(int? channel, Map<String, dynamic> d) =>
      CommandRequest(
        requestId: Json.requireString(d, 'requestId'),
        command: Json.requireString(d, 'command'),
        args: Json.optStringList(d, 'args'),
      );
}

/// Node → Hub: the result of a [CommandRequest].
final class CommandResult extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.command.result';

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

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'exitCode': exitCode,
    if (stdout.isNotEmpty) 'stdout': stdout,
    if (stderr.isNotEmpty) 'stderr': stderr,
  };

  /// Decodes from JSON.
  static CommandResult fromJson(int? channel, Map<String, dynamic> d) =>
      CommandResult(
        requestId: Json.requireString(d, 'requestId'),
        exitCode: Json.optInt(d, 'exitCode', 0) ?? 0,
        stdout: Json.optString(d, 'stdout') ?? '',
        stderr: Json.optString(d, 'stderr') ?? '',
      );
}

/// Hub → node: run a formula action.
final class FormulaRun extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.formula.run';

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

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'formula': formula,
    'action': action.name,
    if (version != null) 'version': version,
    if (parameters.isNotEmpty) 'parameters': parameters,
  };

  /// Decodes from JSON.
  static FormulaRun fromJson(int? channel, Map<String, dynamic> d) =>
      FormulaRun(
        requestId: Json.requireString(d, 'requestId'),
        formula: Json.requireString(d, 'formula'),
        action: FormulaAction.parse(Json.requireString(d, 'action')),
        version: Json.optString(d, 'version'),
        parameters: Json.optStringMap(d, 'parameters'),
      );
}

/// Node → Hub: a streamed progress line during a formula run.
final class FormulaProgress extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.formula.progress';

  /// Correlation id.
  final String requestId;

  /// A single log line.
  final String line;

  /// Creates a progress message.
  const FormulaProgress({required this.requestId, required this.line});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'requestId': requestId, 'line': line};

  /// Decodes from JSON.
  static FormulaProgress fromJson(int? channel, Map<String, dynamic> d) =>
      FormulaProgress(
        requestId: Json.requireString(d, 'requestId'),
        line: Json.optString(d, 'line') ?? '',
      );
}

/// Node → Hub: the final result of a [FormulaRun].
final class FormulaRunResult extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.formula.result';

  /// Correlation id.
  final String requestId;

  /// The structured result.
  final FormulaResult result;

  /// Creates a formula-run result.
  const FormulaRunResult({required this.requestId, required this.result});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'result': result.toJson(),
  };

  /// Decodes from JSON.
  static FormulaRunResult fromJson(int? channel, Map<String, dynamic> d) =>
      FormulaRunResult(
        requestId: Json.requireString(d, 'requestId'),
        result: FormulaResult.fromJson(Json.asObject(d['result'], 'result')),
      );
}

/// Hub → node: apply a preset (a bundle of formula steps).
final class PresetApply extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.preset.apply';

  /// Correlation id.
  final String requestId;

  /// The preset to apply.
  final Preset preset;

  /// Creates a preset-apply request.
  const PresetApply({required this.requestId, required this.preset});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'preset': preset.toJson(),
  };

  /// Decodes from JSON.
  static PresetApply fromJson(int? channel, Map<String, dynamic> d) =>
      PresetApply(
        requestId: Json.requireString(d, 'requestId'),
        preset: Preset.fromJson(Json.asObject(d['preset'], 'preset')),
      );
}

/// Node → Hub: the result of applying a preset.
final class PresetApplyResult extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.preset.result';

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

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'success': success,
    'results': results.map((r) => r.toJson()).toList(),
  };

  /// Decodes from JSON.
  static PresetApplyResult fromJson(int? channel, Map<String, dynamic> d) =>
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
final class ServiceControl extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.service.control';

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

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'service': service,
    'action': action,
  };

  /// Decodes from JSON.
  static ServiceControl fromJson(int? channel, Map<String, dynamic> d) =>
      ServiceControl(
        requestId: Json.requireString(d, 'requestId'),
        service: Json.requireString(d, 'service'),
        action: Json.requireString(d, 'action'),
      );
}

/// Node → Hub: the result of a [ServiceControl].
final class ServiceControlResult extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.service.result';

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

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'success': success,
    if (descriptor != null) 'descriptor': descriptor!.toJson(),
    if (message.isNotEmpty) 'message': message,
  };

  /// Decodes from JSON.
  static ServiceControlResult fromJson(int? channel, Map<String, dynamic> d) {
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
final class NodeControl extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.node.control';

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

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'action': action,
    if (parameters.isNotEmpty) 'parameters': parameters,
  };

  /// Decodes from JSON.
  static NodeControl fromJson(int? channel, Map<String, dynamic> d) =>
      NodeControl(
        requestId: Json.requireString(d, 'requestId'),
        action: Json.requireString(d, 'action'),
        parameters: Json.optStringMap(d, 'parameters'),
      );
}

/// A generic acknowledgement for a request that has no richer result type.
final class OperationAck extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'op.ack';

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

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'success': success,
    if (message.isNotEmpty) 'message': message,
  };

  /// Decodes from JSON.
  static OperationAck fromJson(int? channel, Map<String, dynamic> d) =>
      OperationAck(
        requestId: Json.requireString(d, 'requestId'),
        success: Json.optBool(d, 'success'),
        message: Json.optString(d, 'message') ?? '',
      );
}

/// Either side: a protocol-level error.
final class ProtocolErrorMessage extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'error';

  /// A stable error code.
  final String code;

  /// A human-readable message.
  final String message;

  /// Optional correlation id of the request that failed.
  final String? requestId;

  /// Creates a protocol error message.
  const ProtocolErrorMessage({
    required this.code,
    required this.message,
    this.requestId,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    if (requestId != null) 'requestId': requestId,
  };

  /// Decodes from JSON.
  static ProtocolErrorMessage fromJson(int? channel, Map<String, dynamic> d) =>
      ProtocolErrorMessage(
        code: Json.optString(d, 'code') ?? 'protocol_error',
        message: Json.optString(d, 'message') ?? '',
        requestId: Json.optString(d, 'requestId'),
      );
}
