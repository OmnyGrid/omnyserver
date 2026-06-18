import 'dart:io';

/// Resolves a stable, per-machine fingerprint used as an input to
/// [UidComputer]. It is best-effort and never throws: on platforms where no
/// stable id is available it falls back to the host name.
class MachineId {
  const MachineId._();

  /// Reads a stable machine id for the current host.
  static Future<String> resolve() async {
    try {
      if (Platform.isLinux) {
        for (final path in const [
          '/etc/machine-id',
          '/var/lib/dbus/machine-id',
        ]) {
          final file = File(path);
          if (file.existsSync()) {
            final value = file.readAsStringSync().trim();
            if (value.isNotEmpty) return value;
          }
        }
      } else if (Platform.isMacOS) {
        final result = await Process.run('ioreg', [
          '-rd1',
          '-c',
          'IOPlatformExpertDevice',
        ]);
        final match = RegExp(
          '"IOPlatformUUID" = "([^"]+)"',
        ).firstMatch(result.stdout as String);
        if (match != null) return match.group(1)!;
      } else if (Platform.isWindows) {
        final value = Platform.environment['COMPUTERNAME'];
        if (value != null && value.isNotEmpty) return value;
      }
    } on Object {
      // Fall through to the host-name fallback below.
    }
    return Platform.localHostname;
  }
}
