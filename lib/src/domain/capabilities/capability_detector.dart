import 'capability.dart';

/// Probes the host for a single capability, returning it if present.
///
/// Detectors are cheap, side-effect-free probes (run a `--version`, stat a
/// device file, etc.). They return `null` when the capability is absent and
/// must never throw for an absent capability.
abstract class CapabilityDetector {
  /// The kind this detector probes for.
  CapabilityKind get kind;

  /// Detects the capability, or returns `null` if not present.
  Future<Capability?> detect();
}
