import 'package:omnyshell/omnyshell_hub.dart' as omnyshell;

import '../../shared/utils/clock.dart';
import '../auth/token_authenticator.dart';

/// Hosts an [OmnyShell](https://pub.dev/packages/omnyshell) broker on the
/// OmnyServer Hub's listener, so one Hub serves both fleets.
///
/// OmnyShell nodes then dial `wss://<hub>:<port><mount>` — the same host, port
/// and certificate the OmnyServer nodes and the REST API already use. An
/// operator installs a shell node exactly as before, only pointing at this Hub:
///
/// ```sh
/// omnyshell node start --hub wss://hub:8443/shell --id worker-01 --token …
/// ```
///
/// The broker authenticates **in band** — it speaks first, with a challenge, and
/// the peer answers — so its route must not carry a
/// `ConnectionAuthenticator`. OmnyServer's own node handshake is confined to the
/// node channel's route for exactly this reason (see `OmnyServerHub.start`).
class ShellHub {
  /// The broker that authenticates, authorizes and relays shell sessions.
  final omnyshell.HubBroker broker;

  /// The path the broker is mounted at.
  final String mount;

  ShellHub._(this.broker, this.mount);

  /// Builds a shell broker sharing the OmnyServer Hub's credentials.
  ///
  /// [grants] is the Hub's own token table — the same `principal:token:roles`
  /// set that authenticates OmnyServer nodes and the REST API — so one
  /// credential works across both fleets and there is no second thing to
  /// provision.
  ///
  /// Authorization stays OmnyShell's: its default `RoleBasedAuthorizer` lets the
  /// `admin` role open a session on any node, and other roles only on nodes
  /// whose `allow-roles` label names them.
  ///
  /// [aiConfig] enables the Hub's AI proxy: when set, the broker answers a web
  /// client's `fetchHubAiConfig` and forwards `:ai` / `:ide` provider calls with
  /// the Hub's key injected — the key never leaves the Hub. Without it, the
  /// broker reports no AI provider and the browser agent falls back to a
  /// user-supplied key. Load one with `AiConfigIo.load(...)`.
  factory ShellHub.fromGrants(
    Map<String, TokenGrant> grants, {
    String mount = '/shell',
    Clock clock = const SystemClock(),
    Duration heartbeatTimeout = const Duration(seconds: 30),
    void Function(String message)? logger,
    omnyshell.Authorizer? authorizer,
    omnyshell.AiConfig? aiConfig,
  }) {
    return ShellHub._(
      omnyshell.HubBroker(
        authenticator: omnyshell.TokenAuthenticator(toShellGrants(grants)),
        authorizer: authorizer ?? const omnyshell.RoleBasedAuthorizer(),
        clock: _ShellClock(clock),
        heartbeatTimeout: heartbeatTimeout,
        logger: logger,
        aiProxy: aiConfig == null
            ? null
            : omnyshell.HttpProxyService(defaultConfig: aiConfig),
      ),
      mount,
    );
  }

  /// The omnyhub service to register on the Hub.
  omnyshell.OmnyShellHubService service() =>
      omnyshell.OmnyShellHubService(broker, mount: mount);
}

/// Translates OmnyServer's token grants into OmnyShell's.
///
/// The two are the same shape but distinct types — each package predates the
/// other's dependency — except that OmnyShell's carries a `displayName`, which
/// it shows to operators. OmnyServer has no such field, so the principal id
/// stands in for it.
Map<String, omnyshell.TokenGrant> toShellGrants(
  Map<String, TokenGrant> grants,
) {
  return {
    for (final entry in grants.entries)
      entry.key: omnyshell.TokenGrant(
        principal: omnyshell.PrincipalId(entry.value.principal.value),
        displayName: entry.value.principal.value,
        roles: entry.value.roles,
      ),
  };
}

/// Bridges OmnyServer's [Clock] to OmnyShell's, so the broker's liveness timing
/// reads the same (injectable) clock as the rest of the Hub.
class _ShellClock implements omnyshell.Clock {
  final Clock _clock;

  const _ShellClock(this._clock);

  @override
  DateTime now() => _clock.now();
}
