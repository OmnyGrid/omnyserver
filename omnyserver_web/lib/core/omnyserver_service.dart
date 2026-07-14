import 'dart:convert';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/foundation.dart' show AppError, AppErrorKind;

import 'sse_client.dart';

/// The identity the Hub resolved the current credentials to.
class Identity {
  /// The principal id (`alice`, or `api` for the master token).
  final String principal;

  /// The roles the Hub granted.
  final Set<String> roles;

  /// Creates an identity.
  const Identity({required this.principal, required this.roles});

  /// Whether these roles permit operating the fleet, as opposed to only
  /// watching it. The Hub is the real gate — this only decides what the UI
  /// bothers to offer.
  bool get canOperate => roles.contains('admin') || roles.contains('operator');

  /// Decodes `GET /whoami`.
  factory Identity.fromJson(Map<String, dynamic> json) => Identity(
    principal: (json['principal'] as String?) ?? 'anonymous',
    roles: ((json['roles'] as List?) ?? const []).cast<String>().toSet(),
  );
}

/// The only thing in the app that touches the Hub.
///
/// It owns the [HubApiClient], normalizes the Hub URL a human typed, and
/// translates every failure into an [AppError] with a message worth showing.
/// Everything above it — controllers, screens — deals in entities and
/// [AppError], never in HTTP.
///
/// An [ApiTransport] can be injected to drive the whole app against a fake Hub
/// in tests, which is how the dashboard is tested without a socket.
class OmnyServerService {
  /// Injected in tests; `null` in production, where the browser's `fetch` is
  /// used.
  final ApiTransport? transport;

  HubApiClient? _client;
  Identity? _identity;
  Uri? _hubUri;

  /// Creates the service.
  OmnyServerService({this.transport});

  /// Whether credentials have been accepted by the Hub.
  bool get isConnected => _client != null;

  /// The Hub this service is pointed at, once connected.
  Uri? get hubUri => _hubUri;

  /// The authenticated identity, once connected.
  Identity? get identity => _identity;

  /// The live client. Throws if called before [connect].
  HubApiClient get client {
    final c = _client;
    if (c == null) {
      throw const AppError(AppErrorKind.auth, 'Not connected to a Hub.');
    }
    return c;
  }

  /// Authenticates against [hubUri] and resolves the caller's identity.
  ///
  /// [principal] is half of a Hub *grant* (`--grant alice:tok:admin`); leave it
  /// null when using the Hub's master `--api-token`, which has no identity of
  /// its own.
  ///
  /// `whoami` is what makes this a real login rather than a form that always
  /// "succeeds": without it a bad token would sail through and fail on the first
  /// screen instead, and the app could not know which roles it holds.
  Future<Identity> connect({
    required String hubUri,
    String? principal,
    required String token,
  }) async {
    final uri = normalizeHubUri(hubUri);
    final client = HubApiClient(
      uri,
      principal: (principal == null || principal.isEmpty) ? null : principal,
      token: token,
      transport: transport,
    );
    try {
      final me = await client.get('/whoami') as Map;
      final identity = Identity.fromJson(me.cast<String, dynamic>());
      _client = client;
      _identity = identity;
      _hubUri = uri;
      return identity;
    } on Object catch (e) {
      client.close();
      throw _asAppError(e);
    }
  }

  /// Forgets the credentials.
  void disconnect() {
    _client?.close();
    _client = null;
    _identity = null;
    _hubUri = null;
  }

  /// Every registered node.
  Future<List<NodeDescriptor>> listNodes() => _guard(
    () async => ((await client.get('/nodes')) as List)
        .map((n) => NodeDescriptor.fromJson((n as Map).cast<String, dynamic>()))
        .toList(),
  );

  /// One node's descriptor.
  Future<NodeDescriptor> node(String id) => _guard(
    () async => NodeDescriptor.fromJson(
      ((await client.get('/nodes/$id')) as Map).cast<String, dynamic>(),
    ),
  );

  /// A node's live status: CPU, memory, storage and the process table.
  ///
  /// A node has no status until its first heartbeat, so a `404` here means "not
  /// yet", not "no such node" — the caller shows a waiting state rather than an
  /// error.
  Future<NodeStatus?> status(String id) => _guard(() async {
    try {
      return NodeStatus.fromJson(
        ((await client.get('/nodes/$id/status')) as Map)
            .cast<String, dynamic>(),
      );
    } on HubApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  });

  /// A node's advertised capabilities.
  Future<NodeCapabilities> capabilities(String id) => _guard(
    () async => NodeCapabilities.fromJson(
      ((await client.get('/nodes/$id/capabilities')) as Map)
          .cast<String, dynamic>(),
    ),
  );

  /// A node's resource history, newest first — for charting.
  Future<List<MetricPoint>> metrics(String id, {String since = '1h'}) => _guard(
    () async =>
        ((await client.get('/nodes/$id/metrics?since=$since&limit=200'))
                as List)
            .map(
              (p) => MetricPoint.fromJson((p as Map).cast<String, dynamic>()),
            )
            .toList(),
  );

  /// What is wrong right now.
  Future<List<Alert>> alerts() => _guard(
    () async => ((await client.get('/alerts')) as List)
        .map((a) => Alert.fromJson((a as Map).cast<String, dynamic>()))
        .toList(),
  );

  /// Recent Hub events, newest first.
  Future<List<OmnyEvent>> events() => _guard(
    () async => ((await client.get('/events')) as List)
        .map((e) => OmnyEvent.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
  );

  /// Every event as it happens, over Server-Sent Events.
  ///
  /// Not `EventSource`, which cannot send an `Authorization` header and would
  /// force the token into the URL — where it lands in proxy logs and browser
  /// history. `fetch` can carry the header, and its response body is a readable
  /// stream, so the frames are decoded here instead.
  Stream<OmnyEvent> eventStream() {
    final uri = client.baseUrl.replace(path: '/api/v1/events/stream');
    return sseStream(
      uri,
      headers: {
        if (_client?.token != null) 'authorization': 'Bearer ${_client!.token}',
        if (_client?.principal != null) 'x-omny-principal': _client!.principal!,
      },
    ).map(
      (data) => OmnyEvent.fromJson(jsonDecode(data) as Map<String, dynamic>),
    );
  }

  /// Recent audit entries, newest first.
  Future<List<AuditEntry>> audit() => _guard(
    () async => ((await client.get('/audit')) as List)
        .map((e) => AuditEntry.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
  );

  /// Restarts a node.
  Future<void> restart(String id) =>
      _guard(() => client.post('/nodes/$id/restart'));

  /// Shuts a node down.
  Future<void> shutdown(String id) =>
      _guard(() => client.post('/nodes/$id/shutdown'));

  /// Updates a node's [target] (`agent` by default).
  Future<void> update(String id, {String target = 'agent'}) =>
      _guard(() => client.post('/nodes/$id/update', {'target': target}));

  /// Runs a formula action on a node.
  Future<FormulaResult> runFormula(
    String id, {
    required String formula,
    required FormulaAction action,
    String? version,
  }) => _guard(() async {
    final reply = await client.post('/nodes/$id/formula', {
      'formula': formula,
      'action': action.name,
      'version': ?version,
    });
    return FormulaResult.fromJson(
      ((reply as Map)['result'] as Map).cast<String, dynamic>(),
    );
  });

  /// The formulas a node can run — what the UI offers instead of a text box.
  Future<List<FormulaSpec>> formulas() => _guard(
    () async => ((await client.get('/formulas')) as List)
        .map((f) => FormulaSpec.fromJson((f as Map).cast<String, dynamic>()))
        .toList(),
  );

  /// The presets saved on the Hub.
  Future<List<Preset>> presets() => _guard(
    () async => ((await client.get('/presets')) as List)
        .map((p) => Preset.fromJson((p as Map).cast<String, dynamic>()))
        .toList(),
  );

  /// Applies a saved preset, by id, to a node.
  Future<List<FormulaResult>> applySavedPreset(String id, String presetId) =>
      _guard(() async {
        final reply = await client.post('/presets/apply', {
          'nodeId': id,
          'presetId': presetId,
        });
        return ((reply as Map)['results'] as List)
            .map(
              (r) => FormulaResult.fromJson((r as Map).cast<String, dynamic>()),
            )
            .toList();
      });

  /// Applies a preset (decoded JSON) to a node.
  Future<List<FormulaResult>> applyPreset(
    String id,
    Map<String, dynamic> preset,
  ) => _guard(() async {
    final reply = await client.post('/presets/apply', {
      'nodeId': id,
      'preset': preset,
    });
    return ((reply as Map)['results'] as List)
        .map((r) => FormulaResult.fromJson((r as Map).cast<String, dynamic>()))
        .toList();
  });

  /// The tail of what a node has reported — oldest first.
  Future<List<LogLine>> logs(String id, {int tail = 200}) => _guard(
    () async => ((await client.get('/nodes/$id/logs?tail=$tail')) as List)
        .map((l) => LogLine.fromJson((l as Map).cast<String, dynamic>()))
        .toList(),
  );

  /// A node's log, as it happens.
  Stream<LogLine> logStream(String id) {
    final uri = client.baseUrl.replace(path: '/api/v1/nodes/$id/logs/stream');
    return sseStream(
      uri,
      headers: {
        if (_client?.token != null) 'authorization': 'Bearer ${_client!.token}',
        if (_client?.principal != null) 'x-omny-principal': _client!.principal!,
      },
    ).map((data) => LogLine.fromJson(jsonDecode(data) as Map<String, dynamic>));
  }

  // --- Desired state -------------------------------------------------------

  /// What a node is declared to be, or `null` if nothing was ever declared.
  Future<DesiredState?> desiredState(String id) => _guard(() async {
    try {
      return DesiredState.fromJson(
        ((await client.get('/nodes/$id/desired-state')) as Map)
            .cast<String, dynamic>(),
      );
    } on HubApiException catch (e) {
      // Nothing declared is not an error; it is the normal state of a node
      // nobody has made a claim about.
      if (e.statusCode == 404) return null;
      rethrow;
    }
  });

  /// Declares that [id] should be what the saved preset [presetId] describes.
  ///
  /// Runs nothing — see [reconcile].
  Future<void> declare(String id, Map<String, dynamic> preset) =>
      _guard(() => client.put('/nodes/$id/desired-state', {'preset': preset}));

  /// Stops expecting anything of a node.
  Future<void> undeclare(String id) =>
      _guard(() => client.delete('/nodes/$id/desired-state'));

  /// How far a node has drifted, or `null` if nothing was declared for it.
  Future<Drift?> drift(String id) => _guard(() async {
    try {
      final body = (await client.get('/nodes/$id/drift')) as Map;
      return Drift.fromJson(body.cast<String, dynamic>());
    } on HubApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  });

  /// Runs whatever the drift plan says is outstanding. Idempotent.
  Future<List<FormulaResult>> reconcile(String id) => _guard(() async {
    final reply = (await client.post('/nodes/$id/reconcile')) as Map;
    return (reply['results'] as List)
        .map((r) => FormulaResult.fromJson((r as Map).cast<String, dynamic>()))
        .toList();
  });

  // --- Credentials ---------------------------------------------------------

  /// Every credential the Hub has issued. Hashes, never tokens.
  Future<List<Grant>> grants() => _guard(
    () async => ((await client.get('/grants')) as List)
        .map((g) => Grant.fromJson((g as Map).cast<String, dynamic>()))
        .toList(),
  );

  /// Issues a credential, returning the grant **and its token**.
  ///
  /// The token is readable exactly once, here. The Hub keeps a hash and cannot
  /// show it again — so the UI has to put it in front of the operator now, and
  /// say so.
  Future<({Grant grant, String token})> issueGrant({
    required String principal,
    required Set<String> roles,
    String note = '',
  }) => _guard(() async {
    final reply =
        (await client.post('/grants', {
              'principal': principal,
              'roles': roles.toList(),
              'note': note,
            }))
            as Map;
    return (
      grant: Grant.fromJson(reply.cast<String, dynamic>()),
      token: reply['token'] as String,
    );
  });

  /// Revokes a credential. The next request with its token fails.
  Future<void> revokeGrant(String id) =>
      _guard(() => client.delete('/grants/$id'));

  /// Runs [action], translating any failure into an [AppError].
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on Object catch (e) {
      throw _asAppError(e);
    }
  }

  /// Turns a transport or API failure into something worth showing a human.
  ///
  /// The browser is deliberately vague about a blocked cross-origin request —
  /// it reports a generic network failure and withholds the real reason — so the
  /// two causes a dashboard actually hits (the Hub not allowing this origin, and
  /// an untrusted certificate) are named in the hint rather than left to be
  /// guessed at.
  AppError _asAppError(Object error) {
    if (error is AppError) return error;
    if (error is HubApiException) {
      return switch (error.statusCode) {
        401 => AppError(
          AppErrorKind.auth,
          'The Hub rejected these credentials.',
          hint:
              'Check the principal and token. A grant is "principal + its '
              'token"; the master API token takes no principal.',
          cause: error,
        ),
        403 => AppError(
          AppErrorKind.authorization,
          'Your roles do not permit this.',
          hint:
              'The Hub reserves the API for operators — a node credential '
              'can connect nodes but not drive the fleet.',
          cause: error,
        ),
        404 => AppError(AppErrorKind.notFound, error.message, cause: error),
        502 => AppError(
          AppErrorKind.timeout,
          error.message,
          hint: 'The node is offline, or did not answer in time.',
          cause: error,
        ),
        _ => AppError(AppErrorKind.unknown, error.message, cause: error),
      };
    }
    return AppError(
      AppErrorKind.transport,
      'Could not reach the Hub.',
      hint:
          'Check the address. The Hub must allow this origin '
          '(hub start --cors-origin …) and serve a certificate this browser '
          'trusts — a page cannot wave a self-signed one through.',
      cause: error,
    );
  }

  /// Turns what a human types into a base URL: a bare host becomes `https://`,
  /// and the Hub's default port is assumed.
  static Uri normalizeHubUri(String input) {
    var text = input.trim();
    if (text.isEmpty) {
      throw const AppError(AppErrorKind.transport, 'Enter a Hub address.');
    }
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.parse(text);
    return uri.hasPort ? uri : uri.replace(port: 8443);
  }
}
