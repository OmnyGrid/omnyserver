import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

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
      help: 'Hub HTTP API base URL.',
      defaultsTo: 'http://127.0.0.1:8080',
    )
    ..addOption('token', help: 'Bearer token for the Hub HTTP API.');
}

HubApiClient _apiClientFrom(ArgResults args) => HubApiClient(
  Uri.parse(args['api'] as String),
  token: args['token'] as String?,
);

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
      ..addOption('host', defaultsTo: '0.0.0.0', help: 'WSS bind host.')
      ..addOption('port', defaultsTo: '8443', help: 'WSS bind port.')
      ..addOption('cert', help: 'TLS certificate chain (PEM).')
      ..addOption('key', help: 'TLS private key (PEM).')
      ..addOption('api-host', defaultsTo: '0.0.0.0', help: 'HTTP API host.')
      ..addOption('api-port', defaultsTo: '8080', help: 'HTTP API port.')
      ..addOption('api-token', help: 'Bearer token required by the HTTP API.')
      ..addMultiOption(
        'grant',
        help: 'Token grant "principal:token:role1,role2" (repeatable).',
      );
  }

  @override
  String get name => 'start';

  @override
  String get description => 'Start the Hub (WSS) and its HTTP API.';

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
    final hub = OmnyServerHub(
      HubConfig(
        host: args['host'] as String,
        port: int.parse(args['port'] as String),
        securityContext: context,
        authenticator: TokenAuthenticator(grants),
        logger: stdout.writeln,
      ),
    );
    await hub.start();

    final events = EventAggregator()..attach(hub.config.eventBus);
    final metrics = HubMetrics(hub.registry)..attach(hub.config.eventBus);
    final api = HttpApiServer(
      hub: hub,
      apiToken: args['api-token'] as String?,
      events: events,
      metrics: metrics,
      host: args['api-host'] as String,
      port: int.parse(args['api-port'] as String),
    );
    await api.start();

    stdout.writeln('Hub WSS:  wss://${args['host']}:${hub.port}');
    stdout.writeln('Hub API:  http://${args['api-host']}:${api.boundPort}');
    stdout.writeln('Press Ctrl-C to stop.');
    await _awaitSignal();
    await api.close();
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
    stdout.writeln('Node "$id" connected to $hub. Press Ctrl-C to stop.');
    await _awaitSignal();
    await agent.stop();
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
