import 'dart:typed_data';

import '../../domain/auth/authenticator.dart';
import '../../domain/auth/credential.dart';
import '../../domain/auth/principal.dart';
import '../../shared/errors/omnyserver_exception.dart';

/// Tries several [Authenticator]s in order, succeeding on the first that
/// authenticates the credential.
///
/// Lets a Hub accept both token and public-key credentials. The credential
/// shape (token vs public key) selects which authenticator can succeed.
class CompositeAuthenticator implements Authenticator {
  final List<Authenticator> _delegates;

  /// Creates a composite over [delegates] (tried in order).
  CompositeAuthenticator(List<Authenticator> delegates)
    : _delegates = List.of(delegates);

  @override
  Future<Principal> authenticate(
    Credential credential, {
    required Uint8List challenge,
  }) async {
    AuthException? last;
    for (final delegate in _delegates) {
      try {
        return await delegate.authenticate(credential, challenge: challenge);
      } on AuthException catch (e) {
        last = e;
      }
    }
    throw last ??
        const AuthException('No authenticator accepted the credential');
  }
}
