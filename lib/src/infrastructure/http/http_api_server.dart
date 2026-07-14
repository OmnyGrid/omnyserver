import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart'
    show
        Authenticator,
        ForbiddenException,
        HandlerService,
        HttpTransport,
        HubRequest,
        HubResponse,
        Middleware,
        OmnyHub,
        Principal,
        RouterService,
        Service,
        SseEvent,
        StaticTls,
        UnauthorizedException,
        cors,
        sseResponse;

import '../../application/hub/event_aggregator.dart';
import '../../application/hub/hub_metrics.dart';
import '../../application/hub/omny_server_hub.dart';
import '../../domain/auth/credential.dart';
import '../../domain/auth/principal.dart' as domain;
import '../../domain/entities/preset.dart';
import '../../domain/events/omny_event.dart';
import '../../domain/formula/formula_action.dart';
import '../../domain/state/desired_state.dart';
import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/preset_id.dart';
import '../../domain/value_objects/principal_id.dart';
import '../../shared/errors/omnyserver_exception.dart';
import 'api_errors.dart';
import 'openapi.dart';

/// A reusable, versioned REST API in front of an [OmnyServerHub].
///
/// Everything the CLI can do is reachable here too. Routes live under
/// `/api/v1`; `/metrics` (Prometheus) and `/healthz` sit at the root. A bearer
/// [apiToken], when configured, is required for `/api/v1` routes; request bodies
/// are validated and failures return structured JSON errors.
///
/// The API is a set of omnyhub [Service]s. [start] hosts them on their own
/// [OmnyHub] (the standalone deployment); [buildServices] hands them over to be
/// mounted on an existing hub instead, so the REST API and the node control
/// channel can share one port.
class HttpApiServer {
  /// The Hub this API fronts.
  final OmnyServerHub hub;

  /// Optional bearer token required on `/api/v1` requests.
  final String? apiToken;

  /// Optional event aggregator powering `/api/v1/events`.
  final EventAggregator? events;

  /// Optional metrics powering `/metrics`.
  final HubMetrics? metrics;

  /// The bind host.
  final Object host;

  /// The bind port (0 for ephemeral).
  final int port;

  /// Optional TLS context (plaintext when null).
  final SecurityContext? securityContext;

  /// How often an idle event stream sends a keep-alive comment.
  ///
  /// It is not only an idle-timeout defence against a proxy in front of the Hub:
  /// a write is the only way a vanished client is ever noticed, so this is also
  /// how long a dead subscriber lingers.
  final Duration eventKeepAlive;

  OmnyHub? _server;

  /// The live event streams currently attached to clients.
  ///
  /// Tracked so [close] can hang them up. An SSE response never ends on its own,
  /// so without this a shutdown would block until each idle client's next
  /// keep-alive ping failed to write — a Hub taking 15 seconds to stop because
  /// somebody left a dashboard open.
  final Set<StreamController<OmnyEvent>> _eventStreams = {};

  /// Creates an API server.
  HttpApiServer({
    required this.hub,
    this.apiToken,
    this.events,
    this.metrics,
    this.host = '0.0.0.0',
    this.port = 8080,
    this.securityContext,
    this.eventKeepAlive = const Duration(seconds: 15),
  });

  /// The bound port (valid after [start]).
  int get boundPort => _server?.port ?? port;

  /// The middleware this API needs, outermost first.
  ///
  /// Exposed alongside [buildServices] so a hub hosting the API on a shared port
  /// installs the same request accounting and error envelope.
  List<Middleware> buildMiddleware() => [_countRequests(), apiErrorMapper()];

  /// The CORS middleware for the Hub's allowed origins, or `null` when none are
  /// configured (no browser client, nothing to allow).
  ///
  /// **Install it with `OmnyServerHub.useOuter`, not `use`** — it has to sit
  /// outside the error mapper to stamp a `401`/`404`/`500`, which a browser can
  /// otherwise not read at all, and outside authentication to answer a preflight,
  /// which carries no credentials.
  ///
  /// Credentials are *not* enabled: the dashboard authenticates with a bearer
  /// token in a header, not a cookie, so there is no reason to let the browser
  /// attach ambient credentials to a cross-origin call.
  Middleware? corsMiddleware() {
    final origins = hub.config.corsOrigins;
    if (origins.isEmpty) return null;
    return cors(allowedOrigins: origins);
  }

  /// The omnyhub services this API exposes: the authenticated `/api/v1` surface,
  /// the unauthenticated root endpoints, and the OpenAPI document.
  ///
  /// Register them on any [OmnyHub]. Route specificity does the rest: the
  /// OpenAPI service mounts deeper than `/api/v1`, so it wins and stays
  /// unauthenticated, and `/api/v1` outranks the root service.
  List<Service> buildServices() => [
    _apiService(),
    _publicService(),
    _openApi(),
  ];

  /// Starts a standalone [OmnyHub] hosting the API on [host]:[port].
  Future<void> start() async {
    final corsMiddleware = this.corsMiddleware();
    final server = OmnyHub(
      transports: [
        if (securityContext == null)
          HttpTransport.http(address: host, port: port)
        else
          HttpTransport.https(
            address: host,
            port: port,
            tls: StaticTls.context(securityContext!),
          ),
      ],
      middleware: buildMiddleware(),
      // Outside the error mapper and authentication — see [corsMiddleware].
      outerMiddleware: [?corsMiddleware],
    );
    for (final service in buildServices()) {
      await server.registerService(
        service,
        // Only the /api/v1 surface is token-gated; /healthz, /metrics and the
        // OpenAPI document stay open.
        authenticator: service.name == apiServiceName ? _tokenAuth() : null,
      );
    }
    await server.start();
    _server = server;
  }

  /// Stops the server, hanging up any live event streams first.
  Future<void> close() async {
    for (final stream in [..._eventStreams]) {
      await stream.close();
    }
    _eventStreams.clear();
    await _server?.stop();
    _server = null;
  }

  /// The authenticator guarding `/api/v1`, or `null` when no token is set.
  ///
  /// A hub hosting [buildServices] itself must apply this to the service named
  /// [apiServiceName] — that is the only one behind the token.
  Authenticator? tokenAuthenticator() => _tokenAuth();

  /// The name of the token-gated `/api/v1` service.
  static const String apiServiceName = 'omnyserver-api';

  Authenticator? _tokenAuth() {
    final token = apiToken;
    return token == null ? null : _ApiAuthenticator(hub: hub, apiToken: token);
  }

  /// Counts every request that reaches the API, including rejected ones.
  Middleware _countRequests() =>
      (inner) => (request) async {
        metrics?.recordApiRequest();
        return inner(request);
      };

  RouterService _apiService() =>
      RouterService(name: apiServiceName, mount: '/api/v1')
        ..get('/api/v1/whoami', (r, p) async => _whoami(r))
        ..get('/api/v1/nodes', (r, p) async => _listNodes(r))
        ..get('/api/v1/nodes/<id>', (r, p) async => _getNode(p))
        ..get('/api/v1/nodes/<id>/status', (r, p) async => _getStatus(p))
        ..get(
          '/api/v1/nodes/<id>/capabilities',
          (r, p) async => _getCapabilities(p),
        )
        ..get('/api/v1/nodes/<id>/metrics', (r, p) => _getMetrics(r, p))
        ..get('/api/v1/nodes/<id>/desired-state', (r, p) => _getDesired(p))
        ..put('/api/v1/nodes/<id>/desired-state', (r, p) => _putDesired(r, p))
        ..delete(
          '/api/v1/nodes/<id>/desired-state',
          (r, p) => _deleteDesired(r, p),
        )
        ..get('/api/v1/nodes/<id>/drift', (r, p) => _getDrift(p))
        ..post('/api/v1/nodes/<id>/reconcile', (r, p) => _reconcile(r, p))
        ..post('/api/v1/nodes/<id>/restart', (r, p) => _restart(r, p))
        ..post('/api/v1/nodes/<id>/shutdown', (r, p) => _shutdown(r, p))
        ..post('/api/v1/nodes/<id>/update', (r, p) => _update(r, p))
        ..post('/api/v1/nodes/<id>/formula', (r, p) => _formula(r, p))
        ..get('/api/v1/formulas', (r, p) => _listFormulas())
        // Before `/presets/<id>`: the router takes the first match, and `apply`
        // is not a preset id.
        ..post('/api/v1/presets/apply', (r, p) => _applyPreset(r))
        ..get('/api/v1/presets', (r, p) => _listPresets())
        ..post('/api/v1/presets', (r, p) => _savePreset(r))
        ..get('/api/v1/presets/<id>', (r, p) => _getPreset(p))
        ..delete('/api/v1/presets/<id>', (r, p) => _deletePreset(r, p))
        ..get('/api/v1/grants', (r, p) => _listGrants(r))
        ..post('/api/v1/grants', (r, p) => _issueGrant(r))
        ..delete('/api/v1/grants/<id>', (r, p) => _revokeGrant(r, p))
        // Before `/events`: the router takes the first match, so the more
        // specific path has to be offered first.
        ..get('/api/v1/events/stream', (r, p) async => _eventStream())
        ..get('/api/v1/events', (r, p) async => _events())
        ..get('/api/v1/audit', (r, p) => _audit())
        // Last, so it only sees paths no route above matched. It answers every
        // method, which keeps a wrong method on a known path a 404 rather than
        // omnyhub's 405 — the v1 contract has never had a 405.
        ..all('/api/v1/<rest|.*>', (r, p) async => _unknownRoute());

  RouterService _publicService() => RouterService(name: 'omnyserver-public')
    ..get('/healthz', (r, p) async => jsonOk({'status': 'ok'}))
    ..get('/metrics', (r, p) async => _metrics())
    ..all('/<rest|.*>', (r, p) async => _unknownRoute());

  HandlerService _openApi() => HandlerService(
    name: 'omnyserver-openapi',
    mount: '/api/v1/openapi.json',
    handler: (_) async => jsonOk(openApiDocument()),
  );

  // ---------------------------------------------------------------------------
  // Handlers. They throw; `apiErrorMapper` renders the envelope.
  // ---------------------------------------------------------------------------

  HubResponse _unknownRoute() => ApiErrors.notFound('unknown route');

  HubResponse _metrics() => HubResponse.text(
    metrics?.render() ?? '',
    headers: const {'content-type': 'text/plain'},
  );

  /// Who the Hub decided you are.
  ///
  /// The dashboard needs this at login for two reasons a client cannot answer
  /// for itself. It cannot otherwise tell whether a token is *valid* — the first
  /// real call would be the one to fail, long after the login form is gone. And
  /// it cannot know which roles it holds, so it would have to offer every action
  /// and let the Hub refuse half of them with a `403`.
  ///
  /// An ungated API (no `--api-token`) has no principal to report, hence the
  /// anonymous fallback.
  HubResponse _whoami(HubRequest request) {
    final principal = request.principal;
    return jsonOk({
      'principal': principal?.id ?? 'anonymous',
      'roles': (principal?.roles ?? const <String>{}).toList()..sort(),
      'authenticated': principal != null,
    });
  }

  /// The fleet, optionally narrowed.
  ///
  /// `?label=env=prod` (repeatable, and every one must match) and `?online=true`.
  /// Filtering here rather than in the client is the difference between asking
  /// "which of my machines are the production ones" and downloading the whole
  /// fleet to find out — and it is what makes a label selector mean the same
  /// thing to the CLI, the dashboard and a script.
  HubResponse _listNodes(HubRequest request) {
    final query = request.uri.queryParametersAll;

    final selectors = <String, String>{};
    for (final raw in query['label'] ?? const <String>[]) {
      final i = raw.indexOf('=');
      if (i <= 0) {
        return ApiErrors.badRequest('invalid label "$raw" (want key=value)');
      }
      selectors[raw.substring(0, i)] = raw.substring(i + 1);
    }

    final onlineRaw = request.uri.queryParameters['online'];
    if (onlineRaw != null && onlineRaw != 'true' && onlineRaw != 'false') {
      return ApiErrors.badRequest('online must be true or false');
    }
    final bool? online = onlineRaw == null ? null : onlineRaw == 'true';

    final nodes = hub.listNodes().where((node) {
      if (online != null && node.online != online) return false;
      for (final selector in selectors.entries) {
        if (node.labels[selector.key] != selector.value) return false;
      }
      return true;
    });

    return jsonOk([for (final n in nodes) n.toJson()]);
  }

  HubResponse _getNode(Map<String, String> params) {
    final id = _nodeId(params);
    final node = hub.getNode(id);
    if (node == null) throw NotFoundException('unknown node ${id.value}');
    return jsonOk(node.toJson());
  }

  HubResponse _getStatus(Map<String, String> params) {
    final id = _nodeId(params);
    final status = hub.getStatus(id);
    if (status == null) throw NotFoundException('no status for ${id.value}');
    return jsonOk(status.toJson());
  }

  HubResponse _getCapabilities(Map<String, String> params) {
    final id = _nodeId(params);
    final node = hub.getNode(id);
    if (node == null) throw NotFoundException('unknown node ${id.value}');
    return jsonOk(node.capabilities.toJson());
  }

  Future<HubResponse> _restart(
    HubRequest request,
    Map<String, String> params,
  ) async {
    final id = _nodeId(params);
    _authorize(request, 'node.restart', target: id.value);
    await hub.restartNode(id, principal: _principal(request));
    return jsonOk({'status': 'restarting', 'nodeId': id.value});
  }

  Future<HubResponse> _shutdown(
    HubRequest request,
    Map<String, String> params,
  ) async {
    final id = _nodeId(params);
    _authorize(request, 'node.shutdown', target: id.value);
    await hub.shutdownNode(id, principal: _principal(request));
    return jsonOk({'status': 'shutting_down', 'nodeId': id.value});
  }

  Future<HubResponse> _update(
    HubRequest request,
    Map<String, String> params,
  ) async {
    final id = _nodeId(params);
    _authorize(request, 'node.update', target: id.value);
    final body = await _readJson(request);
    final target = (body['target'] as String?) ?? 'agent';
    await hub.updateNode(id, target, principal: _principal(request));
    return jsonOk({'status': 'updating', 'target': target});
  }

  Future<HubResponse> _formula(
    HubRequest request,
    Map<String, String> params,
  ) async {
    final id = _nodeId(params);
    _authorize(request, 'formula.run', target: id.value);
    final body = await _readJson(request);
    final formula = body['formula'];
    if (formula is! String) {
      return ApiErrors.badRequest('formula is required');
    }
    final action = FormulaAction.parse((body['action'] as String?) ?? 'verify');
    final reply = await hub.runFormula(
      id,
      formula,
      action,
      version: body['version'] as String?,
      principal: _principal(request),
    );
    return jsonOk(reply.toJson());
  }

  /// Applies a preset: either one sent inline, or one saved on the Hub by id.
  ///
  /// The saved form is the one worth using. A preset shipped inline is whatever
  /// copy of the file that caller happens to have; a preset applied by id is the
  /// one everybody agrees on.
  Future<HubResponse> _applyPreset(HubRequest request) async {
    _authorize(request, 'preset.apply');
    final body = await _readJson(request);
    final nodeId = body['nodeId'];
    if (nodeId is! String) {
      return ApiErrors.badRequest('nodeId is required');
    }

    final Preset preset;
    if (body['preset'] case final Map inline) {
      preset = Preset.fromJson(inline.cast<String, dynamic>());
    } else if (body['presetId'] case final String id) {
      final saved = await hub.presetFor(PresetId(id));
      if (saved == null) throw NotFoundException('unknown preset $id');
      preset = saved;
    } else {
      return ApiErrors.badRequest(
        'send a preset inline, or name a saved one with presetId',
      );
    }

    final result = await hub.applyPreset(
      _parseNodeId(nodeId),
      preset,
      principal: _principal(request),
    );
    return jsonOk(result.toJson());
  }

  /// What a node can be asked to do.
  ///
  /// A client that has to be *told* what to type into a free-text box is a client
  /// that gets it wrong; this is what it reads instead.
  Future<HubResponse> _listFormulas() async {
    final formulas = await hub.listFormulas();
    return jsonOk([for (final spec in formulas) spec.toJson()]);
  }

  /// The presets saved on the Hub.
  Future<HubResponse> _listPresets() async {
    final presets = await hub.listPresets();
    return jsonOk([for (final preset in presets) preset.toJson()]);
  }

  Future<HubResponse> _getPreset(Map<String, String> params) async {
    final id = PresetId(params['id']!);
    final preset = await hub.presetFor(id);
    if (preset == null) throw NotFoundException('unknown preset ${id.value}');
    return jsonOk(preset.toJson());
  }

  /// Saves a preset on the Hub, so every operator applies the same one rather
  /// than each shipping a copy of a JSON file that has quietly diverged.
  Future<HubResponse> _savePreset(HubRequest request) async {
    _authorize(request, 'preset.save');
    final body = await _readJson(request);
    final preset = Preset.fromJson(body);
    await hub.savePreset(preset, principal: _principal(request));
    return jsonOk({
      'status': 'saved',
      'id': preset.id.value,
      'steps': preset.steps.length,
    });
  }

  Future<HubResponse> _deletePreset(
    HubRequest request,
    Map<String, String> params,
  ) async {
    _authorize(request, 'preset.save');
    final id = PresetId(params['id']!);
    if (!await hub.deletePreset(id)) {
      throw NotFoundException('unknown preset ${id.value}');
    }
    return jsonOk({'status': 'deleted', 'id': id.value});
  }

  /// Every credential the Hub has issued.
  ///
  /// Hashes, never tokens — there is nothing here to steal, which is the reason
  /// the list is safe to show at all.
  Future<HubResponse> _listGrants(HubRequest request) async {
    _authorize(request, 'grant.manage');
    final grants = await hub.listGrants();
    return jsonOk([for (final grant in grants) grant.toJson()]);
  }

  /// Issues a credential, and returns its token **once**.
  ///
  /// The Hub keeps only a hash, so this response is the single moment the token
  /// is readable. That is stated in the body rather than left to be discovered,
  /// because an operator who closes the terminal has not lost access — they have
  /// lost *that* credential, and the fix is to revoke it and issue another.
  Future<HubResponse> _issueGrant(HubRequest request) async {
    _authorize(request, 'grant.manage');
    final body = await _readJson(request);

    final principal = body['principal'];
    if (principal is! String || principal.isEmpty) {
      return ApiErrors.badRequest('principal is required');
    }
    final roles = ((body['roles'] as List?) ?? const []).cast<String>().toSet();
    if (roles.isEmpty) {
      return ApiErrors.badRequest(
        'roles are required — a credential that may do nothing is not a '
        'credential (try: viewer, operator, admin, node)',
      );
    }

    final issued = await hub.issueGrant(
      principal: PrincipalId(principal),
      roles: roles,
      note: (body['note'] as String?) ?? '',
      issuedBy: _principal(request),
    );

    return jsonOk({
      ...issued.grant.toJson(),
      'token': issued.token,
      'warning':
          'This is the only time the token is shown. The Hub stores a hash of '
          'it and cannot show it again.',
    });
  }

  Future<HubResponse> _revokeGrant(
    HubRequest request,
    Map<String, String> params,
  ) async {
    _authorize(request, 'grant.manage');
    final id = params['id']!;
    final revoked = await hub.revokeGrant(id, revokedBy: _principal(request));
    if (!revoked) throw NotFoundException('unknown grant $id');
    return jsonOk({'status': 'revoked', 'id': id});
  }

  /// What a node is supposed to be.
  Future<HubResponse> _getDesired(Map<String, String> params) async {
    final id = _nodeId(params);
    final desired = await hub.desiredStateFor(id);
    if (desired == null) {
      throw NotFoundException('no desired state declared for ${id.value}');
    }
    return jsonOk(desired.toJson());
  }

  /// Declares what a node should be. `PUT`, because declaring the same state
  /// twice is the same declaration — this is a fact about the node, not an
  /// instruction to it.
  ///
  /// Nothing runs here. `POST /reconcile` is what acts.
  Future<HubResponse> _putDesired(
    HubRequest request,
    Map<String, String> params,
  ) async {
    final id = _nodeId(params);
    _authorize(request, 'state.declare', target: id.value);
    if (hub.getNode(id) == null) {
      throw NotFoundException('unknown node ${id.value}');
    }

    final body = await _readJson(request);
    // Either a bare `{steps: [...]}`, or a whole preset — an operator declaring
    // "this node is a docker host" has a preset in hand, not a step list.
    final DesiredState desired;
    if (body['preset'] case final Map preset) {
      desired = DesiredState.fromPresets([
        Preset.fromJson(preset.cast<String, dynamic>()),
      ]);
    } else {
      desired = DesiredState.fromJson(body);
    }

    await hub.setDesiredState(id, desired, principal: _principal(request));
    return jsonOk({
      'status': 'declared',
      'nodeId': id.value,
      'steps': desired.steps.length,
    });
  }

  Future<HubResponse> _deleteDesired(
    HubRequest request,
    Map<String, String> params,
  ) async {
    final id = _nodeId(params);
    _authorize(request, 'state.declare', target: id.value);
    final removed = await hub.clearDesiredState(id);
    if (!removed) {
      throw NotFoundException('no desired state declared for ${id.value}');
    }
    return jsonOk({'status': 'cleared', 'nodeId': id.value});
  }

  /// How far a node has drifted from what was declared for it.
  ///
  /// A read: it plans, and runs nothing. An empty `actions` list means the node
  /// still is what it was declared to be — which is the question nothing could
  /// ask before, and the reason to declare a state rather than just apply a
  /// preset and hope.
  Future<HubResponse> _getDrift(Map<String, String> params) async {
    final id = _nodeId(params);
    final plan = await hub.drift(id);
    return jsonOk({
      'nodeId': id.value,
      'converged': plan.converged,
      'actions': [for (final step in plan.actions) step.toJson()],
      'notes': plan.notes,
    });
  }

  /// Runs whatever the drift plan says is outstanding.
  ///
  /// Idempotent: a converged node has an empty plan, so this runs nothing the
  /// second time — which is what makes it safe on a timer.
  Future<HubResponse> _reconcile(
    HubRequest request,
    Map<String, String> params,
  ) async {
    final id = _nodeId(params);
    _authorize(request, 'state.reconcile', target: id.value);
    final result = await hub.reconcile(id, principal: _principal(request));
    return jsonOk(result.toJson());
  }

  /// A node's resource history, for charting.
  ///
  /// `?since=` takes an ISO-8601 instant or a duration shorthand (`1h`, `30m`,
  /// `7d`) — the latter because the thing an operator actually wants is "the
  /// last hour", and making them compute a timestamp for that is a small cruelty.
  Future<HubResponse> _getMetrics(
    HubRequest request,
    Map<String, String> params,
  ) async {
    final id = _nodeId(params);
    if (hub.getNode(id) == null) {
      throw NotFoundException('unknown node ${id.value}');
    }
    final query = request.uri.queryParameters;
    final limit = int.tryParse(query['limit'] ?? '') ?? 100;
    if (limit <= 0) return ApiErrors.badRequest('limit must be positive');

    final DateTime? since;
    try {
      since = _parseSince(query['since']);
    } on FormatException catch (e) {
      return ApiErrors.badRequest('invalid since: ${e.message}');
    }

    final points = await hub.metricsFor(id, limit: limit, since: since);
    return jsonOk([for (final p in points) p.toJson()]);
  }

  /// Parses `?since=` as a duration back from now (`90s`, `15m`, `1h`, `7d`) or
  /// an absolute ISO-8601 instant.
  DateTime? _parseSince(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final shorthand = RegExp(r'^(\d+)([smhd])$').firstMatch(raw);
    if (shorthand != null) {
      final n = int.parse(shorthand.group(1)!);
      final span = switch (shorthand.group(2)!) {
        's' => Duration(seconds: n),
        'm' => Duration(minutes: n),
        'h' => Duration(hours: n),
        _ => Duration(days: n),
      };
      return hub.config.clock.now().toUtc().subtract(span);
    }
    return DateTime.parse(raw).toUtc();
  }

  HubResponse _events() =>
      jsonOk((events?.recent() ?? const []).map((e) => e.toJson()).toList());

  /// Every event as it happens, as Server-Sent Events.
  ///
  /// The polling endpoint above returns a bounded snapshot, so a dashboard built
  /// on it is always a few seconds stale and re-fetches a list it has mostly seen
  /// already. This is the same events, pushed: one long-lived response per
  /// client, each event flushed as it occurs.
  ///
  /// Each event carries its own type as the SSE `event:` name, so a browser can
  /// `addEventListener('node.connected', …)` rather than switching on a payload
  /// field.
  HubResponse _eventStream() {
    final events = _trackedEvents();
    return sseResponse(
      events.stream.map(
        (event) => SseEvent.json(event.toJson(), event: event.type),
      ),
      keepAlive: eventKeepAlive,
      // The client went away: stop feeding this one.
      onCancel: () => _eventStreams.remove(events),
    );
  }

  /// The Hub's event bus, per client, behind a controller [close] can hang up.
  StreamController<OmnyEvent> _trackedEvents() {
    late final StreamController<OmnyEvent> controller;
    StreamSubscription<OmnyEvent>? subscription;

    controller = StreamController<OmnyEvent>(
      onListen: () {
        subscription = hub.config.eventBus.events.listen((event) {
          if (!controller.isClosed) controller.add(event);
        }, onError: controller.addError);
      },
      onCancel: () async {
        _eventStreams.remove(controller);
        await subscription?.cancel();
      },
    );
    _eventStreams.add(controller);
    return controller;
  }

  Future<HubResponse> _audit() async {
    final recent = await hub.audit.recent();
    return jsonOk(recent.map((e) => e.toJson()).toList());
  }

  /// Refuses the request unless the caller's roles permit [action].
  ///
  /// Authenticating is not the same as being allowed to act. Reaching the API at
  /// all is `api.access`, which a `viewer` holds — so without a second check here
  /// a read-only credential could still restart a machine, and the role would be
  /// decoration. The Hub's own [Authorizer] decides, so a deployment that
  /// redefines the policy redefines it once.
  void _authorize(HubRequest request, String action, {String? target}) {
    final principal = request.principal;
    // No principal means the API is ungated (no `--api-token`), which is an
    // explicit choice to trust every caller. Nothing to check.
    if (principal == null) return;

    final resolved = domain.Principal(
      id: PrincipalId(principal.id),
      roles: principal.roles.toSet(),
    );
    if (!hub.config.authorizer.authorize(resolved, action, target: target)) {
      throw ForbiddenException(
        '${principal.id} may not $action — this credential can read the fleet, '
        'not change it',
      );
    }
  }

  /// Who to attribute an operation to in the audit trail.
  ///
  /// The authenticated principal first: with a grant it is the identity the Hub
  /// verified, not one the caller asserted. The header is the fallback for an
  /// ungated API (no `--api-token`, hence no authenticator and no principal).
  String _principal(HubRequest request) =>
      request.principal?.id ?? request.header('x-omny-principal') ?? 'api';

  NodeId _nodeId(Map<String, String> params) => _parseNodeId(params['id']!);

  /// A malformed node id is a 404, not a 400: the client asked for a node that
  /// cannot exist.
  NodeId _parseNodeId(String value) {
    try {
      return NodeId(value);
    } on ProtocolException catch (e) {
      throw NotFoundException(e.message);
    }
  }

  Future<Map<String, dynamic>> _readJson(HubRequest request) async {
    final body = await request.readAsString();
    if (body.trim().isEmpty) return {};
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('expected a JSON object');
    }
    return decoded.cast<String, dynamic>();
  }
}

/// Guards `/api/v1`, accepting either credential the Hub knows about.
///
/// * The **static API token** (`--api-token`) — a Hub-wide master key carrying
///   no identity of its own. It always grants `admin`, so `x-omny-principal`
///   merely names the caller in the audit trail; the header is trusted here
///   precisely because holding the master key already implies full access.
/// * A **grant** (`--grant alice:admin-token:admin`) — `x-omny-principal` plus
///   the granted token, verified against the very [TokenAuthenticator] the node
///   channel uses. Identity and roles then come from the grant rather than from
///   the caller, and the Hub's `Authorizer` decides whether those roles may
///   drive the API at all ([apiAction]). Its fail-closed default reserves the
///   API for `admin`, so a node's own token authenticates but cannot operate the
///   fleet.
///
/// Throws rather than returning `null` for a missing token: an unauthenticated
/// request must surface as `401 unauthorized`, and omnyhub reads a `null`
/// principal as "anonymous", which its authorizer would turn into a `403`.
class _ApiAuthenticator implements Authenticator {
  /// The action a grant must be authorized for to use the HTTP API.
  static const String apiAction = 'api.access';

  /// The Hub whose authenticator and authorizer resolve grants.
  final OmnyServerHub hub;

  /// The static bearer token gating `/api/v1`.
  final String apiToken;

  const _ApiAuthenticator({required this.hub, required this.apiToken});

  @override
  Future<Principal?> authenticate(HubRequest request) async {
    final header = request.header('authorization');
    if (header == null || !header.startsWith('Bearer ')) {
      throw const UnauthorizedException('missing bearer token');
    }
    final token = header.substring(7);
    final claimed = request.header('x-omny-principal');

    if (_constantTimeEquals(token, apiToken)) {
      return Principal(id: claimed ?? 'api', roles: const {'admin'});
    }
    // Not the master key, and no principal to look a grant up by: the token is
    // simply wrong. Answer exactly as before, naming neither.
    if (claimed == null || claimed.isEmpty) {
      throw const UnauthorizedException('invalid token');
    }
    return _fromGrant(claimed, token);
  }

  /// Resolves a `(principal, token)` pair against the Hub's grants.
  Future<Principal> _fromGrant(String principal, String token) async {
    final domain.Principal resolved;
    try {
      resolved = await hub.config.authenticator.authenticate(
        Credential.token(principal: principal, token: token),
        // Token grants carry no proof-of-possession to bind, so the nonce the
        // node handshake signs has no counterpart on a stateless HTTP request.
        // TLS keeps the token secret in transit.
        challenge: Uint8List(0),
      );
    } on AuthException catch (e) {
      throw UnauthorizedException(e.message);
    }
    if (!hub.config.authorizer.authorize(resolved, apiAction)) {
      throw ForbiddenException(
        '${resolved.id.value} is not permitted to use the HTTP API',
      );
    }
    return Principal(id: resolved.id.value, roles: resolved.roles);
  }

  /// Compares in constant time, as the grant store does: a wrong master token
  /// must not reveal its length or prefix through timing either.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
