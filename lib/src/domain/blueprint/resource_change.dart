import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import 'resource.dart';

/// What a plan proposes to do about one resource, or what an apply did.
enum ChangeKind {
  /// Nothing to do — the node already matches.
  noop,

  /// The resource is not there and should be.
  create,

  /// It is there but not as declared.
  update,

  /// It is there and should not be. Either declared `ensure: absent`, or in the
  /// node's ledger and no longer in the blueprint at all.
  remove,

  /// Its provider could not tell what state it was in, so nothing was planned.
  ///
  /// Distinct from [noop]: a no-op means "already right", this means "I do not
  /// know", and an operator reading a converged plan deserves to know which.
  unknown,

  /// Not attempted, because something it requires failed.
  skipped,

  /// Attempted and did not work.
  failed;

  /// Parses a wire name, defaulting to [unknown].
  static ChangeKind parse(String value) => ChangeKind.values.firstWhere(
    (k) => k.name == value,
    orElse: () => ChangeKind.unknown,
  );

  /// Whether this kind would change the machine if applied.
  bool get isWork =>
      this == ChangeKind.create ||
      this == ChangeKind.update ||
      this == ChangeKind.remove;
}

/// One resource's line in a plan, and afterwards its line in a report.
///
/// The same type serves both because they are the same statement at different
/// times: a plan says `create formula:docker`, and the report says whether it
/// worked. Two types would mean mapping one onto the other and keeping the
/// mapping honest.
@immutable
class ResourceChange {
  /// Which resource.
  final ResourceId id;

  /// What is proposed, or what happened.
  final ChangeKind kind;

  /// Why — in a sentence an operator can act on.
  ///
  /// Not optional. A plan that says `update file:/etc/nginx/nginx.conf` with no
  /// reason is asking to be approved on trust.
  final String reason;

  /// Where the resource was declared: `local`, `preset:base-hardening`, or
  /// `ledger` for a removal of something no longer in the blueprint.
  final String origin;

  /// The lines the provider produced, when this change was applied.
  ///
  /// Capped like a formula run's: the full output went to the node log, tagged
  /// with this resource, and that is where to read it.
  final List<String> logs;

  /// Creates a change.
  const ResourceChange({
    required this.id,
    required this.kind,
    required this.reason,
    this.origin = 'local',
    this.logs = const [],
  });

  /// A copy carrying [logs].
  ResourceChange withLogs(List<String> logs) => ResourceChange(
    id: id,
    kind: kind,
    reason: reason,
    origin: origin,
    logs: logs,
  );

  /// A copy recording how the attempt went.
  ResourceChange completed({required ChangeKind kind, String? reason}) =>
      ResourceChange(
        id: id,
        kind: kind,
        reason: reason ?? this.reason,
        origin: origin,
        logs: logs,
      );

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'resource': id.toString(),
    'kind': kind.name,
    'reason': reason,
    'origin': origin,
    if (logs.isNotEmpty) 'logs': logs,
  };

  /// Decodes from JSON.
  static ResourceChange fromJson(Map<String, dynamic> json) => ResourceChange(
    id: ResourceId.parse(Json.requireString(json, 'resource')),
    kind: ChangeKind.parse(Json.optString(json, 'kind') ?? ''),
    reason: Json.optString(json, 'reason') ?? '',
    origin: Json.optString(json, 'origin') ?? 'local',
    logs: Json.optStringList(json, 'logs'),
  );

  @override
  String toString() => '${kind.name} $id';
}
