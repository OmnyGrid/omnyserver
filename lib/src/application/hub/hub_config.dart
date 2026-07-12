import 'dart:io';

import '../../domain/auth/authenticator.dart';
import '../../domain/events/event_bus.dart';
import '../../domain/repository/repositories.dart';
import '../../infrastructure/auth/role_based_authorizer.dart';
import '../../infrastructure/persistence/memory/memory_repositories.dart';
import '../../shared/utils/clock.dart';
import '../../shared/utils/id_generator.dart';

/// Configuration for an [OmnyServerHub].
///
/// Critical dependencies ([securityContext], [authenticator]) are required;
/// everything else has a sensible default so a Hub can be embedded in a test or
/// example with a couple of lines. Repositories, the event bus and the clock
/// are injected for testability and pluggable persistence.
class HubConfig {
  /// The bind host (string or [InternetAddress]).
  final Object host;

  /// The bind port (use 0 for an ephemeral port).
  final int port;

  /// The TLS context (server certificate chain + private key). Mandatory:
  /// the Hub only speaks `wss`.
  final SecurityContext securityContext;

  /// Verifies credentials and resolves principals.
  final Authenticator authenticator;

  /// Decides whether a principal may perform an action.
  final Authorizer authorizer;

  /// The path the node control channel is mounted at.
  ///
  /// Nodes connect to `wss://<host>:<port><nodeMount>`. The REST API, when
  /// hosted on the same listener, lives under `/api/v1` alongside it.
  final String nodeMount;

  /// The path an OmnyShell broker is mounted at, when the Hub hosts one.
  ///
  /// OmnyShell nodes then connect to `wss://<host>:<port><shellMount>` — the
  /// same port and certificate as everything else. See `ShellHub`.
  final String shellMount;

  /// How often nodes should heartbeat. Advertised to each node at registration.
  final Duration heartbeatInterval;

  /// How long without a heartbeat before a node is considered stale/offline.
  final Duration heartbeatTimeout;

  /// How long to wait for a node to answer a dispatched operation.
  final Duration requestTimeout;

  /// Time source.
  final Clock clock;

  /// Id generator (request ids, nonces, audit ids).
  final IdGenerator idGenerator;

  /// The event bus the Hub publishes lifecycle/operational events on.
  final EventBus eventBus;

  /// Persists node descriptors.
  final NodeRepository nodeRepository;

  /// Persists the audit trail.
  final AuditRepository auditRepository;

  /// Persists historical metric samples.
  final MetricRepository metricRepository;

  /// Optional log sink.
  final void Function(String message)? logger;

  /// Creates a Hub configuration.
  HubConfig({
    required this.securityContext,
    required this.authenticator,
    this.host = '0.0.0.0',
    this.port = 8443,
    Authorizer? authorizer,
    this.nodeMount = '/node',
    this.shellMount = '/shell',
    this.heartbeatInterval = const Duration(seconds: 15),
    this.heartbeatTimeout = const Duration(seconds: 45),
    this.requestTimeout = const Duration(seconds: 30),
    this.clock = const SystemClock(),
    this.idGenerator = const UuidGenerator(),
    EventBus? eventBus,
    NodeRepository? nodeRepository,
    AuditRepository? auditRepository,
    MetricRepository? metricRepository,
    this.logger,
  }) : authorizer = authorizer ?? const RoleBasedAuthorizer(),
       eventBus = eventBus ?? BroadcastEventBus(),
       nodeRepository = nodeRepository ?? MemoryNodeRepository(),
       auditRepository = auditRepository ?? MemoryAuditRepository(),
       metricRepository = metricRepository ?? MemoryMetricRepository();
}
