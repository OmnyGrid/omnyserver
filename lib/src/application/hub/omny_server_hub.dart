import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../domain/auth/principal.dart';
import '../../domain/entities/audit_entry.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../domain/entities/node_status.dart';
import '../../domain/entities/preset.dart';
import '../../domain/events/omny_event.dart';
import '../../domain/formula/formula_action.dart';
import '../../domain/repository/repositories.dart';
import '../../domain/value_objects/node_id.dart';
import '../../protocol/control_message.dart';
import '../../protocol/omny_connection.dart';
import '../../protocol/omny_frame.dart';
import '../../protocol/protocol_version.dart';
import '../../shared/errors/error_codes.dart';
import '../../shared/errors/omnyserver_exception.dart';
import '../../infrastructure/transport/ws_server_endpoint.dart';
import 'audit_log.dart';
import 'hub_config.dart';
import 'node_registry.dart';

/// The central orchestrator: accepts node and client connections over WSS,
/// authenticates them, maintains a live registry of nodes, aggregates status
/// and events, and dispatches operations (restart, formula, preset, …) to
/// nodes, correlating their results.
///
/// Everything the CLI and HTTP API expose is a method on this class — the wire
/// protocol is an implementation detail of how it reaches the nodes.
class OmnyServerHub {
  /// The hub configuration.
  final HubConfig config;

  /// The live node registry.
  final NodeRegistry registry = NodeRegistry();

  /// The audit log.
  late final AuditLog audit = AuditLog(
    config.auditRepository,
    clock: config.clock,
    ids: config.idGenerator,
  );

  final Map<String, Completer<ControlMessage>> _pending = {};
  final Random _random = Random.secure();
  WsServerEndpoint? _endpoint;
  Timer? _watchdog;

  /// Creates a Hub from [config].
  OmnyServerHub(this.config);

  /// The port the Hub is listening on (valid after [start]).
  int get port => _endpoint?.port ?? config.port;

  /// The event stream (lifecycle + operational events).
  Stream<OmnyEvent> get events => config.eventBus.events;

  void _log(String message) => config.logger?.call(message);

  /// Binds the WSS endpoint and begins accepting connections.
  Future<void> start() async {
    _endpoint = await WsServerEndpoint.bind(
      host: config.host,
      port: config.port,
      securityContext: config.securityContext,
      onConnection: _handleConnection,
    );
    _watchdog = Timer.periodic(
      config.heartbeatTimeout,
      (_) => _sweepStaleNodes(),
    );
    _log('Hub listening on ${config.host}:$port');
  }

  /// Stops the Hub and releases resources.
  Future<void> close() async {
    _watchdog?.cancel();
    await _endpoint?.close(force: true);
    await config.eventBus.close();
  }

  // -------------------------------------------------------------------------
  // Public orchestration API (used by the CLI and HTTP API).
  // -------------------------------------------------------------------------

  /// All known node descriptors.
  List<NodeDescriptor> listNodes() => registry.descriptors();

  /// The descriptor for [id], or `null`.
  NodeDescriptor? getNode(NodeId id) => registry.byId(id)?.descriptor;

  /// The latest live status for [id], or `null`.
  NodeStatus? getStatus(NodeId id) => registry.byId(id)?.lastStatus;

  /// Restarts the node [id] (sends a node-control request and awaits the ack).
  Future<void> restartNode(NodeId id, {String principal = 'system'}) =>
      _nodeControl(id, 'restart', principal: principal);

  /// Shuts down the node [id].
  Future<void> shutdownNode(NodeId id, {String principal = 'system'}) =>
      _nodeControl(id, 'shutdown', principal: principal);

  /// Triggers an update on node [id]. [target] is `agent`, `os` or a package.
  Future<void> updateNode(
    NodeId id,
    String target, {
    String principal = 'system',
  }) async {
    await _nodeControl(
      id,
      'update',
      principal: principal,
      parameters: {'target': target},
    );
    config.eventBus.publish(NodeUpdated(id, target, config.clock.now()));
  }

  /// Runs a formula [action] on node [id], returning the structured result.
  Future<ControlMessage> runFormula(
    NodeId id,
    String formula,
    FormulaAction action, {
    String? version,
    Map<String, String> parameters = const {},
    String principal = 'system',
  }) async {
    final node = _requireOnline(id);
    final requestId = config.idGenerator.next();
    config.eventBus.publish(
      FormulaStarted(id, formula, action.name, config.clock.now()),
    );
    final reply = await _request(
      node.connection!,
      requestId,
      FormulaRun(
        requestId: requestId,
        formula: formula,
        action: action,
        version: version,
        parameters: parameters,
      ),
    );
    final ok = reply is FormulaRunResult ? reply.result.success : false;
    config.eventBus.publish(
      FormulaFinished(id, formula, action.name, ok, config.clock.now()),
    );
    await audit.record(
      principal: principal,
      action: 'formula.run',
      outcome: ok ? AuditOutcome.success : AuditOutcome.failure,
      target: id.value,
      detail: '$formula:${action.name}',
    );
    return reply;
  }

  /// Applies [preset] to node [id], returning the result message.
  Future<ControlMessage> applyPreset(
    NodeId id,
    Preset preset, {
    String principal = 'system',
  }) async {
    final node = _requireOnline(id);
    final requestId = config.idGenerator.next();
    final reply = await _request(
      node.connection!,
      requestId,
      PresetApply(requestId: requestId, preset: preset),
    );
    final ok = reply is PresetApplyResult ? reply.success : false;
    config.eventBus.publish(
      PresetApplied(id, preset.id.value, ok, config.clock.now()),
    );
    await audit.record(
      principal: principal,
      action: 'preset.apply',
      outcome: ok ? AuditOutcome.success : AuditOutcome.failure,
      target: id.value,
      detail: preset.id.value,
    );
    return reply;
  }

  /// Runs a shell [command] on node [id], returning the [CommandResult].
  Future<CommandResult> runCommand(
    NodeId id,
    String command, {
    List<String> args = const [],
  }) async {
    final node = _requireOnline(id);
    final requestId = config.idGenerator.next();
    final reply = await _request(
      node.connection!,
      requestId,
      CommandRequest(requestId: requestId, command: command, args: args),
    );
    if (reply is CommandResult) return reply;
    throw const OperationException('Unexpected reply to command request');
  }

  // -------------------------------------------------------------------------
  // Connection handling.
  // -------------------------------------------------------------------------

  Future<void> _handleConnection(OmnyConnection connection) async {
    try {
      final challenge = _newChallenge();
      final principal = await _authenticate(connection, challenge);
      // Decide role by waiting for the first post-auth message: a node sends
      // NodeRegister; a client issues requests.
      final first = await _nextMessage(connection);
      if (first is NodeRegister) {
        await _serveNode(connection, principal, first);
      } else {
        await _serveClient(connection, principal, first);
      }
    } on _HandshakeError catch (e) {
      _log('handshake rejected: ${e.message}');
      await connection.close();
    } on Object catch (e) {
      _log('connection error: $e');
      await connection.close();
    }
  }

  Uint8List _newChallenge() {
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  Future<Principal> _authenticate(
    OmnyConnection connection,
    Uint8List challenge,
  ) async {
    final hello = await _nextMessage(connection);
    if (hello is! Hello) {
      throw const _HandshakeError('expected hello');
    }
    if (!ProtocolVersion.current.isCompatibleWith(
      ProtocolVersion.parse(hello.protocolVersion),
    )) {
      connection.sendMessage(
        const ProtocolErrorMessage(
          code: 'version_mismatch',
          message: 'incompatible protocol version',
        ),
      );
      throw const _HandshakeError('version mismatch');
    }
    connection.sendMessage(AuthChallenge(base64.encode(challenge)));

    final submit = await _nextMessage(connection);
    if (submit is! AuthSubmit) {
      throw const _HandshakeError('expected auth submit');
    }
    try {
      final principal = await config.authenticator.authenticate(
        submit.credential,
        challenge: challenge,
      );
      connection.sendMessage(
        AuthOk(
          principalId: principal.id.value,
          roles: principal.roles.toList(),
        ),
      );
      return principal;
    } on AuthException catch (e) {
      connection.sendMessage(AuthFail(e.message));
      await audit.record(
        principal: submit.credential.principal,
        action: 'auth',
        outcome: AuditOutcome.failure,
        detail: e.message,
      );
      throw _HandshakeError(e.message);
    }
  }

  Future<void> _serveNode(
    OmnyConnection connection,
    Principal principal,
    NodeRegister register,
  ) async {
    final descriptor = register.descriptor.copyWith(
      online: true,
      registeredAt: config.clock.now(),
    );
    final node = RegisteredNode(
      descriptor: descriptor,
      principal: principal,
      connection: connection,
      lastHeartbeatAt: config.clock.now(),
    );
    registry.upsert(node);
    await config.nodeRepository.save(descriptor);
    connection.sendMessage(NodeRegistered(descriptor.id.value));
    config.eventBus.publish(NodeConnected(descriptor.id, config.clock.now()));
    await audit.record(
      principal: principal.id.value,
      action: 'node.register',
      outcome: AuditOutcome.success,
      target: descriptor.id.value,
    );
    _log('node ${descriptor.id} registered');

    connection.incoming.listen(
      (frame) {
        if (frame is ControlFrame) _onNodeMessage(node, frame.message);
      },
      onDone: () => _onNodeGone(node),
      onError: (Object _) => _onNodeGone(node),
      cancelOnError: false,
    );
  }

  void _onNodeMessage(RegisteredNode node, ControlMessage message) {
    switch (message) {
      case NodeHeartbeat(:final heartbeat):
        node.lastHeartbeatAt = config.clock.now();
        node.lastSequence = heartbeat.sequence;
        if (heartbeat.status != null) {
          node.lastStatus = heartbeat.status;
          unawaited(_recordMetric(node.descriptor.id, heartbeat.status!));
        }
        node.connection?.sendMessage(NodeHeartbeatAck(heartbeat.sequence));
        config.eventBus.publish(
          HeartbeatReceived(
            node.descriptor.id,
            heartbeat.sequence,
            config.clock.now(),
          ),
        );
      case StatusReport(:final status):
        node.lastStatus = status;
        unawaited(_recordMetric(node.descriptor.id, status));
      case CommandResult(:final requestId) ||
          FormulaRunResult(:final requestId) ||
          PresetApplyResult(:final requestId) ||
          ServiceControlResult(:final requestId) ||
          OperationAck(:final requestId):
        _complete(requestId, message);
      default:
        break;
    }
  }

  Future<void> _recordMetric(NodeId id, NodeStatus status) => config
      .metricRepository
      .record(MetricSample(nodeId: id, at: status.capturedAt, status: status));

  void _onNodeGone(RegisteredNode node) {
    final id = node.descriptor.id;
    registry.markOffline(id);
    config.eventBus.publish(NodeDisconnected(id, config.clock.now()));
    unawaited(config.nodeRepository.save(node.descriptor));
    _log('node $id disconnected');
  }

  Future<void> _serveClient(
    OmnyConnection connection,
    Principal principal,
    ControlMessage first,
  ) async {
    void handle(ControlMessage message) {
      if (message is NodeListRequest) {
        connection.sendMessage(
          NodeListResponse(
            requestId: message.requestId,
            nodes: registry.descriptors(),
          ),
        );
      }
    }

    handle(first);
    connection.incoming.listen((frame) {
      if (frame is ControlFrame) handle(frame.message);
    }, cancelOnError: false);
  }

  // -------------------------------------------------------------------------
  // Request/response correlation.
  // -------------------------------------------------------------------------

  Future<ControlMessage> _request(
    OmnyConnection connection,
    String requestId,
    ControlMessage message, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final completer = Completer<ControlMessage>();
    _pending[requestId] = completer;
    connection.sendMessage(message);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(requestId);
        throw const OmnyServerTimeoutException('node did not reply in time');
      },
    );
  }

  void _complete(String requestId, ControlMessage message) {
    final completer = _pending.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(message);
    }
  }

  Future<void> _nodeControl(
    NodeId id,
    String action, {
    required String principal,
    Map<String, String> parameters = const {},
  }) async {
    final node = _requireOnline(id);
    final requestId = config.idGenerator.next();
    final reply = await _request(
      node.connection!,
      requestId,
      NodeControl(requestId: requestId, action: action, parameters: parameters),
    );
    final ok = reply is OperationAck ? reply.success : false;
    await audit.record(
      principal: principal,
      action: 'node.$action',
      outcome: ok ? AuditOutcome.success : AuditOutcome.failure,
      target: id.value,
    );
    if (!ok) {
      final message = reply is OperationAck
          ? reply.message
          : 'node rejected $action';
      throw OperationException('node.$action failed: $message');
    }
  }

  RegisteredNode _requireOnline(NodeId id) {
    final node = registry.byId(id);
    if (node == null) {
      throw NodeUnavailableException(
        ErrorCodes.unknownNode,
        'unknown node $id',
      );
    }
    if (node.connection == null || !node.descriptor.online) {
      throw NodeUnavailableException(
        ErrorCodes.nodeOffline,
        'node $id offline',
      );
    }
    return node;
  }

  void _sweepStaleNodes() {
    final now = config.clock.now();
    for (final node in registry.nodes.toList()) {
      if (!node.descriptor.online) continue;
      if (now.difference(node.lastHeartbeatAt) > config.heartbeatTimeout) {
        _onNodeGone(node);
      }
    }
  }

  /// Reads the next single control message from [connection], failing on close.
  Future<ControlMessage> _nextMessage(OmnyConnection connection) async {
    await for (final frame in connection.incoming) {
      if (frame is ControlFrame) return frame.message;
    }
    throw const _HandshakeError('connection closed during handshake');
  }
}

class _HandshakeError implements Exception {
  final String message;
  const _HandshakeError(this.message);
}
