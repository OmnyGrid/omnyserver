import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../capabilities/capability.dart';

/// The set of capabilities a node advertises, keyed by capability name.
@immutable
class NodeCapabilities {
  /// The advertised capabilities (de-duplicated by name).
  final List<Capability> capabilities;

  /// Creates a capability set.
  const NodeCapabilities(this.capabilities);

  /// An empty capability set.
  static const NodeCapabilities empty = NodeCapabilities(<Capability>[]);

  /// Whether a capability of [kind] is present.
  bool has(CapabilityKind kind) => capabilities.any((c) => c.kind == kind);

  /// Whether a capability with [name] is present.
  bool hasNamed(String name) => capabilities.any((c) => c.name == name);

  /// Returns the capability with [name], or `null`.
  Capability? named(String name) {
    for (final c in capabilities) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'capabilities': capabilities.map((c) => c.toJson()).toList(),
  };

  /// Decodes from JSON.
  static NodeCapabilities fromJson(Map<String, dynamic> json) =>
      NodeCapabilities(
        Json.optObjectList(
          json,
          'capabilities',
        ).map(Capability.fromJson).toList(),
      );

  @override
  String toString() =>
      'NodeCapabilities(${capabilities.map((c) => c.name).join(', ')})';
}
