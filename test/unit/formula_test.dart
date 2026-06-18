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
