import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';

/// Builds a release bundle in memory. [files] maps a path to its content;
/// [modes] gives some of them unix permissions.
List<int> zipOf(
  Map<String, String> files, {
  Map<String, int> modes = const {},
}) {
  final archive = Archive();
  for (final entry in files.entries) {
    final file = ArchiveFile.string(entry.key, entry.value);
    final mode = modes[entry.key];
    if (mode != null) file.mode = mode;
    archive.addFile(file);
  }
  return ZipEncoder().encode(archive);
}

/// The lowercase hex SHA-256 of [bytes] — what a blueprint's `sha256` says.
String sha256Of(List<int> bytes) => [
  for (final b in Sha256().toSync().hashSync(bytes).bytes)
    b.toRadixString(16).padLeft(2, '0'),
].join();
