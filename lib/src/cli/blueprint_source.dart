/// Turning an authored blueprint document into a [Blueprint].
///
/// Deliberately free of `dart:io`: the browser authors blueprints too, and this
/// is the half it needs. Reading a *file* is the other half, and lives in
/// `blueprint_format.dart`, which the web barrel must never reach —
/// `web_barrel_dart_io_free_test` enforces that, because dart2js emits no output
/// at all for an entrypoint whose graph touches an unsupported SDK library, and
/// a blank page looks exactly like a successful build.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart' as yaml;

import '../domain/blueprint/blueprint.dart';
import '../shared/errors/omnyserver_exception.dart';

/// Parses a blueprint written in [format].
///
/// A blueprint's format is fixed when it is authored and never converted, so
/// the caller says which one this is rather than the parser sniffing for it. A
/// sniffed format is one that changes when somebody adds a comment.
///
/// [origin] names the document in any failure — a file path, or something like
/// `the editor` when there is no file. Without it "unexpected character" sends
/// the reader looking in the wrong place.
///
/// The parsed blueprint carries its own [BlueprintSource], so whatever is saved
/// can be handed back exactly as it was written, comments and all.
Blueprint parseBlueprint(
  String text,
  BlueprintFormat format, {
  String origin = 'the blueprint',
}) {
  final decoded = switch (format) {
    BlueprintFormat.yaml => _parseYaml(text, origin),
    BlueprintFormat.json => _parseJson(text, origin),
  };

  return Blueprint.fromJson(
    decoded,
  ).withSource(BlueprintSource(format: format, text: text));
}

/// The format a file extension names.
///
/// Anything that is not `.yaml`/`.yml` is read as JSON — the wire's own format,
/// and the right assumption for a file with no extension at all.
BlueprintFormat blueprintFormatOf(String path) {
  final dot = path.lastIndexOf('.');
  final extension = dot == -1 ? '' : path.substring(dot).toLowerCase();
  return extension == '.yaml' || extension == '.yml'
      ? BlueprintFormat.yaml
      : BlueprintFormat.json;
}

Map<String, dynamic> _parseJson(String text, String origin) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw ProtocolException('$origin is not valid JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw ProtocolException(
      '$origin should hold a blueprint object, not a ${decoded.runtimeType}',
    );
  }
  return decoded.cast<String, dynamic>();
}

Map<String, dynamic> _parseYaml(String text, String origin) {
  final Object? decoded;
  try {
    decoded = yaml.loadYaml(text);
  } on yaml.YamlException catch (e) {
    throw ProtocolException('$origin is not valid YAML: ${e.message}');
  }
  if (decoded is! yaml.YamlMap) {
    throw ProtocolException(
      '$origin should hold a blueprint, not a list or a scalar',
    );
  }
  // `YamlMap` is a `Map`, but a `Map<dynamic, dynamic>` whose nested values are
  // `YamlMap` and `YamlList`. Everything downstream decodes plain JSON types, so
  // convert once here rather than teaching every `fromJson` about YAML.
  return _plain(decoded)! as Map<String, dynamic>;
}

/// Recursively converts YAML nodes to the plain maps and lists `fromJson`
/// expects.
Object? _plain(Object? node) => switch (node) {
  yaml.YamlMap map => {
    for (final entry in map.entries) '${entry.key}': _plain(entry.value),
  },
  yaml.YamlList list => [for (final item in list) _plain(item)],
  _ => node,
};
