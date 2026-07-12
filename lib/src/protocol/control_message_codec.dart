import 'dart:convert';

import 'package:omnyhub/omnyhub.dart' show Message, TextMessage;

import '../shared/errors/omnyserver_exception.dart';
import '../shared/json/json_codec_helpers.dart';
import 'control_message.dart';

/// Encodes handshake [ControlMessage]s to and from the JSON envelope
/// `{"type": <type>, ...fields}`, carried as WebSocket text frames.
///
/// Centralizes the `type` → `fromJson` dispatch so adding a handshake message
/// means registering it in one place. Only the handshake rides this codec —
/// everything after it is omnyhub's node protocol on its own codec.
class ControlMessageCodec {
  const ControlMessageCodec._();

  /// The shared codec instance.
  static const ControlMessageCodec instance = ControlMessageCodec._();

  static final Map<String, ControlMessage Function(Map<String, dynamic>)>
  _decoders = {
    Hello.typeName: Hello.fromJson,
    AuthChallenge.typeName: AuthChallenge.fromJson,
    AuthSubmit.typeName: AuthSubmit.fromJson,
    AuthOk.typeName: AuthOk.fromJson,
    AuthFail.typeName: AuthFail.fromJson,
    ProtocolErrorMessage.typeName: ProtocolErrorMessage.fromJson,
  };

  /// Encodes [message] to a JSON object, injecting `type`.
  Map<String, dynamic> encode(ControlMessage message) => {
    'type': message.type,
    ...message.toJson(),
  };

  /// Decodes a JSON object into a [ControlMessage].
  ///
  /// Throws [ProtocolException] for an unknown or malformed type.
  ControlMessage decode(Map<String, dynamic> json) {
    final type = Json.requireString(json, 'type');
    final decoder = _decoders[type];
    if (decoder == null) {
      throw ProtocolException('Unknown control message type: "$type"');
    }
    return decoder(json);
  }

  /// Encodes [message] as an omnyhub text [Message] for the wire.
  Message toWire(ControlMessage message) =>
      TextMessage(jsonEncode(encode(message)));

  /// Decodes an omnyhub [Message] from the wire.
  ///
  /// Throws [ProtocolException] on a binary frame, malformed JSON or an unknown
  /// type: the handshake is strictly text JSON, and a peer that does not speak
  /// it must be rejected rather than tolerated.
  ControlMessage fromWire(Message message) {
    if (message is! TextMessage) {
      throw const ProtocolException('Handshake expects a text frame');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(message.data);
    } on FormatException catch (e) {
      throw ProtocolException('Invalid control JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw const ProtocolException('Control frame must be a JSON object');
    }
    return decode(decoded.cast<String, dynamic>());
  }
}
