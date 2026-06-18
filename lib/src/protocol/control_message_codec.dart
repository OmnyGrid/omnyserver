import '../shared/errors/omnyserver_exception.dart';
import '../shared/json/json_codec_helpers.dart';
import 'control_message.dart';

/// Decodes a JSON object (`{type, channel?, ...}`) into the matching
/// [ControlMessage] subtype, and encodes a message back to a JSON object.
///
/// Centralizes the `type` → `fromJson` dispatch so adding a message means
/// registering it in one place.
class ControlMessageCodec {
  const ControlMessageCodec._();

  /// The shared codec instance.
  static const ControlMessageCodec instance = ControlMessageCodec._();

  static final Map<
    String,
    ControlMessage Function(int? channel, Map<String, dynamic>)
  >
  _decoders = {
    Hello.typeName: Hello.fromJson,
    AuthChallenge.typeName: AuthChallenge.fromJson,
    AuthSubmit.typeName: AuthSubmit.fromJson,
    AuthOk.typeName: AuthOk.fromJson,
    AuthFail.typeName: AuthFail.fromJson,
    NodeRegister.typeName: NodeRegister.fromJson,
    NodeRegistered.typeName: NodeRegistered.fromJson,
    NodeHeartbeat.typeName: NodeHeartbeat.fromJson,
    NodeHeartbeatAck.typeName: NodeHeartbeatAck.fromJson,
    StatusReport.typeName: StatusReport.fromJson,
    LogBatch.typeName: LogBatch.fromJson,
    Ping.typeName: Ping.fromJson,
    Pong.typeName: Pong.fromJson,
    NodeListRequest.typeName: NodeListRequest.fromJson,
    NodeListResponse.typeName: NodeListResponse.fromJson,
    CommandRequest.typeName: CommandRequest.fromJson,
    CommandResult.typeName: CommandResult.fromJson,
    FormulaRun.typeName: FormulaRun.fromJson,
    FormulaProgress.typeName: FormulaProgress.fromJson,
    FormulaRunResult.typeName: FormulaRunResult.fromJson,
    PresetApply.typeName: PresetApply.fromJson,
    PresetApplyResult.typeName: PresetApplyResult.fromJson,
    ServiceControl.typeName: ServiceControl.fromJson,
    ServiceControlResult.typeName: ServiceControlResult.fromJson,
    NodeControl.typeName: NodeControl.fromJson,
    OperationAck.typeName: OperationAck.fromJson,
    ProtocolErrorMessage.typeName: ProtocolErrorMessage.fromJson,
  };

  /// Encodes [message] to a JSON object, injecting `type` and optional
  /// `channel`.
  Map<String, dynamic> encode(ControlMessage message) => {
    'type': message.type,
    if (message.channelId != null) 'channel': message.channelId,
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
    final channel = Json.optInt(json, 'channel');
    return decoder(channel, json);
  }
}
