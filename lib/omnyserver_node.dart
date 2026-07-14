/// OmnyServer Node agent: runs on each managed server. Connects to the Hub
/// over WSS, maintains a heartbeat, reports live status and capabilities, and
/// executes commands, formulas and presets.
///
/// Re-exports the core API (`omnyserver.dart`) plus the agent runtime and its
/// node-side infrastructure.
library;

export 'omnyserver.dart';

// Agent runtime.
export 'src/application/node/agent_state.dart';
export 'src/application/node/formula_registry.dart';
export 'src/application/node/log_shipper.dart';
export 'src/application/node/node_agent.dart';
export 'src/application/node/node_agent_config.dart';
export 'src/application/node/node_formula_service.dart';
export 'src/application/node/node_service_handler.dart';
export 'src/application/node/update_service.dart';

// Service management.
export 'src/infrastructure/service/service_controller.dart';

// Formula engine.
export 'src/infrastructure/formulas/command_executor.dart';
export 'src/infrastructure/formulas/command_formula.dart';
export 'src/infrastructure/formulas/dart_formula.dart';
export 'src/infrastructure/formulas/docker_formula.dart';
export 'src/infrastructure/state/default_reconciler.dart';

// Credentials.
export 'src/infrastructure/auth/credential_provider.dart';

// Monitoring.
export 'src/infrastructure/monitors/monitor_parsers.dart';
export 'src/infrastructure/monitors/system_monitor.dart';

// Capability detection.
export 'src/infrastructure/capabilities/capability_scanner.dart';
export 'src/infrastructure/capabilities/command_detector.dart';
export 'src/infrastructure/capabilities/gpu_detectors.dart';

// Transport (client connection adapter).
export 'src/application/node/node_handshake.dart';

// Identity.
export 'src/infrastructure/identity/machine_id.dart';
export 'src/infrastructure/identity/uid_computer.dart';
