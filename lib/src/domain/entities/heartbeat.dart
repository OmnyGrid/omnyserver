import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../value_objects/node_id.dart';
import 'node_status.dart';

/// A liveness signal a node sends to the Hub at a regular interval, optionally
/// carrying a fresh [NodeStatus] snapshot.
@immutable
class Heartbeat {
  /// The node sending the heartbeat.
  final NodeId nodeId;

  /// Monotonically increasing sequence number (per connection).
  final int sequence;

  /// When the heartbeat was emitted (UTC).
  final DateTime sentAt;

  /// An optional live status snapshot piggy-backed on the heartbeat.
  final NodeStatus? status;

  /// Creates a heartbeat.
  const Heartbeat({
    required this.nodeId,
    required this.sequence,
    required this.sentAt,
    this.status,
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId.value,
    'sequence': sequence,
    'sentAt': sentAt.toUtc().toIso8601String(),
    if (status != null) 'status': status!.toJson(),
  };

  /// Decodes from JSON.
  static Heartbeat fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    return Heartbeat(
      nodeId: NodeId(Json.requireString(json, 'nodeId')),
      sequence: Json.optInt(json, 'sequence', 0) ?? 0,
      sentAt: Json.requireTimestamp(json, 'sentAt'),
      status: status == null
          ? null
          : NodeStatus.fromJson(Json.asObject(status, 'status')),
    );
  }
}
