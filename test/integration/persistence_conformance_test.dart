@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

/// A bundle of the repositories under test, plus a teardown.
class RepoBundle {
  final NodeRepository nodes;
  final PresetRepository presets;
  final FormulaRepository formulas;
  final GrantRepository grants;
  final DesiredStateRepository desired;
  final AuditRepository audit;
  final MetricRepository metrics;
  final Future<void> Function() dispose;

  RepoBundle({
    required this.nodes,
    required this.presets,
    required this.formulas,
    required this.grants,
    required this.desired,
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
  grants: MemoryGrantRepository(),
  desired: MemoryDesiredStateRepository(),
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
    grants: JsonGrantRepository(dir.path),
    desired: JsonDesiredStateRepository(dir.path),
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
    grants: store.grants,
    desired: store.desired,
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

  // The repository interface is asynchronous, and the Hub calls it from
  // request handlers that overlap. Issuing writes without awaiting between them
  // is therefore the normal case, not an exotic one — a backend that lets two
  // of them interleave can leave a half-written record behind.
  test('overlapping saves each land whole', () async {
    await Future.wait([
      for (var i = 0; i < 20; i++) repos.nodes.save(_node('n$i')),
    ]);
    expect(await repos.nodes.all(), hasLength(20));

    // Ten writes to one id, in flight together. Any of them may win, but the
    // survivor has to be a readable node rather than a mix of two.
    await Future.wait([
      for (var i = 0; i < 10; i++)
        repos.nodes.save(_node('n1', online: i.isEven)),
    ]);
    expect(await repos.nodes.find(NodeId('n1')), isNotNull);
    expect(await repos.nodes.all(), hasLength(20));
  });

  test('overlapping audit appends all land, in the order issued', () async {
    await Future.wait([
      for (var i = 0; i < 25; i++)
        repos.audit.append(
          AuditEntry(
            id: 'a$i',
            at: DateTime.utc(2026, 6, 18, 12, 0, i),
            principal: 'alice',
            action: 'node.restart',
            outcome: AuditOutcome.success,
          ),
        ),
    ]);
    final recent = await repos.audit.recent(limit: 100);
    expect(recent, hasLength(25));
    expect(recent.first.id, 'a24', reason: 'newest first, nothing reordered');
    expect(recent.last.id, 'a0');
  });

  group('grants', () {
    Grant grant(String id, {String hash = 'hash-1', Set<String>? roles}) =>
        Grant(
          id: id,
          principal: PrincipalId('alice'),
          roles: roles ?? const {'operator'},
          tokenHash: hash,
          createdAt: DateTime.utc(2026, 6, 18, 12),
        );

    // Every authenticated request resolves a presented token to a grant this
    // way, so the three backends have to answer it identically.
    test('a token hash finds its grant, and only its grant', () async {
      await repos.grants.save(grant('g1', hash: 'hash-alice'));
      await repos.grants.save(
        grant('g2', hash: 'hash-bob', roles: const {'viewer'}),
      );

      final found = await repos.grants.findByTokenHash('hash-alice');
      expect(found?.id, 'g1');
      expect(found?.roles, {'operator'});
      expect(
        await repos.grants.findByTokenHash('hash-nobody'),
        isNull,
        reason: 'an unknown token must not resolve to someone else',
      );
    });

    test('save/find/all/delete', () async {
      await repos.grants.save(grant('g1'));
      expect((await repos.grants.find('g1'))?.principal, PrincipalId('alice'));
      expect(await repos.grants.find('missing'), isNull);
      expect(await repos.grants.all(), hasLength(1));

      // Revocation: the point of storing grants at all.
      expect(await repos.grants.delete('g1'), isTrue);
      expect(await repos.grants.delete('g1'), isFalse);
      expect(await repos.grants.find('g1'), isNull);
      expect(
        await repos.grants.findByTokenHash('hash-1'),
        isNull,
        reason: 'a revoked token must stop authenticating',
      );
    });

    test('re-saving an id replaces it, rather than duplicating it', () async {
      await repos.grants.save(grant('g1', roles: const {'viewer'}));
      await repos.grants.save(grant('g1', roles: const {'admin'}));
      expect(await repos.grants.all(), hasLength(1));
      expect((await repos.grants.find('g1'))?.roles, {'admin'});
    });
  });

  group('desired state', () {
    DesiredState state(String formula) =>
        DesiredState([PresetStep(formula: FormulaId(formula))]);

    test('save/find/all/delete, keyed by node', () async {
      await repos.desired.save(NodeId('n1'), state('docker'));
      await repos.desired.save(NodeId('n2'), state('git'));

      expect(
        (await repos.desired.find(NodeId('n1')))?.steps.single.formula,
        FormulaId('docker'),
      );
      expect(await repos.desired.find(NodeId('missing')), isNull);

      final all = await repos.desired.all();
      expect(all.keys, containsAll(['n1', 'n2']));
      expect(all['n2']?.steps.single.formula, FormulaId('git'));

      expect(await repos.desired.delete(NodeId('n1')), isTrue);
      expect(await repos.desired.delete(NodeId('n1')), isFalse);
      expect(await repos.desired.all(), hasLength(1));
    });

    test('declaring again replaces the declaration', () async {
      // A declaration is a fact about the node, not an instruction added to a
      // pile of them — the second `state set` wins outright.
      await repos.desired.save(NodeId('n1'), state('docker'));
      await repos.desired.save(NodeId('n1'), state('git'));
      expect(await repos.desired.all(), hasLength(1));
      expect(
        (await repos.desired.find(NodeId('n1')))?.steps.single.formula,
        FormulaId('git'),
      );
    });
  });

  test('presets and formulas are deletable', () async {
    await repos.presets.save(
      Preset(id: PresetId('p1'), name: 'P', steps: const []),
    );
    await repos.formulas.save(FormulaSpec(id: FormulaId('f1'), name: 'F'));

    expect(await repos.presets.delete(PresetId('p1')), isTrue);
    expect(await repos.presets.delete(PresetId('p1')), isFalse);
    expect(await repos.presets.all(), isEmpty);

    expect(await repos.formulas.delete(FormulaId('f1')), isTrue);
    expect(await repos.formulas.delete(FormulaId('f1')), isFalse);
    expect(await repos.formulas.all(), isEmpty);
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

  group('metrics history', () {
    final start = DateTime.utc(2026, 6, 18, 12);

    NodeStatus statusAt(DateTime at, double cpu) => NodeStatus(
      capturedAt: at,
      cpu: CpuInfo(usagePercent: cpu, coreCount: 4),
      memory: const MemoryInfo(
        totalBytes: 8000,
        usedBytes: 2000,
        availableBytes: 6000,
      ),
      storage: const [],
      os: PlatformInfo.local(agentVersion: omnyServerVersion),
    );

    /// Ten minutes of samples, one a minute, oldest first.
    Future<void> recordTen() async {
      for (var i = 0; i < 10; i++) {
        final at = start.add(Duration(minutes: i));
        await repos.metrics.record(
          MetricSample(
            nodeId: NodeId('n1'),
            at: at,
            status: statusAt(at, i.toDouble()),
          ),
        );
      }
    }

    test('returns the newest samples first, capped by limit', () async {
      await recordTen();
      final samples = await repos.metrics.recentFor(NodeId('n1'), limit: 3);
      expect(samples, hasLength(3));
      // A graph wants the last few minutes, not the first few.
      expect(samples.first.at, start.add(const Duration(minutes: 9)));
      expect(samples.first.status.cpu.usagePercent, 9);
    });

    test('since drops everything older than the window', () async {
      await recordTen();
      final samples = await repos.metrics.recentFor(
        NodeId('n1'),
        since: start.add(const Duration(minutes: 7)),
      );
      // Inclusive of the boundary: minutes 7, 8 and 9.
      expect(samples, hasLength(3));
      expect(
        samples.map((s) => s.at),
        everyElement(
          predicate<DateTime>(
            (at) => !at.isBefore(start.add(const Duration(minutes: 7))),
          ),
        ),
      );
    });

    test('one node-s samples are not another-s', () async {
      await recordTen();
      await repos.metrics.record(
        MetricSample(
          nodeId: NodeId('n2'),
          at: start,
          status: statusAt(start, 99),
        ),
      );
      expect(await repos.metrics.recentFor(NodeId('n1')), hasLength(10));
      expect(await repos.metrics.recentFor(NodeId('n2')), hasLength(1));
      expect(await repos.metrics.recentFor(NodeId('n3')), isEmpty);
    });
  });
}
