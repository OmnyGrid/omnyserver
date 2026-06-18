import 'package:dart_service_manager/dart_service_manager.dart' as dsm;

import '../../domain/entities/service_descriptor.dart' as domain;

/// Wraps `dart_service_manager` to install and manage OmnyServer's own Hub and
/// Node agent as native OS services (systemd / launchd / Windows Service
/// Manager), exposing the lifecycle in OmnyServer's domain terms.
///
/// This is the single integration point for "run as a system service" — the
/// CLI's `service` command and the node's service-control handler both go
/// through here, so platform specifics never leak into the core layers.
class ServiceController {
  /// The package name services are registered under (default `omnyserver`).
  final String packageName;

  final dsm.DartServiceManager _manager;

  /// Creates a controller over a [dsm.DartServiceManager].
  ServiceController({
    dsm.DartServiceManager? manager,
    this.packageName = 'omnyserver',
  }) : _manager = manager ?? dsm.DartServiceManager.forCurrentPlatform();

  /// Installs the service named [serviceName] from this package, optionally
  /// starting it and configuring auto-start at boot.
  Future<void> install(
    String serviceName, {
    bool startNow = true,
    String? path,
  }) => _manager.install(packageName, serviceName: serviceName, path: path);

  /// Starts the service.
  Future<void> start(String serviceName) =>
      _manager.start(packageName, serviceName);

  /// Stops the service.
  Future<void> stop(String serviceName) =>
      _manager.stop(packageName, serviceName);

  /// Restarts the service.
  Future<void> restart(String serviceName) =>
      _manager.restart(packageName, serviceName);

  /// Uninstalls the service.
  Future<void> uninstall(String serviceName) =>
      _manager.uninstall(packageName, serviceName: serviceName);

  /// Returns the current status as an OmnyServer [domain.ServiceDescriptor].
  Future<domain.ServiceDescriptor> describe(String serviceName) async {
    final status = await _manager.status(packageName, serviceName);
    return domain.ServiceDescriptor(
      name: serviceName,
      displayName: serviceName,
      status: _mapStatus(status),
      autoStart:
          status == dsm.ServiceStatus.running ||
          status == dsm.ServiceStatus.installed,
    );
  }

  static domain.ServiceStatus _mapStatus(dsm.ServiceStatus status) {
    switch (status) {
      case dsm.ServiceStatus.running:
        return domain.ServiceStatus.running;
      case dsm.ServiceStatus.stopped:
      case dsm.ServiceStatus.paused:
      case dsm.ServiceStatus.installed:
        return domain.ServiceStatus.stopped;
      case dsm.ServiceStatus.failed:
        return domain.ServiceStatus.unknown;
      default:
        return domain.ServiceStatus.notInstalled;
    }
  }
}
