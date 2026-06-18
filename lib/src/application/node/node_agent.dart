import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/entities/heartbeat.dart';
import '../../domain/entities/node_capabilities.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../domain/entities/node_status.dart';
import '../../domain/entities/platform_info.dart';
import '../../domain/entities/resource_metrics.dart';
import '../../domain/formula/formula_result.dart';
import '../../domain/value_objects/node_id.dart';
import '../../infrastructure/transport/web_socket_connection.dart';
import '../../protocol/control_message.dart';
import '../../protocol/omny_connection.dart';
import '../../protocol/omny_frame.dart';
import '../../protocol/protocol_version.dart';
import '../../shared/errors/omnyserver_exception.dart';
import 'agent_state.dart';
import 'node_agent_config.dart';

/// The Node agent runtime: connects to the Hub over WSS, authenticates,
/// registers, maintains a heartbeat with live status, executes Hub-dispatched
/// operations, and reconnects automatically when the connection drops.
class NodeAgent {
  /// The agent configuration.
  final NodeAgentConfig config;

  final StreamController<AgentState> _states =
      StreamController<AgentState>.broadcast();
  AgentState _state = AgentState.offline;
  Completer<void>? _firstConnected;
  OmnyConnection? _connection;
  Timer? _heartbeatTimer;
  int _sequence = 0;
  bool _running = false;

  /// Creates an agent from [config].
  NodeAgent(this.config);

  /// The current state.
  AgentState get state => _state;

  /// A stream of state transitions.
  Stream<AgentState> get states => _states.stream;

  /// Whether the agent is currently connected and registered.
  bool get isConnected => _state == AgentState.connected;

  void _log(String message) => config.logger?.call(message);

  void _setState(AgentState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  /// Starts the agent and resolves once it is first connected and registered.
  ///
  /// Throws an [AuthException] if authentication is rejected on the first
  /// attempt (the agent does not reconnect after an auth failure). Transient
  /// transport failures are retried with backoff.
  Future<void> start() {
    if (_running) {
      throw StateError('agent already started');
    }
    _running = true;
    _firstConnected = Completer<void>();
    unawaited(_loop());
    return _firstConnected!.future;
  }

  /// Stops the agent and closes the connection.
  Future<void> stop() async {
    _running = false;
    _heartbeatTimer?.cancel();
    await _connection?.close();
    _setState(AgentState.offline);
    if (!_states.isClosed) await _states.close();
  }

  Future<void> _loop() async {
    var attempt = 0;
    while (_running) {
      try {
        _setState(AgentState.connecting);
        final connection = await WebSocketConnection.connect(
          config.hubUri,
          securityContext: config.securityContext,
          onBadCertificate: config.onBadCertificate,
        );
        _connection = connection;
        await _handshakeAndRegister(connection);
        attempt = 0;
        _setState(AgentState.connected);
        if (!(_firstConnected?.isCompleted ?? true)) {
          _firstConnected!.complete();
        }
        await _serve(connection);
      } on AuthException catch (e) {
        _setState(AgentState.authenticationFailed);
        _log('authentication failed: ${e.message}');
        if (!(_firstConnected?.isCompleted ?? true)) {
          _firstConnected!.completeError(e);
        }
        _running = false;
        return;
      } on Object catch (e) {
        _log('connection lost: $e');
      }
      if (!_running) break;
      _setState(AgentState.reconnecting);
      await Future<void>.delayed(config.reconnect.delayFor(attempt));
      attempt++;
    }
  }

  Future<void> _handshakeAndRegister(OmnyConnection connection) async {
    connection.sendMessage(
      Hello(
        role: PeerRole.node,
        protocolVersion: ProtocolVersion.current.label,
        agentVersion: config.agentVersion,
      ),
    );

    final challengeMsg = await _expect<AuthChallenge>(connection);
    final challenge = Uint8List.fromList(base64.decode(challengeMsg.nonce));
    final credential = await config.credentials.provide(challenge: challenge);
    connection.sendMessage(AuthSubmit(credential));

    final authReply = await _expectAny(connection);
    if (authReply is AuthFail) {
      throw AuthException(authReply.reason);
    }
    if (authReply is! AuthOk) {
      throw const ProtocolException('expected auth result');
    }

    final descriptor = await _buildDescriptor();
    connection.sendMessage(NodeRegister(descriptor));
    await _expect<NodeRegistered>(connection);
    _log('registered as ${config.nodeId}');
  }

  Future<NodeDescriptor> _buildDescriptor() async {
    final capabilities =
        (await config.capabilityProvider?.call()) ?? NodeCapabilities.empty;
    return NodeDescriptor(
      id: NodeId(config.nodeId),
      displayName: config.displayName.isEmpty
          ? config.nodeId
          : config.displayName,
      platform: PlatformInfo.local(agentVersion: config.agentVersion),
      online: true,
      labels: config.labels,
      capabilities: capabilities,
    );
  }

  Future<void> _serve(OmnyConnection connection) async {
    _sequence = 0;
    _heartbeatTimer = Timer.periodic(
      config.heartbeatInterval,
      (_) => unawaited(_sendHeartbeat(connection)),
    );
    // Send an immediate first heartbeat so status is available promptly.
    await _sendHeartbeat(connection);

    await for (final frame in connection.incoming) {
      if (frame is ControlFrame) {
        await _onMessage(connection, frame.message);
      }
    }
    _heartbeatTimer?.cancel();
  }

  Future<void> _sendHeartbeat(OmnyConnection connection) async {
    if (!connection.isOpen) return;
    final status = await _status();
    connection.sendMessage(
      NodeHeartbeat(
        Heartbeat(
          nodeId: NodeId(config.nodeId),
          sequence: ++_sequence,
          sentAt: config.clock.now(),
          status: status,
        ),
      ),
    );
  }

  Future<NodeStatus> _status() async {
    final provider = config.statusProvider;
    if (provider != null) return provider();
    return _basicStatus();
  }

  NodeStatus _basicStatus() {
    final platform = PlatformInfo.local(agentVersion: config.agentVersion);
    return NodeStatus(
      capturedAt: config.clock.now(),
      cpu: CpuInfo(usagePercent: 0, coreCount: Platform.numberOfProcessors),
      memory: const MemoryInfo(totalBytes: 0, usedBytes: 0, availableBytes: 0),
      storage: const [],
      os: platform,
    );
  }

  Future<void> _onMessage(
    OmnyConnection connection,
    ControlMessage message,
  ) async {
    switch (message) {
      case NodeHeartbeatAck():
        break;
      case CommandRequest():
        connection.sendMessage(await _runCommand(message));
      case FormulaRun():
        connection.sendMessage(await _runFormula(message));
      case PresetApply():
        connection.sendMessage(await _applyPreset(message));
      case ServiceControl():
        connection.sendMessage(await _controlService(message));
      case NodeControl():
        connection.sendMessage(await _controlNode(message));
      default:
        break;
    }
  }

  Future<CommandResult> _runCommand(CommandRequest request) async {
    try {
      final result = await Process.run(request.command, request.args);
      return CommandResult(
        requestId: request.requestId,
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } on Object catch (e) {
      return CommandResult(
        requestId: request.requestId,
        exitCode: 127,
        stderr: 'failed to run command: $e',
      );
    }
  }

  Future<FormulaRunResult> _runFormula(FormulaRun request) async {
    final handler = config.formulaHandler;
    if (handler == null) {
      return FormulaRunResult(
        requestId: request.requestId,
        result: _unsupportedFormula(request),
      );
    }
    final result = await handler(request);
    return FormulaRunResult(requestId: request.requestId, result: result);
  }

  Future<PresetApplyResult> _applyPreset(PresetApply request) async {
    final handler = config.presetHandler;
    if (handler == null) {
      return PresetApplyResult(requestId: request.requestId, success: false);
    }
    return handler(request);
  }

  Future<ServiceControlResult> _controlService(ServiceControl request) async {
    final handler = config.serviceHandler;
    if (handler == null) {
      return ServiceControlResult(
        requestId: request.requestId,
        success: false,
        message: 'service control not supported on this node',
      );
    }
    return handler(request);
  }

  Future<OperationAck> _controlNode(NodeControl request) async {
    final handler = config.nodeControlHandler;
    if (handler == null) {
      // Default: acknowledge without acting (safe no-op for restart/shutdown).
      return OperationAck(
        requestId: request.requestId,
        success: true,
        message: 'acknowledged ${request.action}',
      );
    }
    final (ok, message) = await handler(request);
    return OperationAck(
      requestId: request.requestId,
      success: ok,
      message: message,
    );
  }

  FormulaResult _unsupportedFormula(FormulaRun request) => FormulaResult(
    formula: request.formula,
    action: request.action,
    success: false,
    message: 'formula execution not configured on this node',
    finishedAt: config.clock.now(),
  );

  Future<T> _expect<T extends ControlMessage>(OmnyConnection connection) async {
    final message = await _expectAny(connection);
    if (message is T) return message;
    throw ProtocolException('expected ${T.toString()}, got ${message.type}');
  }

  Future<ControlMessage> _expectAny(OmnyConnection connection) async {
    await for (final frame in connection.incoming) {
      if (frame is ControlFrame) return frame.message;
    }
    throw const TransportException('connection closed during handshake');
  }
}
