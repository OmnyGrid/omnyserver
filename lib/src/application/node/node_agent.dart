import 'dart:async';
import 'dart:io';

import 'package:omnyhub/omnyhub_node.dart' as omnyhub;

import '../../domain/entities/node_capabilities.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../domain/entities/node_status.dart';
import '../../domain/entities/platform_info.dart';
import '../../domain/entities/resource_metrics.dart';
import '../../domain/formula/formula_result.dart';
import '../../domain/value_objects/node_id.dart';
import '../../infrastructure/node/node_mapping.dart';
import '../../protocol/operations.dart';
import '../../shared/errors/omnyserver_exception.dart';
import 'agent_state.dart';
import 'node_agent_config.dart';
import 'node_handshake.dart';

/// The Node agent runtime: connects to the Hub over WSS, authenticates,
/// registers, maintains a heartbeat with live status, executes Hub-dispatched
/// operations, and reconnects automatically when the connection drops.
///
/// The connection lifecycle — dialling, the in-band handshake, registration, the
/// heartbeat timer, exponential backoff, RPC correlation — is omnyhub's
/// [omnyhub.NodeRuntime]. What lives here is OmnyServer's: what a node
/// advertises about itself, what it reports, and what it will do when asked.
class NodeAgent {
  /// The agent configuration.
  final NodeAgentConfig config;

  final StreamController<AgentState> _states =
      StreamController<AgentState>.broadcast();
  AgentState _state = AgentState.offline;
  StreamSubscription<omnyhub.NodeState>? _runtimeStates;
  omnyhub.NodeRuntime? _runtime;
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
    if (_state == state) return;
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  /// Starts the agent and resolves once it is first connected and registered.
  ///
  /// Throws an [AuthException] if authentication is rejected (the agent does not
  /// reconnect after an auth failure — a rejected credential is not fixed by
  /// trying again). Transient transport failures are retried with backoff.
  Future<void> start() async {
    if (_running) {
      throw StateError('agent already started');
    }
    _running = true;

    final runtime = omnyhub.NodeRuntime(_buildConfig());
    _runtime = runtime;

    final ready = Completer<void>();
    _runtimeStates = runtime.states.listen((state) {
      _setState(_mapState(state));
      if (state == omnyhub.NodeState.ready) {
        // Heartbeats are periodic, so the first one — and the status snapshot it
        // carries — is a full interval away. Push a snapshot now instead, or the
        // Hub reports no status at all for a node that just came up (15s by
        // default). Fires on every (re)registration, not just the first.
        unawaited(reportStatus());
      }
      if (state == omnyhub.NodeState.ready && !ready.isCompleted) {
        _log('registered as ${config.nodeId}');
        ready.complete();
      }
      // A terminal failure ends the runtime; surface it to whoever is waiting on
      // start() instead of leaving them hanging on a node that will never come up.
      if (state == omnyhub.NodeState.stopped && !ready.isCompleted) {
        final error = runtime.terminalError;
        ready.completeError(
          error ?? const TransportException('node stopped before registering'),
        );
      }
    });

    await runtime.start();
    try {
      await ready.future;
    } on Object {
      _running = false;
      rethrow;
    }
  }

  /// Stops the agent and closes the connection.
  Future<void> stop() async {
    _running = false;
    await _runtime?.stop();
    _runtime = null;
    await _runtimeStates?.cancel();
    _runtimeStates = null;
    _setState(AgentState.offline);
    if (!_states.isClosed) await _states.close();
  }

  /// Pushes a batch of log [lines] to the Hub (one-way, best-effort).
  void sendLogs(List<String> lines, {String source = 'agent'}) =>
      _runtime?.notify(
        Operations.logs,
        payload: LogBatch(
          nodeId: config.nodeId,
          source: source,
          lines: lines,
        ).toJson(),
      );

  /// Pushes a status snapshot to the Hub outside the heartbeat cadence.
  Future<void> reportStatus() async {
    final runtime = _runtime;
    if (runtime == null) return;
    runtime.notify(
      Operations.status,
      payload: StatusReport(
        nodeId: config.nodeId,
        status: await _status(),
      ).toJson(),
    );
  }

  omnyhub.NodeConfig _buildConfig() => omnyhub.NodeConfig(
    hubUri: config.controlUri,
    nodeId: omnyhub.NodeId(config.nodeId),
    securityContext: config.securityContext,
    onBadCertificate: config.onBadCertificate,
    heartbeatInterval: config.heartbeatInterval,
    reconnect: omnyhub.ReconnectPolicy(
      initial: config.reconnect.initial,
      max: config.reconnect.max,
      factor: config.reconnect.factor,
    ),
    agentVersion: config.agentVersion,
    // The descriptor is rebuilt per attempt so a node that gains a capability
    // (a GPU driver lands, Docker gets installed) advertises it on reconnect.
    descriptorBuilder: () async => (await _buildDescriptor()).toHub(),
    onHandshake: (connection) => runNodeHandshake(
      connection,
      credentials: (challenge) =>
          config.credentials.provide(challenge: challenge),
      agentVersion: config.agentVersion,
    ),
    heartbeatPayload: () async => {'status': (await _status()).toJson()},
    onRequest: _onRequest,
    // A rejected credential is terminal: retrying would hammer the Hub with the
    // same key it just refused.
    isTerminal: (error) =>
        error is AuthException || error is omnyhub.UnauthorizedException,
  );

  AgentState _mapState(omnyhub.NodeState state) => switch (state) {
    omnyhub.NodeState.ready => AgentState.connected,
    omnyhub.NodeState.connecting ||
    omnyhub.NodeState.registering => AgentState.connecting,
    omnyhub.NodeState.backoff => AgentState.reconnecting,
    omnyhub.NodeState.disconnected => AgentState.offline,
    omnyhub.NodeState.stopped =>
      _runtime?.terminalError == null
          ? AgentState.offline
          : AgentState.authenticationFailed,
  };

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

  /// Dispatches an operation the Hub invoked on this node.
  ///
  /// Throwing yields a failed response, so the Hub never waits out its timeout
  /// on an operation this node cannot serve.
  Future<Map<String, dynamic>> _onRequest(
    String action,
    Map<String, dynamic> payload,
  ) async {
    return switch (action) {
      Operations.command => (await _runCommand(
        CommandRequest.fromJson(payload),
      )).toJson(),
      Operations.formula => (await _runFormula(
        FormulaRun.fromJson(payload),
      )).toJson(),
      Operations.preset => (await _applyPreset(
        PresetApply.fromJson(payload),
      )).toJson(),
      Operations.service => (await _controlService(
        ServiceControl.fromJson(payload),
      )).toJson(),
      Operations.control => (await _controlNode(
        NodeControl.fromJson(payload),
      )).toJson(),
      _ => throw ProtocolException('unsupported operation: $action'),
    };
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
}
