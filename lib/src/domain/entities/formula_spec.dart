import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../formula/formula_action.dart';
import '../value_objects/formula_id.dart';

/// Declarative metadata describing a formula: its identity, the platforms it
/// supports, the actions it implements and an optional target version.
///
/// The executable behaviour lives in a `Formula` implementation; this spec is
/// the persistable, transportable description used by presets and the Hub.
@immutable
class FormulaSpec {
  /// The formula identity (e.g. `docker`, `dart`).
  final FormulaId id;

  /// A human-friendly name.
  final String name;

  /// A short description of what the formula manages.
  final String description;

  /// The target version to converge to, if pinned.
  final String? version;

  /// The OS families this formula supports (e.g. `linux`, `macos`, `windows`).
  /// An empty list means "all platforms".
  final List<String> supportedPlatforms;

  /// The actions this formula implements.
  final Set<FormulaAction> actions;

  /// Creates a formula spec.
  const FormulaSpec({
    required this.id,
    required this.name,
    this.description = '',
    this.version,
    this.supportedPlatforms = const [],
    this.actions = const {
      FormulaAction.install,
      FormulaAction.update,
      FormulaAction.uninstall,
      FormulaAction.verify,
    },
  });

  /// Whether this formula supports [platform] (`osName`).
  bool supportsPlatform(String platform) =>
      supportedPlatforms.isEmpty || supportedPlatforms.contains(platform);

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'id': id.value,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    if (version != null) 'version': version,
    if (supportedPlatforms.isNotEmpty) 'supportedPlatforms': supportedPlatforms,
    'actions': actions.map((a) => a.name).toList(),
  };

  /// Decodes from JSON.
  static FormulaSpec fromJson(Map<String, dynamic> json) => FormulaSpec(
    id: FormulaId(Json.requireString(json, 'id')),
    name: Json.optString(json, 'name') ?? Json.requireString(json, 'id'),
    description: Json.optString(json, 'description') ?? '',
    version: Json.optString(json, 'version'),
    supportedPlatforms: Json.optStringList(json, 'supportedPlatforms'),
    actions: Json.optStringList(
      json,
      'actions',
    ).map(FormulaAction.parse).toSet(),
  );

  @override
  String toString() => 'FormulaSpec(${id.value})';
}
