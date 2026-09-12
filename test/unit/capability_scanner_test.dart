@TestOn('vm')
library;

import 'dart:async';

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

/// A detector under the test's control: it reports [capability] (or nothing),
/// and only when [gate] is completed.
class _FakeDetector implements CapabilityDetector {
  @override
  final CapabilityKind kind;

  final Capability? capability;
  final Future<void>? gate;

  /// Completes as soon as `detect()` is entered, so a test can tell that a
  /// probe started without waiting for it to finish.
  final started = Completer<void>();

  _FakeDetector(this.kind, {this.capability, this.gate});

  @override
  Future<Capability?> detect() async {
    if (!started.isCompleted) started.complete();
    if (gate != null) await gate;
    return capability;
  }
}

void main() {
  group('CapabilityScanner', () {
    test('collects what was found and drops what was not', () async {
      final scanner = CapabilityScanner([
        _FakeDetector(
          CapabilityKind.docker,
          capability: Capability.of(CapabilityKind.docker, version: '24.0.7'),
        ),
        // A host without podman: the detector reports nothing, and nothing is
        // what the fleet should see — not an entry saying "absent".
        _FakeDetector(CapabilityKind.podman),
        _FakeDetector(
          CapabilityKind.dart,
          capability: Capability.of(CapabilityKind.dart, version: '3.12.2'),
        ),
      ]);

      final capabilities = await scanner.scan();

      expect(capabilities.has(CapabilityKind.docker), isTrue);
      expect(capabilities.has(CapabilityKind.dart), isTrue);
      expect(capabilities.has(CapabilityKind.podman), isFalse);
      expect(capabilities.named('docker')?.version, '24.0.7');
    });

    test('a host with nothing installed scans clean', () async {
      final scanner = CapabilityScanner([
        _FakeDetector(CapabilityKind.docker),
        _FakeDetector(CapabilityKind.git),
      ]);
      expect((await scanner.scan()).capabilities, isEmpty);
    });

    test('an empty detector list is a scan, not an error', () async {
      expect((await const CapabilityScanner([]).scan()).capabilities, isEmpty);
    });

    test('probes run concurrently, not one after another', () async {
      // Registration waits for the whole scan, so the probes have to overlap:
      // eleven commands run back to back is eleven process spawns of latency
      // before a node can join. Held deterministically rather than by timing —
      // the second detector is only released once the first has started.
      final gate = Completer<void>();
      final slow = _FakeDetector(CapabilityKind.docker, gate: gate.future);
      final quick = _FakeDetector(
        CapabilityKind.git,
        capability: Capability.of(CapabilityKind.git),
      );
      final scanner = CapabilityScanner([slow, quick]);

      final scan = scanner.scan();
      // If the scan were sequential this would hang: the second detector could
      // not have been entered while the first is still blocked.
      await quick.started.future;
      gate.complete();

      expect((await scan).has(CapabilityKind.git), isTrue);
    });

    test('the standard scanner probes the documented eleven', () {
      final kinds = CapabilityScanner.standard().detectors
          .map((d) => d.kind)
          .toList();
      expect(kinds, hasLength(11));
      expect(kinds, [
        CapabilityKind.docker,
        CapabilityKind.podman,
        CapabilityKind.dart,
        CapabilityKind.python,
        CapabilityKind.java,
        CapabilityKind.nodejs,
        CapabilityKind.git,
        CapabilityKind.ssh,
        CapabilityKind.cuda,
        CapabilityKind.metal,
        CapabilityKind.opencl,
      ]);
    });
  });
}
