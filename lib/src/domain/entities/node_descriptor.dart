import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../value_objects/node_id.dart';
import '../value_objects/omny_uid.dart';
import 'node_capabilities.dart';
import 'platform_info.dart';

/// The Hub's view of a registered node: its identity, platform, advertised
/// capabilities, operator labels and live online flag.
@immutable
class NodeDescriptor {
  /// The operator-chosen node id.
  final NodeId id;

  /// The content-derived unique identity, if known.
  final OmnyUid? uid;

  /// A human-friendly display name.
  final String displayName;

  /// Static platform facts.
  final PlatformInfo platform;

  /// Operator-supplied labels (e.g. `{'env': 'prod', 'region': 'eu'}`).
  final Map<String, String> labels;

  /// Whether the node is currently connected.
  final bool online;

  /// The node's advertised capabilities.
  final NodeCapabilities capabilities;

  /// When the node last registered or reconnected (UTC), if known.
  final DateTime? registeredAt;

  /// Creates a node descriptor.
  const NodeDescriptor({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.online,
    this.uid,
    this.labels = const {},
    this.capabilities = NodeCapabilities.empty,
    this.registeredAt,
  });

  /// Returns a copy with selected fields replaced.
  NodeDescriptor copyWith({
    bool? online,
    NodeCapabilities? capabilities,
    Map<String, String>? labels,
    String? displayName,
    OmnyUid? uid,
    PlatformInfo? platform,
    DateTime? registeredAt,
  }) => NodeDescriptor(
    id: id,
    uid: uid ?? this.uid,
    displayName: displayName ?? this.displayName,
    platform: platform ?? this.platform,
    online: online ?? this.online,
    labels: labels ?? this.labels,
    capabilities: capabilities ?? this.capabilities,
    registeredAt: registeredAt ?? this.registeredAt,
  );

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'nodeId': id.value,
    if (uid != null) 'uid': uid!.value,
    'displayName': displayName,
    'platform': platform.toJson(),
    if (labels.isNotEmpty) 'labels': labels,
    'online': online,
    'capabilities': capabilities.toJson(),
    if (registeredAt != null)
      'registeredAt': registeredAt!.toUtc().toIso8601String(),
  };

  /// Decodes from JSON.
  static NodeDescriptor fromJson(Map<String, dynamic> json) {
    final caps = json['capabilities'];
    final uidValue = Json.optString(json, 'uid');
    return NodeDescriptor(
      id: NodeId(Json.requireString(json, 'nodeId')),
      uid: uidValue == null ? null : OmnyUid(uidValue),
      displayName: Json.optString(json, 'displayName') ?? '',
      platform: PlatformInfo.fromJson(
        Json.asObject(json['platform'], 'platform'),
      ),
      labels: Json.optStringMap(json, 'labels'),
      online: Json.optBool(json, 'online'),
      capabilities: caps == null
          ? NodeCapabilities.empty
          : NodeCapabilities.fromJson(Json.asObject(caps, 'capabilities')),
      registeredAt: Json.optTimestamp(json, 'registeredAt'),
    );
  }

  @override
  String toString() => 'NodeDescriptor(${id.value}, online: $online)';
}
