import 'dart:io';

import '../../domain/entities/node_capabilities.dart';
import '../../domain/entities/node_status.dart';
import '../../domain/formula/formula_result.dart';
import '../../infrastructure/auth/credential_provider.dart';
import '../../protocol/operations.dart';
import '../../shared/utils/clock.dart';
import '../../version.dart';
import 'agent_state.dart';

/// Provides the node's current live status snapshot (CPU/mem/storage/…).
typedef StatusProvider = Future<NodeStatus> Function();

/// Provides the node's currently-detected capabilities.
typedef CapabilityProvider = Future<NodeCapabilities> Function();

/// Handles a Hub formula-run request on the node.
typedef FormulaHandler = Future<FormulaResult> Function(FormulaRun request);

/// Handles a Hub preset-apply request on the node.
typedef PresetHandler = Future<PresetApplyResult> Function(PresetApply request);

/// Handles a Hub service-control request on the node.
typedef ServiceHandler =
    Future<ServiceControlResult> Function(ServiceControl request);

/// Handles a Hub node-control request (restart/shutdown/update) on the node.
/// Returns `(success, message)`.
typedef NodeControlHandler =
    Future<(bool, String)> Function(NodeControl request);

/// Configuration for a [NodeAgent].
class NodeAgentConfig {
  /// The Hub `wss://` URL to dial (e.g. `wss://hub.example.com:8443`).
  final Uri hubUri;

  /// The path the Hub mounts its node control channel at.
  ///
  /// Must match the Hub's `HubConfig.nodeMount`. The Hub serves the REST API and
  /// the node channel on one listener, so the node has to say which it wants.
  final String nodeMount;

  /// The operator-chosen node id.
  final String nodeId;

  /// A human-friendly display name.
  final String displayName;

  /// Operator-supplied labels.
  final Map<String, String> labels;

  /// Produces the credential answering the Hub's auth challenge.
  final CredentialProvider credentials;

  /// TLS trust context (e.g. trusting the Hub's CA).
  final SecurityContext? securityContext;

  /// Escape hatch for certificate pinning / self-signed dev certs.
  final bool Function(X509Certificate cert, String host, int port)?
  onBadCertificate;

  /// How often to send heartbeats, if the Hub does not say.
  ///
  /// The Hub advertises the cadence it wants at registration and that wins — a
  /// fleet's liveness budget is the Hub's to set, not each node's. This is the
  /// fallback for a Hub that advertises none.
  final Duration heartbeatInterval;

  /// The reconnection backoff policy.
  final ReconnectPolicy reconnect;

  /// Time source.
  final Clock clock;

  /// The agent version reported in the descriptor.
  final String agentVersion;

  /// Supplies the live status snapshot for heartbeats/reports.
  final StatusProvider? statusProvider;

  /// Supplies detected capabilities at registration.
  final CapabilityProvider? capabilityProvider;

  /// Handles formula-run requests (null ⇒ unsupported).
  final FormulaHandler? formulaHandler;

  /// Handles preset-apply requests (null ⇒ unsupported).
  final PresetHandler? presetHandler;

  /// Handles service-control requests (null ⇒ unsupported).
  final ServiceHandler? serviceHandler;

  /// Handles node-control requests (null ⇒ ack success without acting).
  final NodeControlHandler? nodeControlHandler;

  /// Optional log sink.
  final void Function(String message)? logger;

  /// Creates a node-agent configuration.
  NodeAgentConfig({
    required this.hubUri,
    required this.nodeId,
    required this.credentials,
    this.nodeMount = '/node',
    this.displayName = '',
    this.labels = const {},
    this.securityContext,
    this.onBadCertificate,
    this.heartbeatInterval = const Duration(seconds: 15),
    this.reconnect = const ReconnectPolicy(),
    this.clock = const SystemClock(),
    this.agentVersion = omnyServerVersion,
    this.statusProvider,
    this.capabilityProvider,
    this.formulaHandler,
    this.presetHandler,
    this.serviceHandler,
    this.nodeControlHandler,
    this.logger,
  });

  /// The control-channel URL the agent actually dials: [hubUri] with
  /// [nodeMount] as its path.
  ///
  /// An operator configures the Hub (`wss://hub:8443`), not the mount, so the
  /// path is filled in here. A [hubUri] that already carries one is respected —
  /// that is how a node reaches a Hub mounted somewhere non-default, or one
  /// behind a reverse proxy that rewrites the path.
  Uri get controlUri {
    final path = hubUri.path;
    if (path.isEmpty || path == '/') return hubUri.replace(path: nodeMount);
    return hubUri;
  }
}
