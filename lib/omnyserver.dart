/// OmnyServer core: the shared domain model, protocol, transport contract and
/// utilities used by the Hub, the Node agent and the CLI.
///
/// Import the role-specific libraries for the runtimes:
/// `omnyserver_hub.dart`, `omnyserver_node.dart`, `omnyserver_cli.dart`.
library;

// Version.
export 'src/version.dart';

// Shared.
export 'src/shared/errors/error_codes.dart';
export 'src/shared/errors/omnyserver_exception.dart';
export 'src/shared/json/json_codec_helpers.dart';
export 'src/shared/utils/clock.dart';
export 'src/shared/utils/id_generator.dart';
export 'src/shared/utils/omnyserver_home.dart';

// Value objects.
export 'src/domain/value_objects/ed25519_public_key.dart';
export 'src/domain/value_objects/formula_id.dart';
export 'src/domain/value_objects/node_id.dart';
export 'src/domain/value_objects/omny_uid.dart';
export 'src/domain/value_objects/preset_id.dart';
export 'src/domain/value_objects/principal_id.dart';

// Entities.
export 'src/domain/capabilities/capability.dart';
export 'src/domain/entities/audit_entry.dart';
export 'src/domain/entities/formula_spec.dart';
export 'src/domain/entities/heartbeat.dart';
export 'src/domain/entities/node_capabilities.dart';
export 'src/domain/entities/node_descriptor.dart';
export 'src/domain/entities/node_status.dart';
export 'src/domain/entities/platform_info.dart';
export 'src/domain/entities/preset.dart';
export 'src/domain/entities/resource_metrics.dart';
export 'src/domain/entities/service_descriptor.dart';

// Auth contracts.
export 'src/domain/auth/authenticator.dart';
export 'src/domain/auth/credential.dart';
export 'src/domain/auth/principal.dart';

// Capabilities, formula, state contracts.
export 'src/domain/capabilities/capability_detector.dart';
export 'src/domain/formula/formula.dart';
export 'src/domain/formula/formula_action.dart';
export 'src/domain/formula/formula_context.dart';
export 'src/domain/formula/formula_result.dart';
export 'src/domain/state/desired_state.dart';
export 'src/domain/state/state_reconciler.dart';

// Repositories.
export 'src/domain/repository/repositories.dart';

// Events.
export 'src/domain/events/event_bus.dart';
export 'src/domain/events/omny_event.dart';

// Protocol.
export 'src/protocol/control_message.dart';
export 'src/protocol/control_message_codec.dart';
export 'src/protocol/handshake.dart';
export 'src/protocol/operations.dart';
export 'src/protocol/protocol_version.dart';
