import '../formula/formula_context.dart';
import 'resolved_blueprint.dart';
import 'resource.dart';
import 'resource_change.dart';
import 'resource_state.dart';

/// Knows how to read and write one kind of resource on a node.
///
/// The extension seam of the whole blueprint system: supporting files, cron jobs
/// or firewall rules means writing one of these, not touching the format, the
/// resolver, the protocol or the dashboard.
///
/// Providers live on the **node**, not the Hub — the Hub cannot read a file on a
/// machine a continent away, and a plan built from what the Hub last heard is a
/// plan built from intentions. [read] is expected to shell out.
///
/// Two obligations, and the whole design rests on them:
///
/// * **[read] must not change anything.** It runs on every plan, including the
///   ones nobody applies, and a drift check with side effects is not a check.
/// * **[apply] must be safe to run twice.** The planner will not call it when
///   [ResourceState.satisfies] is already true, but a provider that cannot
///   survive a repeat is one bad reading away from doing damage.
abstract class ResourceProvider {
  /// The resource type this provider owns — the `formula` in `formula:docker`.
  String get type;

  /// The [Ensure] values this type can meaningfully be asked for.
  ///
  /// Checked when a blueprint is saved, so `ensure: running` on a resource that
  /// installs a command is refused with the blueprint in front of the author,
  /// rather than at 3am on the node.
  Set<Ensure> get supportedEnsure;

  /// Looks at the node and reports what is there.
  ///
  /// Never throws for "it is not there" — that is
  /// [ResourceState] with `absent`. Throwing is for "I could not look", and the
  /// planner turns it into [ResourceState.unknown] rather than letting it fail
  /// the whole plan: one unreadable resource should not blind the other thirty.
  Future<ResourceState> read(ResolvedResource resource, FormulaContext context);

  /// Moves the resource to its declared state.
  ///
  /// [current] is what [read] just found, passed in so a provider does not have
  /// to look twice. Returns what it did — `create`, `update`, `remove`, `noop`
  /// when it turned out there was nothing to do, or `failed` with a reason.
  Future<ResourceChange> apply(
    ResolvedResource resource,
    ResourceState current,
    FormulaContext context,
  );
}
