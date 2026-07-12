import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart' show HandshakeConnection;

import '../shared/errors/omnyserver_exception.dart';
import 'control_message.dart';
import 'control_message_codec.dart';

/// A [ControlMessage]-typed view over omnyhub's [HandshakeConnection].
///
/// The handshake runs on the raw connection before the node control protocol
/// starts, so it cannot use a `TypedConnection` (that would consume the single
/// subscription omnyhub needs afterwards). [HandshakeConnection] solves exactly
/// this: it buffers what the handshake does not read and replays it, so both
/// sides can pull messages here and hand the connection on intact.
class HandshakeChannel {
  /// The underlying connection.
  final HandshakeConnection connection;

  /// The codec applied at the boundary.
  final ControlMessageCodec codec;

  /// Wraps [connection].
  const HandshakeChannel(
    this.connection, {
    this.codec = ControlMessageCodec.instance,
  });

  /// Sends [message].
  void send(ControlMessage message) => connection.send(codec.toWire(message));

  /// Reads the next message, failing if none arrives within [timeout].
  ///
  /// Throws [TransportException] if the peer closes mid-handshake, and
  /// [ProtocolException] if what arrives is not a decodable control message.
  Future<ControlMessage> receive({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      return codec.fromWire(await connection.receive(timeout: timeout));
    } on OmnyServerException {
      rethrow;
    } on Object catch (e) {
      throw TransportException('connection closed during handshake: $e');
    }
  }

  /// Reads the next message, requiring it to be a [T].
  Future<T> expect<T extends ControlMessage>({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final message = await receive(timeout: timeout);
    if (message is T) return message;
    if (message is AuthFail) throw AuthException(message.reason);
    if (message is ProtocolErrorMessage) {
      throw ProtocolException(message.message, code: message.code);
    }
    throw ProtocolException('expected $T, got ${message.type}');
  }
}

/// Mints the single-use nonces the Hub challenges peers with.
class ChallengeMinter {
  final Random _random;

  /// Creates a minter. Pass a seeded [random] for deterministic tests; the
  /// default is [Random.secure].
  ChallengeMinter([Random? random]) : _random = random ?? Random.secure();

  /// A fresh 32-byte challenge.
  Uint8List next() {
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }
}

/// Encodes [challenge] for the wire.
String encodeChallenge(Uint8List challenge) => base64.encode(challenge);

/// Decodes a wire nonce back to its raw bytes.
Uint8List decodeChallenge(String nonce) =>
    Uint8List.fromList(base64.decode(nonce));
