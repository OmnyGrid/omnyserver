import 'package:meta/meta.dart';

import '../../shared/errors/omnyserver_exception.dart';
import '../../shared/json/json_codec_helpers.dart';
import 'metric_point.dart';

/// What an [AlertRule] watches.
enum AlertMetric {
  /// CPU usage, as a percentage.
  cpu,

  /// Memory in use, as a percentage of the total.
  memory,

  /// Storage in use, as a percentage of capacity.
  disk,

  /// The node not being connected at all.
  offline;

  /// Parses a metric name, rejecting anything else rather than guessing.
  static AlertMetric parse(String value) => AlertMetric.values.firstWhere(
    (m) => m.name == value,
    orElse: () => throw ProtocolException(
      'unknown alert metric "$value" (want ${AlertMetric.values.map((m) => m.name).join(', ')})',
    ),
  );
}

/// A condition worth being told about.
///
/// Deliberately small. This is not a monitoring system, and it should not grow
/// into one — a fleet tool that tries to be Prometheus ends up a worse Prometheus.
/// It answers the two questions an operator has *while looking at the fleet*: is
/// anything about to run out of something, and has anything gone away?
///
/// [duration] is what separates an alert from a twitch. A node at 95% CPU for one
/// heartbeat is a build running; at 95% for five minutes it is a problem. Without
/// it, every alert is noise, and an operator who has learned to ignore alerts has
/// no alerting.
@immutable
class AlertRule {
  /// A stable id, used to correlate raising with resolving.
  final String id;

  /// What is being watched.
  final AlertMetric metric;

  /// The percentage above which [metric] is a problem. Ignored for
  /// [AlertMetric.offline].
  final double threshold;

  /// How long the condition must hold before it is worth saying.
  final Duration duration;

  /// Creates a rule.
  const AlertRule({
    required this.id,
    required this.metric,
    this.threshold = 0,
    this.duration = Duration.zero,
  });

  /// Whether [point] breaches this rule (offline rules are judged elsewhere:
  /// a node that is gone reports nothing).
  bool breachedBy(MetricPoint point) => switch (metric) {
    AlertMetric.cpu => point.cpuPercent > threshold,
    AlertMetric.memory => (point.memoryPercent ?? 0) > threshold,
    AlertMetric.disk => (point.storagePercent ?? 0) > threshold,
    AlertMetric.offline => false,
  };

  /// Parses the CLI form: `disk>90`, `cpu>95 for 5m`, `offline for 2m`.
  ///
  /// Terse on purpose — this is typed on a command line, and a rule an operator
  /// cannot write from memory is a rule nobody configures.
  factory AlertRule.parse(String raw) {
    final text = raw.trim();
    final match = RegExp(
      r'^(\w+)\s*(?:>\s*(\d+(?:\.\d+)?))?\s*(?:for\s+(\d+)([smh]))?$',
    ).firstMatch(text);
    if (match == null) {
      throw ProtocolException(
        'invalid alert "$raw" (want e.g. "disk>90", "cpu>95 for 5m", '
        '"offline for 2m")',
      );
    }

    final metric = AlertMetric.parse(match.group(1)!);
    final threshold = double.tryParse(match.group(2) ?? '');
    if (metric != AlertMetric.offline && threshold == null) {
      throw ProtocolException('alert "$raw" needs a threshold, e.g. $raw>90');
    }

    final amount = int.tryParse(match.group(3) ?? '');
    final duration = amount == null
        ? Duration.zero
        : switch (match.group(4)) {
            's' => Duration(seconds: amount),
            'm' => Duration(minutes: amount),
            _ => Duration(hours: amount),
          };

    return AlertRule(
      id: text,
      metric: metric,
      threshold: threshold ?? 0,
      duration: duration,
    );
  }

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'id': id,
    'metric': metric.name,
    'threshold': threshold,
    'durationSeconds': duration.inSeconds,
  };

  /// Decodes from JSON.
  static AlertRule fromJson(Map<String, dynamic> json) => AlertRule(
    id: Json.requireString(json, 'id'),
    metric: AlertMetric.parse(Json.requireString(json, 'metric')),
    threshold: Json.optDouble(json, 'threshold') ?? 0,
    duration: Duration(seconds: Json.optInt(json, 'durationSeconds') ?? 0),
  );

  @override
  String toString() => id;
}

/// A rule currently breached by a node.
@immutable
class Alert {
  /// The rule that is breached.
  final AlertRule rule;

  /// The node breaching it.
  final String nodeId;

  /// When the condition *started* — not when the alert fired.
  ///
  /// The distinction matters when reading an alert list: "at 95% since 09:02" is
  /// a fact about the machine; "fired at 09:07" is a fact about the alerting.
  final DateTime since;

  /// The value that breached it (a percentage), or `null` for `offline`.
  final double? value;

  /// Creates an alert.
  const Alert({
    required this.rule,
    required this.nodeId,
    required this.since,
    this.value,
  });

  /// A line an operator can read.
  String get message => switch (rule.metric) {
    AlertMetric.offline =>
      '$nodeId has been offline for '
          '${_humanize(rule.duration)}',
    _ =>
      "$nodeId ${rule.metric.name} is ${value?.toStringAsFixed(0) ?? '?'}% "
          '(over ${rule.threshold.toStringAsFixed(0)}%)',
  };

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'rule': rule.toJson(),
    'nodeId': nodeId,
    'since': since.toUtc().toIso8601String(),
    'value': ?value,
    'message': message,
  };

  /// Decodes from JSON.
  static Alert fromJson(Map<String, dynamic> json) => Alert(
    rule: AlertRule.fromJson(Json.asObject(json['rule'], 'rule')),
    nodeId: Json.requireString(json, 'nodeId'),
    since: Json.requireTimestamp(json, 'since'),
    value: Json.optDouble(json, 'value'),
  );

  static String _humanize(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }

  @override
  String toString() => message;
}
