import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart' as omnyhub;

import '../../domain/auth/credential.dart';
import '../../protocol/control_message.dart';
import '../../protocol/handshake.dart';
import '../../protocol/protocol_version.dart';
import '../../shared/errors/omnyserver_exception.dart';

/// Runs the node side of OmnyServer's in-band authentication exchange — the
/// counterpart of the Hub's `NodeConnectionAuthenticator`.
///
/// Wired into `NodeConfig.onHandshake`, so it runs on the freshly-opened control
/// connection before the node registers: announce, answer the Hub's challenge
/// with a credential (a token, or the nonce signed with the node's Ed25519 key),
/// and wait to be accepted.
///
/// Throws [AuthException] on rejection. The agent treats that as terminal — a
/// revoked key is not fixed by reconnecting, and retrying would only hammer the
/// Hub with the credential it just refused.
Future<void> runNodeHandshake(
  omnyhub.HandshakeConnection connection, {
  required Future<Credential> Function(Uint8List challenge) credentials,
  required String agentVersion,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final channel = HandshakeChannel(connection);

  channel.send(
    Hello(
      role: PeerRole.node,
      protocolVersion: ProtocolVersion.current.label,
      agentVersion: agentVersion,
    ),
  );

  final challenge = await channel.expect<AuthChallenge>(timeout: timeout);
  final credential = await credentials(decodeChallenge(challenge.nonce));
  channel.send(AuthSubmit(credential));

  // `expect` turns an auth.fail into an AuthException for us.
  await channel.expect<AuthOk>(timeout: timeout);
}
