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
import '../../domain/value_objects/node_id.dart';
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
        ..get('/api/v1/nodes', (r, p) async => _listNodes())
        ..get('/api/v1/nodes/<id>', (r, p) async => _getNode(p))
        ..get('/api/v1/nodes/<id>/status', (r, p) async => _getStatus(p))
        ..get(
          '/api/v1/nodes/<id>/capabilities',
          (r, p) async => _getCapabilities(p),
        )
        ..get('/api/v1/nodes/<id>/metrics', (r, p) => _getMetrics(r, p))
        ..post('/api/v1/nodes/<id>/restart', (r, p) => _restart(r, p))
        ..post('/api/v1/nodes/<id>/shutdown', (r, p) => _shutdown(r, p))
        ..post('/api/v1/nodes/<id>/update', (r, p) => _update(r, p))
        ..post('/api/v1/nodes/<id>/formula', (r, p) => _formula(r, p))
        ..post('/api/v1/presets/apply', (r, p) => _applyPreset(r))
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

  HubResponse _listNodes() =>
      jsonOk(hub.listNodes().map((n) => n.toJson()).toList());

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
    await hub.restartNode(id, principal: _principal(request));
    return jsonOk({'status': 'restarting', 'nodeId': id.value});
  }

  Future<HubResponse> _shutdown(
    HubRequest request,
    Map<String, String> params,
  ) async {
    final id = _nodeId(params);
    await hub.shutdownNode(id, principal: _principal(request));
    return jsonOk({'status': 'shutting_down', 'nodeId': id.value});
  }

  Future<HubResponse> _update(
    HubRequest request,
    Map<String, String> params,
  ) async {
    final id = _nodeId(params);
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

  Future<HubResponse> _applyPreset(HubRequest request) async {
    final body = await _readJson(request);
    final nodeId = body['nodeId'];
    final presetJson = body['preset'];
    if (nodeId is! String || presetJson is! Map) {
      return ApiErrors.badRequest('nodeId and preset are required');
    }
    final preset = Preset.fromJson(presetJson.cast<String, dynamic>());
    final result = await hub.applyPreset(
      _parseNodeId(nodeId),
      preset,
      principal: _principal(request),
    );
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
