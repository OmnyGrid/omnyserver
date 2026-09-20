@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

/// A provider that answers from a script, and records what it was asked to do.
///
/// Stands in for a real one so these tests are about the *planner* — reading,
/// diffing, ordering, failure containment and the ledger — rather than about
/// whether some formula supports the platform the suite happens to run on.
class ScriptedProvider implements ResourceProvider {
  ScriptedProvider({
    this.type = 'formula',
    Map<String, FormulaStatus>? present,
    this.failing = const {},
    this.unreadable = const {},
  }) : present = present ?? {};

  @override
  final String type;

  /// What each resource currently looks like. Absent from the map means absent
  /// from the machine.
  final Map<String, FormulaStatus> present;

  /// Resources whose `apply` reports a failure.
  final Set<String> failing;

  /// Resources whose `read` throws, as a real probe can.
  final Set<String> unreadable;

  /// Every resource `apply` was called for, in order.
  final List<String> applied = [];

  @override
  Set<Ensure> get supportedEnsure => Ensure.values.toSet();

  @override
  Future<ResourceState> read(
    ResolvedResource resource,
    FormulaContext context,
  ) async {
    if (unreadable.contains(resource.id.name)) {
      throw StateError('no shell on this node');
    }
    return ResourceState(
      id: resource.id,
      status: present[resource.id.name] ?? FormulaStatus.absent,
      checkedAt: context.now(),
    );
  }

  @override
  Future<ResourceChange> apply(
    ResolvedResource resource,
    ResourceState current,
    FormulaContext context,
  ) async {
    applied.add(resource.id.name);
    context.log('working on ${resource.id.name}');

    if (failing.contains(resource.id.name)) {
      return ResourceChange(
        id: resource.id,
        kind: ChangeKind.failed,
        reason: 'the package server said no',
        origin: resource.origin,
      );
    }

    // A real provider changes the machine; this one changes its own idea of it,
    // so a second plan over the same provider sees the work as done.
    present[resource.id.name] = switch (resource.ensure) {
      Ensure.absent => FormulaStatus.absent,
      Ensure.running => FormulaStatus.running,
      Ensure.stopped => FormulaStatus.stopped,
      _ => FormulaStatus.installed,
    };

    return ResourceChange(
      id: resource.id,
      kind: resource.ensure == Ensure.absent
          ? ChangeKind.remove
          : (current.isPresent ? ChangeKind.update : ChangeKind.create),
      reason: 'done',
      origin: resource.origin,
    );
  }
}

void main() {
  ResolvedResource resource(
    String name, {
    Ensure ensure = Ensure.installed,
    List<String> requires = const [],
    String origin = 'local',
  }) => ResolvedResource(
    resource: Resource(
      id: ResourceId('formula', name),
      ensure: ensure,
      requires: [for (final r in requires) ResourceId.parse(r)],
    ),
    origin: origin,
  );

  ResolvedBlueprint resolved(
    List<ResolvedResource> resources, {
    String hash = 'sha256:one',
  }) => ResolvedBlueprint(
    blueprint: BlueprintId('builder'),
    hash: hash,
    resources: resources,
  );

  NodeBlueprintService service(
    ScriptedProvider provider, {
    LedgerStore? ledgers,
    void Function(String)? onLog,
  }) => NodeBlueprintService(
    providers: ProviderRegistry.of([provider]),
    ledgers: ledgers,
    onLog: onLog,
  );

  Future<BlueprintPlanResult> plan(
    NodeBlueprintService subject,
    ResolvedBlueprint blueprint,
  ) => subject.plan(BlueprintPlanRequest(requestId: 'r', blueprint: blueprint));

  Future<BlueprintApplyResult> apply(
    NodeBlueprintService subject,
    ResolvedBlueprint blueprint, {
    bool dryRun = false,
  }) => subject.apply(
    BlueprintApplyRequest(requestId: 'r', blueprint: blueprint, dryRun: dryRun),
  );

  group('planning', () {
    test('an unmanaged node needs everything creating', () async {
      final result = await plan(
        service(ScriptedProvider()),
        resolved([resource('dart'), resource('nmap')]),
      );

      expect(result.converged, isFalse);
      expect(
        [for (final c in result.changes) c.kind],
        [ChangeKind.create, ChangeKind.create],
      );
      expect(result.changes.first.reason, 'not installed');
    });

    test('a node that already matches has nothing to do', () async {
      final result = await plan(
        service(ScriptedProvider(present: {'dart': FormulaStatus.installed})),
        resolved([resource('dart')]),
      );

      expect(result.converged, isTrue);
      expect(result.changes.single.kind, ChangeKind.noop);
      expect(result.changes.single.reason, 'already installed');
    });

    test('installed is not running', () async {
      final result = await plan(
        service(ScriptedProvider(present: {'docker': FormulaStatus.installed})),
        resolved([resource('docker', ensure: Ensure.running)]),
      );

      expect(result.changes.single.kind, ChangeKind.update);
      expect(result.changes.single.reason, 'is installed, should be running');
    });

    test('a resource that could not be read is never converged', () async {
      // The rule the whole design leans on. A probe that could not run has said
      // nothing, and a plan that called that convergence would report a blind
      // node as healthy — which is exactly the failure blueprints exist to fix.
      final result = await plan(
        service(ScriptedProvider(unreadable: {'dart'})),
        resolved([resource('dart')]),
      );

      expect(result.changes.single.kind, ChangeKind.unknown);
      expect(result.changes.single.reason, contains('could not read'));
      expect(result.converged, isFalse, reason: 'unknown is not agreement');
    });

    test(
      'a type this node has no provider for is unknown, and says so',
      () async {
        final result = await plan(
          service(ScriptedProvider()),
          resolved([
            ResolvedResource(
              resource: Resource(
                id: ResourceId('file', '/etc/nginx.conf'),
                ensure: Ensure.present,
              ),
              origin: 'local',
            ),
          ]),
        );

        expect(result.changes.single.kind, ChangeKind.unknown);
        expect(result.notes.single, contains('no provider for "file"'));
        expect(result.converged, isFalse);
      },
    );

    test('planning changes nothing', () async {
      // A drift check with side effects is not a check. This runs on a timer,
      // against nodes nobody asked about.
      final provider = ScriptedProvider();
      await plan(service(provider), resolved([resource('dart')]));
      expect(provider.applied, isEmpty);
    });
  });

  group('applying', () {
    test('it does the work, then a second apply does none', () async {
      // Idempotence, which everything else rests on: if applying twice did the
      // work twice, drift could not be the same comparison with the apply left
      // off.
      final provider = ScriptedProvider();
      final subject = service(provider);
      final blueprint = resolved([resource('dart'), resource('nmap')]);

      final first = await apply(subject, blueprint);
      expect(first.success, isTrue);
      expect(first.changed, 2);
      expect(provider.applied, ['dart', 'nmap']);

      final second = await apply(subject, blueprint);
      expect(second.changed, 0);
      expect(provider.applied, [
        'dart',
        'nmap',
      ], reason: 'the second apply should not have touched anything');
      expect((await plan(subject, blueprint)).converged, isTrue);
    });

    test('a dry run plans and stops', () async {
      final provider = ScriptedProvider();
      final result = await apply(
        service(provider),
        resolved([resource('dart')]),
        dryRun: true,
      );

      expect(result.changes.single.kind, ChangeKind.create);
      expect(provider.applied, isEmpty);
      expect(result.notes, contains('dry run: nothing was changed'));
    });

    test('output is tagged with the resource that produced it', () async {
      // Same bracketed shape a formula run uses, so the dashboard's log filter
      // works on an apply with nothing changed.
      final streamed = <String>[];
      await apply(
        service(ScriptedProvider(), onLog: streamed.add),
        resolved([resource('dart')]),
      );

      expect(streamed, ['[formula:dart] working on dart']);
      expect(
        NodeBlueprintService.runTag(ResourceId('formula', 'dart')),
        '[formula:dart]',
      );
    });
  });

  group('when something fails', () {
    test('what depended on it is skipped, and says why', () async {
      final provider = ScriptedProvider(failing: {'dart'});
      final result = await apply(
        service(provider),
        resolved([
          resource('dart'),
          resource('build-tools', requires: ['formula:dart']),
        ]),
      );

      expect(result.success, isFalse);
      expect(result.changes.first.kind, ChangeKind.failed);
      expect(result.changes.last.kind, ChangeKind.skipped);
      expect(result.changes.last.reason, 'skipped: formula:dart failed');
      expect(provider.applied, [
        'dart',
      ], reason: 'a dependent of a failure must not be attempted');
    });

    test('independent branches carry on', () async {
      // A blueprint of forty resources with one bad package should report the
      // other thirty-nine, not stop at the third.
      final provider = ScriptedProvider(failing: {'dart'});
      final result = await apply(
        service(provider),
        resolved([
          resource('dart'),
          resource('build-tools', requires: ['formula:dart']),
          resource('nmap'),
        ]),
      );

      expect(provider.applied, ['dart', 'nmap']);
      expect(result.changed, 1);
      expect(result.skipped, 1);
      expect(result.success, isFalse);
    });
  });

  group('the ledger', () {
    test(
      'a resource dropped from the blueprint is planned for removal',
      () async {
        // The reason a blueprint can be edited rather than only added to. The
        // document no longer mentions nmap, so the document cannot ask for it to
        // go — only the record of what was applied last time can.
        final provider = ScriptedProvider();
        final subject = service(provider);

        await apply(subject, resolved([resource('dart'), resource('nmap')]));

        final trimmed = resolved([resource('dart')], hash: 'sha256:two');
        final result = await plan(subject, trimmed);

        final removal = result.changes.singleWhere(
          (c) => c.kind == ChangeKind.remove,
        );
        expect(removal.id.toString(), 'formula:nmap');
        expect(removal.reason, 'no longer declared by this blueprint');
        expect(removal.origin, 'ledger');

        await apply(subject, trimmed);
        expect(provider.present['nmap'], FormulaStatus.absent);
      },
    );

    test('a removal already done is not planned again', () async {
      final provider = ScriptedProvider();
      final subject = service(provider);

      await apply(subject, resolved([resource('dart'), resource('nmap')]));
      final trimmed = resolved([resource('dart')], hash: 'sha256:two');
      await apply(subject, trimmed);

      expect((await plan(subject, trimmed)).converged, isTrue);
    });

    test('it records the hash that was applied', () async {
      // What lets the Hub answer "is this node on the blueprint it was
      // assigned" without reading a single resource.
      final subject = service(ScriptedProvider());
      final blueprint = resolved([resource('dart')], hash: 'sha256:seven');

      expect((await plan(subject, blueprint)).appliedHash, isEmpty);
      await apply(subject, blueprint);
      expect((await plan(subject, blueprint)).appliedHash, 'sha256:seven');
    });

    test('what was already there is adopted, not claimed', () async {
      // If nginx was on this box a year before anyone wrote a blueprint,
      // unassigning must not uninstall it.
      final ledgers = MemoryLedgerStore();
      final subject = service(
        ScriptedProvider(present: {'dart': FormulaStatus.installed}),
        ledgers: ledgers,
      );

      await apply(subject, resolved([resource('dart')]));

      final ledger = await ledgers.read('builder');
      expect(ledger!.entries[ResourceId('formula', 'dart')]!.adopted, isTrue);
    });

    test('what the blueprint installed is owned', () async {
      final ledgers = MemoryLedgerStore();
      final subject = service(ScriptedProvider(), ledgers: ledgers);

      await apply(subject, resolved([resource('dart')]));

      final ledger = await ledgers.read('builder');
      expect(ledger!.entries[ResourceId('formula', 'dart')]!.adopted, isFalse);
    });

    test('provenance is carried through to the ledger', () async {
      // The first question about an unexpected resource is who put it there.
      final ledgers = MemoryLedgerStore();
      final subject = service(ScriptedProvider(), ledgers: ledgers);

      await apply(
        subject,
        resolved([resource('dart', origin: 'preset:dev-tools')]),
      );

      final ledger = await ledgers.read('builder');
      expect(
        ledger!.entries[ResourceId('formula', 'dart')]!.origin,
        'preset:dev-tools',
      );
    });
  });
}
