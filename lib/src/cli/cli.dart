import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:omnyshell/omnyshell_hub.dart' as omnyshell;
import 'package:omnyshell/omnyshell_node.dart' as omnyshell;

import '../../omnyserver_hub.dart';
import '../../omnyserver_node.dart';
import 'ai_command.dart';
import 'api_client.dart';
import 'api_transport_io.dart';
import 'blueprint_format.dart';
import 'cli_error.dart';
import 'service_commands.dart';
import 'start_options.dart';

export 'cli_error.dart';

/// Builds the OmnyServer [CommandRunner] with every command wired to the public
/// runtimes and the Hub HTTP API.
CommandRunner<void> buildRunner() {
  final runner =
      CommandRunner<void>(
          'omnyserver',
          'OmnyServer v$omnyServerVersion — distributed server orchestration.',
        )
        ..argParser.addFlag(
          'version',
          abbr: 'V',
          negatable: false,
          help: 'Print the omnyserver version and exit.',
        )
        ..addCommand(HubCommand())
        ..addCommand(NodeCommand())
        ..addCommand(ServiceCommand())
        ..addCommand(AiCliCommand())
        ..addCommand(NodesCommand())
        ..addCommand(PresetCommand())
        ..addCommand(BlueprintCommand())
        ..addCommand(FormulaCommand())
        ..addCommand(StateCommand())
        ..addCommand(GrantCommand())
        ..addCommand(EventsCommand())
        ..addCommand(OpsCommand())
        ..addCommand(AlertsCommand())
        ..addCommand(AuditCommand())
        ..addCommand(WhoamiCommand())
        ..addCommand(CertCommand());
  return runner;
}

/// Runs the CLI with [args], handling usage and CLI errors with exit codes.
Future<void> runOmnyServerCli(List<String> args) async {
  final runner = buildRunner();
  try {
    final top = runner.parse(args);
    if (top['version'] as bool) {
      stdout.writeln('omnyserver $omnyServerVersion');
      return;
    }
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  } on CliError catch (e) {
    stderr.writeln('error: ${e.message}');
    exitCode = 1;
  } on HubApiException catch (e) {
    stderr.writeln('error: ${e.message}');
    exitCode = 1;
  } on OmnyServerException catch (e) {
    // A classified runtime failure that reached the top — e.g. a node whose
    // credential the Hub rejected outright (terminal auth). Print the message,
    // not a stack trace.
    stderr.writeln('error: ${e.message}');
    exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// API connection options shared by client commands.
// ---------------------------------------------------------------------------

void _addApiOptions(ArgParser parser) {
  parser
    ..addOption(
      'api',
      help: 'Hub HTTP API base URL (shares the Hub port).',
      defaultsTo: 'https://127.0.0.1:8443',
    )
    ..addOption(
      'token',
      help:
          "Bearer token for the Hub HTTP API: the Hub's --api-token, or a "
          'token granted to --principal.',
    )
    ..addOption(
      'principal',
      help:
          'Principal the --token was granted to (--grant principal:token:roles). '
          'The Hub verifies the pair and takes your roles from the grant.',
    )
    ..addOption('ca', help: "CA certificate (PEM) trusting the Hub's cert.")
    ..addFlag(
      'insecure',
      negatable: false,
      help: 'Skip TLS verification (dev Hubs only).',
    );
}

HubApiClient _apiClientFrom(ArgResults args) {
  final ca = args['ca'] as String?;
  return HubApiClient(
    Uri.parse(args['api'] as String),
    token: args['token'] as String?,
    principal: args['principal'] as String?,
    // TLS is a property of the transport, not of the API: a browser cannot be
    // handed a SecurityContext, so those knobs live on the VM transport.
    transport: IoApiTransport(
      securityContext: ca == null
          ? null
          : (SecurityContext(withTrustedRoots: true)
              ..setTrustedCertificates(ca)),
      allowBadCertificate: args['insecure'] as bool,
    ),
  );
}

// ---------------------------------------------------------------------------
// Fleet selectors: how a command says which nodes it means.
// ---------------------------------------------------------------------------

/// Adds `--label`, `--node` and `--all` to a command that operates on nodes.
void _addSelectorOptions(ArgParser parser) {
  parser
    ..addMultiOption(
      'label',
      help: 'Select nodes by label "key=value" (repeatable; all must match).',
    )
    ..addMultiOption('node', help: 'Select a node by id (repeatable).')
    ..addFlag('all', negatable: false, help: 'Select every registered node.');
}

/// Resolves the selector into the node ids to act on.
///
/// One positional id, `--node`, `--label` or `--all`. A selector that matches
/// nothing is an error rather than a silent success: "applied to 0 nodes" reads
/// like it worked, and is how a typo in a label goes unnoticed until someone
/// wonders why production never changed.
Future<List<String>> _selectNodes(
  HubApiClient client,
  ArgResults args, {
  List<String> positional = const [],
}) async {
  final ids = <String>{...positional, ...args['node'] as List<String>};
  final labels = args['label'] as List<String>;
  final all = args['all'] as bool;

  if (ids.isEmpty && labels.isEmpty && !all) {
    throw CliError(
      'name a node, or select some: --node <id>, --label key=value, --all',
    );
  }
  // Explicit ids are taken at face value; the Hub will say if one is unknown.
  if (ids.isNotEmpty && labels.isEmpty && !all) return ids.toList()..sort();

  final matched = [
    for (final node in await client.nodes(labels: labels)) node.id.value,
    ...ids,
  ];

  if (matched.isEmpty) {
    throw CliError(
      labels.isEmpty
          ? 'no nodes are registered'
          : 'no node matches ${labels.join(' ')}',
    );
  }
  return matched.toSet().toList()..sort();
}

/// Runs [action] against every selected node, printing a result per node.
///
/// Sequential on purpose: these are fleet-changing operations, and a failure
/// halfway through a hundred nodes is far easier to reason about when the ones
/// before it are known to have finished. Each line is printed as it lands, so a
/// long run is not a silent wait.
Future<void> _fanOut(
  List<String> nodes,
  Future<String> Function(String nodeId) action,
) async {
  var failed = 0;
  for (final node in nodes) {
    try {
      final outcome = await action(node);
      stdout.writeln('${node.padRight(20)} $outcome');
    } on HubApiException catch (e) {
      failed++;
      stderr.writeln('${node.padRight(20)} failed: ${e.message}');
    }
  }
  if (nodes.length > 1) {
    stdout.writeln('\n${nodes.length - failed}/${nodes.length} succeeded');
  }
  if (failed > 0) exitCode = 1;
}

/// Reads a Server-Sent Events response, calling [onEvent] with each payload.
///
/// The response never ends, so this drives the socket directly rather than going
/// through [HubApiClient], which buffers a body to completion — it would wait
/// forever for a stream designed never to finish.
Future<void> _streamSse(
  ArgResults args,
  String path, {
  required void Function(Map<dynamic, dynamic> payload) onEvent,
  String? banner,
}) async {
  final base = Uri.parse(args['api'] as String);
  final ca = args['ca'] as String?;
  final http = HttpClient(
    context: ca == null
        ? null
        : (SecurityContext(withTrustedRoots: true)..setTrustedCertificates(ca)),
  );
  if (args['insecure'] as bool) {
    http.badCertificateCallback = (_, _, _) => true;
  }

  try {
    final request = await http.getUrl(base.replace(path: path));
    final token = args['token'] as String?;
    final principal = args['principal'] as String?;
    if (token != null) request.headers.set('authorization', 'Bearer $token');
    if (principal != null) {
      request.headers.set('x-omny-principal', principal);
    }
    final response = await request.close();
    if (response.statusCode >= 400) {
      final body = await response.transform(utf8.decoder).join();
      throw CliError(
        'stream failed (HTTP ${response.statusCode}): ${body.trim()}',
      );
    }

    if (banner != null) stdout.writeln(banner);
    // SSE frames a `data:` line per event and dispatches on a blank line;
    // comment lines (`: ping`) are keep-alives and carry nothing.
    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final payload = jsonDecode(line.substring(6));
      if (payload is Map) onEvent(payload);
    }
  } finally {
    http.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// hub
// ---------------------------------------------------------------------------

/// `omnyserver hub …`
class HubCommand extends Command<void> {
  /// Creates the hub command group.
  HubCommand() {
    addSubcommand(HubStartCommand());
    addSubcommand(HubMetricsCommand());
  }

  @override
  String get name => 'hub';

  @override
  String get description => 'Manage the OmnyServer Hub.';
}

/// `omnyserver hub metrics`
class HubMetricsCommand extends Command<void> {
  /// Creates the hub-metrics command.
  HubMetricsCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'metrics';

  @override
  String get description => "Print the Hub's Prometheus metrics.";

  @override
  Future<void> run() async {
    final client = _apiClientFrom(argResults!);
    try {
      // `/metrics` is Prometheus text outside the versioned API, and it is not
      // token-gated — so this works against any reachable Hub.
      stdout.write(await client.getText('/metrics'));
    } finally {
      client.close();
    }
  }
}

/// `omnyserver hub start`
class HubStartCommand extends Command<void> {
  /// What the command waits on before closing the Hub down.
  final Future<void> Function() _untilStopped;

  /// Creates the hub-start command.
  ///
  /// [untilStopped] is what "stop" means: Ctrl-C in production. A test passes a
  /// future of its own so the whole configure/serve/close path runs to the end
  /// without a signal — the alternative is a subprocess, whose coverage the VM
  /// collector never sees.
  HubStartCommand({Future<void> Function()? untilStopped})
    : _untilStopped = untilStopped ?? _awaitSignal {
    addHubStartOptions(argParser);
  }

  @override
  String get name => 'start';

  @override
  String get description =>
      'Start the Hub: the node control channel and the HTTP API, on one '
      'TLS port.';

  @override
  Future<void> run() async {
    final args = argResults!;
    // Either a directory the Hub reloads on renewal, or a static cert/key pair.
    final tlsDir = validateHubTls(args);
    final context = tlsDir != null
        ? null
        : (SecurityContext()
            ..useCertificateChain(args['cert'] as String)
            ..usePrivateKey(args['key'] as String));

    final grants = _parseGrants(args['grant'] as List<String>);
    final nodePath = args['node-path'] as String;
    final shellPath = args['shell-path'] as String;
    final withShell = args['shell'] as bool;

    // The Hub persists by default, in <OMNYSERVER_HOME>/hub. Only --ephemeral
    // opts out — and it says so out loud, because a Hub that keeps nothing
    // forgets the fleet, the audit trail and every credential it issued, on
    // every restart. An explicit --data-dir is used as given.
    final dataDir = resolveHubDataDir(args);
    final persistent = dataDir != null;
    final grantStore = persistent
        ? JsonGrantRepository(dataDir)
        : MemoryGrantRepository();

    final hub = OmnyServerHub(
      HubConfig(
        host: args['host'] as String,
        port: int.parse(args['port'] as String),
        nodeMount: nodePath,
        shellMount: shellPath,
        securityContext: context,
        tlsDirectory: tlsDir,
        // Two sources of credentials, tried in order: the ones baked into this
        // command line, then the ones the Hub has issued at runtime. That is what
        // lets a Hub be bootstrapped from flags and then hand out (and take back)
        // credentials without a restart.
        authenticator: CompositeAuthenticator([
          TokenAuthenticator(grants),
          GrantAuthenticator(grantStore),
        ]),
        grantRepository: grantStore,
        nodeRepository: persistent ? JsonNodeRepository(dataDir) : null,
        presetRepository: persistent ? JsonPresetRepository(dataDir) : null,
        blueprintRepository: persistent
            ? JsonBlueprintRepository(dataDir)
            : null,
        formulaRepository: persistent ? JsonFormulaRepository(dataDir) : null,
        auditRepository: persistent ? JsonAuditRepository(dataDir) : null,
        metricRepository: persistent ? JsonMetricRepository(dataDir) : null,
        desiredStateRepository: persistent
            ? JsonDesiredStateRepository(dataDir)
            : null,
        corsOrigins: args['cors-origin'] as List<String>,
        alertRules: [
          for (final raw in args['alert'] as List<String>) AlertRule.parse(raw),
        ],
        logger: stdout.writeln,
      ),
    );

    // An OmnyShell broker on the same listener, sharing the Hub's credentials —
    // so one Hub serves both fleets and `omnyshell node start --hub …/shell`
    // just works. It authenticates in band, so it takes no connection
    // authenticator; OmnyServer's own handshake stays on the node route.
    omnyshell.AiConfig? aiConfig;
    if (withShell) {
      // The AI provider the broker proxies for the web dashboard's :ai — key
      // injected on the Hub so no browser holds it. Null when unconfigured.
      aiConfig = omnyshell.AiConfigIo.load(
        path: omnyServerAiConfigPath(args['ai-config'] as String?),
      );
      final shell = ShellHub.fromGrants(
        grants,
        mount: shellPath,
        logger: stdout.writeln,
        aiConfig: aiConfig,
      );
      hub.registerService(shell.service());
    }

    // One listener, two surfaces: nodes upgrade to a WebSocket on `nodePath`,
    // operators call the REST API on the same host and port. The API rides the
    // Hub's TLS instead of a second plaintext socket.
    final events = EventAggregator()..attach(hub.config.eventBus);
    final metrics = HubMetrics(hub.registry)..attach(hub.config.eventBus);
    final api = HttpApiServer(
      hub: hub,
      apiToken: args['api-token'] as String?,
      events: events,
      metrics: metrics,
    );
    // CORS goes on the *outermost* layer: a browser must be able to read a 401
    // or a 404 (they are rendered above ordinary middleware, which would
    // therefore never stamp them), and a preflight arrives with no credentials
    // and must be answered before the authenticator rejects it.
    final corsMiddleware = api.corsMiddleware();
    if (corsMiddleware != null) hub.useOuter(corsMiddleware);
    for (final middleware in api.buildMiddleware()) {
      hub.use(middleware);
    }
    for (final service in api.buildServices()) {
      hub.registerService(
        service,
        authenticator: service.name == HttpApiServer.apiServiceName
            ? api.tokenAuthenticator()
            : null,
      );
    }

    await hub.start();

    final host = args['host'] as String;
    stdout.writeln('Hub nodes: wss://$host:${hub.port}$nodePath');
    if (withShell) {
      stdout.writeln('Hub shell: wss://$host:${hub.port}$shellPath');
    }
    stdout.writeln('Hub API:   https://$host:${hub.port}/api/v1');
    stdout.writeln(
      persistent
          ? 'Hub data:  $dataDir'
          : 'Hub data:  in memory (--ephemeral) — a restart forgets the fleet.',
    );
    if (withShell) {
      stdout.writeln(
        aiConfig == null
            ? 'Hub AI:    not configured — the dashboard\'s :ai has no default '
                  '(run: omnyserver ai config).'
            : 'Hub AI:    ${aiConfig.provider.wireName} — proxying :ai for web '
                  'clients (the key stays on the Hub).',
      );
    }
    // Installing no CORS at all is the correct behaviour for a Hub with no
    // browser client, and indistinguishable — from the browser's side — from a
    // Hub that rejected the origin. Say which it is, or the next person debugs
    // it from a browser console. A wildcard says so too: it is a widening, and
    // one nobody should discover by reading the flags months later.
    final corsOrigins = args['cors-origin'] as List<String>;
    if (corsOrigins.isEmpty) {
      stdout.writeln(
        'Hub CORS:  no origins configured — a browser dashboard will be '
        'blocked (pass --cors-origin).',
      );
    } else if (corsOrigins.any(HttpApiServer.isAnyOrigin)) {
      stdout.writeln(
        'Hub CORS:  any origin allowed (*) — any page may call this API. It '
        'still needs a token; the browser supplies none of its own.',
      );
    }
    // The API is controlled with the --api-token or a --grant pair, and nothing
    // else. With neither, every request is refused — which is the safe failure,
    // but a silent one: the Hub would look healthy and answer nobody.
    if (args['api-token'] == null && grants.isEmpty) {
      stdout.writeln(
        'Hub AUTH:  no --api-token and no --grant — the HTTP API can '
        'authenticate nobody. Every call will be a 401.',
      );
    }
    stdout.writeln('Press Ctrl-C to stop.');
    await _untilStopped();
    await hub.close();
  }

  Map<String, TokenGrant> _parseGrants(List<String> raw) {
    final grants = <String, TokenGrant>{};
    for (final entry in raw) {
      final parts = entry.split(':');
      if (parts.length < 2) {
        throw CliError('invalid --grant "$entry" (want principal:token:roles)');
      }
      final roles = parts.length > 2 && parts[2].isNotEmpty
          ? parts[2].split(',').toSet()
          : <String>{};
      grants[parts[1]] = TokenGrant(
        principal: PrincipalId(parts[0]),
        roles: roles,
      );
    }
    return grants;
  }
}

// ---------------------------------------------------------------------------
// node
// ---------------------------------------------------------------------------

/// `omnyserver node …`
class NodeCommand extends Command<void> {
  /// Creates the node command group.
  NodeCommand() {
    addSubcommand(NodeStartCommand());
    addSubcommand(NodeShowCommand());
    addSubcommand(NodeStatusCommand());
    addSubcommand(NodeMetricsCommand());
    addSubcommand(NodeLogsCommand());
    addSubcommand(NodeCapabilitiesCommand());
    addSubcommand(NodeRestartCommand());
    addSubcommand(NodeShutdownCommand());
    addSubcommand(NodeUpdateCommand());
  }

  @override
  String get name => 'node';

  @override
  String get description => 'Manage and run OmnyServer Node agents.';
}

/// `omnyserver node start`
class NodeStartCommand extends Command<void> {
  /// What the command waits on before shutting the agent down.
  final Future<void> Function() _untilStopped;

  /// How the command leaves — see the note on [run] about why it is an
  /// [exit] rather than a return.
  final void Function(int code) _leave;

  /// Creates the node-start command.
  ///
  /// [untilStopped] and [leave] are seams: Ctrl-C and [exit] in production, and
  /// in a test a future it can complete and a recorder for the exit code — so
  /// the agent's whole lifecycle runs in-process, where coverage is collected
  /// and where `exit` would otherwise take the test runner with it.
  NodeStartCommand({
    Future<void> Function()? untilStopped,
    void Function(int code)? leave,
  }) : _untilStopped = untilStopped ?? _awaitSignal,
       _leave = leave ?? exit {
    addNodeStartOptions(argParser);
    argParser.addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help:
          "Show the connection lifecycle, not just failures — every attempt, "
          'handshake and heartbeat.',
    );
  }

  @override
  String get name => 'start';

  @override
  String get description => 'Run a Node agent, connecting to the Hub over WSS.';

  @override
  Future<void> run() async {
    final args = argResults!;
    validateNodeStartArgs(args);
    final hub = args['hub'] as String;
    final id = args['id'] as String;
    final token = args['token'] as String;
    final ca = args['ca'] as String?;
    final context = ca == null
        ? null
        : (SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificates(ca));

    final registry = FormulaRegistry.standard();

    // `node restart` and `node shutdown` act on *this agent*, not on the host,
    // and only the command owning its lifecycle can end it. Completing this is
    // what stops the agent: the exit code then tells a supervisor whether to
    // bring it back — non-zero for a restart, zero for a shutdown, which is
    // what `Restart=on-failure` and Docker's `restart: on-failure` honour.
    final stopped = Completer<int>();
    void stop(int code) {
      if (!stopped.isCompleted) stopped.complete(code);
    }

    final updateService = UpdateService(
      onRestartAgent: () async => stop(agentRestartExitCode),
      onStopAgent: () async => stop(0),
    );
    const monitor = SystemMonitor();
    final scanner = CapabilityScanner.standard();

    // The agent's log goes to this terminal *and*, unless asked not to, to the
    // Hub — so an operator can read what a node is doing without logging into
    // it. The shipper is late-bound because it needs the agent, and the agent's
    // config needs the logger.
    LogShipper? shipper;
    void log(String message) {
      stdout.writeln(message);
      shipper?.add(message);
    }

    // A formula's output goes the same way, so an operator can watch an install
    // happen rather than wait to be told how it went. Until this was wired the
    // lines were produced and dropped: nothing was listening.
    final formulaService = NodeFormulaService(registry: registry, onLog: log);

    // Blueprints run over the same formulas, through a provider. The ledger goes
    // on disk, under the node's own home: an in-memory one would forget what the
    // node owns on every restart, and a node that has forgotten what it owns can
    // never really have a blueprint unassigned from it — it would adopt
    // everything it found and remove nothing.
    final blueprintService = NodeBlueprintService(
      providers: ProviderRegistry.of([FormulaProvider(registry: registry)]),
      ledgers: FileLedgerStore(OmnyServerHome.ensure().path),
      onLog: log,
    );

    final agentConfig = NodeAgentConfig(
      hubUri: Uri.parse(hub),
      nodeId: id,
      credentials: TokenCredentialProvider(
        principal: args['principal'] as String,
        token: token,
      ),
      securityContext: context,
      onBadCertificate: (args['insecure'] as bool)
          ? (cert, host, port) => true
          : null,
      labels: _parseLabels(args['label'] as List<String>, 'label'),
      statusProvider: monitor.snapshot,
      capabilityProvider: scanner.scan,
      formulaHandler: formulaService.runFormula,
      formulaStatusHandler: formulaService.reportStatus,
      blueprintPlanHandler: blueprintService.plan,
      blueprintApplyHandler: blueprintService.apply,
      presetHandler: formulaService.applyPreset,
      nodeControlHandler: updateService.handle,
      logger: log,
      verbose: args['verbose'] as bool,
    );
    final agent = NodeAgent(agentConfig);
    if (args['ship-logs'] as bool) {
      shipper = LogShipper(send: agent.sendLogs);
    }
    // Say what it is doing before it blocks: start() only returns once the node
    // has registered, so without this a slow — or rejected — connection is a
    // silent hang. The runtime's logger (wired in NodeAgent) then reports any
    // failure and its reason.
    log('Connecting to ${agentConfig.controlUri} …');
    await agent.start();
    log('Node "$id" connected to $hub.');

    // The same machine, also serving shell sessions — one process, one service
    // unit, one supervision target. It is an independent runtime speaking
    // OmnyShell's protocol on the Hub's shell mount; the two share only the
    // credentials and the certificate.
    final shellNode = (args['with-shell'] as bool)
        ? await _startShellNode(
            hubUri: Uri.parse(hub),
            shellPath: args['shell-path'] as String,
            nodeId: id,
            principal: args['principal'] as String,
            token: token,
            securityContext: context,
            insecure: args['insecure'] as bool,
            labels: _parseLabels(
              args['shell-label'] as List<String>,
              'shell-label',
            ),
          )
        : null;

    stdout.writeln('Press Ctrl-C to stop.');
    // Ctrl-C, or the Hub asking this agent to restart or stop. Either way the
    // same orderly shutdown runs; only the exit code differs.
    final code = await Future.any([
      _untilStopped().then((_) => 0),
      stopped.future,
    ]);
    if (code != 0) log('Stopping: the Hub asked this agent to restart.');
    shipper?.close();
    await shellNode?.shutdown();
    await agent.stop();
    // Leave deliberately rather than waiting for the isolate to run dry. A
    // long-running agent holds handles that outlive the work — the signal
    // watcher above among them — and the exit code is the whole contract here:
    // non-zero asks a supervisor for the agent back, zero leaves it stopped.
    _leave(code);
  }

  /// Starts an OmnyShell node alongside the OmnyServer agent.
  Future<omnyshell.NodeRuntime> _startShellNode({
    required Uri hubUri,
    required String shellPath,
    required String nodeId,
    required String principal,
    required String token,
    required SecurityContext? securityContext,
    required bool insecure,
    required Map<String, String> labels,
  }) async {
    final shellUri = hubUri.replace(path: shellPath);
    final node = omnyshell.NodeRuntime(
      omnyshell.NodeConfig(
        hubUri: shellUri,
        nodeId: omnyshell.NodeId(nodeId),
        credentials: omnyshell.TokenCredentialProvider(
          principal: principal,
          token: token,
        ),
        backend: _shellBackend(),
        labels: labels,
        securityContext: securityContext,
        onBadCertificate: insecure ? (cert, host, port) => true : null,
        // Both runtimes persist a machine-keyed UID; without separate homes they
        // would contend on the same file and warn about it changing under them.
        home: OmnyServerHome.resolve(),
        logger: stdout.writeln,
      ),
    );
    await node.connect();
    stdout.writeln('Shell node "$nodeId" connected to $shellUri.');
    return node;
  }

  /// The PTY backend for shell sessions, matching what `omnyshell node start`
  /// uses: a real PTY where one exists, decorating a plain pipe fallback.
  /// `script(1)` is POSIX-only, so Windows takes the winpty path.
  omnyshell.ShellBackend _shellBackend() {
    final pipe = omnyshell.ProcessShellBackend();
    return Platform.isWindows
        ? omnyshell.WinptyShellBackend(
            fallback: pipe,
            onWarning: stderr.writeln,
          )
        : omnyshell.ScriptPtyShellBackend(
            fallback: pipe,
            onWarning: stderr.writeln,
          );
  }

  /// Parses `key=value` labels, naming [option] in the error — the agent's own
  /// `--label` and the shell node's `--shell-label` come through here, and an
  /// operator who mistyped one should not be sent to look at the other.
  Map<String, String> _parseLabels(List<String> raw, String option) {
    final labels = <String, String>{};
    for (final entry in raw) {
      final i = entry.indexOf('=');
      if (i <= 0) {
        throw CliError('invalid --$option "$entry" (want key=value)');
      }
      labels[entry.substring(0, i)] = entry.substring(i + 1);
    }
    return labels;
  }
}

/// `omnyserver node status <id>`
class NodeStatusCommand extends Command<void> {
  /// Creates the node-status command.
  NodeStatusCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'status';

  @override
  String get description => 'Show a node live status (via the Hub API).';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: node status <id>');
    final client = _apiClientFrom(argResults!);
    try {
      final status = await client.nodeStatus(rest.first);
      if (status == null) {
        stdout.writeln('no status yet — the node has not heartbeated');
        return;
      }
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(status.toJson()),
      );
    } finally {
      client.close();
    }
  }
}

/// `omnyserver node show <id>`
class NodeShowCommand extends Command<void> {
  /// Creates the node-show command.
  NodeShowCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a node descriptor (via the Hub API).';

  @override
  Future<void> run() => _showJson(
    argResults!,
    'node show',
    (client, id) async => (await client.node(id)).toJson(),
  );
}

/// `omnyserver node capabilities <id>`
class NodeCapabilitiesCommand extends Command<void> {
  /// Creates the node-capabilities command.
  NodeCapabilitiesCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'capabilities';

  @override
  String get description =>
      "Show a node's advertised capabilities (via the Hub API).";

  @override
  Future<void> run() => _showJson(
    argResults!,
    'node capabilities',
    (client, id) async => (await client.capabilities(id)).toJson(),
  );
}

/// `omnyserver node metrics <id>`
class NodeMetricsCommand extends Command<void> {
  /// Creates the node-metrics command.
  NodeMetricsCommand() {
    _addApiOptions(argParser);
    argParser
      ..addOption(
        'since',
        help:
            'Window back from now (30s, 15m, 1h, 7d) or an ISO-8601 instant. '
            'Defaults to everything retained.',
      )
      ..addOption('limit', defaultsTo: '100', help: 'Maximum samples.')
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit the raw series instead of a table.',
      );
  }

  @override
  String get name => 'metrics';

  @override
  String get description =>
      "Show a node's resource history — the samples the Hub has been recording "
      'on every heartbeat.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) throw CliError('usage: node metrics <id> [--since 1h]');
    final since = args['since'] as String?;

    final client = _apiClientFrom(args);
    try {
      final points = await client.metrics(
        rest.first,
        since: since ?? '1h',
        limit: int.tryParse(args['limit'] as String) ?? 200,
      );
      if (args['json'] as bool) {
        stdout.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert([for (final p in points) p.toJson()]),
        );
        return;
      }
      if (points.isEmpty) {
        stdout.writeln('no samples (the node may not have heartbeated yet)');
        return;
      }
      stdout.writeln('AT                        CPU%    MEM%   DISK%');
      // Newest first from the API; print oldest first so it reads as a timeline.
      for (final p in points.reversed) {
        final mem = _pct(p.memoryUsedBytes, p.memoryTotalBytes);
        final disk = _pct(p.storageUsedBytes, p.storageCapacityBytes);
        stdout.writeln(
          '${p.at.toLocal().toString().padRight(26)}'
          '${p.cpuPercent.toStringAsFixed(1).padLeft(5)}  '
          '${mem.padLeft(6)}  ${disk.padLeft(6)}',
        );
      }
    } finally {
      client.close();
    }
  }

  static String _pct(int used, int total) {
    if (total <= 0) return '—';
    return '${(used / total * 100).toStringAsFixed(0)}%';
  }
}

/// `omnyserver node logs <id>`
class NodeLogsCommand extends Command<void> {
  /// Creates the node-logs command.
  NodeLogsCommand() {
    _addApiOptions(argParser);
    argParser
      ..addOption('tail', defaultsTo: '200', help: 'How many lines to show.')
      ..addFlag(
        'follow',
        abbr: 'f',
        negatable: false,
        help: 'Keep printing lines as the node reports them.',
      );
  }

  @override
  String get name => 'logs';

  @override
  String get description =>
      "Show a node's log — the tail the Hub keeps, without logging into the "
      'machine.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) throw CliError('usage: node logs <id> [-f]');
    final node = rest.first;

    final client = _apiClientFrom(args);
    try {
      final lines = await client.logs(
        node,
        tail: int.tryParse(args['tail'] as String) ?? 200,
      );
      if (lines.isEmpty && !(args['follow'] as bool)) {
        stdout.writeln(
          'no logs from $node yet '
          '(the node must run with --ship-logs, which is the default)',
        );
        return;
      }
      for (final line in lines) {
        stdout.writeln(_render(line));
      }
    } finally {
      client.close();
    }

    if (args['follow'] as bool) {
      // The stream is raw SSE frames, not the typed client — there is no
      // typed streaming yet, and a follow that decoded differently from the
      // tail above would print two formats in one run.
      await _streamSse(
        args,
        '/api/v1/nodes/$node/logs/stream',
        onEvent: (payload) => stdout.writeln(
          _render(LogLine.fromJson(payload.cast<String, dynamic>())),
        ),
      );
    }
  }

  static String _render(LogLine line) {
    final at = line.at.toLocal().toString().split('.');
    return '${at.first}  ${line.source}  ${line.message}';
  }
}

/// `omnyserver node restart <id>`
class NodeRestartCommand extends Command<void> {
  /// Creates the node-restart command.
  NodeRestartCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'restart';

  @override
  String get description =>
      'Restart the OmnyServer agent on a node — not the machine.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: node restart <id>');
    final client = _apiClientFrom(argResults!);
    try {
      await client.restartAgent(rest.first);
      stdout.writeln('agent restart requested on ${rest.first}');
    } finally {
      client.close();
    }
  }
}

/// `omnyserver node shutdown <id>`
class NodeShutdownCommand extends Command<void> {
  /// Creates the node-shutdown command.
  NodeShutdownCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'shutdown';

  @override
  String get description =>
      'Stop the OmnyServer agent on a node — not the machine. The node goes '
      'offline until something starts it again.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: node shutdown <id>');
    final client = _apiClientFrom(argResults!);
    try {
      await client.stopAgent(rest.first);
      stdout.writeln('agent shutdown requested on ${rest.first}');
    } finally {
      client.close();
    }
  }
}

/// `omnyserver node update <id>`
class NodeUpdateCommand extends Command<void> {
  /// Creates the node-update command.
  NodeUpdateCommand() {
    _addApiOptions(argParser);
    argParser.addOption(
      'target',
      defaultsTo: 'agent',
      help: 'What to update on the node.',
    );
  }

  @override
  String get name => 'update';

  @override
  String get description => 'Update a node (via the Hub API).';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw CliError('usage: node update <id> [--target agent]');
    }
    final client = _apiClientFrom(argResults!);
    try {
      final target = argResults!['target'] as String;
      await client.update(rest.first, target: target);
      stdout.writeln('update ($target) requested for ${rest.first}');
    } finally {
      client.close();
    }
  }
}

/// Reads one entity for the id in the first positional argument and prints it
/// as JSON — the shape every read-only `show` command shares.
///
/// [fetch] returns the decoded entity, so a field the Hub renamed fails here
/// rather than printing a document with a hole in it. `null` means the thing is
/// not there, which every caller reports the same way.
Future<void> _showJson(
  ArgResults args,
  String usage,
  Future<Map<String, dynamic>?> Function(HubApiClient client, String id) fetch,
) async {
  final rest = args.rest;
  if (rest.isEmpty) throw CliError('usage: $usage <id>');
  final client = _apiClientFrom(args);
  try {
    final body = await fetch(client, rest.first);
    if (body == null) throw CliError('nothing found for ${rest.first}');
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(body));
  } finally {
    client.close();
  }
}

// ---------------------------------------------------------------------------
// nodes
// ---------------------------------------------------------------------------

/// `omnyserver nodes …`
class NodesCommand extends Command<void> {
  /// Creates the nodes command group.
  NodesCommand() {
    addSubcommand(NodesListCommand());
  }

  @override
  String get name => 'nodes';

  @override
  String get description => 'Discover nodes registered with the Hub.';
}

/// `omnyserver nodes list`
class NodesListCommand extends Command<void> {
  /// Creates the nodes-list command.
  NodesListCommand() {
    _addApiOptions(argParser);
    argParser
      ..addMultiOption(
        'label',
        help: 'Only nodes with this label "key=value" (repeatable).',
      )
      ..addFlag(
        'online',
        help: 'Only online (or, negated, only offline) nodes.',
      )
      ..addFlag(
        'offline',
        negatable: false,
        help: 'Only offline nodes — the ones that want attention.',
      );
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List registered nodes (via the Hub API).';

  @override
  Future<void> run() async {
    final args = argResults!;
    final labels = args['label'] as List<String>;
    final online = (args['offline'] as bool)
        ? false
        : (args.wasParsed('online') ? args['online'] as bool : null);
    final narrowed = labels.isNotEmpty || online != null;

    final client = _apiClientFrom(args);
    try {
      final nodes = await client.nodes(labels: labels, online: online);
      if (nodes.isEmpty) {
        stdout.writeln(narrowed ? 'no node matches' : 'no nodes registered');
        return;
      }
      stdout.writeln('NODE                 ONLINE  PLATFORM   LABELS');
      for (final n in nodes) {
        final rendered = n.labels.entries
            .map((l) => '${l.key}=${l.value}')
            .join(' ');
        stdout.writeln(
          '${n.id.value.padRight(20)} ${n.online ? 'yes   ' : 'no    '}  '
          '${n.platform.osName.padRight(10)} $rendered',
        );
      }
    } finally {
      client.close();
    }
  }
}

// ---------------------------------------------------------------------------
// preset
// ---------------------------------------------------------------------------

/// `omnyserver preset …`
class PresetCommand extends Command<void> {
  /// Creates the preset command group.
  PresetCommand() {
    addSubcommand(PresetApplyCommand());
    addSubcommand(PresetSaveCommand());
    addSubcommand(PresetListCommand());
    addSubcommand(PresetShowCommand());
    addSubcommand(PresetDeleteCommand());
  }

  @override
  String get name => 'preset';

  @override
  String get description => 'Apply presets to nodes.';
}

/// `omnyserver preset apply <preset.json> <node>`
class PresetApplyCommand extends Command<void> {
  /// Creates the preset-apply command.
  PresetApplyCommand() {
    _addApiOptions(argParser);
    _addSelectorOptions(argParser);
    argParser.addFlag(
      'async',
      negatable: false,
      help: 'Do not wait. Prints an operation id to ask about later.',
    );
  }

  @override
  String get name => 'apply';

  @override
  String get description =>
      'Apply a preset — a saved one by id, or a JSON file — to one node or a '
      'selected fleet.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) {
      throw CliError(
        'usage: preset apply <preset.json|preset-id> [<node>] '
        '[--label env=prod | --all]',
      );
    }

    // A path if it exists on disk, otherwise the id of a preset saved on the Hub.
    // The saved form is the one worth using: a file is whatever copy *this*
    // caller happens to have, while an id is the one everybody agrees on.
    final source = rest.first;
    final file = File(source);
    final inline = await file.exists()
        ? Preset.fromJson(
            (jsonDecode(await file.readAsString()) as Map)
                .cast<String, dynamic>(),
          )
        : null;

    final client = _apiClientFrom(args);
    try {
      final nodes = await _selectNodes(
        client,
        args,
        positional: rest.skip(1).toList(),
      );
      final async = args['async'] as bool;
      await _fanOut(nodes, (node) async {
        if (async) {
          final operation = await client.applyPresetAsync(
            node,
            presetId: inline == null ? source : null,
            preset: inline,
          );
          return 'dispatched — ops show ${operation.id}';
        }
        final reply = await client.applyPreset(
          node,
          presetId: inline == null ? source : null,
          preset: inline,
        );
        final failed = reply.results.where((r) => !r.success).length;
        final changed = reply.results.where((r) => r.changed).length;
        return failed == 0
            ? 'applied ${reply.results.length} steps ($changed changed)'
            : 'FAILED $failed/${reply.results.length} steps';
      });
    } finally {
      client.close();
    }
  }
}

/// `omnyserver preset save <preset.json>`
class PresetSaveCommand extends Command<void> {
  /// Creates the preset-save command.
  PresetSaveCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'save';

  @override
  String get description =>
      'Save a preset on the Hub, so everyone applies the same one.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: preset save <preset.json>');
    final file = File(rest.first);
    if (!await file.exists()) {
      throw CliError('preset file not found: ${rest.first}');
    }
    final preset = Preset.fromJson(
      (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>(),
    );

    final client = _apiClientFrom(argResults!);
    try {
      await client.savePreset(preset);
      stdout.writeln(
        'saved "${preset.id}" (${preset.steps.length} steps) — apply it '
        'anywhere with: preset apply ${preset.id} --label …',
      );
    } finally {
      client.close();
    }
  }
}

/// `omnyserver preset list`
class PresetListCommand extends Command<void> {
  /// Creates the preset-list command.
  PresetListCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List the presets saved on the Hub.';

  @override
  Future<void> run() async {
    final client = _apiClientFrom(argResults!);
    try {
      final presets = await client.presets();
      if (presets.isEmpty) {
        stdout.writeln('no presets are saved (try: preset save <file>)');
        return;
      }
      stdout.writeln('ID              STEPS  NAME');
      for (final p in presets) {
        stdout.writeln(
          '${p.id.value.padRight(15)} '
          '${'${p.steps.length}'.padLeft(5)}  ${p.name}',
        );
      }
    } finally {
      client.close();
    }
  }
}

/// `omnyserver preset show <id>`
class PresetShowCommand extends Command<void> {
  /// Creates the preset-show command.
  PresetShowCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a saved preset.';

  @override
  Future<void> run() => _showJson(
    argResults!,
    'preset show',
    (client, id) async => (await client.preset(id)).toJson(),
  );
}

/// `omnyserver preset delete <id>`
class PresetDeleteCommand extends Command<void> {
  /// Creates the preset-delete command.
  PresetDeleteCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete a saved preset.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: preset delete <id>');
    final client = _apiClientFrom(argResults!);
    try {
      await client.deletePreset(rest.first);
      stdout.writeln('deleted ${rest.first}');
    } finally {
      client.close();
    }
  }
}

// ---------------------------------------------------------------------------
// blueprint
// ---------------------------------------------------------------------------

/// `omnyserver blueprint …`
class BlueprintCommand extends Command<void> {
  /// Creates the blueprint command group.
  BlueprintCommand() {
    addSubcommand(BlueprintSaveCommand());
    addSubcommand(BlueprintListCommand());
    addSubcommand(BlueprintShowCommand());
    addSubcommand(BlueprintResolvedCommand());
    addSubcommand(BlueprintDeleteCommand());
    addSubcommand(BlueprintAssignCommand());
    addSubcommand(BlueprintPlanCommand());
    addSubcommand(BlueprintApplyCommand());
  }

  @override
  String get name => 'blueprint';

  @override
  String get description => 'Declare what a server should be, and make it so.';
}

/// `omnyserver blueprint save <file.yaml|file.json>`
class BlueprintSaveCommand extends Command<void> {
  /// Creates the blueprint-save command.
  BlueprintSaveCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'save';

  @override
  String get description =>
      'Save a blueprint on the Hub, from a YAML or JSON file.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw CliError('usage: blueprint save <file.yaml|file.json>');
    }

    // Parsed here so a malformed file is a local error naming the file, rather
    // than a 400 from a Hub that only ever saw the bytes.
    final blueprint = await BlueprintFile.read(rest.first);

    final client = _apiClientFrom(argResults!);
    try {
      await client.saveBlueprint(blueprint);
      stdout
        ..writeln(
          'saved "${blueprint.id}" (${blueprint.includes.length} includes, '
          '${blueprint.resources.length} resources)',
        )
        ..writeln('assign it with: blueprint assign ${blueprint.id} <node>');
    } finally {
      client.close();
    }
  }
}

/// `omnyserver blueprint list`
class BlueprintListCommand extends Command<void> {
  /// Creates the blueprint-list command.
  BlueprintListCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List the blueprints saved on the Hub.';

  @override
  Future<void> run() async {
    final client = _apiClientFrom(argResults!);
    try {
      final blueprints = await client.blueprints();
      if (blueprints.isEmpty) {
        stdout.writeln('no blueprints are saved (try: blueprint save <file>)');
        return;
      }
      stdout.writeln('ID              INCLUDES  RESOURCES  NAME');
      for (final b in blueprints) {
        stdout.writeln(
          '${b.id.value.padRight(15)} '
          '${'${b.includes.length}'.padLeft(8)}  '
          '${'${b.resources.length}'.padLeft(9)}  ${b.name}',
        );
      }
    } finally {
      client.close();
    }
  }
}

/// `omnyserver blueprint show <id>`
class BlueprintShowCommand extends Command<void> {
  /// Creates the blueprint-show command.
  BlueprintShowCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'show';

  @override
  String get description =>
      'Show a saved blueprint, in the format it was written in.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: blueprint show <id>');

    final client = _apiClientFrom(argResults!);
    try {
      final blueprint = await client.blueprint(rest.first);
      // A blueprint authored as YAML comes back as that YAML, comments intact.
      // Printing the parsed JSON instead would hand back a different document
      // from the one in the author's editor.
      if (blueprint.source case final source?) {
        stdout.write(source.text);
        return;
      }
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(blueprint.toJson()),
      );
    } finally {
      client.close();
    }
  }
}

/// `omnyserver blueprint resolved <id>`
class BlueprintResolvedCommand extends Command<void> {
  /// Creates the blueprint-resolved command.
  BlueprintResolvedCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'resolved';

  @override
  String get description =>
      'Show a blueprint flattened: what a node is actually sent.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: blueprint resolved <id>');

    final client = _apiClientFrom(argResults!);
    try {
      final resolved = await client.resolvedBlueprint(rest.first);

      stdout.writeln(resolved.hash);
      stdout.writeln('RESOURCE                       ENSURE     FROM');
      for (final r in resolved.resources) {
        final from = r.overrides == null
            ? r.origin
            : '${r.origin} (overrides ${r.overrides})';
        stdout.writeln(
          '${r.id.toString().padRight(30)} '
          '${r.ensure.name.padRight(10)} $from',
        );
      }
      for (final note in resolved.notes) {
        stdout.writeln('note: $note');
      }
    } finally {
      client.close();
    }
  }
}

/// `omnyserver blueprint delete <id>`
class BlueprintDeleteCommand extends Command<void> {
  /// Creates the blueprint-delete command.
  BlueprintDeleteCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete a saved blueprint.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: blueprint delete <id>');
    final client = _apiClientFrom(argResults!);
    try {
      await client.deleteBlueprint(rest.first);
      stdout.writeln('deleted ${rest.first}');
    } finally {
      client.close();
    }
  }
}

/// `omnyserver blueprint assign <id> <node>`
class BlueprintAssignCommand extends Command<void> {
  /// Creates the blueprint-assign command.
  BlueprintAssignCommand() {
    _addApiOptions(argParser);
    _addSelectorOptions(argParser);
  }

  @override
  String get name => 'assign';

  @override
  String get description =>
      'Say a node should be this blueprint — runs nothing.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) {
      throw CliError(
        'usage: blueprint assign <id> [<node>] [--label env=prod | --all]',
      );
    }
    final blueprint = rest.first;

    final client = _apiClientFrom(args);
    try {
      final nodes = await _selectNodes(
        client,
        args,
        positional: rest.skip(1).toList(),
      );
      await _fanOut(nodes, (node) async {
        await client.assignBlueprint(node, blueprint);
        return 'assigned $blueprint';
      });
      // Said plainly: an operator who expects this to have *done* something will
      // otherwise wonder why the machine is unchanged.
      stdout.writeln('nothing has run — blueprint apply <node> to make it so');
    } finally {
      client.close();
    }
  }
}

/// `omnyserver blueprint plan <node>`
class BlueprintPlanCommand extends Command<void> {
  /// Creates the blueprint-plan command.
  BlueprintPlanCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'plan';

  @override
  String get description =>
      'Ask a node what would change — exits 2 when it has drifted.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: blueprint plan <node>');

    final client = _apiClientFrom(argResults!);
    try {
      final drift = await client.drift(rest.first);
      if (drift == null) {
        throw CliError('nothing is declared for ${rest.first}');
      }

      if (drift.converged) {
        stdout.writeln('${rest.first} is converged (${drift.blueprint})');
        return;
      }

      stdout.writeln('${rest.first} has drifted from ${drift.blueprint}:');
      for (final c in drift.changes) {
        if (c.kind == ChangeKind.noop) continue;
        stdout.writeln('  ${c.kind.name.padRight(8)} ${c.id}  — ${c.reason}');
      }
      // A distinct code, so this is usable in CI and on a timer without anyone
      // having to parse the output.
      exitCode = 2;
    } finally {
      client.close();
    }
  }
}

/// `omnyserver blueprint apply <node>`
class BlueprintApplyCommand extends Command<void> {
  /// Creates the blueprint-apply command.
  BlueprintApplyCommand() {
    _addApiOptions(argParser);
    _addSelectorOptions(argParser);
    argParser
      ..addFlag('dry-run', negatable: false, help: 'Plan, and change nothing.')
      ..addFlag(
        'async',
        negatable: false,
        help: 'Do not wait. Prints an operation id to ask about later.',
      );
  }

  @override
  String get name => 'apply';

  @override
  String get description =>
      'Make a node what its blueprint says it should be (idempotent).';

  @override
  Future<void> run() async {
    final args = argResults!;
    final dryRun = args['dry-run'] as bool;
    final async = args['async'] as bool;

    final client = _apiClientFrom(args);
    try {
      final nodes = await _selectNodes(client, args, positional: args.rest);
      await _fanOut(nodes, (node) async {
        if (async) {
          final operation = await client.reconcileAsync(node, dryRun: dryRun);
          return 'dispatched — ops show ${operation.id}';
        }
        final reply = await client.reconcile(node, dryRun: dryRun);
        if (!reply.success) {
          return 'FAILED — ${reply.changed} changed, ${reply.skipped} skipped';
        }
        return dryRun
            ? 'would change ${reply.changed}'
            : 'applied — ${reply.changed} changed';
      });
    } finally {
      client.close();
    }
  }
}

// ---------------------------------------------------------------------------
// formula
// ---------------------------------------------------------------------------

/// `omnyserver formula …`
class FormulaCommand extends Command<void> {
  /// Creates the formula command group.
  FormulaCommand() {
    addSubcommand(FormulaListCommand());
    addSubcommand(FormulaRunCommand());
  }

  @override
  String get name => 'formula';

  @override
  String get description => 'Run formulas on nodes.';
}

/// `omnyserver formula list`
class FormulaListCommand extends Command<void> {
  /// Creates the formula-list command.
  FormulaListCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'list';

  @override
  String get description =>
      'List the formulas a node can run, and the actions each implements.';

  @override
  Future<void> run() async {
    final client = _apiClientFrom(argResults!);
    try {
      final formulas = await client.formulas();
      stdout.writeln('FORMULA     NAME              ACTIONS');
      for (final f in formulas) {
        final actions = [for (final a in f.actions) a.name].join(', ');
        stdout.writeln(
          '${f.id.value.padRight(11)} ${f.name.padRight(17)} $actions',
        );
      }
    } finally {
      client.close();
    }
  }
}

/// `omnyserver formula run <formula> <node>`
class FormulaRunCommand extends Command<void> {
  /// Creates the formula-run command.
  FormulaRunCommand() {
    _addApiOptions(argParser);
    _addSelectorOptions(argParser);
    argParser
      ..addOption('action', defaultsTo: 'verify', help: 'Formula action.')
      ..addOption('formula-version', help: 'Target version.')
      ..addFlag(
        'async',
        negatable: false,
        help:
            'Do not wait. Prints an operation id to ask about later — for work '
            'that outlives the Hub\'s request timeout, like an install.',
      );
  }

  @override
  String get name => 'run';

  @override
  String get description =>
      'Run a formula action on one node, or across a selected fleet.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) {
      throw CliError(
        'usage: formula run <formula> [<node>] [--label env=prod | --all] '
        '[--action verify]',
      );
    }
    final formula = rest.first;
    final version = args['formula-version'] as String?;
    final action = args['action'] as String;

    final client = _apiClientFrom(args);
    try {
      final nodes = await _selectNodes(
        client,
        args,
        positional: rest.skip(1).toList(),
      );
      final async = args['async'] as bool;
      final parsed = FormulaAction.parse(action);
      await _fanOut(nodes, (node) async {
        if (async) {
          final operation = await client.runFormulaAsync(
            node,
            formula: formula,
            action: parsed,
            version: version,
          );
          return 'dispatched — ops show ${operation.id}';
        }
        final result = (await client.runFormula(
          node,
          formula: formula,
          action: parsed,
          version: version,
        )).result;
        // The formula's own message is worth showing when it says something the
        // verdict does not — a failure's reason, or a version. "ok  ok" is not.
        final detail = (result.message.isEmpty || result.message == 'ok')
            ? ''
            : '  ${result.message}';
        return '$formula $action: ${result.success ? 'ok' : 'FAILED'}'
            '${result.changed ? ' (changed)' : ''}$detail';
      });
    } finally {
      client.close();
    }
  }
}

// ---------------------------------------------------------------------------
// grant — credentials the Hub hands out, and takes back
// ---------------------------------------------------------------------------

/// `omnyserver grant …`
class GrantCommand extends Command<void> {
  /// Creates the grant command group.
  GrantCommand() {
    addSubcommand(GrantAddCommand());
    addSubcommand(GrantListCommand());
    addSubcommand(GrantRevokeCommand());
  }

  @override
  String get name => 'grant';

  @override
  String get description =>
      'Issue and revoke credentials, without restarting the Hub.';
}

/// `omnyserver grant add <principal> --role operator`
class GrantAddCommand extends Command<void> {
  /// Creates the grant-add command.
  GrantAddCommand() {
    _addApiOptions(argParser);
    argParser
      ..addMultiOption(
        'role',
        help: 'A role to grant (repeatable): viewer, operator, admin, node.',
      )
      ..addOption('note', help: 'Who this is for, and why.');
  }

  @override
  String get name => 'add';

  @override
  String get description => 'Issue a credential. Prints the token once.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) {
      throw CliError('usage: grant add <principal> --role operator');
    }
    final roles = args['role'] as List<String>;
    if (roles.isEmpty) {
      throw CliError(
        'name at least one --role (viewer, operator, admin, node) — a '
        'credential that may do nothing is not a credential',
      );
    }

    final client = _apiClientFrom(args);
    try {
      final issued = await client.issueGrant(
        principal: rest.first,
        roles: roles.toSet(),
        note: '${args['note'] ?? ''}',
      );

      stdout
        ..writeln('principal: ${issued.grant.principal.value}')
        ..writeln('roles:     ${issued.grant.roles.join(', ')}')
        ..writeln('grant id:  ${issued.id}   (revoke it with this)')
        ..writeln('')
        ..writeln('token:     ${issued.token}')
        ..writeln('')
        // Said out loud, because a Hub that stores a hash genuinely cannot show
        // it again — and an operator who assumes otherwise finds out too late.
        ..writeln(
          'This is the only time the token is shown: the Hub keeps a hash of '
          'it, not the token.',
        );
    } finally {
      client.close();
    }
  }
}

/// `omnyserver grant list`
class GrantListCommand extends Command<void> {
  /// Creates the grant-list command.
  GrantListCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List issued credentials (hashes, never tokens).';

  @override
  Future<void> run() async {
    final client = _apiClientFrom(argResults!);
    try {
      final grants = await client.grants();
      if (grants.isEmpty) {
        stdout.writeln('no credentials have been issued');
        return;
      }
      stdout.writeln('ID                        PRINCIPAL     ROLES');
      for (final g in grants) {
        stdout.writeln(
          '${g.id.padRight(25)} ${g.principal.value.padRight(13)}'
          '${g.roles.join(',')}${g.note.isEmpty ? '' : '   # ${g.note}'}',
        );
      }
    } finally {
      client.close();
    }
  }
}

/// `omnyserver grant revoke <id>`
class GrantRevokeCommand extends Command<void> {
  /// Creates the grant-revoke command.
  GrantRevokeCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'revoke';

  @override
  String get description =>
      'Revoke a credential. The next request with its token fails.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: grant revoke <grant-id>');
    final client = _apiClientFrom(argResults!);
    try {
      await client.revokeGrant(rest.first);
      stdout.writeln('revoked ${rest.first}');
    } finally {
      client.close();
    }
  }
}

// ---------------------------------------------------------------------------
// state — declare what a node should be, and ask whether it still is
// ---------------------------------------------------------------------------

/// `omnyserver state …`
class StateCommand extends Command<void> {
  /// Creates the state command group.
  StateCommand() {
    addSubcommand(StateSetCommand());
    addSubcommand(StateShowCommand());
    addSubcommand(StateDiffCommand());
    addSubcommand(StateReconcileCommand());
    addSubcommand(StateClearCommand());
  }

  @override
  String get name => 'state';

  @override
  String get description =>
      'Declare the state a node should be in, and reconcile it when it drifts.';
}

/// `omnyserver state set <preset.json> [<node>] [--label …]`
class StateSetCommand extends Command<void> {
  /// Creates the state-set command.
  StateSetCommand() {
    _addApiOptions(argParser);
    _addSelectorOptions(argParser);
  }

  @override
  String get name => 'set';

  @override
  String get description =>
      'Declare the state (from a preset file) selected nodes should be in. '
      'Runs nothing — use `state reconcile` for that.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) {
      throw CliError('usage: state set <preset.json> [<node>] [--label …]');
    }
    final file = File(rest.first);
    if (!await file.exists()) {
      throw CliError('preset file not found: ${rest.first}');
    }
    final preset = Preset.fromJson(
      (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>(),
    );

    final client = _apiClientFrom(args);
    try {
      final nodes = await _selectNodes(
        client,
        args,
        positional: rest.skip(1).toList(),
      );
      await _fanOut(nodes, (node) async {
        await client.declarePreset(node, preset);
        // Said plainly, because "declared" and "applied" are easy to confuse and
        // the difference is the whole feature.
        return 'declared ${preset.steps.length} steps (nothing has run yet)';
      });
    } finally {
      client.close();
    }
  }
}

/// `omnyserver state show <node>`
class StateShowCommand extends Command<void> {
  /// Creates the state-show command.
  StateShowCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show what a node is declared to be.';

  @override
  Future<void> run() => _showJson(
    argResults!,
    'state show',
    (client, id) async => (await client.desiredState(id))?.toJson(),
  );
}

/// `omnyserver state diff [<node>] [--label …]`
class StateDiffCommand extends Command<void> {
  /// Creates the state-diff command.
  StateDiffCommand() {
    _addApiOptions(argParser);
    _addSelectorOptions(argParser);
  }

  @override
  String get name => 'diff';

  @override
  String get description =>
      'Show how far selected nodes have drifted from what they were declared '
      'to be. Runs nothing.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final client = _apiClientFrom(args);
    try {
      final nodes = await _selectNodes(client, args, positional: args.rest);
      var drifted = 0;
      for (final node in nodes) {
        try {
          final plan = await client.drift(node);
          if (plan == null) {
            stderr.writeln('${node.padRight(20)} nothing declared');
            continue;
          }
          if (plan.converged) {
            stdout.writeln('${node.padRight(20)} converged');
            continue;
          }
          drifted++;
          // A node declared by a blueprint answers in resource changes; one
          // declared by steps answers in actions. Exactly one is filled.
          final pending = [
            for (final c in plan.changes)
              if (c.kind != ChangeKind.noop) '${c.kind.name} ${c.id}',
            for (final s in plan.actions) '${s.action.name} ${s.formula.value}',
          ];
          stdout.writeln(
            '${node.padRight(20)} DRIFTED — ${pending.length} to run',
          );
          for (final line in pending) {
            stdout.writeln('  $line');
          }
        } on HubApiException catch (e) {
          stderr.writeln('${node.padRight(20)} ${e.message}');
        }
      }
      // Exit non-zero when anything has drifted, so this is usable as a check in
      // a pipeline — "is the fleet still what we said it was?"
      if (drifted > 0) exitCode = 1;
    } finally {
      client.close();
    }
  }
}

/// `omnyserver state reconcile [<node>] [--label …]`
class StateReconcileCommand extends Command<void> {
  /// Creates the state-reconcile command.
  StateReconcileCommand() {
    _addApiOptions(argParser);
    _addSelectorOptions(argParser);
    argParser.addFlag(
      'async',
      negatable: false,
      help: 'Do not wait. Prints an operation id to ask about later.',
    );
  }

  @override
  String get name => 'reconcile';

  @override
  String get description =>
      'Run whatever it takes to make selected nodes match what they were '
      'declared to be. Idempotent: a converged node does nothing.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final client = _apiClientFrom(args);
    try {
      final nodes = await _selectNodes(client, args, positional: args.rest);
      final async = args['async'] as bool;
      await _fanOut(nodes, (node) async {
        if (async) {
          final operation = await client.reconcileAsync(node);
          return 'dispatched — ops show ${operation.id}';
        }
        final reply = await client.reconcile(node);
        // A node declared by preset steps reports per-step results; one
        // declared by a blueprint reports counted changes. `ConvergeResult`
        // answers both the same way.
        final ran = reply.results.isEmpty
            ? reply.changed
            : reply.results.length;
        if (ran == 0) return 'already converged — nothing to do';
        final failed = reply.results.where((r) => !r.success).length;
        return reply.success ? 'converged ($ran ran)' : 'FAILED $failed/$ran';
      });
    } finally {
      client.close();
    }
  }
}

/// `omnyserver state clear <node>`
class StateClearCommand extends Command<void> {
  /// Creates the state-clear command.
  StateClearCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'clear';

  @override
  String get description => 'Stop expecting anything of a node.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: state clear <node>');
    final client = _apiClientFrom(argResults!);
    try {
      await client.undeclare(rest.first);
      stdout.writeln('cleared the desired state of ${rest.first}');
    } finally {
      client.close();
    }
  }
}

// ---------------------------------------------------------------------------
// events / audit
// ---------------------------------------------------------------------------

/// `omnyserver events`
class EventsCommand extends Command<void> {
  /// Creates the events command.
  EventsCommand() {
    _addApiOptions(argParser);
    argParser.addFlag(
      'follow',
      abbr: 'f',
      negatable: false,
      help: 'Stream events as they happen, instead of printing recent ones.',
    );
  }

  @override
  String get name => 'events';

  @override
  String get description => 'Show Hub events; -f streams them live.';

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args['follow'] as bool) return _follow(args);

    final client = _apiClientFrom(args);
    try {
      final events = await client.events();
      if (events.isEmpty) {
        stdout.writeln('no events yet');
        return;
      }
      for (final e in events) {
        stdout.writeln(_format(e.toJson()));
      }
    } finally {
      client.close();
    }
  }

  /// `tail -f` for the fleet.
  Future<void> _follow(ArgResults args) => _streamSse(
    args,
    '/api/v1/events/stream',
    banner: 'streaming events — Ctrl-C to stop',
    onEvent: (payload) => stdout.writeln(_format(payload)),
  );

  static String _format(Map<dynamic, dynamic> event) {
    final at = event['at'];
    final type = event['type'];
    final rest = {...event}
      ..remove('at')
      ..remove('type');
    final fields = rest.entries.map((e) => '${e.key}=${e.value}').join(' ');
    return '$at  $type${fields.isEmpty ? '' : '  $fields'}';
  }
}

/// `omnyserver ops …`
class OpsCommand extends Command<void> {
  /// Creates the ops command group.
  OpsCommand() {
    addSubcommand(OpsListCommand());
    addSubcommand(OpsShowCommand());
  }

  @override
  String get name => 'ops';

  @override
  String get description =>
      'Work dispatched with --async: what is running, and how it went.';
}

/// `omnyserver ops list`
class OpsListCommand extends Command<void> {
  /// Creates the ops-list command.
  OpsListCommand() {
    _addApiOptions(argParser);
    argParser
      ..addOption('node', help: 'Only operations on this node.')
      ..addFlag(
        'running',
        negatable: false,
        help: 'Only what is still working.',
      );
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List operations, newest first.';

  @override
  Future<void> run() async {
    final args = argResults!;

    final client = _apiClientFrom(args);
    try {
      final ops = await client.operations(
        nodeId: args['node'] as String?,
        running: args['running'] as bool,
      );
      if (ops.isEmpty) {
        stdout.writeln('no operations');
        return;
      }
      stdout.writeln(
        'ID                                    NODE        STATUS     WHAT',
      );
      for (final op in ops) {
        stdout.writeln(
          '${op.id.padRight(37)} ${op.nodeId.padRight(11)} '
          '${op.status.name.padRight(10)} ${op.kind} ${op.summary}',
        );
      }
    } finally {
      client.close();
    }
  }
}

/// `omnyserver ops show <id>`
class OpsShowCommand extends Command<void> {
  /// Creates the ops-show command.
  OpsShowCommand() {
    _addApiOptions(argParser);
    argParser.addFlag(
      'wait',
      negatable: false,
      help: 'Block until it finishes.',
    );
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show an operation, and what it produced.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) throw CliError('usage: ops show <id> [--wait]');

    final client = _apiClientFrom(args);
    try {
      var op = await client.operation(rest.first);

      // Polling, deliberately, and only when asked: an operation announces itself
      // finished on the event stream, so a *watcher* has no need to poll — but a
      // script that wants to block on one line does.
      while ((args['wait'] as bool) && op.isRunning) {
        await Future<void>.delayed(const Duration(seconds: 1));
        op = await client.operation(rest.first);
      }

      stdout.writeln(const JsonEncoder.withIndent('  ').convert(op.toJson()));
      if (op.status == OperationStatus.failed) exitCode = 1;
    } finally {
      client.close();
    }
  }
}

/// `omnyserver alerts`
class AlertsCommand extends Command<void> {
  /// Creates the alerts command.
  AlertsCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'alerts';

  @override
  String get description => 'Show what is wrong right now.';

  @override
  Future<void> run() async {
    final client = _apiClientFrom(argResults!);
    try {
      final alerts = await client.alerts();
      if (alerts.isEmpty) {
        stdout.writeln('nothing is alerting');
        return;
      }
      final now = DateTime.now();
      for (final alert in alerts) {
        final held = now.difference(alert.since.toLocal());
        stdout.writeln('${alert.message}  (for ${_humanize(held)})');
      }
      // Non-zero while anything is alerting, so this works as a health check in a
      // pipeline or a supervision script.
      exitCode = 1;
    } finally {
      client.close();
    }
  }

  static String _humanize(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }
}

/// `omnyserver audit`
class AuditCommand extends Command<void> {
  /// Creates the audit command.
  AuditCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'audit';

  @override
  String get description =>
      'Show the audit trail — who did what, as the Hub verified it.';

  @override
  Future<void> run() async {
    final client = _apiClientFrom(argResults!);
    try {
      final entries = await client.audit();
      if (entries.isEmpty) {
        stdout.writeln('no audited actions yet');
        return;
      }
      // Local time, seconds precision: an ISO instant with microseconds is 27
      // characters of mostly noise, and it ran into the next column.
      stdout.writeln('AT                   PRINCIPAL     ACTION');
      for (final e in entries) {
        final at = e.at.toLocal().toString().split('.').first;
        final target = e.target == null ? '' : ' ${e.target}';
        stdout.writeln(
          '${at.padRight(20)} ${e.principal.padRight(13)}'
          '${e.action}$target  (${e.outcome.name})',
        );
      }
    } finally {
      client.close();
    }
  }
}

// ---------------------------------------------------------------------------
// whoami
// ---------------------------------------------------------------------------

/// `omnyserver whoami`
class WhoamiCommand extends Command<void> {
  /// Creates the whoami command.
  WhoamiCommand() {
    _addApiOptions(argParser);
  }

  @override
  String get name => 'whoami';

  @override
  String get description =>
      'Show the identity and roles the Hub resolves your credentials to.';

  @override
  Future<void> run() async {
    final client = _apiClientFrom(argResults!);
    try {
      final me = await client.whoami();
      stdout.writeln('principal: ${me.principal}');
      stdout.writeln(
        'roles:     ${me.roles.isEmpty ? '(none)' : me.roles.join(', ')}',
      );
      if (!me.authenticated) {
        stdout.writeln('note:      the API is not gated (no --api-token).');
      }
    } finally {
      client.close();
    }
  }
}

// ---------------------------------------------------------------------------
// cert
// ---------------------------------------------------------------------------

/// `omnyserver cert …`
class CertCommand extends Command<void> {
  /// Creates the cert command group.
  CertCommand() {
    addSubcommand(CertGenCommand());
  }

  @override
  String get name => 'cert';

  @override
  String get description => 'Generate development TLS certificates.';
}

/// `omnyserver cert gen`
class CertGenCommand extends Command<void> {
  /// Creates the cert-gen command.
  CertGenCommand() {
    argParser
      ..addOption('out', defaultsTo: 'certs', help: 'Output directory.')
      ..addMultiOption('host', help: 'Extra SAN DNS host (repeatable).')
      ..addFlag('force', negatable: false, help: 'Overwrite existing certs.');
  }

  @override
  String get name => 'gen';

  @override
  String get description => 'Generate a dev CA and Hub server certificate.';

  @override
  Future<void> run() async {
    final args = argResults!;
    try {
      final certs = await CertGenerator.generate(
        outputDir: args['out'] as String,
        hosts: args['host'] as List<String>,
        force: args['force'] as bool,
      );
      stdout.writeln('Generated:');
      stdout.writeln('  CA cert:     ${certs.caCert}');
      stdout.writeln('  Server cert: ${certs.serverCert}');
      stdout.writeln('  Server key:  ${certs.serverKey}');
    } on CertGeneratorException catch (e) {
      throw CliError(e.message);
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

Future<void> _awaitSignal() {
  final completer = Completer<void>();
  late StreamSubscription<ProcessSignal> sub;
  sub = ProcessSignal.sigint.watch().listen((_) {
    sub.cancel();
    if (!completer.isCompleted) completer.complete();
  });
  return completer.future;
}
