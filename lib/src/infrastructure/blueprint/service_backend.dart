import 'package:dart_service_manager/dart_service_manager.dart' as dsm;

/// What a `service` resource needs from the operating system's service
/// manager, and nothing more.
///
/// A seam rather than [dsm.DartServiceManager] itself: that class stands for a
/// whole toolchain — a package resolver, a compiler, a registry, a driver per
/// platform — and a test of *when the provider restarts a service* should not
/// need systemd to answer.
abstract interface class ServiceBackend {
  /// What is installed under [serviceName], or `null` if nothing is.
  Future<InstalledService?> describe(String serviceName);

  /// Installs [descriptor], replacing any previous definition.
  Future<void> install(dsm.ServiceDescriptor descriptor);

  /// Re-applies [descriptor] to an installed service, restarting it onto the
  /// new definition if it was running.
  Future<void> reconfigure(dsm.ServiceDescriptor descriptor);

  /// Starts the service.
  Future<void> start(String serviceName);

  /// Stops the service.
  Future<void> stop(String serviceName);

  /// Restarts the service.
  Future<void> restart(String serviceName);

  /// Removes the service.
  Future<void> uninstall(String serviceName);
}

/// One installed service, as the service manager recorded it.
class InstalledService {
  /// Its live status.
  final dsm.ServiceStatus status;

  /// The executable the OS runs.
  final String executable;

  /// Its arguments.
  final List<String> arguments;

  /// Its environment.
  final Map<String, String> environment;

  /// Its working directory.
  final String? workingDirectory;

  /// Its environment file.
  final String? environmentFile;

  /// Its restart policy.
  final dsm.RestartPolicy restart;

  /// Its scope.
  final dsm.ServiceScope scope;

  /// Whether it starts at boot.
  final bool autoStart;

  /// Creates a record of an installed service.
  const InstalledService({
    required this.status,
    required this.executable,
    this.arguments = const [],
    this.environment = const {},
    this.workingDirectory,
    this.environmentFile,
    this.restart = dsm.RestartPolicy.always,
    this.scope = dsm.ServiceScope.system,
    this.autoStart = true,
  });

  /// The same record a [descriptor] would produce once installed.
  factory InstalledService.of(
    dsm.ServiceDescriptor descriptor, {
    dsm.ServiceStatus status = dsm.ServiceStatus.installed,
  }) => InstalledService(
    status: status,
    executable: descriptor.executablePath,
    arguments: descriptor.arguments,
    environment: descriptor.environment,
    workingDirectory: descriptor.workingDirectory,
    environmentFile: descriptor.environmentFile,
    restart: descriptor.restart,
    scope: descriptor.scope,
    autoStart: descriptor.autoStart,
  );
}

/// The production [ServiceBackend]: `dart_service_manager`, under a package
/// name of its own.
///
/// [packageName] keeps an application's services apart from OmnyServer's: the
/// Hub and the agent are registered under `omnyserver`, and a blueprint's under
/// `omnyserver-managed` — so no blueprint can name the agent it is running
/// through and stop it.
class DsmServiceBackend implements ServiceBackend {
  /// The package services are registered under.
  final String packageName;

  final dsm.DartServiceManager _manager;

  /// Creates a backend over [manager] (the current platform's by default).
  DsmServiceBackend({
    this.packageName = managedPackage,
    dsm.DartServiceManager? manager,
  }) : _manager = manager ?? dsm.DartServiceManager.forCurrentPlatform();

  /// The package every blueprint-managed service is registered under.
  static const String managedPackage = 'omnyserver-managed';

  @override
  Future<InstalledService?> describe(String serviceName) async {
    final dsm.ServiceInfo info;
    try {
      info = await _manager.describe(packageName, serviceName);
    } on dsm.ServiceNotFoundException {
      return null;
    }
    final e = info.entry;
    return InstalledService(
      status: info.status,
      executable: e.binaryPath,
      arguments: e.arguments,
      environment: e.environment,
      workingDirectory: e.workingDirectory,
      environmentFile: e.environmentFile,
      restart: e.restart,
      scope: e.scope,
      autoStart: e.autoStart,
    );
  }

  @override
  Future<void> install(dsm.ServiceDescriptor descriptor) =>
      _manager.installDescriptor(descriptor, force: true);

  @override
  Future<void> reconfigure(dsm.ServiceDescriptor descriptor) =>
      _manager.reconfigure(descriptor);

  @override
  Future<void> start(String serviceName) =>
      _manager.start(packageName, serviceName);

  @override
  Future<void> stop(String serviceName) =>
      _manager.stop(packageName, serviceName);

  @override
  Future<void> restart(String serviceName) =>
      _manager.restart(packageName, serviceName);

  @override
  Future<void> uninstall(String serviceName) =>
      _manager.uninstall(packageName, serviceName: serviceName);
}
