import 'dart:convert' as convert;
import 'dart:typed_data';

import '../../shared/errors/omnyserver_exception.dart';

/// An Ed25519 public key, used to identify users and nodes in an
/// `authorized_keys`-style trust store. Equality is by key bytes.
class Ed25519PublicKey {
  /// The raw 32-byte public key.
  final Uint8List bytes;

  /// The canonical (unpadded, standard alphabet) base64 encoding.
  final String base64;

  Ed25519PublicKey._(this.bytes, this.base64);

  /// Parses a base64-encoded (standard or url-safe) 32-byte key.
  factory Ed25519PublicKey.fromBase64(String encoded) {
    final normalized = encoded.trim();
    final Uint8List raw;
    try {
      raw = convert.base64.decode(
        convert.base64.normalize(_toStandard(normalized)),
      );
    } on FormatException {
      throw ProtocolException('Invalid base64 public key: "$encoded"');
    }
    return Ed25519PublicKey.fromBytes(raw);
  }

  /// Wraps raw key [bytes], validating the 32-byte length.
  factory Ed25519PublicKey.fromBytes(List<int> bytes) {
    if (bytes.length != 32) {
      throw ProtocolException(
        'Ed25519 public key must be 32 bytes, got ${bytes.length}',
      );
    }
    final copy = Uint8List.fromList(bytes);
    return Ed25519PublicKey._(
      copy,
      convert.base64.encode(copy).replaceAll('=', ''),
    );
  }

  static String _toStandard(String input) =>
      input.replaceAll('-', '+').replaceAll('_', '/');

  @override
  bool operator ==(Object other) =>
      other is Ed25519PublicKey && other.base64 == base64;

  @override
  int get hashCode => base64.hashCode;

  @override
  String toString() => 'Ed25519PublicKey($base64)';
}
