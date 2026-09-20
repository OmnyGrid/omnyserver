import '../../shared/errors/omnyserver_exception.dart';

/// Identity of a blueprint (the declaration of what a server should be).
///
/// A blueprint id is a non-empty lower-case token (letters, digits, `_`, `-`,
/// `.`). Equality is by [value].
///
/// Deliberately the same shape as a preset id: both are used directly as file
/// names by the JSON-directory repositories, and the validation here is what
/// makes that safe.
class BlueprintId {
  /// The raw blueprint identifier.
  final String value;

  /// Creates and validates a blueprint id.
  factory BlueprintId(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) {
      throw const ProtocolException('Blueprint id cannot be empty');
    }
    if (!_valid.hasMatch(trimmed)) {
      throw ProtocolException('Invalid blueprint id: "$value"');
    }
    return BlueprintId._(trimmed);
  }

  const BlueprintId._(this.value);

  static final RegExp _valid = RegExp(r'^[a-z0-9_.-]+$');

  @override
  bool operator ==(Object other) =>
      other is BlueprintId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
