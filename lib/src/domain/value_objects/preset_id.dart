import '../../shared/errors/omnyserver_exception.dart';

/// Identity of a preset (a named desired-configuration bundle of formulas).
///
/// A preset id is a non-empty lower-case token (letters, digits, `_`, `-`,
/// `.`). Equality is by [value].
class PresetId {
  /// The raw preset identifier.
  final String value;

  /// Creates and validates a preset id.
  factory PresetId(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) {
      throw const ProtocolException('Preset id cannot be empty');
    }
    if (!_valid.hasMatch(trimmed)) {
      throw ProtocolException('Invalid preset id: "$value"');
    }
    return PresetId._(trimmed);
  }

  const PresetId._(this.value);

  static final RegExp _valid = RegExp(r'^[a-z0-9_.-]+$');

  @override
  bool operator ==(Object other) => other is PresetId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
