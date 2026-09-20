import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../value_objects/blueprint_id.dart';
import '../value_objects/preset_id.dart';
import 'resource.dart';

/// The format a blueprint was written in.
///
/// Fixed when the blueprint is authored and never converted afterwards. A
/// blueprint written as YAML is shown, edited and re-saved as YAML; one written
/// as JSON stays JSON. Mixing them — author YAML, read back JSON — loses
/// comments and means the file in your editor and the thing on the Hub are two
/// different documents that happen to agree.
enum BlueprintFormat {
  /// Written as YAML.
  yaml,

  /// Written as JSON.
  json;

  /// Parses a wire name, defaulting to [json] — the wire's own format, and the
  /// right assumption for a blueprint that arrived over the API rather than
  /// from a file.
  static BlueprintFormat parse(String value) => BlueprintFormat.values
      .firstWhere((f) => f.name == value, orElse: () => BlueprintFormat.json);
}

/// The bytes a human actually wrote.
///
/// Kept alongside the parsed [Blueprint] so `blueprint show` can hand back the
/// document as it was authored, comments and all, rather than a re-rendering of
/// what the parser made of it. Both are written from one parse, so they cannot
/// drift: the source is authoritative for editing, the parsed form for planning,
/// and the parsed form is never edited directly.
@immutable
class BlueprintSource {
  /// The format [text] is written in.
  final BlueprintFormat format;

  /// The document, verbatim.
  final String text;

  /// Creates a source record.
  const BlueprintSource({required this.format, required this.text});

  /// JSON form.
  Map<String, dynamic> toJson() => {'format': format.name, 'text': text};

  /// Decodes from JSON.
  static BlueprintSource fromJson(Map<String, dynamic> json) => BlueprintSource(
    format: BlueprintFormat.parse(Json.optString(json, 'format') ?? 'json'),
    text: Json.optString(json, 'text') ?? '',
  );
}

/// What a server should be.
///
/// A blueprint is composed from [includes] — presets that already exist and are
/// shared across the fleet — plus [resources] of its own. A preset is a piece; a
/// blueprint is a machine. Only a blueprint is assignable to a node, which is
/// the distinction that justifies the two names.
///
/// Applying one transforms an unmanaged server into this state and keeps it
/// there. Re-applying does nothing, because every resource declares what it
/// should *be* rather than what to do to it.
@immutable
class Blueprint {
  /// The blueprint identity.
  final BlueprintId id;

  /// A human-friendly name.
  final String name;

  /// A short description of what this kind of server is for.
  final String description;

  /// The OS families this blueprint is written for. Empty means all.
  final List<String> platforms;

  /// Presets to fold in, in order, before [resources].
  ///
  /// Unpinned: an include names a preset and tracks whatever that preset
  /// currently is. Editing a shared preset therefore re-resolves every blueprint
  /// that includes it, and every node assigned to one reports drift on its next
  /// plan — which is the point of sharing, and the hazard of it. Nothing is
  /// applied without somebody asking.
  final List<PresetId> includes;

  /// `${name}` substitutions applied to every string in [resources].
  ///
  /// Substitution and nothing else: no loops, no conditionals, no expressions.
  /// A blueprint that needs logic needs a formula, and that is a feature — a
  /// templating language is a second program that nobody can debug from a
  /// dashboard.
  final Map<String, String> vars;

  /// This blueprint's own resources, applied on top of everything [includes]
  /// brought in.
  final List<Resource> resources;

  /// The document as it was authored, when it came from a file.
  final BlueprintSource? source;

  /// Creates a blueprint.
  const Blueprint({
    required this.id,
    required this.name,
    this.description = '',
    this.platforms = const [],
    this.includes = const [],
    this.vars = const {},
    this.resources = const [],
    this.source,
  });

  /// Whether this blueprint is written for [platform] (an `osName`).
  bool supportsPlatform(String platform) =>
      platforms.isEmpty || platforms.contains(platform);

  /// A copy carrying [source].
  Blueprint withSource(BlueprintSource source) => Blueprint(
    id: id,
    name: name,
    description: description,
    platforms: platforms,
    includes: includes,
    vars: vars,
    resources: resources,
    source: source,
  );

  /// JSON form.
  ///
  /// The key is `blueprint`, not `id`, because this doubles as the authoring
  /// form and `blueprint: web-server` reads as a heading at the top of a file.
  /// `id` is accepted when decoding.
  Map<String, dynamic> toJson() => {
    'blueprint': id.value,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    if (platforms.isNotEmpty) 'platforms': platforms,
    if (includes.isNotEmpty) 'includes': [for (final i in includes) i.value],
    if (vars.isNotEmpty) 'vars': vars,
    'resources': [for (final r in resources) r.toJson()],
    if (source != null) 'source': source!.toJson(),
  };

  /// Decodes from JSON.
  static Blueprint fromJson(Map<String, dynamic> json) {
    final id = BlueprintId(
      Json.optString(json, 'blueprint') ?? Json.requireString(json, 'id'),
    );
    final source = json['source'];
    return Blueprint(
      id: id,
      name: Json.optString(json, 'name') ?? id.value,
      description: Json.optString(json, 'description') ?? '',
      platforms: Json.optStringList(json, 'platforms'),
      includes: [
        for (final i in Json.optStringList(json, 'includes')) PresetId(i),
      ],
      vars: Json.optStringMap(json, 'vars'),
      resources: Json.optObjectList(
        json,
        'resources',
      ).map(Resource.fromJson).toList(),
      source: source is Map
          ? BlueprintSource.fromJson(source.cast<String, dynamic>())
          : null,
    );
  }

  @override
  String toString() =>
      'Blueprint(${id.value}, ${includes.length} includes, '
      '${resources.length} resources)';
}
