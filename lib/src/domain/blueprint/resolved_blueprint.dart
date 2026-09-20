import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../value_objects/blueprint_id.dart';
import 'resource.dart';

/// A resource after resolution, and where it came from.
///
/// [origin] is the answer to the first question anyone asks when something
/// unexpected is on a machine. A blueprint that includes three presets produces
/// a flat list, and without provenance an operator reading it has no way to tell
/// which of the four documents involved put `formula:nmap` there.
@immutable
class ResolvedResource {
  /// The resource itself, with `${var}` already substituted.
  final Resource resource;

  /// Where it was declared — `local`, or `preset:base-hardening`.
  final String origin;

  /// What it overrode, if anything.
  ///
  /// An override is not an error — it is how "the base says running, this role
  /// deliberately says stopped" is expressed — but it must never be invisible.
  final String? overrides;

  /// Creates a resolved resource.
  const ResolvedResource({
    required this.resource,
    required this.origin,
    this.overrides,
  });

  /// The resource's identity.
  ResourceId get id => resource.id;

  /// The state it should be in.
  Ensure get ensure => resource.ensure;

  /// JSON form.
  Map<String, dynamic> toJson() => {
    ...resource.toJson(),
    'origin': origin,
    if (overrides != null) 'overrides': overrides,
  };

  /// Decodes from JSON.
  static ResolvedResource fromJson(Map<String, dynamic> json) =>
      ResolvedResource(
        resource: Resource.fromJson(json),
        origin: Json.optString(json, 'origin') ?? 'local',
        overrides: Json.optString(json, 'overrides'),
      );

  @override
  String toString() => '$id ensure=${ensure.name} from $origin';
}

/// A blueprint with its includes flattened, variables substituted and resources
/// ordered — everything a node needs, and nothing it has to work out.
///
/// The node never learns what a preset is. Resolution happens once, on the Hub,
/// so two nodes given "the same blueprint" are given literally the same bytes,
/// and the [hash] over those bytes is what makes convergence checkable without
/// asking the node anything at all.
@immutable
class ResolvedBlueprint {
  /// Which blueprint this is.
  final BlueprintId blueprint;

  /// A digest of the resolved resources.
  ///
  /// Covers the includes' contents too, since they are flattened in by the time
  /// it is taken. So editing a shared preset changes the hash of every blueprint
  /// that includes it, and a node still carrying the old hash is visibly behind.
  final String hash;

  /// The resources, in the order they must be settled.
  final List<ResolvedResource> resources;

  /// Notes from resolution worth showing — overrides, skipped platforms.
  final List<String> notes;

  /// Creates a resolved blueprint.
  const ResolvedBlueprint({
    required this.blueprint,
    required this.hash,
    this.resources = const [],
    this.notes = const [],
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'blueprint': blueprint.value,
    'hash': hash,
    'resources': [for (final r in resources) r.toJson()],
    if (notes.isNotEmpty) 'notes': notes,
  };

  /// Decodes from JSON.
  static ResolvedBlueprint fromJson(Map<String, dynamic> json) =>
      ResolvedBlueprint(
        blueprint: BlueprintId(Json.requireString(json, 'blueprint')),
        hash: Json.optString(json, 'hash') ?? '',
        resources: Json.optObjectList(
          json,
          'resources',
        ).map(ResolvedResource.fromJson).toList(),
        notes: Json.optStringList(json, 'notes'),
      );

  @override
  String toString() =>
      'ResolvedBlueprint(${blueprint.value}, ${resources.length} resources)';
}
