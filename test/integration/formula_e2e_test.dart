@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Executor that always reports the verify probe as present.
class _PresentExecutor implements CommandExecutor {
  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async => const ExecResult(exitCode: 0, stdout: 'version 1.2.3');
}

void main() {
  late TestCluster cluster;
  setUp(() async => cluster = await TestCluster.start());
  tearDown(() async => cluster.dispose());

  test('hub dispatches a formula run and receives the result', () async {
    final service = NodeFormulaService(
      registry: FormulaRegistry.standard(executor: _PresentExecutor()),
    );
    await cluster.startNode(
      id: 'builder-01',
      formulaHandler: service.runFormula,
      presetHandler: service.applyPreset,
    );

    final reply = await cluster.hub.runFormula(
      NodeId('builder-01'),
      'docker',
      FormulaAction.verify,
      principal: 'alice',
    );
    expect(reply, isA<FormulaRunResult>());
    expect((reply as FormulaRunResult).result.success, isTrue);

    final audit = await cluster.hub.audit.recent();
    expect(audit.any((e) => e.action == 'formula.run'), isTrue);
  });

  test('hub applies a preset across formulas', () async {
    final service = NodeFormulaService(
      registry: FormulaRegistry.standard(executor: _PresentExecutor()),
    );
    await cluster.startNode(
      id: 'builder-02',
      formulaHandler: service.runFormula,
      presetHandler: service.applyPreset,
    );

    final preset = Preset(
      id: PresetId('dev'),
      name: 'Dev',
      steps: [
        PresetStep(formula: FormulaId('docker'), action: FormulaAction.verify),
        PresetStep(formula: FormulaId('dart'), action: FormulaAction.verify),
      ],
    );
    final reply = await cluster.hub.applyPreset(
      NodeId('builder-02'),
      preset,
      principal: 'alice',
    );
    expect(reply, isA<PresetApplyResult>());
    expect((reply as PresetApplyResult).success, isTrue);
    expect(reply.results, hasLength(2));
  });
}
