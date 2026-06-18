import '../../domain/capabilities/capability.dart';
import '../../domain/capabilities/capability_detector.dart';
import '../../domain/entities/node_capabilities.dart';
import 'command_detector.dart';
import 'gpu_detectors.dart';

/// Runs a set of [CapabilityDetector]s concurrently and assembles the detected
/// [NodeCapabilities].
///
/// The [standard] factory wires up the built-in detectors (container engines,
/// language runtimes, tooling and GPU/accelerators); custom detectors can be
/// supplied for site-specific capabilities.
class CapabilityScanner {
  /// The detectors to run.
  final List<CapabilityDetector> detectors;

  /// Creates a scanner over [detectors].
  const CapabilityScanner(this.detectors);

  /// The default scanner: detects Docker, Podman, Dart, Python, Java, Node.js,
  /// Git, SSH, CUDA, Metal and OpenCL.
  factory CapabilityScanner.standard() => CapabilityScanner([
    CommandDetector(kind: CapabilityKind.docker, executable: 'docker'),
    CommandDetector(kind: CapabilityKind.podman, executable: 'podman'),
    CommandDetector(kind: CapabilityKind.dart, executable: 'dart'),
    CommandDetector(
      kind: CapabilityKind.python,
      executable: 'python3',
      name: 'python',
    ),
    CommandDetector(
      kind: CapabilityKind.java,
      executable: 'java',
      args: const ['-version'],
    ),
    CommandDetector(
      kind: CapabilityKind.nodejs,
      executable: 'node',
      name: 'nodejs',
    ),
    CommandDetector(kind: CapabilityKind.git, executable: 'git'),
    CommandDetector(
      kind: CapabilityKind.ssh,
      executable: 'ssh',
      args: const ['-V'],
    ),
    CudaDetector(),
    MetalDetector(),
    OpenClDetector(),
  ]);

  /// Runs all detectors and returns the detected capabilities.
  Future<NodeCapabilities> scan() async {
    final results = await Future.wait(detectors.map((d) => d.detect()));
    final found = <Capability>[for (final c in results) ?c];
    return NodeCapabilities(found);
  }
}
