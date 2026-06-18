import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

/// The lifecycle state of an OS-managed service.
enum ServiceStatus {
  /// The service is installed and running.
  running,

  /// The service is installed but stopped.
  stopped,

  /// The service is not installed.
  notInstalled,

  /// The service state could not be determined.
  unknown;

  /// Parses a wire name, defaulting to [unknown].
  static ServiceStatus parse(String value) => ServiceStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => ServiceStatus.unknown,
  );
}

/// Describes an OS-level service managed by OmnyServer (hub or agent),
/// abstracting over systemd / launchd / Windows Service Manager.
@immutable
class ServiceDescriptor {
  /// The system service name.
  final String name;

  /// A human-friendly display name.
  final String displayName;

  /// The current status.
  final ServiceStatus status;

  /// Whether the service is configured to start at boot.
  final bool autoStart;

  /// Creates a service descriptor.
  const ServiceDescriptor({
    required this.name,
    required this.displayName,
    required this.status,
    this.autoStart = false,
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'name': name,
    'displayName': displayName,
    'status': status.name,
    'autoStart': autoStart,
  };

  /// Decodes from JSON.
  static ServiceDescriptor fromJson(Map<String, dynamic> json) =>
      ServiceDescriptor(
        name: Json.requireString(json, 'name'),
        displayName: Json.optString(json, 'displayName') ?? '',
        status: ServiceStatus.parse(
          Json.optString(json, 'status') ?? 'unknown',
        ),
        autoStart: Json.optBool(json, 'autoStart'),
      );
}
