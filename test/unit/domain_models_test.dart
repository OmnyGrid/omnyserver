@TestOn('vm')
library;

import 'package:omnyserver/omnyserver.dart';
import 'package:test/test.dart';

void main() {
  group('value objects', () {
    test('NodeId validates and compares by value', () {
      expect(NodeId('worker-01'), equals(NodeId('worker-01')));
      expect(NodeId(' worker-01 ').value, 'worker-01');
      expect(() => NodeId(''), throwsA(isA<ProtocolException>()));
      expect(() => NodeId('bad id!'), throwsA(isA<ProtocolException>()));
    });

    test('OmnyUid normalizes to lower-case hex', () {
      expect(OmnyUid('ABCDEF12').value, 'abcdef12');
      expect(() => OmnyUid('xyz'), throwsA(isA<ProtocolException>()));
    });

    test('Ed25519PublicKey round-trips base64', () {
      final bytes = List<int>.generate(32, (i) => i);
      final key = Ed25519PublicKey.fromBytes(bytes);
      expect(Ed25519PublicKey.fromBase64(key.base64), equals(key));
      expect(
        () => Ed25519PublicKey.fromBytes([1, 2, 3]),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('entity JSON round-trips', () {
    final platform = PlatformInfo(
      hostname: 'host-a',
      osName: 'linux',
      osVersion: '6.1.0',
      architecture: 'x64',
      kernelVersion: '6.1.0-generic',
      agentVersion: omnyServerVersion,
    );

    test('NodeDescriptor', () {
      final node = NodeDescriptor(
        id: NodeId('worker-01'),
        uid: OmnyUid('deadbeef'),
        displayName: 'Worker 01',
        platform: platform,
        online: true,
        labels: const {'env': 'prod'},
        capabilities: NodeCapabilities([
          Capability.of(CapabilityKind.docker, version: '24.0.7'),
          Capability.of(CapabilityKind.dart, version: '3.12.2'),
        ]),
        registeredAt: DateTime.utc(2026, 6, 18, 12),
      );
      final back = NodeDescriptor.fromJson(node.toJson());
      expect(back.id, node.id);
      expect(back.uid, node.uid);
      expect(back.online, isTrue);
      expect(back.labels['env'], 'prod');
      expect(back.capabilities.has(CapabilityKind.docker), isTrue);
      expect(back.capabilities.named('dart')?.version, '3.12.2');
      expect(back.registeredAt, node.registeredAt);
    });

    test('NodeStatus', () {
      final status = NodeStatus(
        capturedAt: DateTime.utc(2026, 6, 18, 12, 30),
        cpu: const CpuInfo(
          usagePercent: 42.5,
          coreCount: 8,
          loadAverage: [1.0, 0.8, 0.5],
        ),
        memory: const MemoryInfo(
          totalBytes: 16000000000,
          usedBytes: 8000000000,
          availableBytes: 8000000000,
        ),
        storage: const [
          StorageDevice(
            name: '/',
            capacityBytes: 500000000000,
            freeBytes: 200000000000,
          ),
        ],
        os: platform,
        processes: const [
          ProcessInfo(
            pid: 1234,
            name: 'dart',
            cpuPercent: 5.0,
            memoryBytes: 120000000,
          ),
        ],
      );
      final back = NodeStatus.fromJson(status.toJson());
      expect(back.cpu.usagePercent, 42.5);
      expect(back.cpu.loadAverage, [1.0, 0.8, 0.5]);
      expect(back.memory.usagePercent, closeTo(50, 0.01));
      expect(back.storage.single.usagePercent, closeTo(60, 0.01));
      expect(back.processes.single.pid, 1234);
    });

    test('Preset and steps', () {
      final preset = Preset(
        id: PresetId('docker-host'),
        name: 'Docker Host',
        description: 'A server that runs Docker.',
        steps: [
          PresetStep(formula: FormulaId('docker')),
          PresetStep(formula: FormulaId('docker'), action: FormulaAction.start),
        ],
      );
      final back = Preset.fromJson(preset.toJson());
      expect(back.id, preset.id);
      expect(back.steps, hasLength(2));
      expect(back.steps.last.action, FormulaAction.start);
    });

    test('AuditEntry', () {
      final entry = AuditEntry(
        id: 'a1',
        at: DateTime.utc(2026, 6, 18),
        principal: 'alice',
        action: 'node.restart',
        target: 'worker-01',
        outcome: AuditOutcome.success,
      );
      final back = AuditEntry.fromJson(entry.toJson());
      expect(back.action, 'node.restart');
      expect(back.outcome, AuditOutcome.success);
    });

    test('Heartbeat with embedded status', () {
      final hb = Heartbeat(
        nodeId: NodeId('worker-01'),
        sequence: 7,
        sentAt: DateTime.utc(2026, 6, 18, 12, 0, 5),
        status: NodeStatus(
          capturedAt: DateTime.utc(2026, 6, 18, 12, 0, 5),
          cpu: const CpuInfo(usagePercent: 10, coreCount: 4),
          memory: const MemoryInfo(
            totalBytes: 8000000000,
            usedBytes: 2000000000,
            availableBytes: 6000000000,
          ),
          storage: const [],
          os: platform,
        ),
      );
      final back = Heartbeat.fromJson(hb.toJson());
      expect(back.sequence, 7);
      expect(back.status?.cpu.coreCount, 4);
    });
  });
}
