import 'dart:convert';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/foundation.dart' show AppError, AppErrorKind;

import 'sse_client.dart';

/// The only thing in the app that touches the Hub.
///
/// It owns the [HubApiClient], normalizes the Hub URL a human typed, and
/// translates every failure into an [AppError] with a message worth showing.
/// Everything above it — controllers, screens — deals in entities and
/// [AppError], never in HTTP.
///
/// Decoding is the client's job, not this layer's: every method below is the
/// matching [HubApiClient] call wrapped in [_guard], and the entities come back
/// typed. The two things this adds are the error translation and the streams,
/// which need the browser's `fetch` rather than the client's transport.
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
      final identity = await client.whoami();
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

  /// Every registered node, optionally narrowed to those matching every one of
  /// [labels] (`key=value`).
  ///
  /// Narrowed by the Hub rather than here: "which of my machines are the
  /// production ones" is a different request from downloading the fleet to find
  /// out, and a blueprint assigned by label wants the first one.
  Future<List<NodeDescriptor>> listNodes({List<String> labels = const []}) =>
      _guard(() => client.nodes(labels: labels));

  /// One node's descriptor.
  Future<NodeDescriptor> node(String id) => _guard(() => client.node(id));

  /// A node's live status: CPU, memory, storage and the process table.
  ///
  /// Null until its first heartbeat, which is "not yet" rather than "no such
  /// node" — the caller shows a waiting state rather than an error.
  Future<NodeStatus?> status(String id) => _guard(() => client.nodeStatus(id));

  /// A node's advertised capabilities.
  Future<NodeCapabilities> capabilities(String id) =>
      _guard(() => client.capabilities(id));

  /// A node's resource history, newest first — for charting.
  Future<List<MetricPoint>> metrics(String id, {String since = '1h'}) =>
      _guard(() => client.metrics(id, since: since));

  /// Operations in flight, and the last few that finished.
  Future<List<Operation>> operations({String? nodeId, bool running = false}) =>
      _guard(() => client.operations(nodeId: nodeId, running: running));

  /// Runs a formula **without waiting** — for work that can outlive a request.
  Future<Operation> runFormulaAsync(
    String id, {
    required String formula,
    required FormulaAction action,
  }) => _guard(
    () => client.runFormulaAsync(id, formula: formula, action: action),
  );

  /// Applies a saved preset **without waiting**.
  Future<Operation> applySavedPresetAsync(String id, String presetId) =>
      _guard(() => client.applyPresetAsync(id, presetId: presetId));

  /// What is wrong right now.
  Future<List<Alert>> alerts() => _guard(client.alerts);

  /// Recent Hub events, newest first.
  Future<List<OmnyEvent>> events() => _guard(client.events);

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
  Future<List<AuditEntry>> audit() => _guard(client.audit);

  /// Restarts a node's agent.
  Future<void> restart(String id) => _guard(() => client.restartAgent(id));

  /// Stops a node's agent.
  Future<void> shutdown(String id) => _guard(() => client.stopAgent(id));

  /// Updates a node's [target] (`agent` by default).
  Future<void> update(String id, {String target = 'agent'}) =>
      _guard(() => client.update(id, target: target));

  /// Runs a formula action on a node.
  Future<FormulaResult> runFormula(
    String id, {
    required String formula,
    required FormulaAction action,
    String? version,
  }) => _guard(() async {
    final reply = await client.runFormula(
      id,
      formula: formula,
      action: action,
      version: version,
    );
    return reply.result;
  });

  /// The formulas a node can run — what the UI offers instead of a text box.
  Future<List<FormulaSpec>> formulas() => _guard(client.formulas);

  /// What state each of a node's formulas is in, asked of the node itself.
  ///
  /// Distinct from [formulas], which is the Hub's catalogue of what a node
  /// *could* run. This is what one node reports it actually has, and whether
  /// what it manages is running — so a node that has never been asked to
  /// install anything answers with a list of absences.
  Future<List<FormulaStatusReport>> formulaStatus(String id) =>
      _guard(() => client.formulaStatus(id));

  /// The presets saved on the Hub.
  Future<List<Preset>> presets() => _guard(client.presets);

  /// Applies a saved preset, by id, to a node.
  Future<List<FormulaResult>> applySavedPreset(String id, String presetId) =>
      _guard(() async {
        final reply = await client.applyPreset(id, presetId: presetId);
        return reply.results;
      });

  /// Applies a preset to a node.
  Future<List<FormulaResult>> applyPreset(String id, Preset preset) =>
      _guard(() async {
        final reply = await client.applyPreset(id, preset: preset);
        return reply.results;
      });

  /// The tail of what a node has reported — oldest first.
  Future<List<LogLine>> logs(String id, {int tail = 200}) =>
      _guard(() => client.logs(id, tail: tail));

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
  ///
  /// Null is not an error; it is the normal state of a node nobody has made a
  /// claim about.
  Future<DesiredState?> desiredState(String id) =>
      _guard(() => client.desiredState(id));

  /// Declares that [id] should be what [preset] describes.
  ///
  /// Runs nothing — see [reconcile].
  Future<void> declare(String id, Preset preset) =>
      _guard(() => client.declarePreset(id, preset));

  /// Stops expecting anything of a node, and leaves the machine as it is.
  ///
  /// For hardware that is gone. [unassign] is the one that takes back what the
  /// blueprint installed.
  Future<void> undeclare(String id) => _guard(() => client.undeclare(id));

  /// Takes the blueprint off a node, removing what it put there.
  ///
  /// Resources the machine already had are released rather than removed unless
  /// [purgeAdopted]. A partial failure leaves the blueprint assigned so it can
  /// be retried — read [BlueprintApplyResult.success] rather than assuming.
  Future<BlueprintApplyResult> unassign(
    String id, {
    bool purgeAdopted = false,
  }) => _guard(() => client.unassign(id, purgeAdopted: purgeAdopted));

  /// How far a node has drifted, or `null` if nothing was declared for it.
  Future<Drift?> drift(String id) => _guard(() => client.drift(id));

  /// Runs whatever the drift plan says is outstanding. Idempotent.
  ///
  /// The node may be declared by a blueprint or by preset steps; the client
  /// reduces both to the same [ConvergeResult]. [dryRun] plans and changes
  /// nothing, which is the safe way to see what an apply would do.
  Future<ConvergeResult> reconcile(String id, {bool dryRun = false}) =>
      _guard(() => client.reconcile(id, dryRun: dryRun));

  // --- Blueprints -----------------------------------------------------------

  /// Every blueprint saved on the Hub.
  Future<List<Blueprint>> blueprints() => _guard(client.blueprints);

  /// One blueprint, as it was authored — source text and all.
  Future<Blueprint> blueprint(String id) => _guard(() => client.blueprint(id));

  /// A blueprint flattened: what a node is actually sent.
  ///
  /// Includes expanded, variables substituted, resources in the order they
  /// would be settled, each naming where it came from and what it overrode.
  Future<ResolvedBlueprint> resolvedBlueprint(String id) =>
      _guard(() => client.resolvedBlueprint(id));

  /// Saves a blueprint on the Hub.
  ///
  /// Refused with a `400` if it could never apply, which surfaces here as an
  /// [AppError] carrying the Hub's own reason — a dependency cycle, an
  /// undeclared variable, an include naming a preset nobody saved.
  Future<void> saveBlueprint(Blueprint blueprint) =>
      _guard(() => client.saveBlueprint(blueprint));

  /// Deletes a saved blueprint.
  Future<void> deleteBlueprint(String id) =>
      _guard(() => client.deleteBlueprint(id));

  /// Says a node should be [blueprint]. Runs nothing.
  Future<void> assignBlueprint(String id, String blueprint) =>
      _guard(() => client.assignBlueprint(id, blueprint));

  // --- Presets ---------------------------------------------------------------

  /// One saved preset.
  Future<Preset> preset(String id) => _guard(() => client.preset(id));

  /// Saves a preset on the Hub, so every operator applies the same one.
  Future<void> savePreset(Preset preset) =>
      _guard(() => client.savePreset(preset));

  /// Deletes a saved preset.
  ///
  /// A blueprint that includes it will stop resolving until it is put back or
  /// the include removed — the Hub says so when that blueprint is next read.
  Future<void> deletePreset(String id) => _guard(() => client.deletePreset(id));

  // --- Credentials ---------------------------------------------------------

  /// Every credential the Hub has issued. Hashes, never tokens.
  Future<List<Grant>> grants() => _guard(client.grants);

  /// Issues a credential, returning the grant **and its token**.
  ///
  /// The token is readable exactly once, here. The Hub keeps a hash and cannot
  /// show it again — so the UI has to put it in front of the operator now, and
  /// say so.
  Future<IssuedGrant> issueGrant({
    required String principal,
    required Set<String> roles,
    String note = '',
  }) => _guard(
    () => client.issueGrant(principal: principal, roles: roles, note: note),
  );

  /// Revokes a credential. The next request with its token fails.
  Future<void> revokeGrant(String id) => _guard(() => client.revokeGrant(id));

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
