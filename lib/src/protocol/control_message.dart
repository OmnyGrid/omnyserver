import '../domain/auth/credential.dart';
import '../domain/entities/heartbeat.dart';
import '../domain/entities/node_descriptor.dart';
import '../domain/entities/node_status.dart';
import '../domain/entities/preset.dart';
import '../domain/entities/service_descriptor.dart';
import '../domain/formula/formula_action.dart';
import '../domain/formula/formula_result.dart';
import '../shared/json/json_codec_helpers.dart';

part 'messages.dart';

/// Base type for every JSON control message exchanged over an
/// [OmnyConnection].
///
/// Each concrete message is a `final class` (declared in the `messages.dart`
/// part) with a stable [type] discriminator and a symmetric `toJson` /
/// `fromJson`. The hierarchy is `sealed` so the codec and handlers can switch
/// exhaustively. Decoding is centralized in `ControlMessageCodec`.
sealed class ControlMessage {
  /// Creates a control message.
  const ControlMessage();

  /// The stable type discriminator (e.g. `node.register`).
  String get type;

  /// The logical channel this message is scoped to, or `null` for
  /// connection-level messages.
  int? get channelId => null;

  /// The message payload (excluding `type` / `channel`, which the codec adds).
  Map<String, dynamic> toJson();
}
