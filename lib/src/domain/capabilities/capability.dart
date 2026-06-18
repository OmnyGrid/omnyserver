import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

/// The well-known kinds of capability a node can advertise.
///
/// `custom` is the escape hatch for site-specific capabilities that are not in
/// this enum; the human-readable name is then carried by [Capability.name].
enum CapabilityKind {
  /// Docker container engine.
  docker,

  /// Podman container engine.
  podman,

  /// Dart SDK.
  dart,

  /// Python interpreter.
  python,

  /// Java runtime / JDK.
  java,

  /// Node.js runtime.
  nodejs,

  /// NVIDIA CUDA GPU compute.
  cuda,

  /// Apple Metal GPU compute.
  metal,

  /// OpenCL GPU/accelerator compute.
  opencl,

  /// Git version control.
  git,

  /// OpenSSH client/server.
  ssh,

  /// A site-specific capability not covered by the other kinds.
  custom;

  /// Parses a wire name to a [CapabilityKind], defaulting to [custom].
  static CapabilityKind parse(String value) => CapabilityKind.values.firstWhere(
    (k) => k.name == value,
    orElse: () => CapabilityKind.custom,
  );
}

/// A single detected capability of a node, optionally with a version and
/// free-form details (e.g. the GPU model for `cuda`).
@immutable
class Capability {
  /// The capability kind.
  final CapabilityKind kind;

  /// The capability name (equals `kind.name` for well-known kinds, or a
  /// site-specific token for [CapabilityKind.custom]).
  final String name;

  /// The detected version, if known (e.g. `'24.0.7'` for Docker).
  final String? version;

  /// Arbitrary extra detail (e.g. `{'gpu': 'RTX 4090'}`).
  final Map<String, String> details;

  /// Creates a capability.
  const Capability({
    required this.kind,
    required this.name,
    this.version,
    this.details = const {},
  });

  /// Creates a capability for a well-known [kind] (name derived from the kind).
  factory Capability.of(
    CapabilityKind kind, {
    String? version,
    Map<String, String> details = const {},
  }) => Capability(
    kind: kind,
    name: kind.name,
    version: version,
    details: details,
  );

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'name': name,
    if (version != null) 'version': version,
    if (details.isNotEmpty) 'details': details,
  };

  /// Decodes from JSON.
  static Capability fromJson(Map<String, dynamic> json) => Capability(
    kind: CapabilityKind.parse(Json.requireString(json, 'kind')),
    name: Json.optString(json, 'name') ?? Json.requireString(json, 'kind'),
    version: Json.optString(json, 'version'),
    details: Json.optStringMap(json, 'details'),
  );

  @override
  bool operator ==(Object other) =>
      other is Capability &&
      other.kind == kind &&
      other.name == name &&
      other.version == version;

  @override
  int get hashCode => Object.hash(kind, name, version);

  @override
  String toString() => 'Capability($name${version != null ? '@$version' : ''})';
}
