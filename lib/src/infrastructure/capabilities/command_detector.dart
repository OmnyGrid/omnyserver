import '../../domain/capabilities/capability.dart';
import '../../domain/capabilities/capability_detector.dart';
import 'probe_runner.dart';

/// Detects a capability by running a probe command (typically
/// `tool --version`) and, if it exits successfully, extracting a version
/// string.
///
/// This covers the common case (Docker, Dart, Python, Git, …). GPU/accelerator
/// capabilities use bespoke detectors.
class CommandDetector implements CapabilityDetector {
  @override
  final CapabilityKind kind;

  /// The capability name (defaults to `kind.name`).
  final String name;

  /// The executable to probe.
  final String executable;

  /// The arguments passed to the probe (default `['--version']`).
  final List<String> args;

  /// A regex whose first group captures the version from the probe output.
  final RegExp versionPattern;

  /// Creates a command-based detector.
  CommandDetector({
    required this.kind,
    required this.executable,
    String? name,
    this.args = const ['--version'],
    RegExp? versionPattern,
  }) : name = name ?? kind.name,
       versionPattern = versionPattern ?? RegExp(r'(\d+\.\d+(?:\.\d+)?)');

  @override
  Future<Capability?> detect() async {
    final result = await runProbe(executable, args);
    if (result == null || result.exitCode != 0) return null;
    final output = '${result.stdout}\n${result.stderr}';
    final match = versionPattern.firstMatch(output);
    return Capability(kind: kind, name: name, version: match?.group(1));
  }
}
