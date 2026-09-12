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

    // Ids an operator types, so they fold; a principal is a name a Hub
    // authenticates, so it does not. The difference is deliberate: `preset
    // apply Docker-Host` should work, `--principal Alice` should not silently
    // become alice.
    test('formula and preset ids fold case and trim', () {
      expect(FormulaId(' Docker ').value, 'docker');
      expect(PresetId('Docker-Host'), PresetId('docker-host'));
      expect(() => FormulaId(''), throwsA(isA<ProtocolException>()));
      expect(() => PresetId('   '), throwsA(isA<ProtocolException>()));
      expect(() => FormulaId('docker host'), throwsA(isA<ProtocolException>()));
      expect(() => PresetId('preset!'), throwsA(isA<ProtocolException>()));
    });

    test('a principal is trimmed, but keeps its case', () {
      expect(PrincipalId(' alice ').value, 'alice');
      expect(PrincipalId('Alice'), isNot(PrincipalId('alice')));
      expect(() => PrincipalId(' '), throwsA(isA<ProtocolException>()));
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

    test('Operation, running and completed', () {
      final started = DateTime.utc(2026, 6, 18, 12);
      final running = Operation(
        id: 'op-1',
        kind: 'preset',
        nodeId: 'worker-01',
        principal: 'alice',
        status: OperationStatus.running,
        summary: 'docker-host',
        startedAt: started,
      );
      expect(running.isRunning, isTrue);
      // An unfinished operation is as long as it has been waiting so far.
      expect(
        running.duration(started.add(const Duration(seconds: 5))).inSeconds,
        5,
      );

      final done = running.completed(
        status: OperationStatus.succeeded,
        at: started.add(const Duration(seconds: 2)),
        result: {'steps': 1},
      );
      expect(done.id, 'op-1', reason: 'the same operation, not a new one');
      expect(done.isRunning, isFalse);
      // Finished: the clock stops at finishedAt, however late anyone asks.
      expect(done.duration(started.add(const Duration(hours: 1))).inSeconds, 2);

      final back = Operation.fromJson(done.toJson());
      expect(back.status, OperationStatus.succeeded);
      expect(back.finishedAt, done.finishedAt);
      expect(back.result?['steps'], 1);
      expect(back.error, isNull);
    });

    test('Operation defaults what the wire may omit', () {
      final back = Operation.fromJson({
        'id': 'op-2',
        'kind': 'formula',
        'nodeId': 'worker-01',
        'status': 'running',
        'startedAt': '2026-06-18T12:00:00.000Z',
      });
      expect(back.principal, 'system');
      expect(back.summary, isEmpty);
      expect(back.finishedAt, isNull);
    });

    // Two enums, two deliberately different answers to the same question.
    test(
      'an unknown status: rejected for operations, tolerated for services',
      () {
        expect(
          () => OperationStatus.parse('exploded'),
          throwsA(isA<ProtocolException>()),
          reason: 'an operation in an unknown state is a protocol error',
        );
        expect(
          ServiceStatus.parse('exploded'),
          ServiceStatus.unknown,
          reason: 'a service we cannot read is merely unknown',
        );
      },
    );

    test('ServiceDescriptor', () {
      const service = ServiceDescriptor(
        name: 'omnyserver-hub',
        displayName: 'OmnyServer Hub',
        status: ServiceStatus.running,
        autoStart: true,
      );
      final back = ServiceDescriptor.fromJson(service.toJson());
      expect(back.name, 'omnyserver-hub');
      expect(back.status, ServiceStatus.running);
      expect(back.autoStart, isTrue);

      final sparse = ServiceDescriptor.fromJson({'name': 'omnyserver-node'});
      expect(sparse.displayName, isEmpty);
      expect(sparse.status, ServiceStatus.unknown);
      expect(sparse.autoStart, isFalse);
    });

    test('Drift', () {
      final drift = Drift(
        nodeId: 'worker-01',
        converged: false,
        actions: [PresetStep(formula: FormulaId('docker'))],
        notes: const ['docker is absent'],
      );
      final back = Drift.fromJson(drift.toJson());
      expect(back.nodeId, 'worker-01');
      expect(back.converged, isFalse);
      expect(back.actions.single.formula, FormulaId('docker'));
      expect(back.notes, ['docker is absent']);

      // A converged node is the useful answer: nothing to run.
      final converged = Drift.fromJson({'nodeId': 'w', 'converged': true});
      expect(converged.actions, isEmpty);
      expect(converged.notes, isEmpty);
    });

    test('Grant sorts its roles, so the wire form is stable', () {
      final grant = Grant(
        id: 'g1',
        principal: PrincipalId('alice'),
        roles: {'operator', 'admin'},
        tokenHash: 'hash',
        createdAt: DateTime.utc(2026, 6, 18),
      );
      expect(grant.toJson()['roles'], ['admin', 'operator']);

      final back = Grant.fromJson(grant.toJson());
      expect(back.principal, PrincipalId('alice'));
      expect(back.roles, {'admin', 'operator'});
      expect(back.note, isEmpty);
    });

    test('LogLine', () {
      final line = LogLine(
        nodeId: 'worker-01',
        source: 'stderr',
        message: 'boom',
        at: DateTime.utc(2026, 6, 18),
      );
      final back = LogLine.fromJson(line.toJson());
      expect(back.source, 'stderr');
      expect(back.message, 'boom');

      // A line with no source came from the agent itself.
      final bare = LogLine.fromJson({
        'nodeId': 'worker-01',
        'at': '2026-06-18T00:00:00.000Z',
      });
      expect(bare.source, 'agent');
      expect(bare.message, isEmpty);
    });
  });

  group('MetricPoint', () {
    final host = PlatformInfo(
      hostname: 'host-a',
      osName: 'linux',
      osVersion: '6.1.0',
      architecture: 'x64',
      kernelVersion: '6.1.0-generic',
      agentVersion: omnyServerVersion,
    );

    NodeStatus statusWith(
      List<StorageDevice> storage, {
      List<double> load = const [],
    }) => NodeStatus(
      capturedAt: DateTime.utc(2026, 6, 18, 12),
      cpu: CpuInfo(usagePercent: 25, coreCount: 4, loadAverage: load),
      memory: const MemoryInfo(
        totalBytes: 8000,
        usedBytes: 2000,
        availableBytes: 6000,
      ),
      storage: storage,
      os: host,
    );

    test('sums storage across every device on the host', () {
      final point = MetricPoint.fromStatus(
        statusWith(const [
          StorageDevice(name: '/', capacityBytes: 1000, freeBytes: 400),
          StorageDevice(name: '/data', capacityBytes: 500, freeBytes: 100),
        ]),
      );
      expect(point.storageCapacityBytes, 1500);
      // Used is what is left once free is taken off the whole capacity.
      expect(point.storageUsedBytes, 1000);
      expect(point.storagePercent, closeTo(66.67, 0.01));
      expect(point.memoryPercent, closeTo(25, 0.01));
    });

    test('a host with no storage reports no percentage, not a crash', () {
      // The guard that matters: dividing by a zero capacity.
      final point = MetricPoint.fromStatus(statusWith(const []));
      expect(point.storageCapacityBytes, 0);
      expect(point.storagePercent, isNull);
      expect(point.loadAverage, isNull, reason: 'no load average was reported');
    });

    test('carries the first load average when the host reports one', () {
      final point = MetricPoint.fromStatus(
        statusWith(const [], load: const [1.5, 1.2, 0.9]),
      );
      expect(point.loadAverage, 1.5);

      final back = MetricPoint.fromJson(point.toJson());
      expect(back.loadAverage, 1.5);
      expect(back.cpuPercent, 25);
    });

    test('omits a load average it does not have', () {
      final point = MetricPoint.fromStatus(statusWith(const []));
      expect(point.toJson(), isNot(contains('loadAverage')));
      expect(MetricPoint.fromJson(point.toJson()).loadAverage, isNull);
    });
  });
}
