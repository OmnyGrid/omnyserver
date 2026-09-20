import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart' as yaml;

import '../domain/blueprint/blueprint.dart';
import 'cli_error.dart';

/// Reads a blueprint from a file, in whichever format it was written in.
///
/// A blueprint's format is fixed when it is authored and never converted
/// afterwards. A `.yaml` file stays YAML — shown, edited and re-saved as the
/// YAML somebody wrote, comments and all — and a `.json` file stays JSON. The
/// two are never mixed within one document, and the source travels with the
/// parsed form so the Hub can hand it back exactly as received.
///
/// Only the CLI reads files. The Hub, the wire and the repositories are JSON
/// throughout, where there is nothing human to mix — which is also why this
/// file must stay out of the web barrel's import graph.
class BlueprintFile {
  const BlueprintFile._();

  /// Parses the blueprint at [path].
  ///
  /// The extension decides the format; content is never sniffed. A sniffed
  /// format is one that changes when somebody adds a comment, and the whole
  /// point of fixing it at authoring time is that it does not move.
  static Future<Blueprint> read(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw CliError('blueprint file not found: $path');
    }

    final text = await file.readAsString();
    final format = formatOf(path);
    final decoded = format == BlueprintFormat.yaml
        ? _parseYaml(text, path)
        : _parseJson(text, path);

    return Blueprint.fromJson(
      decoded,
    ).withSource(BlueprintSource(format: format, text: text));
  }

  /// The format [path]'s extension names.
  ///
  /// Anything that is not `.yaml`/`.yml` is read as JSON — the wire's own
  /// format, and the right assumption for a file with no extension at all.
  static BlueprintFormat formatOf(String path) {
    final extension = p.extension(path).toLowerCase();
    return extension == '.yaml' || extension == '.yml'
        ? BlueprintFormat.yaml
        : BlueprintFormat.json;
  }

  static Map<String, dynamic> _parseJson(String text, String path) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw CliError('$path is not valid JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw CliError(
        '$path should hold a blueprint object, not a ${decoded.runtimeType}',
      );
    }
    return decoded.cast<String, dynamic>();
  }

  static Map<String, dynamic> _parseYaml(String text, String path) {
    final Object? decoded;
    try {
      decoded = yaml.loadYaml(text);
    } on yaml.YamlException catch (e) {
      throw CliError('$path is not valid YAML: ${e.message}');
    }
    if (decoded is! yaml.YamlMap) {
      throw CliError('$path should hold a blueprint, not a list or a scalar');
    }
    // YamlMap is a Map, but a Map<dynamic, dynamic> whose nested values are
    // YamlMap and YamlList. Everything downstream decodes plain JSON types, so
    // convert once here rather than teaching every `fromJson` about YAML.
    return _plain(decoded) as Map<String, dynamic>;
  }

  /// Recursively converts YAML nodes to the plain maps and lists `fromJson`
  /// expects.
  static Object? _plain(Object? node) => switch (node) {
    yaml.YamlMap map => {
      for (final entry in map.entries) '${entry.key}': _plain(entry.value),
    },
    yaml.YamlList list => [for (final item in list) _plain(item)],
    _ => node,
  };
}
