# Formulas, Presets & Desired State

## Formulas

A **formula** is an idempotent operational procedure that manages one piece of
software. It implements the `Formula` contract:

```dart
abstract class Formula {
  FormulaSpec get spec;
  Future<FormulaResult> install(FormulaContext c);
  Future<FormulaResult> update(FormulaContext c);
  Future<FormulaResult> start(FormulaContext c);
  Future<FormulaResult> stop(FormulaContext c);
  Future<FormulaResult> restart(FormulaContext c);
  Future<FormulaResult> uninstall(FormulaContext c);
  Future<ValidationResult> validate(FormulaContext c);
}
```

Built-ins: `DockerFormula`, `DartFormula`. Both extend `CommandFormula`, which
runs platform-specific command templates through a `CommandExecutor` (real in
production, faked in tests). `install` is idempotent: if `validate` already
passes it returns `changed: false`.

Every `FormulaResult` reports `success` and `changed` — the basis for
idempotent presets and reconciliation.

### Custom formulas

Implement `Formula` (or extend `CommandFormula`) and register it:

```dart
final registry = FormulaRegistry.standard()..register(MyFormula());
final service = NodeFormulaService(registry: registry);
// wire service.runFormula / service.applyPreset into NodeAgentConfig.
```

## Presets

A **preset** is an ordered, named bundle of formula steps that move a server
toward a desired configuration:

```dart
Preset(
  id: PresetId('docker-host'),
  name: 'Docker Host',
  steps: [
    PresetStep(formula: FormulaId('docker'), action: FormulaAction.install),
    PresetStep(formula: FormulaId('docker'), action: FormulaAction.start),
  ],
);
```

`NodeFormulaService.applyPreset` runs each step; success requires every step to
succeed. Because formulas are idempotent, re-applying a preset is safe.

## Desired-state reconciliation

`DefaultStateReconciler` compares a `DesiredState` (the steps you want) against a
`CurrentState` (the node's detected capabilities) and returns a `Reconciliation`
— the steps that still need to run. Already-present capabilities drop out, so the
plan converges:

```dart
const reconciler = DefaultStateReconciler();
final plan = reconciler.reconcile(desired, current);
if (!plan.converged) {
  // apply plan.actions
}
```
