import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../domain/auth/authenticator.dart';
import '../../domain/auth/credential.dart';
import '../../domain/auth/principal.dart';
import '../../domain/entities/grant.dart';
import '../../domain/repository/repositories.dart';
import '../../shared/errors/omnyserver_exception.dart';

/// Authenticates against the grants the Hub has *issued*, as opposed to the ones
/// baked into its command line.
///
/// The store holds hashes, so this hashes the presented token and looks that up:
/// there is nothing to compare in constant time, because there is no secret on
/// this side to leak. A grant that has been revoked is gone from the store, so
/// the very next request with its token fails — which is the point of being able
/// to revoke one at all.
///
/// Compose it with the flag-based [TokenAuthenticator] (see
/// `CompositeAuthenticator`), so a Hub can be bootstrapped from the command line
/// and then hand out credentials at runtime.
class GrantAuthenticator implements Authenticator {
  /// Where issued grants live.
  final GrantRepository repository;

  /// Creates an authenticator over [repository].
  const GrantAuthenticator(this.repository);

  @override
  Future<Principal> authenticate(
    Credential credential, {
    required Uint8List challenge,
  }) async {
    final token = credential.token;
    if (token == null) {
      throw const AuthException('Missing token for token auth');
    }

    final grant = await repository.findByTokenHash(hashToken(token));
    if (grant == null) {
      throw const AuthException('Invalid token');
    }
    // The same rule the flag-based grants follow: a token proves *an* identity,
    // and the caller has to claim the one it actually proves.
    if (grant.principal.value != credential.principal) {
      throw const AuthException('Token does not match principal');
    }

    return Principal(id: grant.principal, roles: grant.roles);
  }
}

/// The SHA-256 of [token], hex-encoded — what a [Grant] stores in place of it.
String hashToken(String token) {
  final digest = Sha256().toSync().hashSync(utf8.encode(token));
  return [
    for (final byte in digest.bytes) byte.toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Mints a fresh bearer token: 32 bytes from the platform's secure random,
/// base64url-encoded and unpadded.
///
/// Long enough that guessing is not a strategy, and URL-safe so it survives
/// being pasted into a config file, a header or a `--token` flag intact.
String newToken() {
  final random = Random.secure();
  final bytes = Uint8List.fromList([
    for (var i = 0; i < 32; i++) random.nextInt(256),
  ]);
  return base64Url.encode(bytes).replaceAll('=', '');
}
