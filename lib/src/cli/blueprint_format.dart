import 'dart:io';

import '../domain/blueprint/blueprint.dart';
import '../shared/errors/omnyserver_exception.dart';
import 'blueprint_source.dart';
import 'cli_error.dart';

/// Reads a blueprint from a file, in whichever format it was written in.
///
/// A blueprint's format is fixed when it is authored. A `.yaml` file stays
/// YAML — shown, edited and re-saved as the YAML somebody wrote, comments and
/// all — and a `.json` file stays JSON. The two are never mixed within one
/// document, and the source travels with the parsed form so the Hub can hand it
/// back exactly as received.
///
/// The *parsing* lives in `blueprint_source.dart`, which is free of `dart:io`
/// so the dashboard can author blueprints too. Only the file reading is here,
/// and only this half is CLI-only.
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

    try {
      return parseBlueprint(
        await file.readAsString(),
        formatOf(path),
        origin: path,
      );
    } on ProtocolException catch (e) {
      // A malformed file is the operator's problem with *their* file, not a
      // protocol failure to be rendered with a stack trace.
      throw CliError(e.message);
    }
  }

  /// The format [path]'s extension names.
  static BlueprintFormat formatOf(String path) => blueprintFormatOf(path);
}
