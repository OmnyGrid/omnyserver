import 'dart:async';
import 'dart:convert';

import '../domain/blueprint/blueprint.dart';
import '../domain/blueprint/resolved_blueprint.dart';
import '../domain/entities/alert.dart';
import '../domain/entities/audit_entry.dart';
import '../domain/entities/formula_spec.dart';
import '../domain/entities/grant.dart';
import '../domain/entities/log_line.dart';
import '../domain/entities/metric_point.dart';
import '../domain/entities/node_capabilities.dart';
import '../domain/entities/node_descriptor.dart';
import '../domain/entities/node_status.dart';
import '../domain/entities/operation.dart';
import '../domain/entities/preset.dart';
import '../domain/events/omny_event.dart';
import '../domain/formula/formula_action.dart';
import '../domain/formula/formula_status.dart';
import '../domain/state/desired_state.dart';
import '../domain/state/drift.dart';
import '../protocol/operations.dart';
import 'api_results.dart';
import 'api_transport.dart';
// The VM sends with `HttpClient`, the browser with `fetch`. Selected at compile
// time so this library — and everything that imports it — stays free of
// `dart:io` in a web build, which dart2js requires absolutely: it emits *no
// output at all* for an entrypoint that reaches an unsupported SDK library.
import 'api_transport_io.dart'
    if (dart.library.js_interop) 'api_transport_web.dart';

/// A thin REST client for the Hub HTTP API, used by the CLI's operational
/// commands — and by the web dashboard — so both exercise exactly the same
/// public API surface as any other client.
class HubApiClient {
  /// The API base URL (e.g. `https://hub.example.com:8443`).
  ///
  /// The API shares the Hub's TLS listener, so this is normally `https://` on
  /// the same port nodes connect to.
  final Uri baseUrl;

  /// Optional bearer token.
  final String? token;

  /// Optional principal the [token] was granted to.
  ///
  /// Sent as `x-omny-principal`. With a Hub grant (`--grant alice:tok:admin`)
  /// this is half the credential — the Hub verifies the pair and takes the
  /// caller's roles from the grant. With the Hub's static API token it only
  /// attributes the request in the audit trail.
  final String? principal;

  final ApiTransport _transport;

  /// Creates a client for [baseUrl].
  ///
  /// [transport] defaults to the platform's own: `HttpClient` on the VM, `fetch`
  /// in a browser. Inject one to reach a Hub over TLS with a private CA
  /// (`IoApiTransport(securityContext: …)`, VM only), or to drive the client
  /// against a fake Hub in tests.
  HubApiClient(
    this.baseUrl, {
    this.token,
    this.principal,
    ApiTransport? transport,
  }) : _transport = transport ?? defaultApiTransport();

  // ---------------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------------

  /// Who the Hub resolves these credentials to.
  Future<Identity> whoami() async =>
      Identity.fromJson(await _object(await get('/whoami')));

  // ---------------------------------------------------------------------------
  // The fleet
  // ---------------------------------------------------------------------------

  /// Every registered node, optionally narrowed.
  ///
  /// [labels] are `key=value` selectors and **all** must match; [online] limits
  /// it to nodes currently connected. Both are applied by the Hub, which is the
  /// difference between asking which machines are the production ones and
  /// downloading the fleet to find out.
  Future<List<NodeDescriptor>> nodes({
    List<String> labels = const [],
    bool? online,
  }) async => _list(
    await get(
      _query('/nodes', {
        'label': labels,
        if (online != null) 'online': ['$online'],
      }),
    ),
    NodeDescriptor.fromJson,
  );

  /// One node's descriptor.
  Future<NodeDescriptor> node(String id) async =>
      NodeDescriptor.fromJson(await _object(await get('/nodes/$id')));

  /// A node's live status, or `null` if it has not reported one yet.
  ///
  /// A node has no status until its first heartbeat, so a `404` here means "not
  /// yet" rather than "no such node" — the caller shows a waiting state instead
  /// of an error.
  Future<NodeStatus?> nodeStatus(String id) async {
    final json = await _optional(() => get('/nodes/$id/status'));
    return json == null ? null : NodeStatus.fromJson(json);
  }

  /// What a node advertises it can do.
  Future<NodeCapabilities> capabilities(String id) async =>
      NodeCapabilities.fromJson(
        await _object(await get('/nodes/$id/capabilities')),
      );

  /// A node's resource history, newest first.
  ///
  /// [since] is a window (`30s`, `15m`, `1h`, `7d`) or an ISO-8601 instant.
  Future<List<MetricPoint>> metrics(
    String id, {
    String since = '1h',
    int limit = 200,
  }) async => _list(
    await get(
      _query('/nodes/$id/metrics', {
        'since': [since],
        'limit': ['$limit'],
      }),
    ),
    MetricPoint.fromJson,
  );

  /// The tail of what a node has reported.
  Future<List<LogLine>> logs(String id, {int tail = 200}) async => _list(
    await get(
      _query('/nodes/$id/logs', {
        'tail': ['$tail'],
      }),
    ),
    LogLine.fromJson,
  );

  // ---------------------------------------------------------------------------
  // Changing a node
  // ---------------------------------------------------------------------------

  /// Restarts the node **agent** — not the machine.
  Future<void> restartAgent(String id) async => post('/nodes/$id/restart');

  /// Stops the node **agent** — not the machine.
  Future<void> stopAgent(String id) async => post('/nodes/$id/shutdown');

  /// Updates the node: its OS packages, one named package, or the agent itself.
  Future<void> update(String id, {String target = 'agent'}) async =>
      post('/nodes/$id/update', {'target': target});

  /// Runs a formula action and waits for the answer.
  ///
  /// Fine for `verify`; an `install` can outlive the Hub's request timeout, and
  /// a caller that waits for one is told a failure that did not happen. Use
  /// [runFormulaAsync] for those.
  Future<FormulaRunResult> runFormula(
    String id, {
    required String formula,
    required FormulaAction action,
    String? version,
  }) async => FormulaRunResult.fromJson(
    await _object(
      await post('/nodes/$id/formula', {
        'formula': formula,
        'action': action.name,
        'version': ?version,
      }),
    ),
  );

  /// Dispatches a formula action, returning a handle instead of an answer.
  ///
  /// The work is the same; only who waits for it changes. Follow it with
  /// [operation], or on the event stream.
  Future<Operation> runFormulaAsync(
    String id, {
    required String formula,
    required FormulaAction action,
    String? version,
  }) async => Operation.fromJson(
    await _object(
      await post('/nodes/$id/formula', {
        'formula': formula,
        'action': action.name,
        'version': ?version,
        'async': true,
      }),
    ),
  );

  /// What state each of a node's formulas is in, asked of the node.
  ///
  /// Distinct from [formulas], which is the Hub's catalogue of what a node
  /// *could* run. Empty [only] asks about everything the node carries.
  Future<List<FormulaStatusReport>> formulaStatus(
    String id, {
    List<String> only = const [],
  }) async => _list(
    await get(
      _query('/nodes/$id/formulas', {
        if (only.isNotEmpty) 'formulas': [only.join(',')],
      }),
    ),
    FormulaStatusReport.fromJson,
  );

  // ---------------------------------------------------------------------------
  // Desired state: what a node is supposed to be
  // ---------------------------------------------------------------------------

  /// What [id] is declared to be, or `null` if nothing was ever declared.
  Future<DesiredState?> desiredState(String id) async {
    final json = await _optional(() => get('/nodes/$id/desired-state'));
    return json == null ? null : DesiredState.fromJson(json);
  }

  /// Says [id] should be [blueprint]. Runs nothing.
  Future<void> assignBlueprint(String id, String blueprint) async =>
      put('/nodes/$id/desired-state', {'blueprint': blueprint});

  /// Says [id] should be [preset]. Runs nothing.
  Future<void> declarePreset(String id, Preset preset) async =>
      put('/nodes/$id/desired-state', {'preset': preset.toJson()});

  /// Says [id] should be these steps. Runs nothing.
  Future<void> declareSteps(String id, List<PresetStep> steps) async =>
      put('/nodes/$id/desired-state', {
        'steps': [for (final step in steps) step.toJson()],
      });

  /// Stops expecting anything of [id].
  Future<void> undeclare(String id) async => delete('/nodes/$id/desired-state');

  /// How far [id] has drifted, or `null` if nothing was declared for it.
  ///
  /// A read: it plans and runs nothing. A node declared by a blueprint is asked
  /// directly and answers in `changes`; one declared by steps is planned
  /// Hub-side from its advertised capabilities and answers in `actions`.
  Future<Drift?> drift(String id) async {
    final json = await _optional(() => get('/nodes/$id/drift'));
    return json == null ? null : Drift.fromJson(json);
  }

  /// Makes [id] what it was declared to be, and waits.
  ///
  /// Idempotent: a converged node has nothing outstanding, so this changes
  /// nothing the second time — which is what makes it safe on a timer.
  /// [dryRun] plans without touching anything.
  Future<ConvergeResult> reconcile(
    String id, {
    bool dryRun = false,
    bool purgeAdopted = false,
  }) async => ConvergeResult.fromJson(
    await _object(
      await post('/nodes/$id/reconcile', {
        if (dryRun) 'dryRun': true,
        if (purgeAdopted) 'purgeAdopted': true,
      }),
    ),
  );

  /// Dispatches the same work, returning a handle instead of an answer.
  Future<Operation> reconcileAsync(
    String id, {
    bool dryRun = false,
    bool purgeAdopted = false,
  }) async => Operation.fromJson(
    await _object(
      await post('/nodes/$id/reconcile', {
        if (dryRun) 'dryRun': true,
        if (purgeAdopted) 'purgeAdopted': true,
        'async': true,
      }),
    ),
  );

  // ---------------------------------------------------------------------------
  // The catalogue, and the library
  // ---------------------------------------------------------------------------

  /// The formulas a node can be asked to run, and the actions each implements.
  ///
  /// What a client offers instead of a free-text box.
  Future<List<FormulaSpec>> formulas() async =>
      _list(await get('/formulas'), FormulaSpec.fromJson);

  /// Every blueprint saved on the Hub.
  Future<List<Blueprint>> blueprints() async =>
      _list(await get('/blueprints'), Blueprint.fromJson);

  /// One blueprint, as it was authored.
  Future<Blueprint> blueprint(String id) async =>
      Blueprint.fromJson(await _object(await get('/blueprints/$id')));

  /// A blueprint flattened: includes expanded, variables substituted, resources
  /// in the order they would be settled, and a hash over all of it.
  ///
  /// What a node is actually sent, and what to read when a blueprint composed
  /// from several presets is not doing what was expected — every resource names
  /// where it came from.
  Future<ResolvedBlueprint> resolvedBlueprint(String id) async =>
      ResolvedBlueprint.fromJson(
        await _object(await get('/blueprints/$id/resolved')),
      );

  /// Saves a blueprint on the Hub.
  ///
  /// Refused with a `400` if it could never apply — a dependency cycle, an
  /// undeclared variable, an include naming a preset nobody saved.
  Future<void> saveBlueprint(Blueprint blueprint) async =>
      post('/blueprints', blueprint.toJson());

  /// Deletes a saved blueprint.
  Future<void> deleteBlueprint(String id) async => delete('/blueprints/$id');

  /// Every preset saved on the Hub.
  Future<List<Preset>> presets() async =>
      _list(await get('/presets'), Preset.fromJson);

  /// One saved preset.
  Future<Preset> preset(String id) async =>
      Preset.fromJson(await _object(await get('/presets/$id')));

  /// Saves a preset on the Hub, so every operator applies the same one.
  Future<void> savePreset(Preset preset) async =>
      post('/presets', preset.toJson());

  /// Deletes a saved preset.
  Future<void> deletePreset(String id) async => delete('/presets/$id');

  /// Applies a preset to a node and waits.
  ///
  /// Name a saved one with [presetId] — the copy everybody agrees on — or send
  /// one inline with [preset].
  Future<PresetApplyResult> applyPreset(
    String nodeId, {
    String? presetId,
    Preset? preset,
  }) async => PresetApplyResult.fromJson(
    await _object(
      await post('/presets/apply', _applyBody(nodeId, presetId, preset)),
    ),
  );

  /// Dispatches the same work, returning a handle instead of an answer.
  Future<Operation> applyPresetAsync(
    String nodeId, {
    String? presetId,
    Preset? preset,
  }) async => Operation.fromJson(
    await _object(
      await post('/presets/apply', {
        ..._applyBody(nodeId, presetId, preset),
        'async': true,
      }),
    ),
  );

  Map<String, Object?> _applyBody(
    String nodeId,
    String? presetId,
    Preset? preset,
  ) {
    if ((presetId == null) == (preset == null)) {
      throw ArgumentError(
        'name a saved preset with presetId, or send one with preset — '
        'exactly one',
      );
    }
    return {
      'nodeId': nodeId,
      'presetId': ?presetId,
      if (preset != null) 'preset': preset.toJson(),
    };
  }

  // ---------------------------------------------------------------------------
  // Credentials
  // ---------------------------------------------------------------------------

  /// Every credential the Hub has issued. Hashes, never tokens.
  Future<List<Grant>> grants() async =>
      _list(await get('/grants'), Grant.fromJson);

  /// Issues a credential. The token comes back **once** and cannot be read
  /// again — the Hub keeps only a hash of it.
  Future<IssuedGrant> issueGrant({
    required String principal,
    required Set<String> roles,
    String note = '',
  }) async => IssuedGrant.fromJson(
    await _object(
      await post('/grants', {
        'principal': principal,
        'roles': roles.toList(),
        if (note.isNotEmpty) 'note': note,
      }),
    ),
  );

  /// Revokes a credential.
  Future<void> revokeGrant(String id) async => delete('/grants/$id');

  // ---------------------------------------------------------------------------
  // What is happening, and what happened
  // ---------------------------------------------------------------------------

  /// What is wrong right now.
  Future<List<Alert>> alerts() async =>
      _list(await get('/alerts'), Alert.fromJson);

  /// Recent Hub events, newest first.
  Future<List<OmnyEvent>> events() async =>
      _list(await get('/events'), OmnyEvent.fromJson);

  /// Work dispatched with `async`: what is running, and how the last few went.
  Future<List<Operation>> operations({
    String? nodeId,
    bool running = false,
  }) async => _list(
    await get(
      _query('/operations', {
        if (nodeId != null) 'node': [nodeId],
        if (running) 'running': ['true'],
      }),
    ),
    Operation.fromJson,
  );

  /// One dispatched operation.
  Future<Operation> operation(String id) async =>
      Operation.fromJson(await _object(await get('/operations/$id')));

  /// The audit trail — who did what, as the Hub verified it.
  Future<List<AuditEntry>> audit() async =>
      _list(await get('/audit'), AuditEntry.fromJson);

  /// Whether the Hub is up. Unauthenticated, and outside the versioned API.
  Future<bool> healthz() async {
    try {
      await getText('/healthz');
      return true;
    } on Object {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // The raw verbs
  //
  // Kept public, and deliberately: they are what the typed methods above are
  // built from, they reach an endpoint this client does not model yet, and they
  // are what a test asserting the *wire shape* should use — a test that goes
  // through the typed decoders cannot tell you the Hub named a field wrongly,
  // because the decoder would paper over it.
  //
  // Prefer a typed method everywhere else. `as Map` at a call site is how a
  // renamed field becomes a runtime failure in one caller and not the others.
  // ---------------------------------------------------------------------------

  /// GET `/api/v1[path]`, decoding the JSON body.
  Future<dynamic> get(String path) => _send('GET', path);

  /// POST `/api/v1[path]` with an optional JSON [body].
  Future<dynamic> post(String path, [Object? body]) =>
      _send('POST', path, body);

  /// PUT `/api/v1[path]` with an optional JSON [body].
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body);

  /// DELETE `/api/v1[path]`.
  Future<dynamic> delete(String path) => _send('DELETE', path);

  // ---------------------------------------------------------------------------
  // Decoding
  // ---------------------------------------------------------------------------

  /// A decoded reply as an object, or a clear failure.
  ///
  /// The message names the client rather than the JSON, because "expected an
  /// object" on its own sends the reader to the wrong file.
  Future<Map<String, dynamic>> _object(dynamic decoded) async {
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw HubApiException(
      'the Hub answered with ${decoded.runtimeType}, not an object',
      200,
    );
  }

  /// A decoded reply as a list of [T].
  List<T> _list<T>(dynamic decoded, T Function(Map<String, dynamic>) decode) {
    if (decoded is! List) {
      throw HubApiException(
        'the Hub answered with ${decoded.runtimeType}, not a list',
        200,
      );
    }
    return [
      for (final item in decoded) decode((item as Map).cast<String, dynamic>()),
    ];
  }

  /// Runs [request], turning a `404` into `null`.
  ///
  /// For the endpoints where absence is an ordinary answer: a node that has not
  /// heartbeated yet has no status, and a node nobody has declared anything
  /// about has no drift. Neither is an error, and a caller made to catch one
  /// will sooner or later catch the wrong one.
  Future<Map<String, dynamic>?> _optional(
    Future<dynamic> Function() request,
  ) async {
    try {
      return await _object(await request());
    } on HubApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Builds `path?a=1&a=2`, encoding each value.
  ///
  /// Repeated keys are kept repeated — `?label=env=prod&label=region=eu` is how
  /// the Hub reads an all-must-match selector, and collapsing them to one
  /// comma-joined value would silently widen the selection.
  String _query(String path, Map<String, List<String>> params) {
    final parts = [
      for (final entry in params.entries)
        for (final value in entry.value)
          '${Uri.encodeQueryComponent(entry.key)}='
              '${Uri.encodeQueryComponent(value)}',
    ];
    return parts.isEmpty ? path : '$path?${parts.join('&')}';
  }

  /// GET a raw text endpoint (e.g. `/metrics`) outside the versioned API.
  Future<String> getText(String absolutePath) async {
    final response = await _transport.send(
      'GET',
      baseUrl.replace(path: absolutePath),
      headers: _headers(),
    );
    return response.body;
  }

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    // `Uri.replace(path: …)` percent-encodes a `?`, which would bury the query
    // string inside the path and turn `/nodes/x/metrics?since=1h` into a route
    // that matches nothing. Split it off and hand it over as a query.
    final split = path.indexOf('?');
    final uri = split == -1
        ? baseUrl.replace(path: '/api/v1$path')
        : baseUrl.replace(
            path: '/api/v1${path.substring(0, split)}',
            query: path.substring(split + 1),
          );
    final response = await _transport.send(
      method,
      uri,
      headers: {
        ..._headers(),
        if (body != null) 'content-type': 'application/json; charset=utf-8',
      },
      body: body == null ? null : jsonEncode(body),
    );

    final text = response.body;
    final decoded = text.isEmpty ? null : jsonDecode(text);
    if (response.statusCode >= 400) {
      final message = decoded is Map && decoded['error'] is Map
          ? decoded['error']['message']
          : 'HTTP ${response.statusCode}';
      throw HubApiException('$message', response.statusCode);
    }
    return decoded;
  }

  Map<String, String> _headers() => {
    if (token != null) 'authorization': 'Bearer $token',
    'x-omny-principal': ?principal,
  };

  /// Releases the underlying transport.
  void close() => _transport.close();
}

/// Thrown when a Hub API request fails.
class HubApiException implements Exception {
  /// The error message.
  final String message;

  /// The HTTP status code.
  final int statusCode;

  /// Creates the exception.
  HubApiException(this.message, this.statusCode);

  @override
  String toString() => 'HubApiException($statusCode): $message';
}
