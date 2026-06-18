@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

/// A bundle of the five repositories under test, plus a teardown.
class RepoBundle {
  final NodeRepository nodes;
  final PresetRepository presets;
  final FormulaRepository formulas;
  final AuditRepository audit;
  final MetricRepository metrics;
  final Future<void> Function() dispose;

  RepoBundle({
    required this.nodes,
    required this.presets,
    required this.formulas,
    required this.audit,
    required this.metrics,
    required this.dispose,
  });
}

void main() {
  group('memory', () => _conformance(_memoryBundle));
  group('json-directory', () => _conformance(_jsonBundle));
  group('sqlite', () => _conformance(_sqliteBundle));
}

RepoBundle _memoryBundle() => RepoBundle(
  nodes: MemoryNodeRepository(),
  presets: MemoryPresetRepository(),
  formulas: MemoryFormulaRepository(),
  audit: MemoryAuditRepository(),
  metrics: MemoryMetricRepository(),
  dispose: () async {},
);

RepoBundle _jsonBundle() {
  final dir = Directory.systemTemp.createTempSync('omnyserver-json-repo');
  return RepoBundle(
    nodes: JsonNodeRepository(dir.path),
    presets: JsonPresetRepository(dir.path),
    formulas: JsonFormulaRepository(dir.path),
    audit: JsonAuditRepository(dir.path),
    metrics: JsonMetricRepository(dir.path),
    dispose: () async => dir.deleteSync(recursive: true),
  );
}

RepoBundle _sqliteBundle() {
  final store = SqliteStore.inMemory();
  return RepoBundle(
    nodes: store.nodes,
    presets: store.presets,
    formulas: store.formulas,
    audit: store.audit,
    metrics: store.metrics,
    dispose: () async => store.close(),
  );
}

NodeDescriptor _node(String id, {bool online = true}) => NodeDescriptor(
  id: NodeId(id),
  displayName: id,
  platform: PlatformInfo.local(agentVersion: omnyServerVersion),
  online: online,
  capabilities: NodeCapabilities([
    Capability.of(CapabilityKind.docker, version: '24.0.7'),
  ]),
);

void _conformance(RepoBundle Function() make) {
  late RepoBundle repos;
  setUp(() => repos = make());
  tearDown(() => repos.dispose());

  test('node save/find/all/delete', () async {
    await repos.nodes.save(_node('n1'));
    await repos.nodes.save(_node('n2', online: false));
    expect((await repos.nodes.all()), hasLength(2));
    final found = await repos.nodes.find(NodeId('n1'));
    expect(found?.capabilities.has(CapabilityKind.docker), isTrue);
    // Upsert replaces.
    await repos.nodes.save(_node('n1', online: false));
    expect((await repos.nodes.find(NodeId('n1')))!.online, isFalse);
    expect(await repos.nodes.delete(NodeId('n2')), isTrue);
    expect(await repos.nodes.delete(NodeId('missing')), isFalse);
    expect((await repos.nodes.all()), hasLength(1));
  });

  test('preset save/find/all', () async {
    final preset = Preset(
      id: PresetId('docker-host'),
      name: 'Docker Host',
      steps: [PresetStep(formula: FormulaId('docker'))],
    );
    await repos.presets.save(preset);
    final back = await repos.presets.find(PresetId('docker-host'));
    expect(back?.steps, hasLength(1));
    expect(await repos.presets.all(), hasLength(1));
  });

  test('formula save/find', () async {
    final spec = FormulaSpec(id: FormulaId('dart'), name: 'Dart SDK');
    await repos.formulas.save(spec);
    expect((await repos.formulas.find(FormulaId('dart')))?.name, 'Dart SDK');
  });

  test('audit append/recent newest-first', () async {
    for (var i = 0; i < 3; i++) {
      await repos.audit.append(
        AuditEntry(
          id: 'a$i',
          at: DateTime.utc(2026, 6, 18, 12, i),
          principal: 'alice',
          action: 'node.restart',
          outcome: AuditOutcome.success,
        ),
      );
    }
    final recent = await repos.audit.recent(limit: 2);
    expect(recent, hasLength(2));
    expect(recent.first.id, 'a2');
  });

  test('metrics record/recentFor', () async {
    final status = NodeStatus(
      capturedAt: DateTime.utc(2026, 6, 18, 12),
      cpu: const CpuInfo(usagePercent: 5, coreCount: 4),
      memory: const MemoryInfo(
        totalBytes: 8000000000,
        usedBytes: 2000000000,
        availableBytes: 6000000000,
      ),
      storage: const [],
      os: PlatformInfo.local(agentVersion: omnyServerVersion),
    );
    await repos.metrics.record(
      MetricSample(nodeId: NodeId('n1'), at: status.capturedAt, status: status),
    );
    final samples = await repos.metrics.recentFor(NodeId('n1'));
    expect(samples, hasLength(1));
    expect(samples.first.status.cpu.coreCount, 4);
  });
}
