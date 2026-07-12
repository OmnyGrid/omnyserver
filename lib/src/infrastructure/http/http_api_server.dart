import 'dart:convert';
import 'dart:io';

import 'package:omnyhub/omnyhub.dart'
    show
        Authenticator,
        HandlerService,
        HttpTransport,
        HubRequest,
        HubResponse,
        Middleware,
        OmnyHub,
        Principal,
        RouterService,
        Service,
        StaticTls,
        UnauthorizedException;

import '../../application/hub/event_aggregator.dart';
import '../../application/hub/hub_metrics.dart';
import '../../application/hub/omny_server_hub.dart';
import '../../domain/entities/preset.dart';
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

  OmnyHub? _server;

  /// Creates an API server.
  HttpApiServer({
    required this.hub,
    this.apiToken,
    this.events,
    this.metrics,
    this.host = '0.0.0.0',
    this.port = 8080,
    this.securityContext,
  });

  /// The bound port (valid after [start]).
  int get boundPort => _server?.port ?? port;

  /// The middleware this API needs, outermost first.
  ///
  /// Exposed alongside [buildServices] so a hub hosting the API on a shared port
  /// installs the same request accounting and error envelope.
  List<Middleware> buildMiddleware() => [_countRequests(), apiErrorMapper()];

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

  /// Stops the server.
  Future<void> close() async {
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
    return token == null ? null : _BearerToken(token);
  }

  /// Counts every request that reaches the API, including rejected ones.
  Middleware _countRequests() =>
      (inner) => (request) async {
        metrics?.recordApiRequest();
        return inner(request);
      };

  RouterService _apiService() =>
      RouterService(name: apiServiceName, mount: '/api/v1')
        ..get('/api/v1/nodes', (r, p) async => _listNodes())
        ..get('/api/v1/nodes/<id>', (r, p) async => _getNode(p))
        ..get('/api/v1/nodes/<id>/status', (r, p) async => _getStatus(p))
        ..get(
          '/api/v1/nodes/<id>/capabilities',
          (r, p) async => _getCapabilities(p),
        )
        ..post('/api/v1/nodes/<id>/restart', (r, p) => _restart(r, p))
        ..post('/api/v1/nodes/<id>/shutdown', (r, p) => _shutdown(r, p))
        ..post('/api/v1/nodes/<id>/update', (r, p) => _update(r, p))
        ..post('/api/v1/nodes/<id>/formula', (r, p) => _formula(r, p))
        ..post('/api/v1/presets/apply', (r, p) => _applyPreset(r))
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

  HubResponse _events() =>
      jsonOk((events?.recent() ?? const []).map((e) => e.toJson()).toList());

  Future<HubResponse> _audit() async {
    final recent = await hub.audit.recent();
    return jsonOk(recent.map((e) => e.toJson()).toList());
  }

  String _principal(HubRequest request) =>
      request.header('x-omny-principal') ?? 'api';

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

/// Guards `/api/v1` with a single static bearer token.
///
/// Throws rather than returning `null` for a missing token: an unauthenticated
/// request must surface as `401 unauthorized`, and omnyhub reads a `null`
/// principal as "anonymous", which its authorizer would turn into a `403`.
class _BearerToken implements Authenticator {
  final String token;

  const _BearerToken(this.token);

  @override
  Future<Principal?> authenticate(HubRequest request) async {
    final header = request.header('authorization');
    if (header == null || !header.startsWith('Bearer ')) {
      throw const UnauthorizedException('missing bearer token');
    }
    if (header.substring(7) != token) {
      throw const UnauthorizedException('invalid token');
    }
    return Principal(id: 'api', roles: const {'admin'});
  }
}
