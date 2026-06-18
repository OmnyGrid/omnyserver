import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../domain/auth/credential.dart';

/// Produces the [Credential] a connecting agent/client presents in answer to a
/// Hub-issued auth challenge.
///
/// Token providers ignore the challenge; public-key providers sign it so a
/// captured credential cannot be replayed onto a new connection.
abstract class CredentialProvider {
  /// The principal this provider authenticates as.
  String get principal;

  /// Builds a credential answering [challenge].
  Future<Credential> provide({required Uint8List challenge});
}

/// A [CredentialProvider] that presents a static bearer token.
class TokenCredentialProvider implements CredentialProvider {
  @override
  final String principal;

  /// The bearer token.
  final String token;

  /// Creates a token credential provider.
  const TokenCredentialProvider({required this.principal, required this.token});

  @override
  Future<Credential> provide({required Uint8List challenge}) async =>
      Credential.token(principal: principal, token: token);
}

/// A [CredentialProvider] that signs the challenge with an Ed25519 key pair.
class PublicKeyCredentialProvider implements CredentialProvider {
  @override
  final String principal;

  /// The Ed25519 key pair used to sign challenges.
  final SimpleKeyPair keyPair;

  /// Wraps an existing [keyPair].
  const PublicKeyCredentialProvider({
    required this.principal,
    required this.keyPair,
  });

  /// Creates a provider from a 32-byte Ed25519 [seed].
  static Future<PublicKeyCredentialProvider> fromSeed({
    required String principal,
    required List<int> seed,
  }) async {
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    return PublicKeyCredentialProvider(principal: principal, keyPair: keyPair);
  }

  @override
  Future<Credential> provide({required Uint8List challenge}) async {
    final algorithm = Ed25519();
    final pub = await keyPair.extractPublicKey();
    final sig = await algorithm.sign(challenge, keyPair: keyPair);
    return Credential(
      principal: principal,
      publicKey: base64.encode(pub.bytes),
      signature: base64.encode(sig.bytes),
    );
  }
}
