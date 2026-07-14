import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dart_service_manager/dart_service_manager.dart' as svc;
import 'package:meta/meta.dart';

import 'cli_error.dart';
import 'start_options.dart';

// ---------------------------------------------------------------------------
// service — install the Hub or a Node agent as a native OS service.
//
// The CLI installs *itself*: it reconstructs the `omnyserver <role> start …`
// command line from the flags you pass here and bakes it into a systemd unit,
// a launchd plist or a Windows scheduled task. No manifest, no compilation —
// `dart_service_manager` does the platform work behind one interface.
//
// Not to be confused with Hub→node *remote* service control (`ServiceControl`,
// `NodeServiceHandler`), which is a fleet-management feature: the Hub telling a
// node to manage some service on that machine. This is omnyserver supervising
// itself.
// ---------------------------------------------------------------------------

/// The package name `dart_service_manager` records these services under.
const String servicePackage = 'omnyserver';

/// The installable roles. The role is a positional argument.
const Set<String> serviceRoles = {'hub', 'node'};

/// The `hub start` options — used to reject them on `service install node`.
const Set<String> _hubOnlyOptions = {
  'host',
  'port',
  'cert',
  'key',
  'tls-dir',
  'node-path',
  'shell',
  'api-token',
  'grant',
  'alert',
  'cors-origin',
  'ephemeral',
};

/// The `node start` options — used to reject them on `service install hub`.
const Set<String> _nodeOnlyOptions = {
  'hub',
  'id',
  'principal',
  'token',
  'ca',
  'insecure',
  'with-shell',
  'ship-logs',
  'label',
  'shell-label',
};

/// `omnyserver service …`
class ServiceCommand extends Command<void> {
  /// Creates the service command group.
  ServiceCommand() {
    addSubcommand(ServiceInstallCommand());
    addSubcommand(ServiceReinstallCommand());
    addSubcommand(ServiceReconfigureCommand());
    addSubcommand(ServiceUninstallCommand());
    addSubcommand(ServiceStartCommand());
    addSubcommand(ServiceStopCommand());
    addSubcommand(ServiceRestartCommand());
    addSubcommand(ServiceStatusCommand());
    addSubcommand(ServiceInfoCommand());
  }

  @override
  String get name => 'service';

  @override
  String get description =>
      'Install and manage the Hub or a Node agent as an OS service.';
}

// ---------------------------------------------------------------------------
// Shared plumbing.
// ---------------------------------------------------------------------------

/// Reads and validates the `hub|node` role positional from [args].
String requireRole(ArgResults args) {
  final rest = args.rest;
  if (rest.isEmpty) throw CliError('specify a role: hub or node');
  final role = rest.first;
  if (!serviceRoles.contains(role)) {
    throw CliError("unknown role '$role' (expected: hub or node)");
  }
  if (rest.length > 1) {
    throw CliError('unexpected arguments: ${rest.skip(1).join(' ')}');
  }
  return role;
}

/// Rejects options belonging to the *other* role.
///
/// The `service` parser accepts the union of both roles' options, so nothing
/// stops you writing `service install node --cert x`. Silently ignoring it
/// would install a node that quietly dropped the flag you asked for.
void rejectForeignOptions(String role, ArgResults args) {
  final foreign = role == 'hub' ? _nodeOnlyOptions : _hubOnlyOptions;
  final passed = foreign.where(args.wasParsed).toList()..sort();
  if (passed.isEmpty) return;
  final names = passed.map((o) => '--$o').join(', ');
  final other = role == 'hub' ? 'node' : 'hub';
  throw CliError(
    passed.length == 1
        ? '$names is a $other option; not valid for role "$role"'
        : '$names are $other options; not valid for role "$role"',
  );
}

/// Runs a `dart_service_manager` [action], translating its exceptions into the
/// CLI's [CliError] for a clean, stack-trace-free message.
Future<void> runService(Future<void> Function() action) async {
  try {
    await action();
  } on svc.ServiceAlreadyInstalledException catch (e) {
    throw CliError(e.message);
  } on svc.PermissionDeniedException catch (e) {
    throw CliError('${e.message} (try again with elevated privileges)');
  } on svc.ServiceManagerException catch (e) {
    throw CliError(e.message);
  }
}

svc.DartServiceManager _serviceManager({bool verbose = false}) =>
    svc.DartServiceManager.forCurrentPlatform(
      logger: svc.ConsoleServiceLogger(
        minLevel: verbose ? svc.LogLevel.debug : svc.LogLevel.info,
      ),
      // On Windows, run via the Task Scheduler, not the SCM: a plain Dart
      // console app cannot perform the SCM start handshake, so the SCM kills it
      // (error 1053).
      windowsBackend: svc.WindowsServiceBackend.taskScheduler,
    );

void _addVerboseFlag(ArgParser parser) {
  parser.addFlag(
    'verbose',
    abbr: 'v',
    negatable: false,
    help: 'Show debug-level service manager logging.',
  );
}

/// Registers the union of the Hub and Node `start` options.
///
/// `shell-path` is the one name both roles declare (same default, same
/// meaning modulo direction), and `data-dir` means something broader here than
/// it does on `hub start` — the *root* holding credentials, identity and, for a
/// Hub, the fleet data underneath. Both are registered exactly once, here:
/// `ArgParser` throws on a duplicate name, and since `ServiceCommand()` is
/// built inside `buildRunner()`, a duplicate would take down every command.
@visibleForTesting
void addServiceRoleOptions(ArgParser parser) {
  parser
    ..addOption(
      'shell-path',
      defaultsTo: '/shell',
      help:
          'OmnyShell broker mount path (Hub: where it is served; Node: where '
          'the Hub serves it).',
    )
    ..addOption(
      'data-dir',
      help:
          'Directory the service keeps its state in: credentials and identity, '
          'and — for a Hub — the fleet data (nodes, audit, metrics, desired '
          'state, issued grants) under <dir>/hub. Defaults to ~/.omnyserver, '
          'or /var/lib/omnyserver under --system.',
    );
  addHubStartOptions(parser, includeShellPath: false, includeDataDir: false);
  addNodeStartOptions(parser, includeShellPath: false);
}

/// Adds the options shared by `install`, `reinstall` and `reconfigure`.
void _addServiceConfigOptions(ArgParser parser) {
  addServiceRoleOptions(parser);
  _addVerboseFlag(parser);
  parser.addFlag(
    'system',
    negatable: false,
    help: 'Install machine-wide (requires elevated privileges).',
  );
}

/// Reconstructs the `omnyserver <role> start …` argument vector from [args],
/// absolutizing filesystem paths so the baked-in command works from any
/// directory.
@visibleForTesting
List<String> serviceStartArgs(String role, ArgResults args) {
  final systemScope = args['system'] as bool;
  final out = <String>[role, 'start'];
  if (role == 'hub') {
    emitOption(out, 'host', args['host']);
    emitOption(out, 'port', args['port']);
    emitPathOption(out, 'cert', args['cert']);
    emitPathOption(out, 'key', args['key']);
    emitPathOption(out, 'tls-dir', args['tls-dir']);
    // A URL mount point, not a filesystem path — never absolutize it.
    emitOption(out, 'node-path', args['node-path']);
    emitFlag(out, 'shell', args['shell'] as bool);
    emitOption(out, 'shell-path', args['shell-path']);
    emitOption(out, 'api-token', args['api-token']);
    emitMultiOption(out, 'grant', args['grant'] as List<String>);
    emitMultiOption(out, 'alert', args['alert'] as List<String>);
    emitMultiOption(out, 'cors-origin', args['cors-origin'] as List<String>);
    final root = resolveDataDir(args, systemScope: systemScope);
    if (root == null) {
      emitFlag(out, 'ephemeral', true);
    } else {
      emitOption(out, 'data-dir', hubDataDir(root));
    }
  } else {
    emitOption(out, 'hub', args['hub']);
    emitOption(out, 'id', args['id']);
    emitOption(out, 'principal', args['principal']);
    emitOption(out, 'token', args['token']);
    emitPathOption(out, 'ca', args['ca']);
    emitFlag(out, 'insecure', args['insecure'] as bool);
    emitFlag(out, 'with-shell', args['with-shell'] as bool);
    emitOption(out, 'shell-path', args['shell-path']);
    emitNegatableFlag(out, 'ship-logs', args['ship-logs'] as bool);
    emitMultiOption(out, 'label', args['label'] as List<String>);
    emitMultiOption(out, 'shell-label', args['shell-label'] as List<String>);
    // `node start` has no --data-dir; the node's state rides in
    // OMNYSERVER_HOME, set in the descriptor's environment.
  }
  return out;
}

/// Builds the descriptor that installs *this* omnyserver executable to run
/// `omnyserver <role> start …` with the flags captured from [args].
@visibleForTesting
svc.ServiceDescriptor serviceDescriptor(String role, ArgResults args) {
  rejectForeignOptions(role, args);
  if (role == 'hub') {
    validateHubTls(args);
  } else {
    validateNodeStartArgs(args);
  }
  final systemScope = args['system'] as bool;
  final scope = systemScope ? svc.ServiceScope.system : svc.ServiceScope.user;

  // Both roles: pin OMNYSERVER_HOME. `OmnyServerHome.resolve()` falls back to
  // $HOME and then to the system temp dir, and a system service has no
  // meaningful $HOME — without this a node would keep its machine-UID file in
  // /tmp and re-register as a brand-new node after every reboot.
  final root = resolveDataDir(args, systemScope: systemScope);
  final env = <String, String>{'OMNYSERVER_HOME': ?root};

  return svc.ServiceDescriptor.forCurrentExecutable(
    packageName: servicePackage,
    serviceName: role,
    arguments: serviceStartArgs(role, args),
    environment: env,
    scope: scope,
    restart: svc.RestartPolicy.always,
  );
}

/// Renders the `service info` block: the recorded parameters, the resolved
/// command, and the native definition the OS actually runs the service from.
String _formatServiceInfo(String role, svc.ServiceInfo info) {
  final e = info.entry;
  final command = [e.binaryPath, ...e.arguments].join(' ');
  final out = StringBuffer()
    ..writeln('Service "$role" (${e.qualifiedName})')
    ..writeln('  status:      ${info.status.name}')
    ..writeln('  scope:       ${e.scope.name}')
    ..writeln('  installed:   ${e.installedAt.toIso8601String()}')
    ..writeln('  restart:     ${e.restart.name}')
    ..writeln('  command:     $command');
  if (e.environment.isNotEmpty) {
    out.writeln('  environment:');
    for (final entry in e.environment.entries) {
      out.writeln('    ${entry.key}=${entry.value}');
    }
  }
  out.writeln('  definition (${e.platform}):');
  for (final line in info.definition.split('\n')) {
    out.writeln('    $line');
  }
  return out.toString();
}

String _usageExamples(List<String> examples) =>
    ['', 'Examples:', ...examples.map((e) => '  $e')].join('\n');

// ---------------------------------------------------------------------------
// Subcommands.
// ---------------------------------------------------------------------------

/// `omnyserver service install <hub|node>`
class ServiceInstallCommand extends Command<void> {
  /// Creates the service-install command.
  ServiceInstallCommand() {
    _addServiceConfigOptions(argParser);
    argParser
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print the rendered service definition without installing.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Replace an existing service of the same role.',
      );
  }

  @override
  String get name => 'install';

  @override
  String get description => 'Install the Hub or a Node agent as an OS service.';

  @override
  String get invocation => 'omnyserver service install <hub|node> [options]';

  @override
  String? get usageFooter => _usageExamples([
    'omnyserver service install hub --cert certs/server.crt '
        '--key certs/server.key --grant "alice:s3cr3t:admin"',
    'omnyserver service install node --hub wss://hub:8443 --id web-01 '
        '--token s3cr3t',
    'omnyserver service install hub --system --tls-dir /etc/letsencrypt/live/hub',
    'omnyserver service install node --hub wss://hub:8443 --id web-01 '
        '--token s3cr3t --dry-run',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    final role = requireRole(args);
    final descriptor = serviceDescriptor(role, args);
    final manager = _serviceManager(verbose: args['verbose'] as bool);
    if (args['dry-run'] as bool) {
      stdout.writeln(manager.renderDefinition(descriptor));
      return;
    }
    await runService(() async {
      await manager.installDescriptor(
        descriptor,
        startNow: true,
        force: args['force'] as bool,
      );
      stdout.writeln(
        'Installed and started service "$role" (${descriptor.scope.name} '
        'scope).',
      );
    });
  }
}

/// `omnyserver service reinstall <hub|node>`
class ServiceReinstallCommand extends Command<void> {
  /// Creates the service-reinstall command.
  ServiceReinstallCommand() {
    _addServiceConfigOptions(argParser);
    argParser.addFlag(
      'dry-run',
      negatable: false,
      help: 'Print the rendered service definition without installing.',
    );
  }

  @override
  String get name => 'reinstall';

  @override
  String get description =>
      'Reinstall the Hub/Node service, refreshing the executable. With no '
      'options the installed config is reused; pass install options to '
      'reinstall with a fresh config.';

  @override
  String get invocation => 'omnyserver service reinstall <hub|node> [options]';

  @override
  String? get usageFooter => _usageExamples([
    'omnyserver service reinstall hub',
    'omnyserver service reinstall node --id web-01 --hub wss://hub:8443',
  ]);

  /// Whether the user passed any config option — as opposed to just the role,
  /// `--verbose` or `--dry-run`. If so, reinstall builds a fresh descriptor
  /// from the flags rather than reusing the stored one.
  bool _hasConfigOverride(ArgResults args) => args.options.any(
    (o) => o != 'verbose' && o != 'dry-run' && args.wasParsed(o),
  );

  @override
  Future<void> run() async {
    final args = argResults!;
    final role = requireRole(args);
    final manager = _serviceManager(verbose: args['verbose'] as bool);
    await runService(() async {
      final svc.ServiceDescriptor descriptor;
      if (_hasConfigOverride(args)) {
        descriptor = serviceDescriptor(role, args);
      } else {
        // Reuse mode: rebuild the descriptor for *this* executable — so the
        // binary refreshes — from the config already installed.
        final svc.ServiceInfo info;
        try {
          info = await manager.describe(servicePackage, role);
        } on svc.ServiceNotFoundException {
          throw CliError(
            '"$role" is not installed; pass install options to install it '
            '(e.g. `omnyserver service install $role …`).',
          );
        }
        descriptor = svc.ServiceDescriptor.forCurrentExecutable(
          packageName: servicePackage,
          serviceName: role,
          arguments: info.entry.arguments,
          environment: info.entry.environment,
          scope: info.entry.scope,
          restart: svc.RestartPolicy.always,
        );
      }
      if (args['dry-run'] as bool) {
        stdout.writeln(manager.renderDefinition(descriptor));
        return;
      }
      await manager.reinstall(descriptor, startNow: true);
      stdout.writeln(
        'Reinstalled service "$role" (${descriptor.scope.name} scope).',
      );
    });
  }
}

/// `omnyserver service reconfigure <hub|node>`
class ServiceReconfigureCommand extends Command<void> {
  /// Creates the service-reconfigure command.
  ServiceReconfigureCommand() {
    _addServiceConfigOptions(argParser);
  }

  @override
  String get name => 'reconfigure';

  @override
  String get description =>
      'Re-apply changed flags to an installed Hub/Node service.';

  @override
  String get invocation =>
      'omnyserver service reconfigure <hub|node> [options]';

  @override
  String? get usageFooter => _usageExamples([
    'omnyserver service reconfigure node --id web-01 --label region=eu',
    'omnyserver service reconfigure hub --cors-origin https://dash.example.com',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    final role = requireRole(args);
    final descriptor = serviceDescriptor(role, args);
    await runService(() async {
      await _serviceManager(
        verbose: args['verbose'] as bool,
      ).reconfigure(descriptor);
      stdout.writeln('Reconfigured service "$role".');
    });
  }
}

/// Base for the lifecycle subcommands, which take only a `hub|node` role.
abstract class _ServiceRoleCommand extends Command<void> {
  _ServiceRoleCommand() {
    _addVerboseFlag(argParser);
  }

  @override
  String get invocation => 'omnyserver service $name <hub|node>';

  @override
  String? get usageFooter => _usageExamples([
    'omnyserver service $name hub',
    'omnyserver service $name node',
  ]);

  /// Performs the action against the platform service manager.
  Future<void> act(svc.DartServiceManager manager, String role);

  @override
  Future<void> run() async {
    final args = argResults!;
    final role = requireRole(args);
    await runService(
      () => act(_serviceManager(verbose: args['verbose'] as bool), role),
    );
  }
}

/// `omnyserver service uninstall <hub|node>`
class ServiceUninstallCommand extends _ServiceRoleCommand {
  @override
  String get name => 'uninstall';

  @override
  String get description => 'Stop and remove the Hub/Node service.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    await manager.uninstall(servicePackage, serviceName: role);
    stdout.writeln('Uninstalled service "$role".');
  }
}

/// `omnyserver service start <hub|node>`
class ServiceStartCommand extends _ServiceRoleCommand {
  @override
  String get name => 'start';

  @override
  String get description => 'Start the installed Hub/Node service.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    await manager.start(servicePackage, role);
    stdout.writeln('Started service "$role".');
  }
}

/// `omnyserver service stop <hub|node>`
class ServiceStopCommand extends _ServiceRoleCommand {
  @override
  String get name => 'stop';

  @override
  String get description => 'Stop the installed Hub/Node service.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    await manager.stop(servicePackage, role);
    stdout.writeln('Stopped service "$role".');
  }
}

/// `omnyserver service restart <hub|node>`
class ServiceRestartCommand extends _ServiceRoleCommand {
  @override
  String get name => 'restart';

  @override
  String get description => 'Restart the installed Hub/Node service.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    await manager.restart(servicePackage, role);
    stdout.writeln('Restarted service "$role".');
  }
}

/// `omnyserver service status <hub|node>`
class ServiceStatusCommand extends _ServiceRoleCommand {
  @override
  String get name => 'status';

  @override
  String get description => 'Show the status of the Hub/Node service.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    final status = await manager.status(servicePackage, role);
    stdout.writeln('$role: ${status.name}');
  }
}

/// `omnyserver service info <hub|node>`
class ServiceInfoCommand extends _ServiceRoleCommand {
  @override
  String get name => 'info';

  @override
  String get description =>
      'Show the installed Hub/Node service: its parameters and the actual '
      'command the OS runs it with.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    final svc.ServiceInfo info;
    try {
      info = await manager.describe(servicePackage, role);
    } on svc.ServiceNotFoundException {
      stdout.writeln('$role: not installed');
      return;
    }
    stdout.write(_formatServiceInfo(role, info));
  }
}
