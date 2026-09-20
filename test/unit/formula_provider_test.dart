@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart' show FixedClock;

/// The bridge that makes every formula a node already has into a resource a
/// blueprint can declare.
///
/// `test/integration/blueprint_test.dart` drives it through a real Hub against
/// a real formula engine, which is the proof that it works. These are the
/// answers it has to give when things are *not* working — a formula this node
/// has never heard of, a run that fails, a run that finds the work already
/// done — because those are what a plan has to survive and what an operator
/// actually reads.
void main() {
  final at = DateTime.utc(2026, 9, 20, 12);

  FormulaContext context() => FormulaContext(
    platform: const PlatformInfo(
      hostname: 'test',
      osName: 'linux',
      osVersion: '13',
      architecture: 'x64',
      kernelVersion: '6.1.0',
      agentVersion: 'test',
    ),
    clock: FixedClock(at),
  );

  ResolvedResource resource(
    String name, {
    Ensure ensure = Ensure.installed,
    String origin = 'local',
    Map<String, String> params = const {},
  }) => ResolvedResource(
    resource: Resource(
      id: ResourceId('formula', name),
      ensure: ensure,
      params: params,
    ),
    origin: origin,
  );

  FormulaProvider providerWith(Formula formula) =>
      FormulaProvider(registry: FormulaRegistry()..register(formula));

  group('a formula this node does not have', () {
    final provider = FormulaProvider(registry: FormulaRegistry());

    test('reads as unknown, and says so — never as absent', () async {
      // The distinction the whole planner rests on. "Absent" invites an
      // install; this node cannot install it, and the software may well be on
      // the machine already.
      final state = await provider.read(resource('nginx'), context());

      expect(state.status, FormulaStatus.unknown);
      expect(state.message, contains('no formula "nginx"'));
      expect(state.satisfies(Ensure.installed), isFalse);
      expect(state.satisfies(Ensure.absent), isFalse);
    });

    test('applying fails rather than reporting nothing to do', () async {
      // A resource that cannot be read cannot be skipped quietly: a plan that
      // did nothing and called itself converged is the worst outcome here.
      final change = await provider.apply(
        resource('nginx', origin: 'preset:web'),
        ResourceState.unknown(ResourceId('formula', 'nginx'), at),
        context(),
      );

      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('no formula "nginx"'));
      // The origin travels with the failure, because "which of these four
      // documents asked for nginx" is the first question it raises.
      expect(change.origin, 'preset:web');
    });
  });

  group('a formula whose run fails', () {
    test('reports failed, carrying the formula’s own message', () async {
      final provider = providerWith(
        _StubFormula(
          'nginx',
          outcome: const _Outcome(
            success: false,
            message: 'apt-get returned 100',
          ),
        ),
      );

      final change = await provider.apply(
        resource('nginx'),
        ResourceState.unknown(ResourceId('formula', 'nginx'), at),
        context(),
      );

      expect(change.kind, ChangeKind.failed);
      // Verbatim: an operator reads this line and nothing else.
      expect(change.reason, 'apt-get returned 100');
    });
  });

  group('a formula that finds the work already done', () {
    test('reports a no-op, not a change', () async {
      // An idempotent formula answering `changed: false` looked, found nothing
      // to do, and did nothing. Counting that as a change would have an operator
      // tallying work that never happened.
      final provider = providerWith(
        _StubFormula(
          'nginx',
          outcome: const _Outcome(changed: false, message: 'already installed'),
        ),
      );

      final change = await provider.apply(
        resource('nginx'),
        ResourceState(
          id: ResourceId('formula', 'nginx'),
          status: FormulaStatus.installed,
          checkedAt: at,
        ),
        context(),
      );

      expect(change.kind, ChangeKind.noop);
      expect(change.reason, 'already installed');
    });
  });

  group('what a successful run amounted to', () {
    Future<ChangeKind> kindFor(Ensure ensure, FormulaStatus from) async {
      final provider = providerWith(_StubFormula('nginx'));
      final change = await provider.apply(
        resource('nginx', ensure: ensure),
        ResourceState(
          id: ResourceId('formula', 'nginx'),
          status: from,
          checkedAt: at,
        ),
        context(),
      );
      return change.kind;
    }

    test('not there before, there now — a create', () async {
      expect(
        await kindFor(Ensure.installed, FormulaStatus.absent),
        ChangeKind.create,
      );
    });

    test(
      'already there and moved — an update, however it was phrased',
      () async {
        expect(
          await kindFor(Ensure.running, FormulaStatus.stopped),
          ChangeKind.update,
        );
        expect(
          await kindFor(Ensure.latest, FormulaStatus.installed),
          ChangeKind.update,
        );
      },
    );

    test('ensure absent is a remove, whatever it started as', () async {
      expect(
        await kindFor(Ensure.absent, FormulaStatus.running),
        ChangeKind.remove,
      );
    });
  });

  group('reading what is there', () {
    test('the detected version is the fingerprint', () async {
      // For a formula, "the same" means the same version; there is nothing
      // else to compare, and the fingerprint is how the ledger notices drift.
      final provider = providerWith(
        _StubFormula('nginx', valid: true, version: '1.24.0'),
      );

      final state = await provider.read(resource('nginx'), context());

      expect(state.status, FormulaStatus.installed);
      expect(state.version, '1.24.0');
      expect(state.fingerprint, '1.24.0');
    });

    test('a probe that throws is unknown, not absent', () async {
      final provider = providerWith(
        _StubFormula('nginx', throwsOnValidate: true),
      );

      final state = await provider.read(resource('nginx'), context());

      expect(state.status, FormulaStatus.unknown);
    });
  });

  test('a pinned version and params reach the formula', () async {
    // The resource's own settings, handed down without the caller rebuilding a
    // context — which is how the log sink used to get dropped.
    final formula = _StubFormula('nginx');
    final provider = providerWith(formula);

    await provider.apply(
      resource('nginx', params: {'version': '1.24.0', 'mode': '0644'}),
      ResourceState.unknown(ResourceId('formula', 'nginx'), at),
      context(),
    );

    expect(formula.sawVersion, '1.24.0');
    expect(formula.sawParams, {'version': '1.24.0', 'mode': '0644'});
  });

  test('every state a blueprint can declare is supported', () {
    // If this ever stops being total, a blueprint saved today stops applying —
    // so it is pinned rather than left to be discovered on a node.
    expect(
      FormulaProvider(registry: FormulaRegistry()).supportedEnsure,
      Ensure.values.toSet(),
    );
  });
}

/// What a stubbed run reports.
class _Outcome {
  const _Outcome({
    this.success = true,
    this.changed = true,
    this.message = 'done',
  });

  final bool success;
  final bool changed;
  final String message;
}

/// A formula that answers from a script and records what it was handed.
class _StubFormula extends Formula {
  _StubFormula(
    this.name, {
    this.outcome = const _Outcome(),
    this.valid = false,
    this.version,
    this.throwsOnValidate = false,
  });

  final String name;
  final _Outcome outcome;
  final bool valid;
  final String? version;
  final bool throwsOnValidate;

  String? sawVersion;
  Map<String, String>? sawParams;

  @override
  FormulaSpec get spec => FormulaSpec(
    id: FormulaId(name),
    name: name,
    description: 'a stub',
    actions: FormulaAction.values.toSet(),
  );

  Future<FormulaResult> _run(FormulaAction action, FormulaContext context) {
    sawVersion = context.targetVersion;
    sawParams = context.parameters;
    return Future.value(
      FormulaResult(
        formula: name,
        action: action,
        success: outcome.success,
        changed: outcome.changed,
        message: outcome.message,
        finishedAt: context.now(),
      ),
    );
  }

  @override
  Future<FormulaResult> install(FormulaContext c) =>
      _run(FormulaAction.install, c);

  @override
  Future<FormulaResult> update(FormulaContext c) =>
      _run(FormulaAction.update, c);

  @override
  Future<FormulaResult> start(FormulaContext c) => _run(FormulaAction.start, c);

  @override
  Future<FormulaResult> stop(FormulaContext c) => _run(FormulaAction.stop, c);

  @override
  Future<FormulaResult> restart(FormulaContext c) =>
      _run(FormulaAction.restart, c);

  @override
  Future<FormulaResult> uninstall(FormulaContext c) =>
      _run(FormulaAction.uninstall, c);

  @override
  Future<ValidationResult> validate(FormulaContext c) async {
    if (throwsOnValidate) throw StateError('the probe could not run');
    return ValidationResult(
      valid: valid,
      detectedVersion: version,
      message: valid ? 'present' : 'absent',
    );
  }
}
