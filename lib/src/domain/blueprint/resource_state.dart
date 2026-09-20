import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../formula/formula_status.dart';
import 'resource.dart';

/// What a provider found when it looked at one resource on a node.
///
/// The status vocabulary is [FormulaStatus], reused rather than reinvented: its
/// values — `unknown`, `absent`, `installed`, `running`, `stopped`, `failed` —
/// were already the general ones, and a second enum saying the same words would
/// only have to be mapped onto the first. (If a later provider needs a word this
/// set lacks, the honest move is to rename the enum, not to fork it.)
///
/// The [FormulaStatus.unknown] rule carries over intact and matters more here
/// than it did for a single formula: a probe that could not *run* has said
/// nothing about whether the resource is there. Reporting `absent` on that basis
/// invites a create, and creating over something that already works is how a
/// failed probe becomes an outage.
@immutable
class ResourceState {
  /// Which resource this is about.
  final ResourceId id;

  /// What the provider found.
  final FormulaStatus status;

  /// The version detected, when the resource could say.
  final String? version;

  /// A short note — what the probe saw, or why it could not look.
  final String message;

  /// A digest of the resource's contents, for types where "the same" is more
  /// than "present" — a file's bytes, a cron line. Null when presence is the
  /// whole story.
  final String? fingerprint;

  /// When the node looked.
  final DateTime checkedAt;

  /// Creates a resource state.
  const ResourceState({
    required this.id,
    required this.status,
    required this.checkedAt,
    this.version,
    this.message = '',
    this.fingerprint,
  });

  /// A resource whose probe could not run.
  ///
  /// A named constructor because getting this wrong is the expensive mistake,
  /// and a provider reaching for it should not have to remember which status
  /// means "I could not tell".
  factory ResourceState.unknown(
    ResourceId id,
    DateTime at, {
    String message = '',
  }) => ResourceState(
    id: id,
    status: FormulaStatus.unknown,
    checkedAt: at,
    message: message,
  );

  /// Whether the resource is on the node at all.
  bool get isPresent => status.isPresent;

  /// Whether this reading already satisfies [ensure].
  ///
  /// [FormulaStatus.unknown] satisfies nothing — see the class doc.
  bool satisfies(Ensure ensure) => switch (ensure) {
    Ensure.absent => status == FormulaStatus.absent,
    _ when status == FormulaStatus.unknown => false,
    Ensure.present || Ensure.installed => isPresent,
    // Deliberately not idempotent-by-reading: "the newest version" cannot be
    // known without asking the package manager, so `latest` always plans an
    // action and the provider reports `changed: false` when there was nothing
    // to do. Claiming convergence here would pin a node to whatever it had.
    Ensure.latest => false,
    Ensure.running => status == FormulaStatus.running,
    Ensure.stopped =>
      status == FormulaStatus.stopped || status == FormulaStatus.installed,
  };

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'resource': id.toString(),
    'status': status.name,
    if (version != null) 'version': version,
    if (message.isNotEmpty) 'message': message,
    if (fingerprint != null) 'fingerprint': fingerprint,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
  };

  /// Decodes from JSON.
  static ResourceState fromJson(Map<String, dynamic> json) => ResourceState(
    id: ResourceId.parse(Json.requireString(json, 'resource')),
    status: FormulaStatus.parse(Json.optString(json, 'status') ?? ''),
    version: Json.optString(json, 'version'),
    message: Json.optString(json, 'message') ?? '',
    fingerprint: Json.optString(json, 'fingerprint'),
    checkedAt: Json.optTimestamp(json, 'checkedAt') ?? DateTime.now().toUtc(),
  );

  @override
  String toString() => 'ResourceState($id: ${status.name})';
}
