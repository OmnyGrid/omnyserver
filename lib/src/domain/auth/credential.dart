import 'package:meta/meta.dart';

/// A credential presented by a connecting party (client or node) during the
/// authentication handshake.
///
/// Two built-in shapes are supported: a bearer [token] and an Ed25519 public
/// key with a [signature] over the server-issued challenge. Authenticators
/// inspect the fields relevant to them.
@immutable
class Credential {
  /// The claimed principal id (account name).
  final String principal;

  /// A bearer token, if token auth is used.
  final String? token;

  /// A base64 Ed25519 public key, if public-key auth is used.
  final String? publicKey;

  /// A base64 signature over the auth challenge, paired with [publicKey].
  final String? signature;

  /// Creates a credential.
  const Credential({
    required this.principal,
    this.token,
    this.publicKey,
    this.signature,
  });

  /// A token credential.
  const Credential.token({required this.principal, required String this.token})
    : publicKey = null,
      signature = null;

  /// JSON form (used inside the auth control message).
  Map<String, dynamic> toJson() => {
    'principal': principal,
    if (token != null) 'token': token,
    if (publicKey != null) 'publicKey': publicKey,
    if (signature != null) 'signature': signature,
  };
}
