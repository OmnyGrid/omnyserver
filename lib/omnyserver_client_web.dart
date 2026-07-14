/// OmnyServer for the browser: the REST client and the domain model it decodes.
///
/// The browser-safe subset of the package. A web dashboard imports **this**,
/// never `omnyserver.dart` or `omnyserver_hub.dart`, which reach `dart:io` —
/// and that distinction is load-bearing rather than stylistic: `dart2js` emits
/// *no output at all* for an entrypoint whose graph touches an unsupported SDK
/// library, so a stray import is not a compile error but a silently empty build.
/// `test/unit/web_barrel_dart_io_free_test.dart` walks this barrel's import graph
/// and fails if anything creeps back in.
///
/// What you get:
///
/// * [HubApiClient] — the same client the CLI drives the Hub with, so the
///   dashboard exercises exactly the public API surface any other client does.
///   In a browser it sends with `fetch`; inject an [ApiTransport] to drive it
///   against a fake Hub in tests.
/// * The entities the API returns — [NodeDescriptor], [NodeStatus] (with
///   [CpuInfo], [MemoryInfo], [StorageDevice], [ProcessInfo]), [PlatformInfo],
///   [NodeCapabilities], [Preset], [FormulaResult], [OmnyEvent], [AuditEntry] —
///   decoded with the very `fromJson` the Hub encodes with, so there is no
///   second, drifting copy of the wire format in the web app.
///
/// Two things the browser does not get, and cannot:
///
/// * **TLS options.** The browser owns its TLS stack: a self-signed Hub
///   certificate has to be trusted at the OS or browser level, and there is no
///   in-page bypass to offer.
/// * **`PlatformInfo.local()`.** A node runs on a machine; a page is a client of
///   one. It throws.
///
/// The Hub must allow the app's origin (`hub start --cors-origin …`) or the
/// browser blocks every response before this code sees it.
library;

// The API client and its transport seam.
export 'src/cli/api_client.dart';
export 'src/cli/api_transport.dart';

// Version.
export 'src/version.dart';

// Shared. (`omnyserver_home.dart` is deliberately absent — it reads the
// environment, and a browser has none.)
export 'src/shared/errors/error_codes.dart';
export 'src/shared/errors/omnyserver_exception.dart';
export 'src/shared/json/json_codec_helpers.dart';
export 'src/shared/utils/clock.dart';

// Value objects.
export 'src/domain/value_objects/formula_id.dart';
export 'src/domain/value_objects/node_id.dart';
export 'src/domain/value_objects/omny_uid.dart';
export 'src/domain/value_objects/preset_id.dart';
export 'src/domain/value_objects/principal_id.dart';

// Entities — what the API returns.
export 'src/domain/capabilities/capability.dart';
export 'src/domain/entities/audit_entry.dart';
export 'src/domain/entities/formula_spec.dart';
export 'src/domain/entities/grant.dart';
export 'src/domain/entities/heartbeat.dart';
export 'src/domain/entities/log_line.dart';
export 'src/domain/entities/metric_point.dart';
export 'src/domain/entities/node_capabilities.dart';
export 'src/domain/entities/node_descriptor.dart';
export 'src/domain/entities/node_status.dart';
export 'src/domain/entities/platform_info.dart';
export 'src/domain/entities/preset.dart';
export 'src/domain/state/desired_state.dart';
export 'src/domain/state/drift.dart';
export 'src/domain/entities/resource_metrics.dart';
export 'src/domain/entities/service_descriptor.dart';

// Identity and events.
export 'src/domain/auth/principal.dart';
export 'src/domain/events/omny_event.dart';
export 'src/domain/formula/formula_action.dart';
export 'src/domain/formula/formula_result.dart';

// Operation results (`FormulaRunResult`, `PresetApplyResult`).
export 'src/protocol/operations.dart';
