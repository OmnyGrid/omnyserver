import 'dart:convert';
import 'dart:typed_data';

import '../shared/errors/omnyserver_exception.dart';
import 'control_message_codec.dart';
import 'omny_frame.dart';

/// Encodes [OmnyFrame]s to and from the wire representation carried by a
/// WebSocket: text frames (UTF-8 JSON) for control messages, binary frames for
/// data.
///
/// Binary layout: `[opcode:1][channel:uint32 BE][payload…]`.
class FrameCodec {
  /// The control-message JSON codec.
  final ControlMessageCodec controlCodec;

  /// Creates a frame codec.
  const FrameCodec({this.controlCodec = ControlMessageCodec.instance});

  /// The default frame codec.
  static const FrameCodec standard = FrameCodec();

  /// Encodes [frame] to either a [String] (control) or [Uint8List] (data).
  Object encode(OmnyFrame frame) {
    switch (frame) {
      case ControlFrame(:final message):
        return jsonEncode(controlCodec.encode(message));
      case DataFrame(:final channel, :final opcode, :final payload):
        final out = Uint8List(5 + payload.length);
        out[0] = opcode.code;
        final view = ByteData.view(out.buffer);
        view.setUint32(1, channel);
        out.setRange(5, out.length, payload);
        return out;
    }
  }

  /// Decodes a wire [event] (a [String] or list of bytes) to an [OmnyFrame].
  ///
  /// Throws [ProtocolException] on malformed input.
  OmnyFrame decode(Object event) {
    if (event is String) {
      final Object? decoded;
      try {
        decoded = jsonDecode(event);
      } on FormatException catch (e) {
        throw ProtocolException('Invalid control JSON: ${e.message}');
      }
      if (decoded is! Map) {
        throw const ProtocolException('Control frame must be a JSON object');
      }
      return ControlFrame(controlCodec.decode(decoded.cast<String, dynamic>()));
    }
    if (event is List<int>) {
      if (event.length < 5) {
        throw const ProtocolException('Data frame header too short');
      }
      final bytes = Uint8List.fromList(event);
      final view = ByteData.view(bytes.buffer);
      final opcode = DataOpcode.fromCode(bytes[0]);
      final channel = view.getUint32(1);
      final payload = Uint8List.sublistView(bytes, 5);
      return DataFrame(channel: channel, opcode: opcode, payload: payload);
    }
    throw ProtocolException('Unsupported wire frame: ${event.runtimeType}');
  }
}
