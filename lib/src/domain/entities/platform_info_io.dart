import 'dart:io';

import 'platform_info.dart';

/// Captures the platform facts of the current process's host.
///
/// The `dart:io` half of [PlatformInfo.local], kept behind a conditional import
/// so the entity itself stays browser-compatible: a web dashboard deserializes
/// `PlatformInfo` from the Hub's API, and `dart:io` anywhere in that graph makes
/// `dart2js` emit nothing at all.
PlatformInfo localPlatformInfo({required String agentVersion}) {
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
