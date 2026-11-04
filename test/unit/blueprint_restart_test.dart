@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

/// The machine both fakes act on: which release is current, and which
/// versions the service runs healthily on.
class World {
  String? release;
  final Set<String> healthyOn = {};
  final Map<String, FormulaStatus> services = {};
  final List<String> log = [];
}

/// A `release` type: versioned, judged by version, and revertible.
class FakeRelease
    implements ResourceProvider, ConvergenceJudge, RevertibleProvider {
  FakeRelease(this.world, {this.failApply = false, this.failRevert = false});

  final World world;
  final bool failApply;
  final bool failRevert;

  @override
  String get type => 'release';

  @override
  Set<Ensure> get supportedEnsure => {Ensure.present, Ensure.absent};

  @override
  Future<ResourceState> read(ResolvedResource r, FormulaContext c) async =>
      ResourceState(
        id: r.id,
        status: world.release == null
            ? FormulaStatus.absent
            : FormulaStatus.installed,
        version: world.release,
        checkedAt: c.now(),
      );

  @override
  bool satisfies(ResolvedResource r, ResourceState s) =>
      s.isPresent && s.version == r.resource.version;

  @override
  Future<ResourceChange> apply(
    ResolvedResource r,
    ResourceState current,
    FormulaContext c,
  ) async {
    world.log.add('install ${r.resource.version}');
    if (failApply) {
      return ResourceChange(
        id: r.id,
        kind: ChangeKind.failed,
        reason: 'download failed',
      );
    }
    final was = world.release;
    world.release = r.resource.version;
    return ResourceChange(
      id: r.id,
      kind: was == null ? ChangeKind.create : ChangeKind.update,
      reason: 'installed ${r.resource.version}',
    );
  }

  @override
  Future<ResourceChange> revert(
    ResolvedResource r,
    ResourceState before,
    FormulaContext c,
  ) async {
    world.log.add('revert to ${before.version}');
    if (!before.isPresent) {
      return ResourceChange(
        id: r.id,
        kind: ChangeKind.failed,
        reason: 'nothing to roll back to',
      );
    }
    if (failRevert) {
      return ResourceChange(
        id: r.id,
        kind: ChangeKind.failed,
        reason: 'the old version was pruned',
      );
    }
    world.release = before.version;
    return ResourceChange(
      id: r.id,
      kind: ChangeKind.update,
      reason: 'back on ${before.version}',
    );
  }
}

/// A `service` type whose health depends on the current release.
class FakeService implements ResourceProvider, RefreshableProvider {
  FakeService(this.world);

  final World world;

  @override
  String get type => 'service';

  @override
  Set<Ensure> get supportedEnsure => {Ensure.running, Ensure.absent};

  @override
  Future<ResourceState> read(ResolvedResource r, FormulaContext c) async =>
      ResourceState(
        id: r.id,
        status: world.services[r.id.name] ?? FormulaStatus.absent,
        checkedAt: c.now(),
      );

  ResourceChange _healthy(ResolvedResource r, ChangeKind kind, String did) {
    final ok = world.healthyOn.contains(world.release);
    return ResourceChange(
      id: r.id,
      kind: ok ? kind : ChangeKind.failed,
      reason: ok ? did : '$did, but not healthy on ${world.release}',
    );
  }

  @override
  Future<ResourceChange> apply(
    ResolvedResource r,
    ResourceState current,
    FormulaContext c,
  ) async {
    world.log.add('start ${r.id.name}');
    final was = world.services[r.id.name];
    world.services[r.id.name] = FormulaStatus.running;
    return _healthy(
      r,
      was == null ? ChangeKind.create : ChangeKind.update,
      'started',
    );
  }

  @override
  Future<ResourceChange> refresh(ResolvedResource r, FormulaContext c) async {
    world.log.add('restart ${r.id.name}');
    return _healthy(r, ChangeKind.update, 'restarted');
  }
}

/// A formula-like type with no refresh at all.
class PlainProvider implements ResourceProvider {
  @override
  String get type => 'plain';

  @override
  Set<Ensure> get supportedEnsure => {Ensure.present};

  @override
  Future<ResourceState> read(ResolvedResource r, FormulaContext c) async =>
      ResourceState(
        id: r.id,
        status: FormulaStatus.installed,
        checkedAt: c.now(),
      );

  @override
  Future<ResourceChange> apply(
    ResolvedResource r,
    ResourceState current,
    FormulaContext c,
  ) async => ResourceChange(id: r.id, kind: ChangeKind.noop, reason: 'ok');
}

void main() {
  late World world;

  setUp(() => world = World());

  ResolvedResource rel(
    String version, {
    Map<String, String> extra = const {},
  }) => ResolvedResource(
    resource: Resource(
      id: ResourceId('release', 'app'),
      params: {'version': version, ...extra},
    ),
    origin: 'local',
  );

  ResolvedResource svc(
    String name, {
    List<String> restartOn = const ['release:app'],
  }) => ResolvedResource(
    resource: Resource(
      id: ResourceId('service', name),
      ensure: Ensure.running,
      restartOn: [for (final r in restartOn) ResourceId.parse(r)],
    ),
    origin: 'local',
  );

  ResolvedBlueprint blueprint(List<ResolvedResource> resources) =>
      ResolvedBlueprint(
        blueprint: BlueprintId('app'),
        hash: 'sha256:x',
        resources: resources,
      );

  NodeBlueprintService planner({
    bool failApply = false,
    bool failRevert = false,
    List<ResourceProvider> extra = const [],
  }) => NodeBlueprintService(
    providers: ProviderRegistry.of([
      FakeRelease(world, failApply: failApply, failRevert: failRevert),
      FakeService(world),
      ...extra,
    ]),
  );

  Future<BlueprintApplyResult> apply(
    NodeBlueprintService subject,
    ResolvedBlueprint b, {
    bool dryRun = false,
  }) => subject.apply(
    BlueprintApplyRequest(requestId: 'r', blueprint: b, dryRun: dryRun),
  );

  Future<BlueprintPlanResult> plan(
    NodeBlueprintService subject,
    ResolvedBlueprint b,
  ) => subject.plan(BlueprintPlanRequest(requestId: 'r', blueprint: b));

  Map<String, ChangeKind> kinds(List<ResourceChange> changes) => {
    for (final c in changes) '${c.id}': c.kind,
  };

  /// A node running 1.0 healthily, with the service up.
  void deployed(String version) {
    world.release = version;
    world.healthyOn.add(version);
    world.services['api'] = FormulaStatus.running;
  }

  group('convergence judged by the provider', () {
    test('a different version is drift, not a no-op', () async {
      deployed('1.0');
      final result = await plan(planner(), blueprint([rel('1.1')]));
      expect(result.changes.single.kind, ChangeKind.update);
      expect(result.changes.single.reason, 'is 1.0, should be 1.1');
    });

    test('the same version converges', () async {
      deployed('1.0');
      final result = await plan(planner(), blueprint([rel('1.0')]));
      expect(result.converged, isTrue);
    });
  });

  group('restartOn', () {
    test('a changed release restarts the service that runs it', () async {
      deployed('1.0');
      world.healthyOn.add('1.1');
      final result = await apply(
        planner(),
        blueprint([rel('1.1'), svc('api')]),
      );

      expect(result.success, isTrue);
      expect(kinds(result.changes), {
        'release:app': ChangeKind.update,
        'service:api': ChangeKind.update,
      });
      expect(result.changes.last.reason, 'restarted: release:app changed');
      expect(world.log, ['install 1.1', 'restart api']);
    });

    test('an unchanged release restarts nothing', () async {
      deployed('1.0');
      final result = await apply(
        planner(),
        blueprint([rel('1.0'), svc('api')]),
      );
      expect(result.success, isTrue);
      expect(world.log, isEmpty);
      expect(kinds(result.changes).values, everyElement(ChangeKind.noop));
    });

    test('a service started fresh in the same run is not restarted', () async {
      world.healthyOn.add('1.0');
      final result = await apply(
        planner(),
        blueprint([rel('1.0'), svc('api')]),
      );
      expect(result.success, isTrue);
      expect(world.log, ['install 1.0', 'start api']);
    });

    test(
      'a plan says which converged resources a change will restart',
      () async {
        deployed('1.0');
        final result = await plan(
          planner(),
          blueprint([rel('1.1'), svc('api')]),
        );
        expect(kinds(result.changes)['service:api'], ChangeKind.update);
        expect(result.changes.last.reason, 'restart: release:app will change');
        expect(world.log, isEmpty);
      },
    );

    test('a dry run says the same, and does nothing', () async {
      deployed('1.0');
      final result = await apply(
        planner(),
        blueprint([rel('1.1'), svc('api')]),
        dryRun: true,
      );
      expect(result.changes.last.reason, 'restart: release:app will change');
      expect(world.log, isEmpty);
    });

    test('a failed release skips what restarts on it', () async {
      deployed('1.0');
      final result = await apply(
        planner(failApply: true),
        blueprint([rel('1.1'), svc('api')]),
      );
      expect(result.success, isFalse);
      expect(kinds(result.changes), {
        'release:app': ChangeKind.failed,
        'service:api': ChangeKind.skipped,
      });
      expect(world.log, ['install 1.1']);
    });

    test(
      'a type that cannot refresh fails loudly instead of skipping',
      () async {
        deployed('1.0');
        final plain = ResolvedResource(
          resource: Resource(
            id: ResourceId('plain', 'thing'),
            restartOn: [ResourceId('release', 'app')],
          ),
          origin: 'local',
        );
        final result = await apply(
          planner(extra: [PlainProvider()]),
          blueprint([rel('1.1'), plain]),
        );
        expect(result.success, isFalse);
        expect(
          result.changes.last.reason,
          contains('cannot restart a "plain"'),
        );
      },
    );
  });

  group('rollback', () {
    test(
      'a service unhealthy on the new release is put back on the old one',
      () async {
        deployed('1.0'); // 1.1 is not healthy
        final result = await apply(
          planner(),
          blueprint([rel('1.1'), svc('api')]),
        );

        expect(result.success, isFalse);
        expect(world.release, '1.0');
        expect(world.log, [
          'install 1.1',
          'restart api',
          'revert to 1.0',
          'restart api',
        ]);
        final release = result.changes.first;
        expect(release.kind, ChangeKind.failed);
        expect(release.reason, contains('rolled back (back on 1.0)'));
        expect(
          release.reason,
          contains('service:api failed on the new version'),
        );
        final service = result.changes.last;
        expect(service.kind, ChangeKind.failed);
        expect(service.reason, contains('not healthy on 1.1'));
        expect(service.reason, contains('restarted on the previous version'));
      },
    );

    test('after a rollback the next plan still shows the drift', () async {
      deployed('1.0');
      final subject = planner();
      await apply(subject, blueprint([rel('1.1'), svc('api')]));
      final again = await plan(subject, blueprint([rel('1.1'), svc('api')]));
      expect(again.converged, isFalse);
      expect(again.changes.first.reason, 'is 1.0, should be 1.1');
    });

    test('siblings already restarted on the new release go back too', () async {
      deployed('1.0');
      world.services['worker'] = FormulaStatus.running;
      // `worker` comes first and is fine on 1.1 — only `api` is not. But a
      // rollback takes 1.1 away from both, so worker must follow.
      final healthyWorker = FakeService(world);
      final result =
          await NodeBlueprintService(
            providers: ProviderRegistry.of([FakeRelease(world), healthyWorker]),
          ).apply(
            BlueprintApplyRequest(
              requestId: 'r',
              blueprint: blueprint([rel('1.1'), svc('worker'), svc('api')]),
            ),
          );
      expect(result.success, isFalse);
      expect(world.release, '1.0');
      expect(
        world.log.where((l) => l == 'restart worker'),
        hasLength(2),
        reason: world.log.join(', '),
      );
    });

    test('rollback: none keeps the new version', () async {
      deployed('1.0');
      final result = await apply(
        planner(),
        blueprint([
          rel('1.1', extra: {'rollback': 'none'}),
          svc('api'),
        ]),
      );
      expect(result.success, isFalse);
      expect(world.release, '1.1');
      expect(world.log, ['install 1.1', 'restart api']);
    });

    test('a failed revert says the machine is on the new version', () async {
      deployed('1.0');
      final result = await apply(
        planner(failRevert: true),
        blueprint([rel('1.1'), svc('api')]),
      );
      expect(result.success, isFalse);
      expect(world.release, '1.1');
      expect(result.changes.first.reason, contains('could not be rolled back'));
      expect(result.changes.first.reason, contains('pruned'));
    });

    test('a first install that fails has nothing to roll back to', () async {
      // Nothing was here before: the planner still asks, the provider says
      // no, and the release is reported as failed on the new version.
      final result = await apply(
        planner(),
        blueprint([rel('1.0'), svc('api')]),
      );
      expect(result.success, isFalse);
      expect(world.release, '1.0');
      expect(result.changes.first.kind, ChangeKind.failed);
      expect(
        result.changes.first.reason,
        contains('could not be rolled back: nothing to roll back to'),
      );
    });
  });

  test('the capability names providers, refreshable types and features', () {
    final cap = planner(extra: [PlainProvider()]).capability;
    expect(cap.name, ProviderRegistry.capabilityName);
    expect(cap.kind, CapabilityKind.custom);
    expect(cap.details['providers'], 'plain,release,service');
    expect(cap.details['refreshable'], 'service');
    expect(cap.details['features'], contains('restartOn'));
    expect(cap.version, omnyServerVersion);
  });
}
