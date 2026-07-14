import 'package:meta/meta.dart';

import '../../shared/errors/omnyserver_exception.dart';
import '../../shared/json/json_codec_helpers.dart';
import '../value_objects/node_id.dart';

/// Base type for every event emitted on the Hub's [EventBus].
///
/// Events are immutable facts ("something happened"). The hierarchy is `sealed`
/// so subscribers can switch exhaustively, and so the event aggregator and
/// (future) websocket/SSE streaming can serialize them uniformly.
sealed class OmnyEvent {
  /// When the event occurred (UTC).
  final DateTime at;

  /// Creates an event stamped at [at].
  const OmnyEvent(this.at);

  /// A stable event type discriminator (used in JSON / streaming).
  String get type;

  /// JSON form (type + payload).
  Map<String, dynamic> toJson() => {
    'type': type,
    'at': at.toUtc().toIso8601String(),
    ...payload(),
  };

  /// Decodes the JSON form produced by [toJson].
  ///
  /// The counterpart the Hub's `/events` endpoint needs on the other side: it
  /// encodes these, so a client — the web dashboard, or anything reading the
  /// stream — must be able to decode them back into the sealed hierarchy rather
  /// than picking at raw maps.
  ///
  /// An unrecognised `type` throws rather than being dropped: a client silently
  /// ignoring events it does not understand is how a fleet view quietly goes
  /// stale after the Hub learns a new one.
  factory OmnyEvent.fromJson(Map<String, dynamic> json) {
    final type = Json.requireString(json, 'type');
    final at = Json.requireTimestamp(json, 'at');
    NodeId node() => NodeId(Json.requireString(json, 'nodeId'));

    return switch (type) {
      'node.connected' => NodeConnected(node(), at),
      'node.disconnected' => NodeDisconnected(
        node(),
        at,
        reason: Json.optString(json, 'reason'),
      ),
      'heartbeat.received' => HeartbeatReceived(
        node(),
        Json.requireInt(json, 'sequence'),
        at,
      ),
      'formula.started' => FormulaStarted(
        node(),
        Json.requireString(json, 'formula'),
        Json.requireString(json, 'action'),
        at,
      ),
      'formula.finished' => FormulaFinished(
        node(),
        Json.requireString(json, 'formula'),
        Json.requireString(json, 'action'),
        Json.optBool(json, 'success'),
        at,
      ),
      'preset.applied' => PresetApplied(
        node(),
        Json.requireString(json, 'preset'),
        Json.optBool(json, 'success'),
        at,
      ),
      'node.updated' => NodeUpdated(
        node(),
        Json.requireString(json, 'target'),
        at,
      ),
      'alert.raised' => AlertRaised(
        node(),
        Json.requireString(json, 'rule'),
        Json.requireString(json, 'message'),
        at,
      ),
      'alert.resolved' => AlertResolved(
        node(),
        Json.requireString(json, 'rule'),
        at,
      ),
      _ => throw ProtocolException('unknown event type "$type"'),
    };
  }

  /// Event-specific payload fields.
  @protected
  Map<String, dynamic> payload();
}

/// A node connected and authenticated to the Hub.
final class NodeConnected extends OmnyEvent {
  /// The connected node.
  final NodeId nodeId;

  /// Creates the event.
  const NodeConnected(this.nodeId, DateTime at) : super(at);

  @override
  String get type => 'node.connected';

  @override
  Map<String, dynamic> payload() => {'nodeId': nodeId.value};
}

/// A node disconnected from the Hub.
final class NodeDisconnected extends OmnyEvent {
  /// The disconnected node.
  final NodeId nodeId;

  /// An optional reason.
  final String? reason;

  /// Creates the event.
  const NodeDisconnected(this.nodeId, DateTime at, {this.reason}) : super(at);

  @override
  String get type => 'node.disconnected';

  @override
  Map<String, dynamic> payload() => {
    'nodeId': nodeId.value,
    if (reason != null) 'reason': reason,
  };
}

/// A heartbeat was received from a node.
final class HeartbeatReceived extends OmnyEvent {
  /// The node.
  final NodeId nodeId;

  /// The heartbeat sequence number.
  final int sequence;

  /// Creates the event.
  const HeartbeatReceived(this.nodeId, this.sequence, DateTime at) : super(at);

  @override
  String get type => 'heartbeat.received';

  @override
  Map<String, dynamic> payload() => {
    'nodeId': nodeId.value,
    'sequence': sequence,
  };
}

/// A formula run started on a node.
final class FormulaStarted extends OmnyEvent {
  /// The target node.
  final NodeId nodeId;

  /// The formula id.
  final String formula;

  /// The action being run.
  final String action;

  /// Creates the event.
  const FormulaStarted(this.nodeId, this.formula, this.action, DateTime at)
    : super(at);

  @override
  String get type => 'formula.started';

  @override
  Map<String, dynamic> payload() => {
    'nodeId': nodeId.value,
    'formula': formula,
    'action': action,
  };
}

/// A formula run finished on a node.
final class FormulaFinished extends OmnyEvent {
  /// The target node.
  final NodeId nodeId;

  /// The formula id.
  final String formula;

  /// The action that was run.
  final String action;

  /// Whether it succeeded.
  final bool success;

  /// Creates the event.
  const FormulaFinished(
    this.nodeId,
    this.formula,
    this.action,
    this.success,
    DateTime at,
  ) : super(at);

  @override
  String get type => 'formula.finished';

  @override
  Map<String, dynamic> payload() => {
    'nodeId': nodeId.value,
    'formula': formula,
    'action': action,
    'success': success,
  };
}

/// A preset was applied to a node.
final class PresetApplied extends OmnyEvent {
  /// The target node.
  final NodeId nodeId;

  /// The preset id.
  final String preset;

  /// Whether application succeeded overall.
  final bool success;

  /// Creates the event.
  const PresetApplied(this.nodeId, this.preset, this.success, DateTime at)
    : super(at);

  @override
  String get type => 'preset.applied';

  @override
  Map<String, dynamic> payload() => {
    'nodeId': nodeId.value,
    'preset': preset,
    'success': success,
  };
}

/// A node was updated (OS, package or agent).
final class NodeUpdated extends OmnyEvent {
  /// The target node.
  final NodeId nodeId;

  /// What was updated (e.g. `agent`, `os`, a package name).
  final String target;

  /// Creates the event.
  const NodeUpdated(this.nodeId, this.target, DateTime at) : super(at);

  @override
  String get type => 'node.updated';

  @override
  Map<String, dynamic> payload() => {'nodeId': nodeId.value, 'target': target};
}

/// A rule became breached by a node.
///
/// Raised on the same bus as everything else, so an alert reaches a dashboard,
/// `events --follow` and the audit trail by the paths that already exist —
/// rather than needing a delivery mechanism of its own.
final class AlertRaised extends OmnyEvent {
  /// The breaching node.
  final NodeId nodeId;

  /// The rule that is breached (its id, e.g. `disk>90`).
  final String rule;

  /// A line an operator can read.
  final String message;

  /// Creates the event.
  const AlertRaised(this.nodeId, this.rule, this.message, DateTime at)
    : super(at);

  @override
  String get type => 'alert.raised';

  @override
  Map<String, dynamic> payload() => {
    'nodeId': nodeId.value,
    'rule': rule,
    'message': message,
  };
}

/// A rule stopped being breached.
///
/// The counterpart matters: an alert that fires and never clears teaches an
/// operator to ignore alerts.
final class AlertResolved extends OmnyEvent {
  /// The node that recovered.
  final NodeId nodeId;

  /// The rule that is no longer breached.
  final String rule;

  /// Creates the event.
  const AlertResolved(this.nodeId, this.rule, DateTime at) : super(at);

  @override
  String get type => 'alert.resolved';

  @override
  Map<String, dynamic> payload() => {'nodeId': nodeId.value, 'rule': rule};
}
