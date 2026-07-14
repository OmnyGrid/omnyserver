import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

/// One line a node reported, stamped with when the Hub received it.
@immutable
class LogLine {
  /// The node that reported it.
  final String nodeId;

  /// Where on the node it came from (`agent`, `system`, `formula`).
  final String source;

  /// The line itself.
  final String message;

  /// When the Hub received it (UTC).
  ///
  /// The Hub's clock, not the node's: a fleet's clocks disagree, and a tail that
  /// interleaves several nodes is unreadable if each of them is telling a
  /// different time.
  final DateTime at;

  /// Creates a log line.
  const LogLine({
    required this.nodeId,
    required this.source,
    required this.message,
    required this.at,
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'source': source,
    'message': message,
    'at': at.toUtc().toIso8601String(),
  };

  /// Decodes from JSON.
  static LogLine fromJson(Map<String, dynamic> json) => LogLine(
    nodeId: Json.requireString(json, 'nodeId'),
    source: Json.optString(json, 'source') ?? 'agent',
    message: Json.optString(json, 'message') ?? '',
    at: Json.requireTimestamp(json, 'at'),
  );

  @override
  String toString() => '[$nodeId/$source] $message';
}
