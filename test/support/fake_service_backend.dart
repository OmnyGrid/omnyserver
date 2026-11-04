import 'package:dart_service_manager/dart_service_manager.dart' as dsm;
import 'package:omnyserver/omnyserver_node.dart';

/// A service manager that keeps its units in a map, and records every call.
///
/// Stands in for systemd and launchd, so a test of *when* a service is
/// installed, restarted or rolled back needs neither — nor root.
class FakeBackend implements ServiceBackend {
  /// The installed units, by service name.
  final Map<String, InstalledService> units = {};

  /// Every call, as `"<verb> <name>"`, in order.
  final List<String> calls = [];

  /// What a start (or restart) leaves the service as.
  dsm.ServiceStatus startsAs = dsm.ServiceStatus.running;

  /// Throws from install, to stand for a service manager that refuses.
  Object? installError;

  void _set(String name, dsm.ServiceStatus status) {
    final u = units[name]!;
    units[name] = InstalledService(
      status: status,
      executable: u.executable,
      arguments: u.arguments,
      environment: u.environment,
      workingDirectory: u.workingDirectory,
      environmentFile: u.environmentFile,
      restart: u.restart,
      scope: u.scope,
      autoStart: u.autoStart,
    );
  }

  @override
  Future<InstalledService?> describe(String serviceName) async =>
      units[serviceName];

  @override
  Future<void> install(dsm.ServiceDescriptor d) async {
    calls.add('install ${d.serviceName}');
    if (installError != null) throw installError!;
    units[d.serviceName] = InstalledService.of(d);
  }

  @override
  Future<void> reconfigure(dsm.ServiceDescriptor d) async {
    calls.add('reconfigure ${d.serviceName}');
    final was = units[d.serviceName]?.status;
    units[d.serviceName] = InstalledService.of(
      d,
      status: was == dsm.ServiceStatus.running ? startsAs : was!,
    );
  }

  @override
  Future<void> start(String n) async {
    calls.add('start $n');
    _set(n, startsAs);
  }

  @override
  Future<void> stop(String n) async {
    calls.add('stop $n');
    _set(n, dsm.ServiceStatus.stopped);
  }

  @override
  Future<void> restart(String n) async {
    calls.add('restart $n');
    _set(n, startsAs);
  }

  @override
  Future<void> uninstall(String n) async {
    calls.add('uninstall $n');
    units.remove(n);
  }
}

/// Answers health checks from a script: each entry is one attempt's answer.
class ScriptedProbe implements HealthProbe {
  /// Creates a probe answering [answers] in order, then "still not ready".
  ScriptedProbe(this.answers);

  /// The answers left: `null` is healthy, a string is why not.
  final List<String?> answers;

  /// Every check asked, in order.
  final List<HealthCheck> asked = [];

  @override
  Future<String?> check(HealthCheck check) async {
    asked.add(check);
    if (answers.isEmpty) return 'still not ready';
    return answers.removeAt(0);
  }
}
