/// The wire protocol version negotiated in the [Hello] handshake.
///
/// Bumped when the frame format or message contract changes incompatibly. Peers
/// advertising a different major version are rejected.
class ProtocolVersion {
  /// The major version (incompatible changes).
  final int major;

  /// The minor version (backward-compatible additions).
  final int minor;

  /// Creates a protocol version.
  const ProtocolVersion(this.major, this.minor);

  /// The current protocol version this build speaks.
  static const ProtocolVersion current = ProtocolVersion(1, 0);

  /// Whether [other] is wire-compatible with this version (same major).
  bool isCompatibleWith(ProtocolVersion other) => other.major == major;

  /// The canonical `major.minor` string.
  String get label => '$major.$minor';

  /// Parses a `major.minor` string, defaulting minor to 0.
  static ProtocolVersion parse(String value) {
    final parts = value.split('.');
    final major = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 1;
    final minor = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
    return ProtocolVersion(major, minor);
  }

  @override
  String toString() => label;
}
