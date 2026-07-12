import 'package:omnyhub/omnyhub.dart' as omnyhub;

import '../../domain/auth/authenticator.dart';
import '../../protocol/control_message.dart';
import '../../protocol/handshake.dart';
import '../../protocol/protocol_version.dart';
import '../../shared/errors/error_codes.dart';
import '../../shared/errors/omnyserver_exception.dart';

/// Records a rejected authentication attempt.
typedef AuthAuditSink = Future<void> Function(String principal, String reason);

/// Authenticates a node's control connection with OmnyServer's in-band
/// challenge/response, before omnyhub's node protocol takes over.
///
/// Runs the exchange the Hub has always run — `hello` → `auth.challenge` →
/// `auth.submit` → `auth.ok`/`auth.fail` — but as an omnyhub
/// [omnyhub.ConnectionAuthenticator], so the hub owns the socket, the routing
/// and the close codes. The credential verification itself is untouched:
/// [authenticator] is the same [Authenticator] (token or Ed25519 public key)
/// that the Hub used before.
///
/// Throwing rejects the connection: omnyhub closes it with the WebSocket code
/// echoing the failure, and the node never registers.
class NodeConnectionAuthenticator implements omnyhub.ConnectionAuthenticator {
  /// Verifies the presented credential.
  final Authenticator authenticator;

  /// Mints the per-connection challenge nonce.
  final ChallengeMinter challenges;

  /// Records rejected attempts, if the Hub audits them.
  final AuthAuditSink? onRejected;

  /// How long each handshake step may take.
  final Duration timeout;

  /// Creates a connection authenticator.
  NodeConnectionAuthenticator({
    required this.authenticator,
    ChallengeMinter? challenges,
    this.onRejected,
    this.timeout = const Duration(seconds: 10),
  }) : challenges = challenges ?? ChallengeMinter();

  @override
  Future<omnyhub.Principal?> authenticate(
    omnyhub.HandshakeConnection connection,
    omnyhub.HubRequest request,
  ) async {
    final channel = HandshakeChannel(connection);

    final hello = await channel.expect<Hello>(timeout: timeout);
    if (!ProtocolVersion.current.isCompatibleWith(
      ProtocolVersion.parse(hello.protocolVersion),
    )) {
      // Report before rejecting: a peer that cannot parse our protocol still
      // needs to learn *why* it was turned away.
      channel.send(
        const ProtocolErrorMessage(
          code: ErrorCodes.versionMismatch,
          message: 'incompatible protocol version',
        ),
      );
      throw const omnyhub.UnauthorizedException(
        'incompatible protocol version',
      );
    }

    final challenge = challenges.next();
    channel.send(AuthChallenge(encodeChallenge(challenge)));

    final submit = await channel.expect<AuthSubmit>(timeout: timeout);
    try {
      final principal = await authenticator.authenticate(
        submit.credential,
        challenge: challenge,
      );
      channel.send(
        AuthOk(
          principalId: principal.id.value,
          roles: principal.roles.toList(),
        ),
      );
      // Carry the roles across the boundary so the gateway's registration
      // handler can authorize on them without re-reading the credential.
      return omnyhub.Principal(id: principal.id.value, roles: principal.roles);
    } on AuthException catch (e) {
      channel.send(AuthFail(e.message));
      await onRejected?.call(submit.credential.principal, e.message);
      throw omnyhub.UnauthorizedException(e.message);
    }
  }
}
