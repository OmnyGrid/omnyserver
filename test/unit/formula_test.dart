@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

/// A fake executor that records invocations and returns scripted results.
class FakeExecutor implements CommandExecutor {
  final List<String> calls = [];
  final Map<String, ExecResult> scripted;
  final ExecResult fallback;

  FakeExecutor({
    this.scripted = const {},
    this.fallback = const ExecResult(exitCode: 0, stdout: 'ok'),
  });

  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    final key = '$executable ${args.join(' ')}';
    calls.add(key);
    return scripted[key] ?? fallback;
  }
}

void main() {
  group('DockerFormula', () {
    test('install is idempotent when already present', () async {
      final exec = FakeExecutor(
        scripted: {
          'docker --version': const ExecResult(
            exitCode: 0,
            stdout: 'Docker version 24.0.7, build afdd53b',
          ),
        },
      );
      final formula = DockerFormula(executor: exec);
      final ctx = _context();
      final result = await formula.install(ctx);
      expect(result.success, isTrue);
      expect(result.changed, isFalse);
      expect(result.message, contains('already installed'));
      // Only the verify probe ran; no install command.
      expect(exec.calls, ['docker --version']);
    });

    test('install runs the platform command when absent', () async {
      final exec = FakeExecutor(
        scripted: {
          'docker --version': const ExecResult(
            exitCode: 1,
            stderr: 'not found',
          ),
        },
      );
      final formula = DockerFormula(executor: exec);
      final result = await formula.install(_context(osName: 'linux'));
      expect(result.changed, isTrue);
      expect(exec.calls.any((c) => c.startsWith('sh -c')), isTrue);
    });

    test('validate reports the detected version', () async {
      final exec = FakeExecutor(
        scripted: {
          'docker --version': const ExecResult(
            exitCode: 0,
            stdout: 'Docker version 24.0.7, build afdd53b',
          ),
        },
      );
      final v = await DockerFormula(executor: exec).validate(_context());
      expect(v.valid, isTrue);
      expect(v.detectedVersion, '24.0.7');
    });
  });

  // Two faults that a formula can have without anyone noticing: asking for a
  // package that does not exist, and a command that cannot report failure.
  // Both were live, and the second is the worse one.
  group('what the install steps actually run', () {
    String linuxStep(CommandFormula formula, FormulaAction action) =>
        formula.stepFor(action, 'linux')!.args.join(' ');

    test('dart adds the repository the SDK actually lives in', () {
      // Neither Debian nor Ubuntu carries a `dart` package, so the old step —
      // `apt-get install -y dart` — could only ever answer
      // "E: Unable to locate package dart".
      final install = linuxStep(DartFormula(), FormulaAction.install);
      expect(install, contains('download.dartlang.org/linux/debian'));
      expect(install, contains('signed-by=/usr/share/keyrings/dart.gpg'));
      expect(install, contains('apt-get install -y dart'));

      // Written once, then only the package lists are refreshed.
      expect(
        install,
        contains('if [ ! -f /etc/apt/sources.list.d/dart_stable.list ]'),
      );

      // The update path needs the repository just as much as the install does.
      expect(
        linuxStep(DartFormula(), FormulaAction.update),
        stringContainsInOrder([
          'dart_stable.list',
          'apt-get install -y --only-upgrade dart',
        ]),
      );
    });

    test('no step fetches through a pipe that swallows the failure', () {
      // `curl … | sh` exits with the status of `sh`, which happily runs an
      // empty script — so a missing curl, a dead network or a 404 all reported
      // a successful install. Fetch to a file, then run the file.
      final install = linuxStep(DockerFormula(), FormulaAction.install);
      expect(install, isNot(contains('| sh')));
      expect(install, contains('set -e'));
      expect(install, contains('-o "\$script"'));
      expect(
        install,
        contains('needs curl or wget'),
        reason: 'a host with no downloader should be told, not congratulated',
      );

      // The key is fetched to a file for the same reason: `wget … | gpg` would
      // dearmor an empty download into a keyring that verifies nothing.
      final dart = linuxStep(DartFormula(), FormulaAction.install);
      expect(dart, isNot(contains('| gpg')));
      expect(dart, contains('set -e'));
    });

    test('every scripted step refuses to continue after a failure', () {
      // A multi-command step that is not `set -e` and not chained with `&&`
      // runs on after something fails, and reports whatever the last line did.
      for (final (name, formula) in [
        ('docker', DockerFormula()),
        ('dart', DartFormula()),
        ('procps', ProcpsFormula()),
      ]) {
        for (final action in FormulaAction.values) {
          final step = formula.stepFor(action, 'linux');
          if (step == null || step.executable != 'sh') continue;
          final script = step.args.join(' ');
          if (!script.contains('\n')) continue;
          expect(
            script,
            anyOf(contains('set -e'), contains('if '), contains('&&')),
            reason: '$name ${action.name} runs on after a failure',
          );
        }
      }
    });
  });

  // The node's own monitor reports its process table by shelling out to `ps`,
  // so on a host without it the table is empty rather than wrong. This is the
  // formula that puts it there.
  group('ProcpsFormula', () {
    /// The probe the formula verifies with, as the fake executor records it.
    String probeOf(FakeExecutor exec) =>
        exec.calls.firstWhere((c) => c.contains('command -v ps'));

    test('verify wants both tools, and takes a version if one is offered', () {
      final step = ProcpsFormula().verifyStep;
      expect(step.args.join(' '), contains('command -v ps'));
      expect(step.args.join(' '), contains('command -v top'));
      // procps-ng answers `--version`; BSD and busybox do not, and the probe
      // must not fail because of it.
      expect(step.args.join(' '), contains('ps --version 2>/dev/null || true'));
    });

    test('reports the version a procps-ng host prints', () async {
      final exec = FakeExecutor(
        fallback: const ExecResult(
          exitCode: 0,
          stdout: 'ps from procps-ng 4.0.4',
        ),
      );
      final v = await ProcpsFormula(executor: exec).validate(_context());
      expect(v.valid, isTrue);
      expect(v.detectedVersion, '4.0.4');
    });

    test('a host with neither tool is simply not valid', () async {
      final exec = FakeExecutor(fallback: const ExecResult(exitCode: 1));
      final v = await ProcpsFormula(executor: exec).validate(_context());
      expect(v.valid, isFalse);
      expect(v.message, contains('not found'));
    });

    test('install is idempotent when the tools are already there', () async {
      final exec = FakeExecutor(
        fallback: const ExecResult(exitCode: 0, stdout: '/bin/ps'),
      );
      final result = await ProcpsFormula(
        executor: exec,
      ).install(_context(osName: 'linux'));

      expect(result.success, isTrue);
      expect(result.changed, isFalse);
      expect(result.message, contains('already installed'));
      expect(exec.calls, hasLength(1), reason: 'only the probe ran');
    });

    test('install picks the package manager on the host', () async {
      final exec = FakeExecutor(fallback: const ExecResult(exitCode: 1));
      await ProcpsFormula(executor: exec).install(_context(osName: 'linux'));

      // One script rather than a branch here, because `stepFor` is told the OS
      // and not the distribution — only the host knows which manager it has.
      final script = exec.calls.last;
      expect(script, contains('apt-get install -y procps'));
      expect(script, contains('apk add --no-cache procps'));
      expect(script, contains('dnf install -y procps-ng'));
      expect(
        script,
        contains('no supported package manager'),
        reason: 'a host with none of them should say so, not fail obscurely',
      );
    });

    test('update and uninstall cover the same three managers', () async {
      final exec = FakeExecutor(
        fallback: const ExecResult(exitCode: 0, stdout: '/bin/ps'),
      );
      final formula = ProcpsFormula(executor: exec);

      await formula.update(_context(osName: 'linux'));
      expect(exec.calls.last, contains('--only-upgrade procps'));
      expect(exec.calls.last, contains('apk add --no-cache --upgrade procps'));
      expect(exec.calls.last, contains('dnf upgrade -y procps-ng'));

      await formula.uninstall(_context(osName: 'linux'));
      expect(exec.calls.last, contains('apt-get remove -y procps'));
      expect(exec.calls.last, contains('apk del procps'));
      expect(exec.calls.last, contains('dnf remove -y procps-ng'));
    });

    test('on macOS the tools are the system-s, and stay that way', () async {
      final exec = FakeExecutor(
        fallback: const ExecResult(exitCode: 0, stdout: '/bin/ps'),
      );
      final formula = ProcpsFormula(executor: exec);

      // Present, so install is a no-op rather than an attempt to package-manage
      // a platform that does not package these.
      final installed = await formula.install(_context());
      expect(installed.success, isTrue);
      expect(installed.changed, isFalse);
      expect(probeOf(exec), isNotEmpty);

      // And removing /bin/ps is not something to be talked into.
      final removed = await formula.uninstall(_context());
      expect(removed.success, isFalse);
      expect(removed.message, contains('not supported on macos'));
    });

    test('every node has it, and it is not a service', () {
      expect(
        FormulaRegistry.standard().byId('procps'),
        isA<ProcpsFormula>(),
        reason: 'a node should have it without being configured to',
      );

      final spec = ProcpsFormula().spec;
      expect(spec.actions, contains(FormulaAction.install));
      expect(
        spec.actions,
        isNot(contains(FormulaAction.restart)),
        reason: 'two binaries are not a service',
      );
    });
  });

  group('NodeFormulaService', () {
    test('applyPreset runs each step and aggregates success', () async {
      final exec = FakeExecutor(
        scripted: {
          'docker --version': const ExecResult(
            exitCode: 0,
            stdout: 'Docker version 24.0.7',
          ),
          'dart --version': const ExecResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.2',
          ),
        },
      );
      final service = NodeFormulaService(
        registry: FormulaRegistry.standard(executor: exec),
      );
      final request = PresetApply(
        requestId: 'r1',
        preset: Preset(
          id: PresetId('dev'),
          name: 'Dev',
          steps: [
            PresetStep(formula: FormulaId('docker')),
            PresetStep(formula: FormulaId('dart')),
          ],
        ),
      );
      final result = await service.applyPreset(request);
      expect(result.success, isTrue);
      expect(result.results, hasLength(2));
      expect(result.results.every((r) => !r.changed), isTrue);
    });

    test('unknown formula yields a failing step', () async {
      final service = NodeFormulaService(registry: FormulaRegistry());
      final result = await service.runFormula(
        FormulaRun(
          requestId: 'r2',
          formula: 'ghost',
          action: FormulaAction.install,
        ),
      );
      expect(result.success, isFalse);
      expect(result.message, contains('unknown formula'));
    });
  });

  // What a formula says while it works used to go nowhere: the service took an
  // `onLog` sink that nothing ever passed, and `FormulaResult.logs` was always
  // empty. An operator could watch a node install something for two minutes and
  // be told only whether it worked.
  group('NodeFormulaService run output', () {
    /// A formula that is absent, so `install` actually runs its step.
    FormulaRegistry absentDocker(List<String> stdout) =>
        FormulaRegistry()..register(
          DockerFormula(
            executor: FakeExecutor(
              scripted: {
                'docker --version': const ExecResult(exitCode: 1, stderr: 'no'),
              },
              fallback: ExecResult(exitCode: 0, stdout: stdout.join('\n')),
            ),
          ),
        );

    test('the result carries what the run printed', () async {
      final service = NodeFormulaService(
        registry: absentDocker(['fetching', 'unpacking', 'done']),
      );
      final result = await service.runFormula(
        FormulaRun(
          requestId: 'r',
          formula: 'docker',
          action: FormulaAction.install,
        ),
      );

      expect(result.logs, contains('fetching'));
      expect(result.logs, contains('done'));
      expect(
        result.logs.first,
        contains('running'),
        reason: 'the command itself is the first thing worth seeing',
      );
    });

    test('every line is tagged with the run, for the shared stream', () async {
      // The node log carries everything the agent says; a reader picks one run
      // out of it by this tag, and the Hub names the operation the same way.
      final streamed = <String>[];
      final service = NodeFormulaService(
        registry: absentDocker(['unpacking']),
        onLog: streamed.add,
      );
      await service.runFormula(
        FormulaRun(
          requestId: 'r',
          formula: 'docker',
          action: FormulaAction.install,
        ),
      );

      expect(streamed, isNotEmpty);
      expect(
        streamed.every((l) => l.startsWith('[docker install] ')),
        isTrue,
        reason: 'an untagged line cannot be attributed to a run',
      );
      expect(streamed.any((l) => l.endsWith('unpacking')), isTrue);
      expect(
        NodeFormulaService.runTag('docker', FormulaAction.install),
        '[docker install]',
      );
    });

    test('a noisy run keeps its tail, and says what it dropped', () async {
      final noisy = [
        for (var i = 0; i < NodeFormulaService.logLimit + 50; i++) 'line $i',
      ];
      final streamed = <String>[];
      final service = NodeFormulaService(
        registry: absentDocker(noisy),
        onLog: streamed.add,
      );
      final result = await service.runFormula(
        FormulaRun(
          requestId: 'r',
          formula: 'docker',
          action: FormulaAction.install,
        ),
      );

      // The tail, because a failure is explained by the last lines, not the
      // first — and the reader is told the beginning is missing rather than
      // being left to assume it is looking at one.
      expect(result.logs.length, NodeFormulaService.logLimit + 1);
      expect(result.logs.first, contains('earlier lines not kept'));
      expect(result.logs.last, 'line ${noisy.length - 1}');

      // Only the result is capped. The stream carried everything.
      expect(streamed.length, greaterThan(result.logs.length));
    });

    test('preset steps each carry their own output', () async {
      final exec = FakeExecutor(
        scripted: {
          'docker --version': const ExecResult(exitCode: 1, stderr: 'no'),
          'dart --version': const ExecResult(exitCode: 1, stderr: 'no'),
        },
        fallback: const ExecResult(exitCode: 0, stdout: 'working'),
      );
      final streamed = <String>[];
      final service = NodeFormulaService(
        registry: FormulaRegistry.standard(executor: exec),
        onLog: streamed.add,
      );

      final result = await service.applyPreset(
        PresetApply(
          requestId: 'r',
          preset: Preset(
            id: PresetId('dev'),
            name: 'Dev',
            steps: [
              PresetStep(formula: FormulaId('docker')),
              PresetStep(formula: FormulaId('dart')),
            ],
          ),
        ),
      );

      expect(result.results.every((r) => r.logs.isNotEmpty), isTrue);
      // Two steps, two tags — a preset's output is not one undifferentiated
      // heap.
      expect(streamed.any((l) => l.startsWith('[docker install]')), isTrue);
      expect(streamed.any((l) => l.startsWith('[dart install]')), isTrue);
    });
  });

  group('DefaultStateReconciler', () {
    test('drops install steps for already-present capabilities', () {
      const reconciler = DefaultStateReconciler();
      final desired = DesiredState([
        PresetStep(formula: FormulaId('docker')),
        PresetStep(formula: FormulaId('dart')),
      ]);
      final current = CurrentState(
        capabilities: NodeCapabilities([
          Capability.of(CapabilityKind.docker, version: '24.0.7'),
        ]),
      );
      final plan = reconciler.reconcile(desired, current);
      expect(plan.actions, hasLength(1));
      expect(plan.actions.single.formula.value, 'dart');
      expect(plan.converged, isFalse);
    });

    test('converges when all capabilities present', () {
      const reconciler = DefaultStateReconciler();
      final desired = DesiredState([PresetStep(formula: FormulaId('docker'))]);
      final current = CurrentState(
        capabilities: NodeCapabilities([Capability.of(CapabilityKind.docker)]),
      );
      expect(reconciler.reconcile(desired, current).converged, isTrue);
    });
  });
}

FormulaContext _context({String osName = 'macos'}) => FormulaContext(
  platform: PlatformInfo(
    hostname: 'h',
    osName: osName,
    osVersion: '1',
    architecture: 'x64',
    kernelVersion: '1',
    agentVersion: omnyServerVersion,
  ),
);
