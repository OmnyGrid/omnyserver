import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the OmnyServer home directory (`~/.omnyserver` by default), where
/// identity, credentials and local state live.
///
/// The location can be overridden with the `OMNYSERVER_HOME` environment
/// variable, which is convenient for tests and for running multiple isolated
/// instances on one machine.
class OmnyServerHome {
  const OmnyServerHome._();

  /// The resolved home directory path.
  static String resolve({String? override}) {
    final fromArg = override ?? Platform.environment['OMNYSERVER_HOME'];
    if (fromArg != null && fromArg.trim().isNotEmpty) return fromArg;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return p.join(home, '.omnyserver');
  }

  /// Ensures the home directory exists and returns it.
  static Directory ensure({String? override}) {
    final dir = Directory(resolve(override: override));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
}
