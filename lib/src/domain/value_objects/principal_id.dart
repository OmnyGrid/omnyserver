import '../../shared/errors/omnyserver_exception.dart';

/// Identity of an authenticated principal (a user account or a node account).
///
/// Equality is by [value]; the value is a non-empty trimmed token.
class PrincipalId {
  /// The raw principal identifier.
  final String value;

  /// Creates and validates a principal id.
  factory PrincipalId(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const ProtocolException('Principal id cannot be empty');
    }
    return PrincipalId._(trimmed);
  }

  const PrincipalId._(this.value);

  @override
  bool operator ==(Object other) =>
      other is PrincipalId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
