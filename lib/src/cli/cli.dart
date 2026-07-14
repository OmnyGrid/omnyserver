import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:omnyshell/omnyshell_node.dart' as omnyshell;

import '../../omnyserver_hub.dart';
import '../../omnyserver_node.dart';
import 'api_client.dart';
import 'api_transport_io.dart';

/// A user-facing CLI error (printed without a stack trace).
class CliError implements Exception {
  /// The message shown to the user.
  final String message;

  /// Creates a CLI error.
  CliError(this.message);

  @override
  String toString() => message;
}

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
        ..addCommand(NodesCommand())
        ..addCommand(PresetCommand())
        ..addCommand(FormulaCommand())
        ..addCommand(EventsCommand())
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

  final query = [
    for (final label in labels) 'label=${Uri.encodeQueryComponent(label)}',
  ].join('&');
  final nodes =
      (await client.get('/nodes${query.isEmpty ? '' : '?$query'}')) as List;
  final matched = [
    for (final n in nodes.cast<Map>()) n['nodeId'] as String,
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
  /// Creates the hub-start command.
  HubStartCommand() {
    argParser
      ..addOption('host', defaultsTo: '0.0.0.0', help: 'TLS bind host.')
      ..addOption('port', defaultsTo: '8443', help: 'TLS bind port.')
      ..addOption(
        'cert',
        help: 'TLS certificate chain (PEM). Required unless --tls-dir is set.',
      )
      ..addOption(
        'key',
        help: 'TLS private key (PEM). Required unless --tls-dir is set.',
      )
      ..addOption(
        'tls-dir',
        help:
            'Directory holding the listener certificate (fullchain.pem + '
            'privkey.pem, LetsEncrypt layout), as an alternative to '
            '--cert/--key. Re-checked periodically and reloaded automatically '
            'when the files change (e.g. on renewal).',
      )
      ..addOption(
        'node-path',
        defaultsTo: '/node',
        help: 'Path the node control channel is mounted at.',
      )
      ..addFlag(
        'shell',
        negatable: false,
        help: 'Also serve OmnyShell nodes (same port, same certificate).',
      )
      ..addOption(
        'shell-path',
        defaultsTo: '/shell',
        help: 'Path the OmnyShell broker is mounted at.',
      )
      ..addOption('api-token', help: 'Bearer token required by the HTTP API.')
      ..addMultiOption(
        'grant',
        help: 'Token grant "principal:token:role1,role2" (repeatable).',
      )
      ..addMultiOption(
        'cors-origin',
        help:
            'Browser origin allowed to call the HTTP API, e.g. '
            'https://dashboard.example.com (repeatable). Required for a web '
            'dashboard — a browser is always a different origin than the Hub.',
      );
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
    final tlsDir = _validateTls(args);
    final context = tlsDir != null
        ? null
        : (SecurityContext()
            ..useCertificateChain(args['cert'] as String)
            ..usePrivateKey(args['key'] as String));

    final grants = _parseGrants(args['grant'] as List<String>);
    final nodePath = args['node-path'] as String;
    final shellPath = args['shell-path'] as String;
    final withShell = args['shell'] as bool;
    final hub = OmnyServerHub(
      HubConfig(
        host: args['host'] as String,
        port: int.parse(args['port'] as String),
        nodeMount: nodePath,
        shellMount: shellPath,
        securityContext: context,
        tlsDirectory: tlsDir,
        authenticator: TokenAuthenticator(grants),
        corsOrigins: args['cors-origin'] as List<String>,
        logger: stdout.writeln,
      ),
    );

    // An OmnyShell broker on the same listener, sharing the Hub's credentials —
    // so one Hub serves both fleets and `omnyshell node start --hub …/shell`
    // just works. It authenticates in band, so it takes no connection
    // authenticator; OmnyServer's own handshake stays on the node route.
    if (withShell) {
      final shell = ShellHub.fromGrants(
        grants,
        mount: shellPath,
        logger: stdout.writeln,
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
    stdout.writeln('Press Ctrl-C to stop.');
    await _awaitSignal();
    await hub.close();
  }

  /// Validates the Hub's TLS source — exactly one of `--tls-dir` or
  /// (`--cert` + `--key`), never neither (the Hub has no insecure mode).
  /// Returns the trimmed `--tls-dir` in directory mode, otherwise `null`.
  String? _validateTls(ArgResults args) {
    final tlsDir = (args['tls-dir'] as String?)?.trim();
    final cert = args['cert'] as String?;
    final key = args['key'] as String?;
    final hasCertOrKey =
        (cert != null && cert.isNotEmpty) || (key != null && key.isNotEmpty);

    if (tlsDir != null && tlsDir.isNotEmpty) {
      if (hasCertOrKey) {
        throw CliError('use either --tls-dir or --cert/--key, not both');
      }
      if (!File('$tlsDir/fullchain.pem').existsSync() ||
          !File('$tlsDir/privkey.pem').existsSync()) {
        throw CliError(
          '--tls-dir "$tlsDir" must contain fullchain.pem and privkey.pem',
        );
      }
      return tlsDir;
    }

    if (cert == null || cert.isEmpty || key == null || key.isEmpty) {
      throw CliError(
        '--cert and --key are required unless --tls-dir is set '
        '(try: omnyserver cert gen)',
      );
    }
    return null;
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
  /// Creates the node-start command.
  NodeStartCommand() {
    argParser
      ..addOption('hub', help: 'Hub WSS URL, e.g. wss://hub:8443.')
      ..addOption('id', help: 'Node id.')
      ..addOption('principal', defaultsTo: 'node-account', help: 'Principal.')
      ..addOption('token', help: 'Bearer token.')
      ..addOption('ca', help: 'Trusted CA certificate (PEM).')
      ..addFlag(
        'insecure',
        negatable: false,
        help: 'Accept any TLS certificate (dev only).',
      )
      ..addFlag(
        'with-shell',
        negatable: false,
        help: 'Also run an OmnyShell node, so the Hub can open shell sessions.',
      )
      ..addOption(
        'shell-path',
        defaultsTo: '/shell',
        help: "Path of the Hub's OmnyShell broker (with --with-shell).",
      )
      ..addMultiOption(
        'label',
        help:
            'Node label "key=value" (repeatable), e.g. env=prod. Labels are how '
            'a fleet is addressed: they filter `nodes list` and select the '
            'targets of `formula run` and `preset apply`.',
      )
      ..addMultiOption(
        'shell-label',
        help:
            'OmnyShell node label "key=value" (repeatable), e.g. '
            'allow-roles=admin.',
      );
  }

  @override
  String get name => 'start';

  @override
  String get description => 'Run a Node agent, connecting to the Hub over WSS.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final hub = args['hub'] as String?;
    final id = args['id'] as String?;
    final token = args['token'] as String?;
    if (hub == null || id == null || token == null) {
      throw CliError('--hub, --id and --token are required');
    }
    final ca = args['ca'] as String?;
    final context = ca == null
        ? null
        : (SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificates(ca));

    final registry = FormulaRegistry.standard();
    final formulaService = NodeFormulaService(registry: registry);
    final updateService = const UpdateService();
    const monitor = SystemMonitor();
    final scanner = CapabilityScanner.standard();

    final agent = NodeAgent(
      NodeAgentConfig(
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
        labels: _parseLabels(args['label'] as List<String>),
        statusProvider: monitor.snapshot,
        capabilityProvider: scanner.scan,
        formulaHandler: formulaService.runFormula,
        presetHandler: formulaService.applyPreset,
        nodeControlHandler: updateService.handle,
        logger: stdout.writeln,
      ),
    );
    await agent.start();
    stdout.writeln('Node "$id" connected to $hub.');

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
            labels: _parseLabels(args['shell-label'] as List<String>),
          )
        : null;

    stdout.writeln('Press Ctrl-C to stop.');
    await _awaitSignal();
    await shellNode?.shutdown();
    await agent.stop();
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

  Map<String, String> _parseLabels(List<String> raw) {
    final labels = <String, String>{};
    for (final entry in raw) {
      final i = entry.indexOf('=');
      if (i <= 0) {
        throw CliError('invalid --shell-label "$entry" (want key=value)');
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
      final status = await client.get('/nodes/${rest.first}/status');
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(status));
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
  Future<void> run() => _getAndPrint(argResults!, 'show', (id) => '/nodes/$id');
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
  Future<void> run() => _getAndPrint(
    argResults!,
    'capabilities',
    (id) => '/nodes/$id/capabilities',
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
    final query = [
      'limit=${Uri.encodeQueryComponent(args['limit'] as String)}',
      if (since != null) 'since=${Uri.encodeQueryComponent(since)}',
    ].join('&');

    final client = _apiClientFrom(args);
    try {
      final series = await client.get('/nodes/${rest.first}/metrics?$query');
      if (args['json'] as bool) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(series));
        return;
      }
      final points = (series as List).cast<Map>();
      if (points.isEmpty) {
        stdout.writeln('no samples (the node may not have heartbeated yet)');
        return;
      }
      stdout.writeln('AT                        CPU%    MEM%   DISK%');
      // Newest first from the API; print oldest first so it reads as a timeline.
      for (final p in points.reversed) {
        final at = DateTime.parse(p['at'] as String).toLocal();
        final cpu = (p['cpuPercent'] as num).toDouble();
        final mem = _pct(p['memoryUsedBytes'], p['memoryTotalBytes']);
        final disk = _pct(p['storageUsedBytes'], p['storageCapacityBytes']);
        stdout.writeln(
          '${at.toString().padRight(26)}'
          '${cpu.toStringAsFixed(1).padLeft(5)}  '
          '${mem.padLeft(6)}  ${disk.padLeft(6)}',
        );
      }
    } finally {
      client.close();
    }
  }

  static String _pct(Object? used, Object? total) {
    final u = (used as num?)?.toDouble() ?? 0;
    final t = (total as num?)?.toDouble() ?? 0;
    if (t <= 0) return '—';
    return '${(u / t * 100).toStringAsFixed(0)}%';
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
  String get description => 'Restart a node (via the Hub API).';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: node restart <id>');
    final client = _apiClientFrom(argResults!);
    try {
      await client.post('/nodes/${rest.first}/restart');
      stdout.writeln('restart requested for ${rest.first}');
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
  String get description => 'Shut a node down (via the Hub API).';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliError('usage: node shutdown <id>');
    final client = _apiClientFrom(argResults!);
    try {
      await client.post('/nodes/${rest.first}/shutdown');
      stdout.writeln('shutdown requested for ${rest.first}');
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
      await client.post('/nodes/${rest.first}/update', {'target': target});
      stdout.writeln('update ($target) requested for ${rest.first}');
    } finally {
      client.close();
    }
  }
}

/// GETs [path] for the node named in the first positional argument and prints
/// the JSON — the shape every read-only node command shares.
Future<void> _getAndPrint(
  ArgResults args,
  String usage,
  String Function(String id) path,
) async {
  final rest = args.rest;
  if (rest.isEmpty) throw CliError('usage: node $usage <id>');
  final client = _apiClientFrom(args);
  try {
    final body = await client.get(path(rest.first));
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
    final query = <String>[
      for (final label in args['label'] as List<String>)
        'label=${Uri.encodeQueryComponent(label)}',
      if (args['offline'] as bool)
        'online=false'
      else if (args.wasParsed('online'))
        'online=${args['online']}',
    ].join('&');

    final client = _apiClientFrom(args);
    try {
      final nodes =
          (await client.get('/nodes${query.isEmpty ? '' : '?$query'}') as List)
              .cast<Map>();
      if (nodes.isEmpty) {
        stdout.writeln(
          query.isEmpty ? 'no nodes registered' : 'no node matches',
        );
        return;
      }
      stdout.writeln('NODE                 ONLINE  PLATFORM   LABELS');
      for (final n in nodes) {
        final id = (n['nodeId'] as String).padRight(20);
        final online = (n['online'] as bool? ?? false) ? 'yes   ' : 'no    ';
        final platform = '${(n['platform'] as Map?)?['osName'] ?? '?'}'
            .padRight(10);
        final labels = (n['labels'] as Map?) ?? const {};
        final rendered = labels.entries
            .map((l) => '${l.key}=${l.value}')
            .join(' ');
        stdout.writeln('$id $online  $platform $rendered');
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
  }

  @override
  String get name => 'apply';

  @override
  String get description =>
      'Apply a preset (JSON file) to one node, or across a selected fleet.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) {
      throw CliError(
        'usage: preset apply <preset.json> [<node>] [--label env=prod | --all]',
      );
    }
    final file = File(rest.first);
    if (!file.existsSync()) {
      throw CliError('preset file not found: ${rest.first}');
    }
    final preset = jsonDecode(file.readAsStringSync());

    final client = _apiClientFrom(args);
    try {
      final nodes = await _selectNodes(
        client,
        args,
        positional: rest.skip(1).toList(),
      );
      await _fanOut(nodes, (node) async {
        final reply =
            await client.post('/presets/apply', {
                  'nodeId': node,
                  'preset': preset,
                })
                as Map;
        final results = (reply['results'] as List).cast<Map>();
        final failed = results.where((r) => r['success'] != true).length;
        final changed = results.where((r) => r['changed'] == true).length;
        return failed == 0
            ? 'applied ${results.length} steps ($changed changed)'
            : 'FAILED $failed/${results.length} steps';
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
    addSubcommand(FormulaRunCommand());
  }

  @override
  String get name => 'formula';

  @override
  String get description => 'Run formulas on nodes.';
}

/// `omnyserver formula run <formula> <node>`
class FormulaRunCommand extends Command<void> {
  /// Creates the formula-run command.
  FormulaRunCommand() {
    _addApiOptions(argParser);
    _addSelectorOptions(argParser);
    argParser
      ..addOption('action', defaultsTo: 'verify', help: 'Formula action.')
      ..addOption('formula-version', help: 'Target version.');
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
      await _fanOut(nodes, (node) async {
        final reply = await client.post('/nodes/$node/formula', {
          'formula': formula,
          'action': action,
          'version': ?version,
        });
        final result = (reply as Map)['result'] as Map;
        final ok = result['success'] == true;
        final changed = result['changed'] == true;
        final message = '${result['message'] ?? ''}';
        // The formula's own message is worth showing when it says something the
        // verdict does not — a failure's reason, or a version. "ok  ok" is not.
        final detail = (message.isEmpty || message == 'ok') ? '' : '  $message';
        return '$formula $action: ${ok ? 'ok' : 'FAILED'}'
            '${changed ? ' (changed)' : ''}$detail';
      });
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
      final events = (await client.get('/events') as List).cast<Map>();
      if (events.isEmpty) {
        stdout.writeln('no events yet');
        return;
      }
      for (final e in events) {
        stdout.writeln(_format(e));
      }
    } finally {
      client.close();
    }
  }

  /// `tail -f` for the fleet, over Server-Sent Events.
  ///
  /// The response never ends, so this reads the socket directly rather than
  /// going through [HubApiClient], which buffers a body to completion.
  Future<void> _follow(ArgResults args) async {
    final base = Uri.parse(args['api'] as String);
    final ca = args['ca'] as String?;
    final http = HttpClient(
      context: ca == null
          ? null
          : (SecurityContext(withTrustedRoots: true)
              ..setTrustedCertificates(ca)),
    );
    if (args['insecure'] as bool) {
      http.badCertificateCallback = (_, _, _) => true;
    }

    try {
      final request = await http.getUrl(
        base.replace(path: '/api/v1/events/stream'),
      );
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

      stdout.writeln('streaming events — Ctrl-C to stop');
      // SSE frames a `data:` line per event and dispatches on a blank line;
      // comment lines (`: ping`) are keep-alives and carry nothing.
      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data: ')) continue;
        final payload = jsonDecode(line.substring(6));
        if (payload is Map) {
          stdout.writeln(_format(payload));
        }
      }
    } finally {
      http.close(force: true);
    }
  }

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
      final entries = (await client.get('/audit') as List).cast<Map>();
      if (entries.isEmpty) {
        stdout.writeln('no audited actions yet');
        return;
      }
      // Local time, seconds precision: an ISO instant with microseconds is 27
      // characters of mostly noise, and it ran into the next column.
      stdout.writeln('AT                   PRINCIPAL     ACTION');
      for (final e in entries) {
        final at = DateTime.parse(
          e['at'] as String,
        ).toLocal().toString().split('.').first;
        final target = e['target'] == null ? '' : ' ${e['target']}';
        stdout.writeln(
          '${at.padRight(20)} '
          '${'${e['principal']}'.padRight(13)}'
          '${e['action']}$target  (${e['outcome']})',
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
      final me = await client.get('/whoami') as Map;
      final roles = (me['roles'] as List).cast<String>();
      stdout.writeln('principal: ${me['principal']}');
      stdout.writeln(
        'roles:     ${roles.isEmpty ? '(none)' : roles.join(', ')}',
      );
      if (me['authenticated'] != true) {
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
