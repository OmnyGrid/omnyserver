import 'dart:async';

import 'package:omnyhub/omnyhub.dart' as omnyhub;

import '../../domain/auth/principal.dart';
import '../../domain/entities/audit_entry.dart';
import '../../domain/entities/metric_point.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../infrastructure/auth/grant_authenticator.dart';
import '../../domain/entities/grant.dart';
import '../../domain/entities/log_line.dart';
import '../../domain/formula/standard_formulas.dart';
import '../../domain/entities/formula_spec.dart';
import '../../domain/entities/node_status.dart';
import '../../domain/entities/preset.dart';
import '../../domain/events/omny_event.dart';
import '../../domain/formula/formula_action.dart';
import '../../domain/repository/repositories.dart';
import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/preset_id.dart';
import '../../domain/state/state_reconciler.dart';
import '../../domain/state/desired_state.dart';
import '../../domain/value_objects/principal_id.dart';
import '../../infrastructure/auth/node_connection_authenticator.dart';
import '../../infrastructure/node/node_mapping.dart';
import '../../protocol/operations.dart';
import '../../shared/errors/error_codes.dart';
import '../../shared/errors/omnyserver_exception.dart';
import '../../shared/utils/clock.dart';
import '../../shared/utils/id_generator.dart';
import 'audit_log.dart';
import 'log_buffer.dart';
import 'hub_config.dart';

/// The key OmnyServer's last status snapshot is cached under, in the omnyhub
/// registry's per-node state bag.
const String _statusState = 'status';

/// The central orchestrator: accepts node connections over WSS, authenticates
/// them, maintains a live registry, aggregates status and events, and dispatches
/// operations (restart, formula, preset, …) to nodes, correlating their results.
///
/// Everything the CLI and HTTP API expose is a method on this class — the wire
/// protocol is an implementation detail of how it reaches the nodes. That
/// protocol is omnyhub's: this class hosts an [omnyhub.OmnyHub] with a
/// [omnyhub.NodeGateway], which owns the transport, the registry, the heartbeat
/// watchdog and the request/response correlation. What remains here is what is
/// actually OmnyServer's: identity, auditing, events, persistence and the
/// operation vocabulary.
class OmnyServerHub {
  /// The hub configuration.
  final HubConfig config;

  /// The tail of what nodes have reported.
  ///
  /// Bounded and in memory — see [LogBuffer]. Nodes have been pushing log batches
  /// from the start; until now the Hub decoded them and threw them away.
  late final LogBuffer logs = LogBuffer(
    capacityPerNode: config.logCapacityPerNode,
  );

  /// The audit log.
  late final AuditLog audit = AuditLog(
    config.auditRepository,
    clock: config.clock,
    ids: config.idGenerator,
  );

  late final omnyhub.NodeGateway _gateway = omnyhub.NodeGateway(
    name: 'omnyserver-nodes',
    mount: config.nodeMount,
    clock: _HubClock(config.clock),
    idGenerator: _HubIds(config.idGenerator),
    heartbeatInterval: config.heartbeatInterval,
    heartbeatTimeout: config.heartbeatTimeout,
    // The Hub is the system of record for a known fleet: a node that goes away
    // stays in the registry, marked offline, so its history survives.
    retainNodes: true,
    onRegister: _onRegister,
    onHeartbeat: _onHeartbeat,
    onNotify: _onNotify,
    onDisconnect: (node, _) => _onNodeGone(node),
    onTimeout: _onNodeGone,
  );

  omnyhub.OmnyHub? _server;

  /// Creates a Hub from [config].
  OmnyServerHub(this.config);

  /// The live node registry.
  omnyhub.NodeRegistry get registry => _gateway.registry;

  /// The port the Hub is listening on (valid after [start]).
  int get port => _server?.port ?? config.port;

  /// The event stream (lifecycle + operational events).
  Stream<OmnyEvent> get events => config.eventBus.events;

  void _log(String message) => config.logger?.call(message);

  /// Registers an extra [service] (e.g. the REST API, or an OmnyShell broker) on
  /// the Hub's listener, so it shares the node channel's port and TLS. Must be
  /// called before [start].
  ///
  /// [authenticator] gates the service's HTTP requests.
  /// [connectionAuthenticator] runs an in-band handshake on its WebSocket
  /// upgrades — supply one only if the service's own protocol does not
  /// authenticate itself. OmnyServer's node handshake is confined to the node
  /// channel, so a service registered here is *not* subjected to it.
  void registerService(
    omnyhub.Service service, {
    omnyhub.Authenticator? authenticator,
    omnyhub.ConnectionAuthenticator? connectionAuthenticator,
  }) {
    if (_server != null) {
      throw StateError('cannot add services to a running Hub');
    }
    _extraServices.add(
      _HostedService(service, authenticator, connectionAuthenticator),
    );
  }

  /// Installs extra [middleware] on the Hub's listener. Must be called before
  /// [start].
  void use(omnyhub.Middleware middleware) {
    if (_server != null) {
      throw StateError('cannot add middleware to a running Hub');
    }
    _extraMiddleware.add(middleware);
  }

  /// Installs [middleware] *outside* the Hub's error mapping and authentication
  /// — the outermost layer. Must be called before [start].
  ///
  /// This is where CORS goes. Ordinary middleware runs inside the error mapper,
  /// so it never sees the `401` the authenticator throws or the `404` routing
  /// throws — those become responses above it — and a browser would receive an
  /// unreadable, opaque error instead of the real status. It also never sees a
  /// preflight, which by specification carries no credentials and so is rejected
  /// by the authenticator first.
  void useOuter(omnyhub.Middleware middleware) {
    if (_server != null) {
      throw StateError('cannot add middleware to a running Hub');
    }
    _outerMiddleware.add(middleware);
  }

  final List<_HostedService> _extraServices = [];
  final List<omnyhub.Middleware> _extraMiddleware = [];
  final List<omnyhub.Middleware> _outerMiddleware = [];

  /// Binds the WSS endpoint and begins accepting connections.
  Future<void> start() async {
    final server = omnyhub.OmnyHub(
      transports: [
        omnyhub.HttpTransport.https(
          address: config.host,
          port: config.port,
          tls: _tls(),
        ),
      ],
      middleware: _extraMiddleware,
      outerMiddleware: _outerMiddleware,
      // Drives the certificate re-check when the TLS material comes from a
      // directory: on renewal omnyhub rebinds the listener gap-free, so
      // established connections drain on the old certificate while new ones land
      // on the fresh one. Inert for a static context (not hot-reloadable).
      tlsRenewalInterval: config.tlsReloadInterval,
    );

    // The OmnyServer handshake belongs to the node channel *alone*, so it is
    // attached to that route rather than hub-wide. omnyhub resolves a route's
    // connection authenticator as `route.connectionAuthenticator ?? hubWide` —
    // a route's `null` means **inherit**, not *none*. A hub-wide one would
    // therefore be imposed on every other WebSocket mount too: a co-hosted
    // service speaking its own protocol (an OmnyShell broker, say, which
    // authenticates in band and expects to speak first) would have its frames
    // eaten by a handshake meant for someone else, and every peer rejected.
    await server.registerService(
      _gateway,
      connectionAuthenticator: NodeConnectionAuthenticator(
        authenticator: config.authenticator,
        onRejected: (principal, reason) => audit.record(
          principal: principal,
          action: 'auth',
          outcome: AuditOutcome.failure,
          detail: reason,
        ),
      ),
    );
    for (final service in _extraServices) {
      await server.registerService(
        service.service,
        authenticator: service.authenticator,
        connectionAuthenticator: service.connectionAuthenticator,
      );
    }
    await server.start();
    _server = server;
    _log('Hub listening on ${config.host}:$port');
  }

  /// The TLS source for the listener: a static context, or a hot-reloading
  /// `fullchain.pem`/`privkey.pem` directory that picks up renewals.
  omnyhub.TlsProvider _tls() {
    final dir = config.tlsDirectory;
    if (dir != null && dir.isNotEmpty) {
      return omnyhub.ReloadableFileTls.directory(dir);
    }
    return omnyhub.StaticTls.context(config.securityContext!);
  }

  /// Stops the Hub and releases resources.
  Future<void> close() async {
    await logs.close();
    await _server?.stop();
    _server = null;
    await config.eventBus.close();
  }

  // ---------------------------------------------------------------------------
  // Public orchestration API (used by the CLI and HTTP API).
  // ---------------------------------------------------------------------------

  /// All known node descriptors.
  List<NodeDescriptor> listNodes() =>
      registry.all.map((n) => nodeDescriptorFrom(n.descriptor)).toList();

  /// The descriptor for [id], or `null`.
  NodeDescriptor? getNode(NodeId id) {
    final node = registry.byId(toHubId(id));
    return node == null ? null : nodeDescriptorFrom(node.descriptor);
  }

  /// The latest live status for [id], or `null`.
  NodeStatus? getStatus(NodeId id) =>
      registry.byId(toHubId(id))?.state[_statusState] as NodeStatus?;

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
  Future<FormulaRunResult> runFormula(
    NodeId id,
    String formula,
    FormulaAction action, {
    String? version,
    Map<String, String> parameters = const {},
    String principal = 'system',
  }) async {
    final requestId = config.idGenerator.next();
    config.eventBus.publish(
      FormulaStarted(id, formula, action.name, config.clock.now()),
    );
    final reply = await _call(
      id,
      Operations.formula,
      FormulaRun(
        requestId: requestId,
        formula: formula,
        action: action,
        version: version,
        parameters: parameters,
      ).toJson(),
    );
    final result = FormulaRunResult.fromJson(reply);
    final ok = result.result.success;
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
    return result;
  }

  /// Applies [preset] to node [id], returning the result.
  Future<PresetApplyResult> applyPreset(
    NodeId id,
    Preset preset, {
    String principal = 'system',
  }) async {
    final requestId = config.idGenerator.next();
    final reply = await _call(
      id,
      Operations.preset,
      PresetApply(requestId: requestId, preset: preset).toJson(),
    );
    final result = PresetApplyResult.fromJson(reply);
    config.eventBus.publish(
      PresetApplied(id, preset.id.value, result.success, config.clock.now()),
    );
    await audit.record(
      principal: principal,
      action: 'preset.apply',
      outcome: result.success ? AuditOutcome.success : AuditOutcome.failure,
      target: id.value,
      detail: preset.id.value,
    );
    return result;
  }

  /// Runs a shell [command] on node [id], returning the [CommandResult].
  Future<CommandResult> runCommand(
    NodeId id,
    String command, {
    List<String> args = const [],
  }) async {
    final requestId = config.idGenerator.next();
    final reply = await _call(
      id,
      Operations.command,
      CommandRequest(
        requestId: requestId,
        command: command,
        args: args,
      ).toJson(),
    );
    return CommandResult.fromJson(reply);
  }

  // ---------------------------------------------------------------------------
  // Node RPC.
  // ---------------------------------------------------------------------------

  /// Invokes [action] on node [id] and returns its response payload.
  ///
  /// Translates omnyhub's failures into OmnyServer's, so callers (and the HTTP
  /// API's error mapper) keep seeing one exception hierarchy.
  Future<Map<String, dynamic>> _call(
    NodeId id,
    String action,
    Map<String, dynamic> payload,
  ) async {
    _requireOnline(id);
    final omnyhub.NodeResponse reply;
    try {
      reply = await _gateway.request(
        toHubId(id),
        action,
        payload: payload,
        timeout: config.requestTimeout,
      );
    } on omnyhub.HubTimeoutException {
      throw const OmnyServerTimeoutException('node did not reply in time');
    } on omnyhub.NodeUnavailableException catch (e) {
      throw NodeUnavailableException(ErrorCodes.nodeOffline, e.message);
    }
    if (!reply.ok) {
      throw OperationException(reply.error ?? '$action failed on node $id');
    }
    return reply.payload;
  }

  Future<void> _nodeControl(
    NodeId id,
    String action, {
    required String principal,
    Map<String, String> parameters = const {},
  }) async {
    final requestId = config.idGenerator.next();
    Map<String, dynamic> reply;
    try {
      reply = await _call(
        id,
        Operations.control,
        NodeControl(
          requestId: requestId,
          action: action,
          parameters: parameters,
        ).toJson(),
      );
    } on OperationException {
      await audit.record(
        principal: principal,
        action: 'node.$action',
        outcome: AuditOutcome.failure,
        target: id.value,
      );
      rethrow;
    }

    final ack = OperationAck.fromJson(reply);
    await audit.record(
      principal: principal,
      action: 'node.$action',
      outcome: ack.success ? AuditOutcome.success : AuditOutcome.failure,
      target: id.value,
    );
    if (!ack.success) {
      throw OperationException('node.$action failed: ${ack.message}');
    }
  }

  omnyhub.RegisteredNode _requireOnline(NodeId id) {
    final node = registry.byId(toHubId(id));
    if (node == null) {
      throw NodeUnavailableException(
        ErrorCodes.unknownNode,
        'unknown node $id',
      );
    }
    if (node.descriptor.status != omnyhub.NodeStatus.online) {
      throw NodeUnavailableException(
        ErrorCodes.nodeOffline,
        'node $id offline',
      );
    }
    return node;
  }

  // ---------------------------------------------------------------------------
  // Gateway hooks.
  // ---------------------------------------------------------------------------

  /// Vets a node's registration, then persists and announces it.
  ///
  /// Registration is now *authorized*, not merely authenticated: the [Authorizer]
  /// is consulted with the claimed node id as the target, so a credential that
  /// can open a connection cannot necessarily enrol a node. Previously any
  /// authenticated principal could claim — and so hijack — any node id, because
  /// the configured authorizer was never called.
  ///
  /// The default [RoleBasedAuthorizer] policy grants `node.register` to the
  /// `node` role. Restricting *which* ids a given principal may claim is a policy
  /// decision: the target is passed, so an authorizer can enforce it.
  Future<Map<String, dynamic>> _onRegister(
    omnyhub.NodeDescriptor hubDescriptor,
    Map<String, dynamic> payload,
    omnyhub.Principal? principal,
  ) async {
    if (principal == null) {
      throw const omnyhub.UnauthorizedException('node is not authenticated');
    }

    final NodeDescriptor descriptor;
    try {
      descriptor = nodeDescriptorFrom(hubDescriptor);
    } on ProtocolException catch (e) {
      throw omnyhub.ValidationException(e.message);
    }

    if (!config.authorizer.authorize(
      _principalOf(principal),
      'node.register',
      target: descriptor.id.value,
    )) {
      await audit.record(
        principal: principal.id,
        action: 'node.register',
        outcome: AuditOutcome.failure,
        target: descriptor.id.value,
        detail: 'not permitted to register this node',
      );
      throw omnyhub.ForbiddenException(
        'principal ${principal.id} may not register node ${descriptor.id}',
      );
    }

    final registered = descriptor.copyWith(
      online: true,
      registeredAt: config.clock.now(),
    );
    await config.nodeRepository.save(registered);
    config.eventBus.publish(NodeConnected(registered.id, config.clock.now()));
    await audit.record(
      principal: principal.id,
      action: 'node.register',
      outcome: AuditOutcome.success,
      target: registered.id.value,
    );
    _log('node ${registered.id} registered');
    return const {};
  }

  /// Records the status snapshot a node piggy-backs on each heartbeat.
  void _onHeartbeat(omnyhub.RegisteredNode node, omnyhub.Heartbeat beat) {
    final id = NodeId(node.id.value);
    config.eventBus.publish(
      HeartbeatReceived(id, beat.seq, config.clock.now()),
    );

    final raw = beat.payload['status'];
    if (raw is! Map) return;
    final status = NodeStatus.fromJson(raw.cast<String, dynamic>());
    node.state[_statusState] = status;
    unawaited(_recordMetric(id, status));
  }

  /// Handles the one-way pushes a node makes: status reports and log batches.
  void _onNotify(
    String action,
    Map<String, dynamic> payload,
    omnyhub.RegisteredNode from,
  ) {
    switch (action) {
      case Operations.status:
        final report = StatusReport.fromJson(payload);
        from.state[_statusState] = report.status;
        unawaited(_recordMetric(NodeId(from.id.value), report.status));
      case Operations.logs:
        final batch = LogBatch.fromJson(payload);
        final now = config.clock.now().toUtc();
        logs.record([
          for (final line in batch.lines)
            LogLine(
              nodeId: from.id.value,
              source: batch.source,
              message: line,
              // The Hub's clock, not the node's: a fleet's clocks disagree, and a
              // tail interleaving several nodes is unreadable if each is telling
              // a different time.
              at: now,
            ),
        ]);
      default:
        _log('node ${from.id} sent an unknown notify: $action');
    }
  }

  Future<void> _recordMetric(NodeId id, NodeStatus status) => config
      .metricRepository
      .record(MetricSample(nodeId: id, at: status.capturedAt, status: status));

  // ---------------------------------------------------------------------------
  // The catalogue: what can be asked of a node, and what has been saved to ask.
  // ---------------------------------------------------------------------------

  /// The formulas a node can run.
  ///
  /// The built-ins, plus anything registered in the Hub's [FormulaRepository].
  /// A client that has to be *told* what to type into a free-text box is a client
  /// that gets it wrong; this is what it reads instead.
  Future<List<FormulaSpec>> listFormulas() async {
    final custom = await config.formulaRepository.all();
    final byId = {
      for (final spec in standardFormulaSpecs) spec.id.value: spec,
      // A site's own registration wins over a built-in of the same name.
      for (final spec in custom) spec.id.value: spec,
    };
    return byId.values.toList()
      ..sort((a, b) => a.id.value.compareTo(b.id.value));
  }

  /// Saves a preset on the Hub, so every operator applies the same one.
  Future<void> savePreset(Preset preset, {String principal = 'system'}) async {
    await config.presetRepository.save(preset);
    await audit.record(
      principal: principal,
      action: 'preset.save',
      target: preset.id.value,
      outcome: AuditOutcome.success,
      detail: '${preset.steps.length} steps',
    );
  }

  /// Every saved preset.
  Future<List<Preset>> listPresets() => config.presetRepository.all();

  /// The saved preset with [id], or `null`.
  Future<Preset?> presetFor(PresetId id) => config.presetRepository.find(id);

  /// Deletes a saved preset.
  Future<bool> deletePreset(PresetId id) => config.presetRepository.delete(id);

  // ---------------------------------------------------------------------------
  // Grants: credentials the Hub hands out, and takes back.
  // ---------------------------------------------------------------------------

  /// Issues a credential for [principal] with [roles], and returns the grant
  /// **and its token**.
  ///
  /// This is the only moment the token exists in readable form. The Hub keeps
  /// its SHA-256 and nothing else, so it cannot show it again later, and neither
  /// can anyone who steals the Hub's storage. Lost tokens are replaced, not
  /// recovered — which is why a grant has an id you can revoke it by.
  Future<({Grant grant, String token})> issueGrant({
    required PrincipalId principal,
    required Set<String> roles,
    String note = '',
    String issuedBy = 'system',
  }) async {
    final token = newToken();
    final grant = Grant(
      id: config.idGenerator.next(),
      principal: principal,
      roles: roles,
      tokenHash: hashToken(token),
      createdAt: config.clock.now().toUtc(),
      note: note,
    );
    await config.grantRepository.save(grant);
    await audit.record(
      principal: issuedBy,
      action: 'grant.issue',
      target: principal.value,
      outcome: AuditOutcome.success,
      detail: 'roles: ${(roles.toList()..sort()).join(',')}',
    );
    return (grant: grant, token: token);
  }

  /// Every credential the Hub has issued. Hashes, never tokens.
  Future<List<Grant>> listGrants() => config.grantRepository.all();

  /// Revokes a credential. The next request that presents its token fails.
  Future<bool> revokeGrant(String id, {String revokedBy = 'system'}) async {
    final grant = await config.grantRepository.find(id);
    if (grant == null) return false;
    await config.grantRepository.delete(id);
    await audit.record(
      principal: revokedBy,
      action: 'grant.revoke',
      target: grant.principal.value,
      outcome: AuditOutcome.success,
      detail: 'grant $id',
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // Desired state: what a node is supposed to be, and how far it has drifted.
  // ---------------------------------------------------------------------------

  /// Declares the state [id] should be in.
  ///
  /// Declaring is not applying. Nothing runs on the node here — this records the
  /// intent, so that [drift] can answer "is it still true?" later, and keep
  /// answering it after someone logs into the machine and changes something by
  /// hand. That question is the reason to declare a state at all; re-applying a
  /// preset and watching it succeed only tells you it succeeded.
  Future<void> setDesiredState(
    NodeId id,
    DesiredState state, {
    String principal = 'system',
  }) async {
    await config.desiredStateRepository.save(id, state);
    await audit.record(
      principal: principal,
      action: 'state.declare',
      target: id.value,
      outcome: AuditOutcome.success,
      detail: '${state.steps.length} steps',
    );
  }

  /// The state [id] should be in, or `null` if none was ever declared.
  Future<DesiredState?> desiredStateFor(NodeId id) =>
      config.desiredStateRepository.find(id);

  /// Stops expecting anything of [id].
  Future<bool> clearDesiredState(NodeId id) =>
      config.desiredStateRepository.delete(id);

  /// How far [id] has drifted from what was declared for it.
  ///
  /// The plan is what would have to *run* to make the declaration true again. An
  /// empty plan means the node has not drifted — which is the useful answer, and
  /// the one nothing could ask for before.
  ///
  /// Current state is read from what the node advertises, so this costs nothing
  /// and works on an offline node too (against its last-known capabilities).
  Future<Reconciliation> drift(NodeId id) async {
    final node = getNode(id);
    if (node == null) throw NotFoundException('unknown node ${id.value}');

    final desired = await config.desiredStateRepository.find(id);
    if (desired == null) {
      throw NotFoundException('no desired state declared for ${id.value}');
    }

    return config.reconciler.reconcile(
      desired,
      CurrentState(capabilities: node.capabilities),
    );
  }

  /// Runs whatever [drift] says is outstanding, and returns what happened.
  ///
  /// Idempotent by construction: a converged node has an empty plan, so
  /// reconciling it twice runs nothing the second time. That is what makes this
  /// safe to put on a timer or in a pipeline.
  Future<PresetApplyResult> reconcile(
    NodeId id, {
    String principal = 'system',
  }) async {
    final plan = await drift(id);
    if (plan.converged) {
      return PresetApplyResult(
        requestId: config.idGenerator.next(),
        success: true,
        results: const [],
      );
    }
    // The plan is a list of steps, which is exactly a preset — so it runs through
    // the same path an operator's preset does, and is audited the same way.
    return applyPreset(
      id,
      Preset(
        id: PresetId('reconcile'),
        name: 'reconcile',
        description: 'Converging ${id.value} to its declared state',
        steps: plan.actions,
      ),
      principal: principal,
    );
  }

  /// A node's resource history, newest first — the samples the Hub has been
  /// recording on every heartbeat all along.
  ///
  /// Projected down to [MetricPoint]s: a stored sample is a whole [NodeStatus],
  /// process table included, and a chart wants none of that.
  Future<List<MetricPoint>> metricsFor(
    NodeId id, {
    int limit = 100,
    DateTime? since,
  }) async {
    final samples = await config.metricRepository.recentFor(
      id,
      limit: limit,
      since: since,
    );
    return [for (final s in samples) MetricPoint.fromStatus(s.status)];
  }

  /// A node's connection is gone (dropped or timed out). The registry keeps the
  /// record, marked offline; we persist that and announce it.
  void _onNodeGone(omnyhub.RegisteredNode? node) {
    if (node == null) return;
    final id = NodeId(node.id.value);
    config.eventBus.publish(NodeDisconnected(id, config.clock.now()));
    try {
      final descriptor = nodeDescriptorFrom(node.descriptor);
      unawaited(config.nodeRepository.save(descriptor.copyWith(online: false)));
    } on ProtocolException {
      // Not an OmnyServer node; nothing to persist.
    }
    _log('node $id disconnected');
  }

  Principal _principalOf(omnyhub.Principal principal) =>
      Principal(id: PrincipalId(principal.id), roles: principal.roles);
}

/// A service hosted on the Hub's listener alongside the node channel, with the
/// auth it should (or should not) be subjected to.
class _HostedService {
  final omnyhub.Service service;
  final omnyhub.Authenticator? authenticator;
  final omnyhub.ConnectionAuthenticator? connectionAuthenticator;

  const _HostedService(
    this.service,
    this.authenticator,
    this.connectionAuthenticator,
  );
}

/// Bridges OmnyServer's [IdGenerator] to omnyhub's, so ids the gateway mints
/// (connection ids, RPC correlation ids) come from the Hub's injected generator
/// and stay deterministic under a seeded one in tests.
///
/// The two ports are the same shape but distinct types — OmnyServer's predate
/// the omnyhub dependency and are part of its public API — so they are adapted
/// rather than replaced.
class _HubIds implements omnyhub.IdGenerator {
  final IdGenerator _ids;

  const _HubIds(this._ids);

  @override
  String next([String prefix = '']) {
    final id = _ids.next();
    return prefix.isEmpty ? id : '$prefix-$id';
  }
}

/// Bridges OmnyServer's [Clock] to omnyhub's, so the gateway's liveness timing
/// and the Hub's events read the same (injectable) clock.
class _HubClock implements omnyhub.Clock {
  final Clock _clock;

  const _HubClock(this._clock);

  @override
  DateTime now() => _clock.now();
}
