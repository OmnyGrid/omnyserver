import '../domain/auth/credential.dart';
import '../shared/json/json_codec_helpers.dart';

/// Base type for the JSON messages exchanged during the OmnyServer **handshake**
/// — the challenge/response that runs on a freshly-opened control connection,
/// before the omnyhub node protocol takes over.
///
/// This is deliberately small. Registration, heartbeats, discovery and RPC are
/// omnyhub's (`NodeRegister`, `Heartbeat`, `NodeQuery`, `NodeRequest`, …); what
/// remains here is the part omnyhub has no opinion about: proving who the peer
/// is. Operations ride in `NodeRequest`/`NodeResponse` payloads and are declared
/// in `operations.dart`.
///
/// Each message is a `final class` with a stable [type] discriminator and a
/// symmetric `toJson`/`fromJson`. The hierarchy is `sealed` so the codec and the
/// handshake can switch exhaustively.
sealed class ControlMessage {
  /// Creates a control message.
  const ControlMessage();

  /// The stable type discriminator (e.g. `auth.challenge`).
  String get type;

  /// The message payload (excluding `type`, which the codec adds).
  Map<String, dynamic> toJson();
}

/// The role a connecting party announces in its [Hello].
enum PeerRole {
  /// A node agent connecting to the Hub.
  node,

  /// An operator client / API consumer.
  client;

  /// Parses a wire name, defaulting to [client].
  static PeerRole parse(String value) =>
      PeerRole.values.firstWhere((r) => r.name == value, orElse: () => client);
}

/// First message a peer sends after connecting: announces role and protocol.
final class Hello extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'hello';

  /// The peer's role.
  final PeerRole role;

  /// The protocol version the peer speaks (`major.minor`).
  final String protocolVersion;

  /// The peer's software version.
  final String agentVersion;

  /// The peer's content-derived uid, if it has one.
  final String? uid;

  /// Creates a hello.
  const Hello({
    required this.role,
    required this.protocolVersion,
    required this.agentVersion,
    this.uid,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'role': role.name,
    'protocolVersion': protocolVersion,
    'agentVersion': agentVersion,
    if (uid != null) 'uid': uid,
  };

  /// Decodes from JSON.
  static Hello fromJson(Map<String, dynamic> d) => Hello(
    role: PeerRole.parse(Json.requireString(d, 'role')),
    protocolVersion: Json.optString(d, 'protocolVersion') ?? '1.0',
    agentVersion: Json.optString(d, 'agentVersion') ?? '',
    uid: Json.optString(d, 'uid'),
  );
}

/// Hub → peer: a nonce the peer must sign (public-key auth) and echo.
final class AuthChallenge extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'auth.challenge';

  /// A base64 random nonce.
  final String nonce;

  /// Creates an auth challenge.
  const AuthChallenge(this.nonce);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'nonce': nonce};

  /// Decodes from JSON.
  static AuthChallenge fromJson(Map<String, dynamic> d) =>
      AuthChallenge(Json.requireString(d, 'nonce'));
}

/// Peer → Hub: the credential answering an [AuthChallenge].
final class AuthSubmit extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'auth.submit';

  /// The presented credential.
  final Credential credential;

  /// Creates an auth submit.
  const AuthSubmit(this.credential);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => credential.toJson();

  /// Decodes from JSON.
  static AuthSubmit fromJson(Map<String, dynamic> d) => AuthSubmit(
    Credential(
      principal: Json.requireString(d, 'principal'),
      token: Json.optString(d, 'token'),
      publicKey: Json.optString(d, 'publicKey'),
      signature: Json.optString(d, 'signature'),
    ),
  );
}

/// Hub → peer: authentication succeeded.
final class AuthOk extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'auth.ok';

  /// The resolved principal id.
  final String principalId;

  /// The roles granted.
  final List<String> roles;

  /// Creates an auth-ok.
  const AuthOk({required this.principalId, this.roles = const []});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'principalId': principalId,
    if (roles.isNotEmpty) 'roles': roles,
  };

  /// Decodes from JSON.
  static AuthOk fromJson(Map<String, dynamic> d) => AuthOk(
    principalId: Json.requireString(d, 'principalId'),
    roles: Json.optStringList(d, 'roles'),
  );
}

/// Hub → peer: authentication failed.
final class AuthFail extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'auth.fail';

  /// A human-readable reason.
  final String reason;

  /// Creates an auth-fail.
  const AuthFail(this.reason);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'reason': reason};

  /// Decodes from JSON.
  static AuthFail fromJson(Map<String, dynamic> d) =>
      AuthFail(Json.optString(d, 'reason') ?? 'authentication failed');
}

/// Either side: a protocol-level error raised during the handshake.
///
/// Once the handshake completes, protocol errors are omnyhub's
/// `NodeErrorMessage`; this covers the window before that (e.g. a version
/// mismatch, which the Hub reports before it will authenticate at all).
final class ProtocolErrorMessage extends ControlMessage {
  /// The discriminator.
  static const String typeName = 'error';

  /// A stable error code.
  final String code;

  /// A human-readable message.
  final String message;

  /// Creates a protocol error message.
  const ProtocolErrorMessage({required this.code, required this.message});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'code': code, 'message': message};

  /// Decodes from JSON.
  static ProtocolErrorMessage fromJson(Map<String, dynamic> d) =>
      ProtocolErrorMessage(
        code: Json.optString(d, 'code') ?? 'protocol_error',
        message: Json.optString(d, 'message') ?? '',
      );
}
