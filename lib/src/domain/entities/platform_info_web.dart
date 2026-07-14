import 'platform_info.dart';

/// The browser has no host to describe.
///
/// A node runs on a machine; a browser is a client of one. It reads
/// [PlatformInfo] off the Hub's API (`PlatformInfo.fromJson`) and never captures
/// its own — so this exists only to keep `dart:io` out of the web graph, and
/// says so if it is ever called.
PlatformInfo localPlatformInfo({required String agentVersion}) =>
    throw UnsupportedError(
      'PlatformInfo.local() reads the host OS and is unavailable in a browser. '
      'A web client receives platform info from the Hub instead.',
    );
