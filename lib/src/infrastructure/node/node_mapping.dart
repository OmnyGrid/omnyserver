import 'package:omnyhub/omnyhub.dart' as omnyhub;

import '../../domain/entities/node_descriptor.dart';
import '../../domain/value_objects/node_id.dart';
import '../../shared/errors/omnyserver_exception.dart';

/// The key OmnyServer's full descriptor is advertised under, inside omnyhub's
/// free-form [omnyhub.NodeDescriptor.attributes].
const String descriptorAttribute = 'omnyserver';

/// Translates between OmnyServer's node descriptor and omnyhub's.
///
/// omnyhub's descriptor is deliberately thin — an id, a flat capability set,
/// string labels — because that is all its registry and discovery need to reason
/// about. OmnyServer's carries a platform profile, structured capabilities and a
/// content-derived uid, none of which omnyhub has an opinion on. So the full
/// descriptor travels as JSON in `attributes`, and the parts omnyhub *can* use
/// are mirrored into its own fields so discovery keeps working.
extension NodeDescriptorMapping on NodeDescriptor {
  /// The omnyhub descriptor this node advertises at registration.
  omnyhub.NodeDescriptor toHub() => omnyhub.NodeDescriptor(
    id: omnyhub.NodeId(id.value),
    // Mirrored so `NodeGateway.discover(capability: …)` works on OmnyServer
    // nodes without teaching omnyhub about CapabilityKind.
    capabilities: capabilities.capabilities.map((c) => c.name).toSet(),
    labels: labels,
    agentVersion: platform.agentVersion,
    attributes: {descriptorAttribute: toJson()},
  );
}

/// Recovers OmnyServer's descriptor from an omnyhub [descriptor].
///
/// Throws [ProtocolException] if the node did not advertise one — it is not an
/// OmnyServer node, and nothing downstream can treat it as one.
NodeDescriptor nodeDescriptorFrom(omnyhub.NodeDescriptor descriptor) {
  final raw = descriptor.attributes[descriptorAttribute];
  if (raw is! Map) {
    throw ProtocolException(
      'node ${descriptor.id.value} did not advertise an OmnyServer descriptor',
    );
  }
  final parsed = NodeDescriptor.fromJson(raw.cast<String, dynamic>());
  // omnyhub owns liveness, so its view of online/offline wins over whatever the
  // node advertised about itself.
  return parsed.copyWith(
    online: descriptor.status == omnyhub.NodeStatus.online,
  );
}

/// The omnyhub id for [id].
omnyhub.NodeId toHubId(NodeId id) => omnyhub.NodeId(id.value);
