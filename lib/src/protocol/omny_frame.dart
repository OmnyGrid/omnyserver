import 'dart:typed_data';

import 'control_message.dart';

/// The opcode of a binary [DataFrame], identifying the stream it carries.
///
/// Data frames are reserved for high-volume streaming (log tailing, metric
/// bursts) that would be wasteful to wrap in JSON control messages.
enum DataOpcode {
  /// A batch of log lines.
  log,

  /// A binary metric sample blob.
  metric,

  /// Opaque application data.
  data;

  /// The byte value on the wire.
  int get code => index;

  /// Parses a byte value, defaulting to [data].
  static DataOpcode fromCode(int code) =>
      code >= 0 && code < DataOpcode.values.length
      ? DataOpcode.values[code]
      : DataOpcode.data;
}

/// A single unit transmitted over an [OmnyConnection]: either a JSON
/// [ControlFrame] (text) or a binary [DataFrame].
sealed class OmnyFrame {
  const OmnyFrame();
}

/// A text frame carrying a JSON [ControlMessage].
final class ControlFrame extends OmnyFrame {
  /// The control message.
  final ControlMessage message;

  /// Wraps [message] in a control frame.
  const ControlFrame(this.message);
}

/// A binary frame: a channel-scoped, opcode-tagged payload.
final class DataFrame extends OmnyFrame {
  /// The logical channel this data belongs to.
  final int channel;

  /// The stream opcode.
  final DataOpcode opcode;

  /// The raw payload bytes.
  final Uint8List payload;

  /// Creates a data frame.
  const DataFrame({
    required this.channel,
    required this.opcode,
    required this.payload,
  });
}
