import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../../application/hub/event_aggregator.dart';
import '../../application/hub/hub_metrics.dart';
import '../../application/hub/omny_server_hub.dart';
import '../../domain/entities/preset.dart';
import '../../domain/formula/formula_action.dart';
import '../../shared/errors/omnyserver_exception.dart';
import '../../domain/value_objects/node_id.dart';
import 'api_errors.dart';
import 'openapi.dart';

/// A reusable, versioned REST API in front of an [OmnyServerHub].
///
/// Everything the CLI can do is reachable here too. Routes live under
/// `/api/v1`; `/metrics` (Prometheus) and `/healthz` sit at the root. A bearer
/// [apiToken], when configured, is required for `/api/v1` routes (auth
/// middleware); request bodies are validated and failures return structured
/// JSON errors.
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

  HttpServer? _server;

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

  /// Starts the HTTP server.
  Future<void> start() async {
    final handler = const Pipeline()
        .addMiddleware(_logRequests())
        .addHandler(_route);
    _server = await shelf_io.serve(
      handler,
      host,
      port,
      securityContext: securityContext,
    );
  }

  /// Stops the server.
  Future<void> close() async => _server?.close(force: true);

  Middleware _logRequests() =>
      (inner) => (request) async {
        metrics?.recordApiRequest();
        return inner(request);
      };

  Future<Response> _route(Request request) async {
    final segments = request.url.pathSegments;

    // Root-level, unauthenticated endpoints.
    if (_match(segments, ['healthz'])) {
      return jsonOk({'status': 'ok'});
    }
    if (_match(segments, ['metrics'])) {
      final body = metrics?.render() ?? '';
      return Response.ok(body, headers: const {'content-type': 'text/plain'});
    }

    // Everything else is under /api/v1.
    if (segments.length < 2 || segments[0] != 'api' || segments[1] != 'v1') {
      return ApiErrors.notFound('unknown route');
    }
    final path = segments.sublist(2);

    if (_match(path, ['openapi.json'])) {
      return jsonOk(openApiDocument());
    }

    final authError = _checkAuth(request);
    if (authError != null) return authError;

    try {
      return await _routeV1(request, path);
    } on NotFoundException catch (e) {
      return ApiErrors.notFound(e.message);
    } on NodeUnavailableException catch (e) {
      return ApiErrors.upstream(e.message);
    } on OperationException catch (e) {
      return ApiErrors.upstream(e.message);
    } on OmnyServerTimeoutException catch (e) {
      return ApiErrors.upstream(e.message);
    } on FormatException catch (e) {
      return ApiErrors.badRequest('invalid JSON: ${e.message}');
    }
  }

  Future<Response> _routeV1(Request request, List<String> path) async {
    final method = request.method;

    // /nodes
    if (_match(path, ['nodes']) && method == 'GET') {
      return jsonOk(hub.listNodes().map((n) => n.toJson()).toList());
    }

    // /nodes/{id}...
    if (path.isNotEmpty && path[0] == 'nodes' && path.length >= 2) {
      final id = _parseNodeId(path[1]);
      final rest = path.sublist(2);

      if (rest.isEmpty && method == 'GET') {
        final node = hub.getNode(id);
        if (node == null) throw NotFoundException('unknown node ${id.value}');
        return jsonOk(node.toJson());
      }
      if (_match(rest, ['status']) && method == 'GET') {
        final status = hub.getStatus(id);
        if (status == null) {
          throw NotFoundException('no status for ${id.value}');
        }
        return jsonOk(status.toJson());
      }
      if (_match(rest, ['capabilities']) && method == 'GET') {
        final node = hub.getNode(id);
        if (node == null) throw NotFoundException('unknown node ${id.value}');
        return jsonOk(node.capabilities.toJson());
      }
      if (_match(rest, ['restart']) && method == 'POST') {
        await hub.restartNode(id, principal: _principal(request));
        return jsonOk({'status': 'restarting', 'nodeId': id.value});
      }
      if (_match(rest, ['shutdown']) && method == 'POST') {
        await hub.shutdownNode(id, principal: _principal(request));
        return jsonOk({'status': 'shutting_down', 'nodeId': id.value});
      }
      if (_match(rest, ['update']) && method == 'POST') {
        final body = await _readJson(request);
        final target = (body['target'] as String?) ?? 'agent';
        await hub.updateNode(id, target, principal: _principal(request));
        return jsonOk({'status': 'updating', 'target': target});
      }
      if (_match(rest, ['formula']) && method == 'POST') {
        final body = await _readJson(request);
        final formula = body['formula'];
        if (formula is! String) {
          return ApiErrors.badRequest('formula is required');
        }
        final action = FormulaAction.parse(
          (body['action'] as String?) ?? 'verify',
        );
        final reply = await hub.runFormula(
          id,
          formula,
          action,
          version: body['version'] as String?,
          principal: _principal(request),
        );
        return jsonOk(reply.toJson());
      }
    }

    // /presets/apply
    if (_match(path, ['presets', 'apply']) && method == 'POST') {
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

    // /events
    if (_match(path, ['events']) && method == 'GET') {
      final recent = events?.recent() ?? const [];
      return jsonOk(recent.map((e) => e.toJson()).toList());
    }

    // /audit
    if (_match(path, ['audit']) && method == 'GET') {
      final recent = await hub.audit.recent();
      return jsonOk(recent.map((e) => e.toJson()).toList());
    }

    return ApiErrors.notFound('unknown route');
  }

  Response? _checkAuth(Request request) {
    if (apiToken == null) return null;
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) {
      return ApiErrors.unauthorized('missing bearer token');
    }
    if (header.substring(7) != apiToken) {
      return ApiErrors.unauthorized('invalid token');
    }
    return null;
  }

  String _principal(Request request) =>
      request.headers['x-omny-principal'] ?? 'api';

  NodeId _parseNodeId(String value) {
    try {
      return NodeId(value);
    } on ProtocolException catch (e) {
      throw NotFoundException(e.message);
    }
  }

  Future<Map<String, dynamic>> _readJson(Request request) async {
    final body = await request.readAsString();
    if (body.trim().isEmpty) return {};
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('expected a JSON object');
    }
    return decoded.cast<String, dynamic>();
  }

  bool _match(List<String> segments, List<String> pattern) {
    if (segments.length != pattern.length) return false;
    for (var i = 0; i < segments.length; i++) {
      if (segments[i] != pattern[i]) return false;
    }
    return true;
  }
}
