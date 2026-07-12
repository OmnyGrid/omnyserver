import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:omnyshell/omnyshell_node.dart' as omnyshell;

import '../../omnyserver_hub.dart';
import '../../omnyserver_node.dart';
import 'api_client.dart';

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
    ..addOption('token', help: 'Bearer token for the Hub HTTP API.')
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
    securityContext: ca == null
        ? null
        : (SecurityContext(withTrustedRoots: true)..setTrustedCertificates(ca)),
    allowBadCertificate: args['insecure'] as bool,
  );
}

// ---------------------------------------------------------------------------
// hub
// ---------------------------------------------------------------------------

/// `omnyserver hub …`
class HubCommand extends Command<void> {
  /// Creates the hub command group.
  HubCommand() {
    addSubcommand(HubStartCommand());
  }

  @override
  String get name => 'hub';

  @override
  String get description => 'Manage the OmnyServer Hub.';
}

/// `omnyserver hub start`
class HubStartCommand extends Command<void> {
  /// Creates the hub-start command.
  HubStartCommand() {
    argParser
      ..addOption('host', defaultsTo: '0.0.0.0', help: 'TLS bind host.')
      ..addOption('port', defaultsTo: '8443', help: 'TLS bind port.')
      ..addOption('cert', help: 'TLS certificate chain (PEM).')
      ..addOption('key', help: 'TLS private key (PEM).')
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
    final cert = args['cert'] as String?;
    final key = args['key'] as String?;
    if (cert == null || key == null) {
      throw CliError(
        '--cert and --key are required (try: omnyserver cert gen)',
      );
    }
    final context = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);

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
        authenticator: TokenAuthenticator(grants),
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
    addSubcommand(NodeStatusCommand());
    addSubcommand(NodeRestartCommand());
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
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List all registered nodes (via the Hub API).';

  @override
  Future<void> run() async {
    final client = _apiClientFrom(argResults!);
    try {
      final nodes = (await client.get('/nodes') as List).cast<Map>();
      if (nodes.isEmpty) {
        stdout.writeln('no nodes registered');
        return;
      }
      stdout.writeln('NODE                 ONLINE  PLATFORM');
      for (final n in nodes) {
        final id = (n['nodeId'] as String).padRight(20);
        final online = (n['online'] as bool? ?? false) ? 'yes   ' : 'no    ';
        final platform = (n['platform'] as Map?)?['osName'] ?? '?';
        stdout.writeln('$id $online  $platform');
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
  }

  @override
  String get name => 'apply';

  @override
  String get description => 'Apply a preset (JSON file) to a node.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.length < 2) {
      throw CliError('usage: preset apply <preset.json> <node>');
    }
    final file = File(rest[0]);
    if (!file.existsSync()) throw CliError('preset file not found: ${rest[0]}');
    final preset = jsonDecode(file.readAsStringSync());
    final client = _apiClientFrom(argResults!);
    try {
      final result = await client.post('/presets/apply', {
        'nodeId': rest[1],
        'preset': preset,
      });
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
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
    argParser
      ..addOption('action', defaultsTo: 'verify', help: 'Formula action.')
      ..addOption('formula-version', help: 'Target version.');
  }

  @override
  String get name => 'run';

  @override
  String get description => 'Run a formula action on a node (via the Hub API).';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.length < 2) {
      throw CliError('usage: formula run <formula> <node> [--action verify]');
    }
    final client = _apiClientFrom(argResults!);
    try {
      final result = await client.post('/nodes/${rest[1]}/formula', {
        'formula': rest[0],
        'action': argResults!['action'],
        if (argResults!['formula-version'] != null)
          'version': argResults!['formula-version'],
      });
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
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
