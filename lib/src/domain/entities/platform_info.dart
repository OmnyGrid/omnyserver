import 'dart:io';

import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

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
  factory PlatformInfo.local({required String agentVersion}) {
    final v = Platform.version;
    final arch = v.contains('arm64') || v.contains('aarch64')
        ? 'arm64'
        : (v.contains('x64') || v.contains('x86_64') ? 'x64' : 'unknown');
    return PlatformInfo(
      hostname: Platform.localHostname,
      osName: Platform.operatingSystem,
      osVersion: Platform.operatingSystemVersion,
      architecture: arch,
      kernelVersion: Platform.operatingSystemVersion,
      agentVersion: agentVersion,
    );
  }

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
