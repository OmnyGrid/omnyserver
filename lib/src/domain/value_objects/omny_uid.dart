import '../../shared/errors/omnyserver_exception.dart';

/// A globally-unique, content-derived identity for a node or hub.
///
/// Unlike a [NodeId] (which is an operator-chosen label), an [OmnyUid] is
/// computed deterministically from the entity's public key (see
/// `UidComputer`), so it is stable across restarts and cannot be spoofed by
/// merely claiming a different label. Equality is by [value].
class OmnyUid {
  /// The canonical uid string (lower-case hex digest).
  final String value;

  /// Creates and validates a uid.
  factory OmnyUid(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) {
      throw const ProtocolException('Uid cannot be empty');
    }
    if (!_valid.hasMatch(trimmed)) {
      throw ProtocolException('Invalid uid: "$value"');
    }
    return OmnyUid._(trimmed);
  }

  const OmnyUid._(this.value);

  static final RegExp _valid = RegExp(r'^[a-f0-9]{8,}$');

  @override
  bool operator ==(Object other) => other is OmnyUid && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
