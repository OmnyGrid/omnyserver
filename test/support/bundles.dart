import 'dart:convert';
import 'dart:typed_data';

// `show`, because newer `archive` releases export a `Sha256` of their own.
import 'package:archive/archive.dart'
    show Archive, ArchiveFile, ZipEncoder, getCrc32;
import 'package:cryptography/cryptography.dart' show Sha256;

/// One entry of a hand-built zip: a file, a directory (name ending in `/`), or
/// a symlink whose [data] is its target.
typedef RawEntry = ({String name, String data, int mode});

/// A file entry.
RawEntry rawFile(String name, String data) =>
    (name: name, data: data, mode: 0x81a4); // regular, 0644

/// A directory entry.
RawEntry rawDir(String name) =>
    (name: name.endsWith('/') ? name : '$name/', data: '', mode: 0x41ed);

/// A symlink entry pointing at [target].
RawEntry rawLink(String name, String target) =>
    (name: name, data: target, mode: 0xa1ff); // symlink, 0777

/// Writes a stored (uncompressed) zip from [entries], in order, with unix
/// modes — which is all a symlink entry is.
///
/// Hand-built because the interesting archives are the malicious ones:
/// `archive`'s encoder cannot write a symlink at all, and `zip -y` can only
/// record a tree that exists on disk, which a chain of links through each
/// other never does.
List<int> rawZip(List<RawEntry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

  for (final e in entries) {
    final name = utf8.encode(e.name);
    final data = utf8.encode(e.data);
    final crc = getCrc32(data);
    final offset = out.length;

    u32(out, 0x04034b50);
    u16(out, 20); // version needed
    u16(out, 0); // flags
    u16(out, 0); // stored
    u16(out, 0); // time
    u16(out, 0x21); // date: 1980-01-01
    u32(out, crc);
    u32(out, data.length);
    u32(out, data.length);
    u16(out, name.length);
    u16(out, 0);
    out
      ..add(name)
      ..add(data);

    u32(central, 0x02014b50);
    u16(central, (3 << 8) | 20); // made by unix
    u16(central, 20);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0x21);
    u32(central, crc);
    u32(central, data.length);
    u32(central, data.length);
    u16(central, name.length);
    u16(central, 0); // extra
    u16(central, 0); // comment
    u16(central, 0); // disk
    u16(central, 0); // internal attrs
    u32(central, e.mode << 16); // external attrs: the unix mode
    u32(central, offset);
    central.add(name);
  }

  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, entries.length);
  u16(out, entries.length);
  u32(out, centralBytes.length);
  u32(out, centralOffset);
  u16(out, 0);
  return out.takeBytes();
}

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
