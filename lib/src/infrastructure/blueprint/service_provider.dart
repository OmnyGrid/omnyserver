import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dart_service_manager/dart_service_manager.dart' as dsm;
import 'package:path/path.dart' as p;

import '../../domain/blueprint/built_in_provider.dart';
import '../../domain/blueprint/resolved_blueprint.dart';
import '../../domain/blueprint/resource.dart';
import '../../domain/blueprint/resource_change.dart';
import '../../domain/blueprint/resource_provider.dart';
import '../../domain/blueprint/resource_state.dart';
import '../../domain/formula/formula_context.dart';
import '../../domain/formula/formula_status.dart';
import 'health_probe.dart';
import 'service_backend.dart';

/// Serves `service:<name>` resources: an application run as a native OS
/// service — a systemd unit, a launchd job — supervised and started at boot.
///
/// ```yaml
/// - type: service
///   name: nfeflash-api
///   ensure: running
///   restartOn: [ "release:nfeflash_api" ]
///   params:
///     exec: /opt/nfeflash/current/api_server
///     args: "--config /etc/nfeflash/api.yaml"
///     working_dir: /opt/nfeflash/current
///     env_file: /etc/nfeflash/api.env
///     env.TZ: America/Sao_Paulo
///     user: nfeflash
///     restart: on-failure
///     health_url: http://127.0.0.1:8080/health
///     health_timeout: "90"
/// ```
///
/// **What "the same service" means.** The unit is compared with what it would
/// be if installed from the declaration now — executable, arguments,
/// environment, working directory, restart policy, scope. A unit somebody edited
/// by hand, or a declaration somebody changed, is drift; applying reconfigures
/// it and restarts it onto the new definition. A matching unit in the right
/// state is left alone, so an apply on a timer does not bounce production.
///
/// **Healthy, not just running.** With `health_url` (a GET that must answer
/// 2xx) or `health_cmd` (a command that must exit 0), every start and restart
/// waits until the service says it is working, up to `health_timeout` seconds,
/// and fails the change if it never does. That failure is what a release
/// rollback is triggered by.
///
/// **Running as someone else.** `user:` runs the service as that account. On
/// Linux the unit `exec`s through `setpriv` with the account's uid, gid and
/// groups, and `HOME`/`USER` set to match; elsewhere it is refused rather than
/// silently run as root. (A native `User=` belongs in dart_service_manager.)
///
/// **What a blueprint may run.** `exec` and `working_dir` must sit under one of
/// [allowedRoots] when the node gives any — the operator who installed the
/// agent decides which directories a blueprint may start programs from.
class ServiceProvider
    implements ResourceProvider, ConvergenceJudge, RefreshableProvider {
  /// The service manager.
  final ServiceBackend backend;

  /// Asks a started service whether it works.
  final HealthProbe probe;

  /// Directories `exec` and `working_dir` must be inside; `null` for anywhere.
  final List<String>? allowedRoots;

  /// Whether this agent runs as root — and so installs system-wide by default.
  final bool runningAsRoot;

  /// Whether `user:` can be honoured here.
  final bool canSwitchUser;

  /// Looks an account up: `(uid, gid, home)`, or `null` if there is none.
  final ({int uid, int gid, String home})? Function(String user) lookupUser;

  /// Where `setpriv` is.
  final String setprivPath;

  /// Waits between health attempts. A seam so tests do not sleep.
  final Future<void> Function(Duration) delay;

  /// Creates a service provider.
  ServiceProvider({
    ServiceBackend? backend,
    this.probe = const DefaultHealthProbe(),
    this.allowedRoots,
    bool? runningAsRoot,
    bool? canSwitchUser,
    ({int uid, int gid, String home})? Function(String user)? lookupUser,
    this.setprivPath = '/usr/bin/setpriv',
    Future<void> Function(Duration)? delay,
  }) : backend = backend ?? DsmServiceBackend(),
       runningAsRoot = runningAsRoot ?? _isRoot(),
       canSwitchUser =
           canSwitchUser ??
           (Platform.isLinux && File('/usr/bin/setpriv').existsSync()),
       lookupUser = lookupUser ?? _getent,
       delay = delay ?? Future<void>.delayed;

  @override
  String get type => BuiltInProvider.service.type;

  @override
  Set<Ensure> get supportedEnsure => BuiltInProvider.service.supportedEnsure;

  @override
  Future<ResourceState> read(
    ResolvedResource resource,
    FormulaContext context,
  ) async {
    final installed = await backend.describe(resource.id.name);
    if (installed == null) {
      return ResourceState(
        id: resource.id,
        status: FormulaStatus.absent,
        checkedAt: context.now(),
        message: 'not installed',
      );
    }
    return ResourceState(
      id: resource.id,
      status: switch (installed.status) {
        dsm.ServiceStatus.running => FormulaStatus.running,
        dsm.ServiceStatus.failed => FormulaStatus.failed,
        dsm.ServiceStatus.unknown => FormulaStatus.unknown,
        _ => FormulaStatus.stopped,
      },
      fingerprint: fingerprintOf(installed),
      message: installed.status.name,
      checkedAt: context.now(),
    );
  }

  @override
  bool satisfies(ResolvedResource resource, ResourceState state) {
    if (state.status == FormulaStatus.unknown) return false;
    if (resource.ensure == Ensure.absent) {
      return state.status == FormulaStatus.absent;
    }
    if (!state.isPresent) return false;
    final String want;
    try {
      want = fingerprintOf(InstalledService.of(descriptorFor(resource)));
    } on Object {
      // A declaration that cannot be turned into a unit converges on nothing;
      // the apply reports why.
      return false;
    }
    if (state.fingerprint != want) return false;
    return switch (resource.ensure) {
      Ensure.running => state.status == FormulaStatus.running,
      Ensure.stopped => state.status == FormulaStatus.stopped,
      _ => true,
    };
  }

  @override
  Future<ResourceChange> apply(
    ResolvedResource resource,
    ResourceState current,
    FormulaContext context,
  ) async {
    final name = resource.id.name;
    try {
      if (resource.ensure == Ensure.absent) {
        if (current.status == FormulaStatus.running) {
          await backend.stop(name);
        }
        await backend.uninstall(name);
        context.log('uninstalled $name');
        return _change(resource, ChangeKind.remove, 'uninstalled');
      }

      final descriptor = descriptorFor(resource);
      final wanted = fingerprintOf(InstalledService.of(descriptor));
      final run = resource.ensure == Ensure.running;
      final String did;
      final ChangeKind kind;

      if (!current.isPresent) {
        await backend.install(descriptor);
        context.log('installed $name: ${_commandLine(descriptor)}');
        kind = ChangeKind.create;
        did = 'installed';
        if (run) await backend.start(name);
      } else if (current.fingerprint != wanted) {
        // Reconfiguring restarts a running service onto the new definition, so
        // only a stopped one that should run needs starting afterwards.
        await backend.reconfigure(descriptor);
        context.log('reconfigured $name: ${_commandLine(descriptor)}');
        kind = ChangeKind.update;
        did = 'reconfigured';
        if (run && current.status != FormulaStatus.running) {
          await backend.start(name);
        } else if (!run &&
            current.status == FormulaStatus.running &&
            resource.ensure == Ensure.stopped) {
          await backend.stop(name);
        }
      } else if (run) {
        await backend.start(name);
        kind = ChangeKind.update;
        did = 'started';
      } else if (resource.ensure == Ensure.stopped) {
        await backend.stop(name);
        kind = ChangeKind.update;
        did = 'stopped';
      } else {
        return _change(resource, ChangeKind.noop, 'already installed');
      }

      if (run) {
        final unhealthy = await _awaitHealthy(resource, context);
        if (unhealthy != null) {
          return _change(resource, ChangeKind.failed, '$did, but $unhealthy');
        }
        return _change(resource, kind, '$did and running');
      }
      return _change(resource, kind, did);
    } on Object catch (e) {
      return _change(resource, ChangeKind.failed, '$e');
    }
  }

  @override
  Future<ResourceChange> refresh(
    ResolvedResource resource,
    FormulaContext context,
  ) async {
    try {
      if (resource.ensure != Ensure.running) {
        // A service declared stopped stays stopped: a new release is picked up
        // whenever somebody does start it.
        return _change(
          resource,
          ChangeKind.noop,
          'not running — not restarted',
        );
      }
      await backend.restart(resource.id.name);
      context.log('restarted ${resource.id.name}');
      final unhealthy = await _awaitHealthy(resource, context);
      return unhealthy == null
          ? _change(resource, ChangeKind.update, 'restarted')
          : _change(resource, ChangeKind.failed, 'restarted, but $unhealthy');
    } on Object catch (e) {
      return _change(resource, ChangeKind.failed, '$e');
    }
  }

  // ---------------------------------------------------------------------------

  /// The unit [resource] declares.
  dsm.ServiceDescriptor descriptorFor(ResolvedResource resource) {
    final params = resource.resource.params;
    final exec = params['exec'];
    if (exec == null || exec.isEmpty) {
      throw ArgumentError('a service needs `exec`');
    }
    _checkPath('exec', exec);
    final workingDir = params['working_dir'];
    if (workingDir != null) _checkPath('working_dir', workingDir);

    final scope = switch (params['scope']) {
      null => runningAsRoot ? dsm.ServiceScope.system : dsm.ServiceScope.user,
      'system' => dsm.ServiceScope.system,
      'user' => dsm.ServiceScope.user,
      final other => throw ArgumentError('scope "$other" — use system or user'),
    };

    final restartRaw = params['restart'] ?? 'always';
    final restart =
        dsm.RestartPolicy.tryParse(restartRaw) ??
        (throw ArgumentError(
          'restart "$restartRaw" — use always, on-failure or never',
        ));

    final environment = <String, String>{
      for (final entry in params.entries)
        if (entry.key.startsWith('env.') && entry.key.length > 4)
          entry.key.substring(4): entry.value,
    };

    var executable = exec;
    var arguments = splitArguments(params['args'] ?? '');

    final user = params['user'];
    if (user != null && user.isNotEmpty) {
      if (!canSwitchUser) {
        throw ArgumentError(
          '`user: $user` needs Linux with setpriv — this node would run the '
          'service as itself instead, so it refuses',
        );
      }
      final account = lookupUser(user);
      if (account == null) throw ArgumentError('no such user "$user"');
      final group = params['group'];
      final gid = group == null ? account.gid : _gidOf(group);
      executable = setprivPath;
      arguments = [
        '--reuid=${account.uid}',
        '--regid=$gid',
        '--init-groups',
        '--',
        exec,
        ...arguments,
      ];
      environment.putIfAbsent('HOME', () => account.home);
      environment.putIfAbsent('USER', () => user);
      environment.putIfAbsent('LOGNAME', () => user);
    }

    return dsm.ServiceDescriptor(
      packageName: DsmServiceBackend.managedPackage,
      serviceName: resource.id.name,
      executablePath: executable,
      arguments: arguments,
      scope: scope,
      description:
          params['description'] ??
          '${resource.id.name} (managed by omnyserver)',
      environment: environment,
      workingDirectory: workingDir,
      environmentFile: params['env_file'],
      restart: restart,
      restartDelay: Duration(
        seconds: int.tryParse(params['restart_delay'] ?? '') ?? 5,
      ),
      stopTimeout: switch (int.tryParse(params['stop_timeout'] ?? '')) {
        null => null,
        final s => Duration(seconds: s),
      },
    );
  }

  /// A digest of what the OS would run — the comparison drift is made of.
  static String fingerprintOf(InstalledService s) {
    final keys = s.environment.keys.toList()..sort();
    final canonical = jsonEncode({
      'exec': s.executable,
      'args': s.arguments,
      'env': [for (final k in keys) '$k=${s.environment[k]}'],
      'cwd': s.workingDirectory,
      'envFile': s.environmentFile,
      'restart': s.restart.name,
      'scope': s.scope.name,
      'boot': s.autoStart,
    });
    final digest = Sha256().toSync().hashSync(utf8.encode(canonical));
    return [
      for (final b in digest.bytes) b.toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// Splits `--config "/etc/my app.yaml" -v` the way a POSIX shell would —
  /// whitespace separates, quotes group, a backslash escapes — and nothing
  /// more: no variables, no globs, no substitution.
  static List<String> splitArguments(String line) {
    final out = <String>[];
    final current = StringBuffer();
    var inToken = false;
    String? quote;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else if (c == r'\' && quote == '"' && i + 1 < line.length) {
          current.write(line[++i]);
        } else {
          current.write(c);
        }
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        inToken = true;
      } else if (c == r'\' && i + 1 < line.length) {
        current.write(line[++i]);
        inToken = true;
      } else if (c.trim().isEmpty) {
        if (inToken) {
          out.add(current.toString());
          current.clear();
          inToken = false;
        }
      } else {
        current.write(c);
        inToken = true;
      }
    }
    if (quote != null) {
      throw ArgumentError('unterminated $quote in args: $line');
    }
    if (inToken) out.add(current.toString());
    return out;
  }

  /// Polls the health check until it passes or `health_timeout` runs out.
  Future<String?> _awaitHealthy(
    ResolvedResource resource,
    FormulaContext context,
  ) async {
    final params = resource.resource.params;
    final url = params['health_url'];
    final check = HealthCheck(
      url: url == null || url.isEmpty ? null : Uri.parse(url),
      command: params['health_cmd'],
    );
    if (check.isEmpty) return null;

    final timeout = Duration(
      seconds: int.tryParse(params['health_timeout'] ?? '') ?? 60,
    );
    final interval = Duration(
      seconds: int.tryParse(params['health_interval'] ?? '') ?? 2,
    );
    final deadline = DateTime.now().add(timeout);
    // Bounded by count as well as by the wall clock: an attempt that itself
    // takes the whole interval must not stretch the budget, and a clock that
    // does not move — a test's — must not make it endless.
    final maxAttempts = interval.inMilliseconds <= 0
        ? 1
        : timeout.inMilliseconds ~/ interval.inMilliseconds + 1;
    var attempts = 0;
    String? last;
    while (true) {
      attempts++;
      last = await probe.check(check);
      if (last == null) {
        context.log('healthy: $check (attempt $attempts)');
        return null;
      }
      // The process is gone: no amount of waiting will make it answer.
      final installed = await backend.describe(resource.id.name);
      if (installed != null && installed.status == dsm.ServiceStatus.failed) {
        return 'it exited (${installed.status.name}) — last check: $last';
      }
      if (attempts >= maxAttempts || !DateTime.now().isBefore(deadline)) {
        break;
      }
      await delay(interval);
    }
    context.log('unhealthy after $attempts attempts: $last');
    return 'not healthy within ${timeout.inSeconds}s: $last';
  }

  void _checkPath(String field, String path) {
    if (!p.isAbsolute(path)) {
      throw ArgumentError('$field "$path" must be an absolute path');
    }
    final allowed = allowedRoots;
    if (allowed == null) return;
    final normalized = p.normalize(path);
    final ok = allowed.any((a) {
      final base = p.normalize(p.absolute(a));
      return normalized == base || p.isWithin(base, normalized);
    });
    if (!ok) {
      throw ArgumentError(
        '$field "$path" is outside what this node allows '
        '(${allowed.isEmpty ? 'nothing — start it with --allow-root' : allowed.join(', ')})',
      );
    }
  }

  static String _commandLine(dsm.ServiceDescriptor d) =>
      [d.executablePath, ...d.arguments].join(' ');

  ResourceChange _change(
    ResolvedResource resource,
    ChangeKind kind,
    String reason,
  ) => ResourceChange(
    id: resource.id,
    kind: kind,
    reason: reason,
    origin: resource.origin,
  );

  static bool _isRoot() {
    if (Platform.isWindows) return false;
    try {
      final result = Process.runSync('id', ['-u']);
      return '${result.stdout}'.trim() == '0';
    } on Object {
      return false;
    }
  }

  static ({int uid, int gid, String home})? _getent(String user) {
    try {
      final result = Process.runSync('getent', ['passwd', user]);
      if (result.exitCode != 0) return null;
      final fields = '${result.stdout}'.trim().split(':');
      if (fields.length < 6) return null;
      final uid = int.tryParse(fields[2]);
      final gid = int.tryParse(fields[3]);
      if (uid == null || gid == null) return null;
      return (uid: uid, gid: gid, home: fields[5]);
    } on Object {
      return null;
    }
  }

  static int _gidOf(String group) {
    final numeric = int.tryParse(group);
    if (numeric != null) return numeric;
    final result = Process.runSync('getent', ['group', group]);
    final fields = '${result.stdout}'.trim().split(':');
    final gid = result.exitCode == 0 && fields.length >= 3
        ? int.tryParse(fields[2])
        : null;
    if (gid == null) throw ArgumentError('no such group "$group"');
    return gid;
  }
}
