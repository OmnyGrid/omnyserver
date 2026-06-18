/// OmnyServer Hub: the central orchestrator. Registers nodes, authenticates
/// peers, aggregates live status and events, and drives presets/formulas.
///
/// Re-exports the core API (`omnyserver.dart`) plus the Hub runtime and its
/// server-side infrastructure.
library;

export 'omnyserver.dart';

// Hub runtime.
export 'src/application/hub/audit_log.dart';
export 'src/application/hub/event_aggregator.dart';
export 'src/application/hub/hub_config.dart';
export 'src/application/hub/hub_metrics.dart';
export 'src/application/hub/node_registry.dart';
export 'src/application/hub/omny_server_hub.dart';

// Metrics.
export 'src/infrastructure/metrics/metrics_registry.dart';

// HTTP API.
export 'src/infrastructure/http/api_errors.dart' show jsonOk;
export 'src/infrastructure/http/http_api_server.dart';
export 'src/infrastructure/http/openapi.dart';

// Persistence (in-memory, JSON-directory and SQLite backends).
export 'src/infrastructure/persistence/memory/memory_repositories.dart';
export 'src/infrastructure/persistence/json_directory/json_directory_repositories.dart';
export 'src/infrastructure/persistence/sqlite/sqlite_repositories.dart';

// Transport (server endpoint + connection adapter).
export 'src/infrastructure/transport/web_socket_connection.dart';
export 'src/infrastructure/transport/ws_server_endpoint.dart';

// Auth infrastructure.
export 'src/infrastructure/auth/authorized_keys_store.dart';
export 'src/infrastructure/auth/composite_authenticator.dart';
export 'src/infrastructure/auth/public_key_authenticator.dart';
export 'src/infrastructure/auth/role_based_authorizer.dart';
export 'src/infrastructure/auth/token_authenticator.dart';

// Identity & TLS.
export 'src/infrastructure/identity/machine_id.dart';
export 'src/infrastructure/identity/uid_computer.dart';
export 'src/infrastructure/tls/cert_generator.dart';
