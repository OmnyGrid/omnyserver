import 'dart:typed_data';

import 'credential.dart';
import 'principal.dart';

/// Verifies a [Credential] and resolves the authenticated [Principal].
///
/// Implementations throw `AuthException` on failure. The [challenge] is the
/// server-issued nonce the client must sign for public-key auth (ignored by
/// token authenticators).
abstract class Authenticator {
  /// Authenticates [credential], returning the resolved principal.
  Future<Principal> authenticate(
    Credential credential, {
    required Uint8List challenge,
  });
}

/// Decides whether an authenticated [Principal] may perform an action.
///
/// The action is identified by a stable string (e.g. `node.restart`,
/// `preset.apply`) plus an optional target. This is the designed seam for
/// future fine-grained RBAC.
abstract class Authorizer {
  /// Returns true if [principal] may perform [action] on [target].
  bool authorize(Principal principal, String action, {String? target});
}
