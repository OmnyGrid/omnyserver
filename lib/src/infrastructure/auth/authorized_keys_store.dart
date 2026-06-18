import '../../domain/value_objects/ed25519_public_key.dart';

/// An authorized public key entry: which principal it grants and the roles.
class AuthorizedKey {
  /// The principal this key authenticates.
  final String principal;

  /// The authorized public key.
  final Ed25519PublicKey key;

  /// Roles granted on successful authentication.
  final Set<String> roles;

  /// Creates an authorized key entry.
  const AuthorizedKey({
    required this.principal,
    required this.key,
    this.roles = const {},
  });
}

/// An in-memory trust store of authorized public keys, keyed by
/// `(principal, key)`.
class AuthorizedKeysStore {
  final List<AuthorizedKey> _entries;

  /// Creates a store from [entries].
  AuthorizedKeysStore([List<AuthorizedKey> entries = const []])
    : _entries = List.of(entries);

  /// Adds an [entry] to the store.
  void add(AuthorizedKey entry) => _entries.add(entry);

  /// Finds the entry matching [principal] and [key], or `null`.
  AuthorizedKey? find(String principal, Ed25519PublicKey key) {
    for (final e in _entries) {
      if (e.principal == principal && e.key == key) return e;
    }
    return null;
  }
}
