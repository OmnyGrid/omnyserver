import 'dart:io';

import '../../domain/auth/authenticator.dart';
import '../../domain/events/event_bus.dart';
import '../../domain/repository/repositories.dart';
import '../../domain/state/state_reconciler.dart';
import '../../infrastructure/state/default_reconciler.dart';
import '../../infrastructure/auth/role_based_authorizer.dart';
import '../../infrastructure/persistence/memory/memory_repositories.dart';
import '../../shared/utils/clock.dart';
import '../../shared/utils/id_generator.dart';

/// Configuration for an [OmnyServerHub].
///
/// Critical dependencies (TLS material, [authenticator]) are required;
/// everything else has a sensible default so a Hub can be embedded in a test or
/// example with a couple of lines. Repositories, the event bus and the clock
/// are injected for testability and pluggable persistence.
class HubConfig {
  /// The bind host (string or [InternetAddress]).
  final Object host;

  /// The bind port (use 0 for an ephemeral port).
  final int port;

  /// The TLS context (server certificate chain + private key). Exactly one of
  /// [securityContext] or [tlsDirectory] must be set: the Hub only speaks
  /// `wss`, so there is no insecure mode.
  final SecurityContext? securityContext;

  /// A directory holding `fullchain.pem` + `privkey.pem` (the LetsEncrypt
  /// layout), as an alternative to a static [securityContext].
  ///
  /// The Hub loads the certificate at [OmnyServerHub.start] and re-checks the
  /// files every [tlsReloadInterval]; when they change (a renewal) it rebinds
  /// the listener with the fresh certificate, so a renewed certificate is served
  /// without a restart.
  final String? tlsDirectory;

  /// How often the Hub re-checks [tlsDirectory] for a renewed certificate. Kept
  /// below a day so a renewal is always picked up within 24h.
  final Duration tlsReloadInterval;

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

  /// Browser origins allowed to call the HTTP API (e.g.
  /// `https://dashboard.example.com`), or empty for none.
  ///
  /// A browser refuses to hand a page the response to a cross-origin request
  /// unless the server says that origin may have it — and a web dashboard is
  /// *always* a different origin from the Hub, even in development (`webdev` on
  /// `:8080`, Hub on `:8443`). So without this, the dashboard sees only network
  /// errors. Empty by default: a Hub with no browser client stays exactly as it
  /// was, and no origin is trusted by accident.
  final List<String> corsOrigins;

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

  /// Persists formulas a site has registered beyond the built-ins.
  ///
  /// Read by the catalogue the Hub serves, so a client can be *told* what a node
  /// can do rather than made to guess it into a free-text box.
  final FormulaRepository formulaRepository;

  /// Persists the presets an operator has saved on the Hub.
  ///
  /// A preset is a reusable declaration ("this is what a docker host is"), so
  /// keeping it on the Hub means every operator and every script applies the
  /// *same* one, rather than each shipping their own copy of a JSON file that
  /// has quietly diverged.
  final PresetRepository presetRepository;

  /// Persists the credentials the Hub has issued at runtime.
  ///
  /// Separate from [authenticator], which is how a credential is *checked*: this
  /// is where one comes from. A Hub that only ever uses `--grant` flags never
  /// touches it.
  final GrantRepository grantRepository;

  /// Persists the state each node is *supposed* to be in.
  ///
  /// The other repositories record what happened; this one records what is meant
  /// to be true, and the difference between the two is drift.
  final DesiredStateRepository desiredStateRepository;

  /// Plans how to move a node from what it is to what it should be.
  final StateReconciler reconciler;

  /// How many log lines the Hub retains per node.
  ///
  /// A tail for looking at a misbehaving node, not a log server: see `LogBuffer`
  /// for why this is bounded and in memory.
  final int logCapacityPerNode;

  /// Optional log sink.
  final void Function(String message)? logger;

  /// Creates a Hub configuration.
  ///
  /// Provide exactly one TLS source: a static [securityContext], or a
  /// [tlsDirectory] the Hub reloads on renewal.
  HubConfig({
    required this.authenticator,
    this.securityContext,
    this.tlsDirectory,
    this.tlsReloadInterval = const Duration(hours: 12),
    this.host = '0.0.0.0',
    this.port = 8443,
    Authorizer? authorizer,
    this.nodeMount = '/node',
    this.shellMount = '/shell',
    this.corsOrigins = const [],
    this.heartbeatInterval = const Duration(seconds: 15),
    this.heartbeatTimeout = const Duration(seconds: 45),
    this.requestTimeout = const Duration(seconds: 30),
    this.clock = const SystemClock(),
    this.idGenerator = const UuidGenerator(),
    EventBus? eventBus,
    NodeRepository? nodeRepository,
    AuditRepository? auditRepository,
    MetricRepository? metricRepository,
    FormulaRepository? formulaRepository,
    PresetRepository? presetRepository,
    GrantRepository? grantRepository,
    DesiredStateRepository? desiredStateRepository,
    StateReconciler? reconciler,
    this.logCapacityPerNode = 500,
    this.logger,
  }) : assert(
         (securityContext == null) != (tlsDirectory == null),
         'provide exactly one of securityContext or tlsDirectory',
       ),
       authorizer = authorizer ?? const RoleBasedAuthorizer(),
       eventBus = eventBus ?? BroadcastEventBus(),
       nodeRepository = nodeRepository ?? MemoryNodeRepository(),
       auditRepository = auditRepository ?? MemoryAuditRepository(),
       metricRepository = metricRepository ?? MemoryMetricRepository(),
       formulaRepository = formulaRepository ?? MemoryFormulaRepository(),
       presetRepository = presetRepository ?? MemoryPresetRepository(),
       grantRepository = grantRepository ?? MemoryGrantRepository(),
       desiredStateRepository =
           desiredStateRepository ?? MemoryDesiredStateRepository(),
       reconciler = reconciler ?? const DefaultStateReconciler();
}
