import '../../application/node/formula_registry.dart';
import '../../domain/blueprint/resolved_blueprint.dart';
import '../../domain/blueprint/resource.dart';
import '../../domain/blueprint/resource_change.dart';
import '../../domain/blueprint/resource_provider.dart';
import '../../domain/blueprint/resource_state.dart';
import '../../domain/formula/formula_context.dart';
import '../../domain/formula/formula_status.dart';

/// Serves `formula:<id>` resources out of the node's existing
/// [FormulaRegistry].
///
/// The bridge that makes blueprints work on day one: every formula a node
/// already has — and every preset ever saved, once read through
/// [Ensure.fromAction] — becomes a resource with nothing rewritten.
///
/// It is also the smallest provider there could be, because the formula engine
/// already had both halves. `Formula.status()` is a read that does not change
/// anything and reports `absent` / `installed` / `running` / `stopped` /
/// `unknown`; `Formula.run(action)` is a write. All this does is decide which
/// action a declared state calls for, and say plainly when there is none.
class FormulaProvider implements ResourceProvider {
  /// The formulas this node can run.
  final FormulaRegistry registry;

  /// Creates a formula provider over [registry].
  const FormulaProvider({required this.registry});

  @override
  String get type => 'formula';

  @override
  Set<Ensure> get supportedEnsure => const {
    Ensure.present,
    Ensure.installed,
    Ensure.latest,
    Ensure.running,
    Ensure.stopped,
    Ensure.absent,
  };

  @override
  Future<ResourceState> read(
    ResolvedResource resource,
    FormulaContext context,
  ) async {
    final formula = registry.byId(resource.id.name);
    if (formula == null) {
      // Not absent. This node has never heard of the formula, which says
      // nothing about whether the software is on the machine — and reporting
      // `absent` would invite an install this node cannot perform anyway.
      return ResourceState.unknown(
        resource.id,
        context.now(),
        message: 'this node has no formula "${resource.id.name}"',
      );
    }

    final report = await formula.status(context);
    return ResourceState(
      id: resource.id,
      status: report.status,
      version: report.version,
      message: report.message,
      // The detected version is the fingerprint: for a formula, "the same" means
      // the same version, and there is nothing else to compare.
      fingerprint: report.version,
      checkedAt: report.checkedAt,
    );
  }

  @override
  Future<ResourceChange> apply(
    ResolvedResource resource,
    ResourceState current,
    FormulaContext context,
  ) async {
    final formula = registry.byId(resource.id.name);
    if (formula == null) {
      return ResourceChange(
        id: resource.id,
        kind: ChangeKind.failed,
        reason: 'this node has no formula "${resource.id.name}"',
        origin: resource.origin,
      );
    }

    // A pinned version travels through the context, which is where a formula
    // already looks for one.
    final result = await formula.run(
      resource.ensure.action,
      context.copyWith(
        targetVersion: resource.resource.version,
        parameters: resource.resource.params,
      ),
    );

    if (!result.success) {
      return ResourceChange(
        id: resource.id,
        kind: ChangeKind.failed,
        reason: result.message,
        origin: resource.origin,
      );
    }

    // `changed: false` from an idempotent formula means it looked, found the
    // work already done, and did nothing — which is a no-op however the planner
    // got here. Worth reporting honestly: an operator counting what an apply
    // touched should not be told about work that never happened.
    if (!result.changed) {
      return ResourceChange(
        id: resource.id,
        kind: ChangeKind.noop,
        reason: result.message,
        origin: resource.origin,
      );
    }

    return ResourceChange(
      id: resource.id,
      kind: _kindFor(resource.ensure, current),
      reason: result.message,
      origin: resource.origin,
    );
  }

  /// What a successful run amounted to, from where it started.
  ChangeKind _kindFor(Ensure ensure, ResourceState current) {
    if (ensure == Ensure.absent) return ChangeKind.remove;
    // Not there before, there now — a create. Anything else was already
    // installed and has been moved (started, stopped, upgraded), which is an
    // update however the formula phrased it.
    return current.status == FormulaStatus.absent
        ? ChangeKind.create
        : ChangeKind.update;
  }
}
