import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../value_objects/blueprint_id.dart';
import 'resolved_blueprint.dart';
import 'resource.dart';
import 'resource_state.dart';

/// One resource the node has been told to manage, and how it came to be there.
@immutable
class LedgerEntry {
  /// Which resource.
  final ResourceId id;

  /// The state it was last declared to be in.
  final Ensure ensure;

  /// Where it was declared — `local`, or `preset:base-hardening`.
  final String origin;

  /// Whether it was already on the machine, correct, before anything ran.
  ///
  /// The safety flag. Unassigning a blueprint removes what it put there, and if
  /// nginx was installed on this box a year before anyone wrote a blueprint,
  /// "remove what we manage" must not mean "uninstall nginx". Adopted resources
  /// are released rather than removed unless an operator explicitly asks to
  /// purge them.
  final bool adopted;

  /// A digest of what was applied, for types where presence is not the whole
  /// story.
  final String? fingerprint;

  /// Creates a ledger entry.
  const LedgerEntry({
    required this.id,
    required this.ensure,
    this.origin = 'local',
    this.adopted = false,
    this.fingerprint,
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'resource': id.toString(),
    'ensure': ensure.name,
    'origin': origin,
    if (adopted) 'adopted': true,
    if (fingerprint != null) 'fingerprint': fingerprint,
  };

  /// Decodes from JSON.
  static LedgerEntry fromJson(Map<String, dynamic> json) => LedgerEntry(
    id: ResourceId.parse(Json.requireString(json, 'resource')),
    ensure: Ensure.parse(Json.optString(json, 'ensure') ?? 'present'),
    origin: Json.optString(json, 'origin') ?? 'local',
    adopted: Json.optBool(json, 'adopted'),
    fingerprint: Json.optString(json, 'fingerprint'),
  );

  @override
  String toString() => 'LedgerEntry($id${adopted ? ', adopted' : ''})';
}

/// What this system put on this machine.
///
/// Written by the node after every apply, and the reason a blueprint can be
/// *edited* rather than only added to. Delete a resource from a blueprint and
/// the document no longer mentions it — so the document cannot ask for its
/// removal. The ledger can: it is the record of what was declared last time, and
/// the difference between it and the blueprint is what has to be undone.
///
/// Without it, removing a line from a blueprint would leave that software
/// running on every server it was ever applied to, forever.
@immutable
class Ledger {
  /// Which blueprint this records.
  final BlueprintId blueprint;

  /// The resolved hash that was applied.
  ///
  /// Compared against the Hub's current resolution to answer "is this node on
  /// the blueprint it was assigned" without reading a single resource.
  final String hash;

  /// When it was applied.
  final DateTime appliedAt;

  /// What is managed, keyed by resource.
  final Map<ResourceId, LedgerEntry> entries;

  /// Creates a ledger.
  const Ledger({
    required this.blueprint,
    required this.hash,
    required this.appliedAt,
    this.entries = const {},
  });

  /// An empty ledger for a node that has never applied [blueprint].
  factory Ledger.empty(BlueprintId blueprint, DateTime at) =>
      Ledger(blueprint: blueprint, hash: '', appliedAt: at, entries: const {});

  /// The resources this ledger holds that [resolved] no longer declares.
  ///
  /// What has to be removed, in reverse dependency order — a dependent is torn
  /// down before the thing it depends on, which is the order that worked for
  /// creation read backwards.
  List<LedgerEntry> orphansOf(ResolvedBlueprint resolved) {
    final declared = {for (final r in resolved.resources) r.id};
    return [
      for (final entry in entries.values)
        if (!declared.contains(entry.id)) entry,
    ].reversed.toList();
  }

  /// A ledger recording [resolved] as applied, carrying forward what is known
  /// about each resource.
  ///
  /// [adopted] names the resources that were already correct before anything
  /// ran. An entry that was adopted once stays adopted: the machine's history
  /// does not change because a later apply touched something else.
  ///
  /// [retain] names resources this blueprint no longer declares but which are
  /// **still on the machine**, because removing them was attempted and did not
  /// work. They stay in the ledger, and that is the whole point: a resource
  /// that falls out of the ledger while it is still installed is leaked for
  /// good. Nothing remembers we put it there, the next apply finds no orphan to
  /// retry, and a later re-declaration *adopts* it — so it can never be removed
  /// again. One transient failure would otherwise cost an owned resource
  /// permanently.
  Ledger recording(
    ResolvedBlueprint resolved,
    DateTime at, {
    required Set<ResourceId> adopted,
    Map<ResourceId, ResourceState> states = const {},
    Set<ResourceId> retain = const {},
  }) => Ledger(
    blueprint: resolved.blueprint,
    hash: resolved.hash,
    appliedAt: at,
    entries: {
      for (final r in resolved.resources)
        if (r.ensure != Ensure.absent)
          r.id: LedgerEntry(
            id: r.id,
            ensure: r.ensure,
            origin: r.origin,
            adopted:
                adopted.contains(r.id) || (entries[r.id]?.adopted ?? false),
            fingerprint: states[r.id]?.fingerprint,
          ),
      // Kept exactly as they were — including `adopted`, which must not flip
      // just because a teardown failed.
      for (final id in retain) id: ?entries[id],
    },
  );

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'blueprint': blueprint.value,
    'hash': hash,
    'appliedAt': appliedAt.toUtc().toIso8601String(),
    'entries': [for (final e in entries.values) e.toJson()],
  };

  /// Decodes from JSON.
  static Ledger fromJson(Map<String, dynamic> json) {
    final entries = [
      for (final e in Json.optObjectList(json, 'entries'))
        LedgerEntry.fromJson(e),
    ];
    return Ledger(
      blueprint: BlueprintId(Json.requireString(json, 'blueprint')),
      hash: Json.optString(json, 'hash') ?? '',
      appliedAt: Json.optTimestamp(json, 'appliedAt') ?? DateTime.now().toUtc(),
      entries: {for (final e in entries) e.id: e},
    );
  }

  @override
  String toString() =>
      'Ledger(${blueprint.value}, ${entries.length} resources)';
}
