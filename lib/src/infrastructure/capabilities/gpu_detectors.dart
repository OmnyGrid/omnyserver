import 'dart:io';

import '../../domain/capabilities/capability.dart';
import '../../domain/capabilities/capability_detector.dart';

/// Detects an NVIDIA CUDA GPU via `nvidia-smi`.
class CudaDetector implements CapabilityDetector {
  @override
  CapabilityKind get kind => CapabilityKind.cuda;

  @override
  Future<Capability?> detect() async {
    try {
      final result = await Process.run('nvidia-smi', [
        '--query-gpu=name,driver_version',
        '--format=csv,noheader',
      ]);
      if (result.exitCode != 0) return null;
      final line = (result.stdout as String).trim().split('\n').first.trim();
      if (line.isEmpty) return null;
      final parts = line.split(',').map((s) => s.trim()).toList();
      return Capability(
        kind: CapabilityKind.cuda,
        name: 'cuda',
        version: parts.length > 1 ? parts[1] : null,
        details: {if (parts.isNotEmpty) 'gpu': parts.first},
      );
    } on Object {
      return null;
    }
  }
}

/// Detects Apple Metal GPU support. Metal is available on every modern macOS
/// host, so presence is inferred from the platform.
class MetalDetector implements CapabilityDetector {
  @override
  CapabilityKind get kind => CapabilityKind.metal;

  @override
  Future<Capability?> detect() async {
    if (!Platform.isMacOS) return null;
    return const Capability(kind: CapabilityKind.metal, name: 'metal');
  }
}

/// Detects OpenCL support via `clinfo` (best effort).
class OpenClDetector implements CapabilityDetector {
  @override
  CapabilityKind get kind => CapabilityKind.opencl;

  @override
  Future<Capability?> detect() async {
    try {
      final result = await Process.run('clinfo', ['--list']);
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim();
      if (out.isEmpty || out.toLowerCase().contains('0 platforms')) return null;
      return const Capability(kind: CapabilityKind.opencl, name: 'opencl');
    } on Object {
      return null;
    }
  }
}
