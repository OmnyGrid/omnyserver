import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
// The host-facts capture is the one thing here that needs `dart:io`. It lives
// behind a conditional import so this entity — which a browser dashboard has to
// deserialize — carries no `dart:io` into the web graph. dart2js silently emits
// *nothing* for an entrypoint that reaches an unsupported SDK library, so a
// single stray import is not a warning but an invisible build failure.
import 'platform_info_io.dart'
    if (dart.library.js_interop) 'platform_info_web.dart'
    as host;

/// Static facts about a node's host operating system and agent build, reported
/// once at registration (and refreshed on reconnect).
///
/// This also serves as the "Operating System" section of live monitoring
/// (name / version / architecture / kernel version).
@immutable
class PlatformInfo {
  /// The host name of the machine.
  final String hostname;

  /// The OS family name (e.g. `linux`, `macos`, `windows`).
  final String osName;

  /// The OS version string.
  final String osVersion;

  /// The CPU architecture (e.g. `x64`, `arm64`).
  final String architecture;

  /// The kernel version string.
  final String kernelVersion;

  /// The OmnyServer agent version running on the node.
  final String agentVersion;

  /// Creates platform info.
  const PlatformInfo({
    required this.hostname,
    required this.osName,
    required this.osVersion,
    required this.architecture,
    required this.kernelVersion,
    required this.agentVersion,
  });

  /// Captures the platform info of the current process's host.
  ///
  /// Native only: a browser has no host to describe, and calling this there
  /// throws [UnsupportedError]. A web client reads platform info off the Hub's
  /// API with [fromJson] instead.
  factory PlatformInfo.local({required String agentVersion}) =>
      host.localPlatformInfo(agentVersion: agentVersion);

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'hostname': hostname,
    'osName': osName,
    'osVersion': osVersion,
    'architecture': architecture,
    'kernelVersion': kernelVersion,
    'agentVersion': agentVersion,
  };

  /// Decodes from JSON.
  static PlatformInfo fromJson(Map<String, dynamic> json) => PlatformInfo(
    hostname: Json.optString(json, 'hostname') ?? '',
    osName: Json.optString(json, 'osName') ?? 'unknown',
    osVersion: Json.optString(json, 'osVersion') ?? '',
    architecture: Json.optString(json, 'architecture') ?? 'unknown',
    kernelVersion: Json.optString(json, 'kernelVersion') ?? '',
    agentVersion: Json.optString(json, 'agentVersion') ?? '',
  );

  @override
  String toString() => 'PlatformInfo($osName $osVersion, $architecture)';
}
