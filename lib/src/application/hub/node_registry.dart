import '../../domain/auth/principal.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../domain/entities/node_status.dart';
import '../../domain/value_objects/node_id.dart';
import '../../protocol/omny_connection.dart';

/// The Hub's live record of a connected (or recently-disconnected) node.
class RegisteredNode {
  /// The node's descriptor (identity, platform, capabilities, labels).
  NodeDescriptor descriptor;

  /// The authenticated principal behind the node connection.
  final Principal principal;

  /// The live connection to the node, or `null` once offline.
  OmnyConnection? connection;

  /// When the last heartbeat was received (UTC).
  DateTime lastHeartbeatAt;

  /// The highest heartbeat sequence seen.
  int lastSequence;

  /// The most recent live status snapshot, if any.
  NodeStatus? lastStatus;

  /// Creates a registered-node record.
  RegisteredNode({
    required this.descriptor,
    required this.principal,
    required this.connection,
    required this.lastHeartbeatAt,
    this.lastSequence = 0,
    this.lastStatus,
  });
}

/// The in-memory index of nodes known to the Hub, keyed by [NodeId].
///
/// Holds both the persistable [NodeDescriptor] and the transient live state
/// (connection, last heartbeat, last status). Persistence is layered on top via
/// a `NodeRepository`.
class NodeRegistry {
  final Map<String, RegisteredNode> _nodes = {};

  /// All registered nodes.
  Iterable<RegisteredNode> get nodes => _nodes.values;

  /// All node descriptors (the API/CLI view).
  List<NodeDescriptor> descriptors() =>
      _nodes.values.map((n) => n.descriptor).toList();

  /// The record for [id], or `null`.
  RegisteredNode? byId(NodeId id) => _nodes[id.value];

  /// Inserts or replaces the record for a node.
  void upsert(RegisteredNode node) => _nodes[node.descriptor.id.value] = node;

  /// Marks a node offline (keeps its descriptor for history) and drops the
  /// live connection. Returns the record if it existed.
  RegisteredNode? markOffline(NodeId id) {
    final node = _nodes[id.value];
    if (node == null) return null;
    node.connection = null;
    node.descriptor = node.descriptor.copyWith(online: false);
    return node;
  }

  /// Removes a node entirely.
  bool remove(NodeId id) => _nodes.remove(id.value) != null;

  /// The number of currently-online nodes.
  int get onlineCount => _nodes.values.where((n) => n.descriptor.online).length;
}
