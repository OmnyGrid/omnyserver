import '../../shared/errors/omnyserver_exception.dart';

/// Identity of a formula (an operational procedure such as `docker` or `dart`).
///
/// A formula id is a non-empty lower-case token (letters, digits, `_`, `-`,
/// `.`). Equality is by [value].
class FormulaId {
  /// The raw formula identifier.
  final String value;

  /// Creates and validates a formula id.
  factory FormulaId(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) {
      throw const ProtocolException('Formula id cannot be empty');
    }
    if (!_valid.hasMatch(trimmed)) {
      throw ProtocolException('Invalid formula id: "$value"');
    }
    return FormulaId._(trimmed);
  }

  const FormulaId._(this.value);

  static final RegExp _valid = RegExp(r'^[a-z0-9_.-]+$');

  @override
  bool operator ==(Object other) => other is FormulaId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
