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

// The optional halves of a provider. Interfaces rather than methods with a
// default body on [ResourceProvider]: a provider written as `implements
// ResourceProvider` — the natural way to write one, and how every test fake is
// written — would otherwise stop compiling the day a method is added. The
// planner asks with `is`, and a provider that has never heard of these keeps
// working exactly as it did.

/// A provider that decides for itself whether a reading satisfies a
/// declaration.
///
/// The default — [ResourceState.satisfies] — compares the status with `ensure`
/// and nothing else, which is right for a formula and wrong for anything with
/// contents. A release that is `installed` at 1.0.140 does not satisfy a
/// declaration of 1.0.141, however installed it is; nor does a service whose
/// unit runs a different command than the one declared.
abstract interface class ConvergenceJudge {
  /// Whether [state] already is what [resource] declares.
  ///
  /// Must not be more lenient than [ResourceState.satisfies]: an `unknown`
  /// reading satisfies nothing, whatever else is true.
  bool satisfies(ResolvedResource resource, ResourceState state);
}

/// A provider whose resources can be refreshed in place — a service restarted —
/// without being reinstalled.
///
/// What `restartOn` calls when something the resource depends on changed in the
/// same apply. A resource type without this cannot be the subject of a
/// `restartOn`: the node advertises which types can, and the Hub refuses the
/// blueprint before it is ever sent rather than letting the restart silently
/// not happen.
abstract interface class RefreshableProvider {
  /// Refreshes [resource], which is already in its declared state.
  ///
  /// Reports `update` when it did, `failed` with a reason when it could not.
  Future<ResourceChange> refresh(
    ResolvedResource resource,
    FormulaContext context,
  );
}

/// A provider that can put a resource back the way it was before an apply
/// changed it — a release whose previous version is still on disk.
///
/// The planner calls this when something that `restartOn`s the resource failed
/// in the same apply: the new version went in, the service it runs would not
/// come up healthy, and the honest recovery is the version that worked.
abstract interface class RevertibleProvider {
  /// Restores [resource] to [before] — the reading taken before this apply
  /// touched it.
  ///
  /// Reports `update` when it restored it, and `failed` when it could not —
  /// in which case the machine is in the new state, and the change says so.
  Future<ResourceChange> revert(
    ResolvedResource resource,
    ResourceState before,
    FormulaContext context,
  );
}
