import '../../domain/blueprint/ledger.dart';
import '../../domain/capabilities/capability.dart';
import '../../domain/blueprint/resolved_blueprint.dart';
import '../../domain/blueprint/resource.dart';
import '../../domain/blueprint/resource_change.dart';
import '../../domain/blueprint/resource_provider.dart';
import '../../domain/blueprint/resource_state.dart';
import '../../domain/entities/platform_info.dart';
import '../../domain/formula/formula_context.dart';
import '../../domain/formula/formula_status.dart';
import '../../protocol/operations.dart';
import '../../shared/utils/clock.dart';
import '../../version.dart';

/// Where a node keeps what it has applied.
///
/// An interface rather than a file path so the service stays testable without a
/// disk, and so a node with no writable data directory can hold one in memory
/// and still work for the length of a session.
abstract class LedgerStore {
  /// The ledger for [blueprint], or `null` if it has never been applied here.
  Future<Ledger?> read(String blueprint);

  /// Records [ledger].
  Future<void> write(Ledger ledger);

  /// Forgets [blueprint] entirely.
  Future<void> clear(String blueprint);
}

/// A [LedgerStore] that lives only as long as the process.
///
/// The default, and honest about what it costs: a node that restarts forgets
/// what it owned, so the first plan afterwards sees every resource as adopted
/// and will not remove anything on unassign. Losing the ability to clean up is
/// the right failure — the alternative is deleting things on a guess.
class MemoryLedgerStore implements LedgerStore {
  final Map<String, Ledger> _ledgers = {};

  @override
  Future<Ledger?> read(String blueprint) async => _ledgers[blueprint];

  @override
  Future<void> write(Ledger ledger) async =>
      _ledgers[ledger.blueprint.value] = ledger;

  @override
  Future<void> clear(String blueprint) async => _ledgers.remove(blueprint);
}

/// The catalogue of resource types this node can actually handle.
class ProviderRegistry {
  final Map<String, ResourceProvider> _providers = {};

  /// Creates an empty registry.
  ProviderRegistry();

  /// Creates a registry holding [providers].
  factory ProviderRegistry.of(Iterable<ResourceProvider> providers) {
    final registry = ProviderRegistry();
    for (final provider in providers) {
      registry.register(provider);
    }
    return registry;
  }

  /// Registers (or replaces) [provider].
  void register(ResourceProvider provider) =>
      _providers[provider.type] = provider;

  /// The provider for [type], or `null`.
  ResourceProvider? byType(String type) => _providers[type];

  /// Every registered provider.
  Iterable<ResourceProvider> get providers => _providers.values;

  /// The name of the capability a node advertises its blueprint support under.
  static const String capabilityName = 'blueprint';

  /// The features of the blueprint model this build of the planner honours.
  ///
  /// Advertised so the Hub can refuse a blueprint a node would apply *wrongly*
  /// rather than not at all: a node from before `restartOn` decodes the field
  /// as nothing, applies the release and never restarts the service — a deploy
  /// that reports success and runs the old code.
  static const List<String> features = ['restartOn', 'rollback'];

  /// What this node can do with a blueprint, as a capability the Hub can read.
  ///
  /// `providers` is every resource type it has; `refreshable` the ones that can
  /// be the subject of a `restartOn`.
  Capability get capability {
    final types = [for (final p in _providers.values) p.type]..sort();
    final refreshable = [
      for (final p in _providers.values)
        if (p is RefreshableProvider) p.type,
    ]..sort();
    return Capability(
      kind: CapabilityKind.custom,
      name: capabilityName,
      version: omnyServerVersion,
      details: {
        'providers': types.join(','),
        'refreshable': refreshable.join(','),
        'features': features.join(','),
      },
    );
  }
}

/// Plans and applies blueprints on a node.
///
/// Sibling to `NodeFormulaService`, and deliberately node-side: planning has to
/// read the machine, and a plan assembled from what the Hub last heard is a plan
/// assembled from intentions. The Hub resolves and sends; this reads, diffs,
/// applies in order and writes the ledger.
class NodeBlueprintService {
  /// What this node knows how to manage.
  final ProviderRegistry providers;

  /// Where the record of what it manages is kept.
  final LedgerStore ledgers;

  /// The agent version reported in the formula context platform.
  final String agentVersion;

  /// Time source.
  final Clock clock;

  /// Where a resource's output goes as it is produced.
  ///
  /// Wired to the agent's own logger, so an apply travels the path the node log
  /// already takes and an operator can watch it happen. Each line is tagged with
  /// the resource that produced it — `[formula:dart] …` — because the stream
  /// carries everything the node says and a reader needs to pick one run out of
  /// it.
  final void Function(String line)? onLog;

  /// How many lines one resource keeps in its change.
  ///
  /// The tail, not the head: when an install fails after four hundred lines of
  /// `apt-get`, the interesting ones are at the end. The live stream is not
  /// capped.
  static const int logLimit = 200;

  /// Creates a blueprint service.
  NodeBlueprintService({
    required this.providers,
    LedgerStore? ledgers,
    this.agentVersion = omnyServerVersion,
    this.clock = const SystemClock(),
    this.onLog,
  }) : ledgers = ledgers ?? MemoryLedgerStore();

  /// The prefix every line of a resource's work carries on the node log stream.
  ///
  /// Public because it is a wire format in all but name: a client filtering the
  /// stream for one resource has to build the same string. Deliberately the same
  /// bracketed shape `NodeFormulaService.runTag` uses, so the dashboard's log
  /// filter works on blueprint applies with nothing changed.
  static String runTag(ResourceId id) => '[$id]';

  FormulaContext _context({void Function(String line)? log}) => FormulaContext(
    platform: PlatformInfo.local(agentVersion: agentVersion),
    clock: clock,
    log: log ?? onLog,
  );

  /// What this node can do with a blueprint — see [ProviderRegistry.capability].
  Capability get capability => providers.capability;

  /// Works out what applying [request] would change, without changing anything.
  Future<BlueprintPlanResult> plan(BlueprintPlanRequest request) async {
    final ledger = await ledgers.read(request.blueprint.blueprint.value);
    final reading = await _read(request.blueprint);
    final notes = [...reading.notes];

    return BlueprintPlanResult(
      requestId: request.requestId,
      changes: _withRestarts(
        request.blueprint,
        _diff(request.blueprint, reading.states, ledger, notes),
      ),
      states: reading.states.values.toList(),
      appliedHash: ledger?.hash ?? '',
      expectedHash: request.blueprint.hash,
      notes: notes,
    );
  }

  /// Moves the node to what [request] declares.
  Future<BlueprintApplyResult> apply(BlueprintApplyRequest request) async {
    final resolved = request.blueprint;
    final ledger = await ledgers.read(resolved.blueprint.value);
    final reading = await _read(resolved);
    final notes = [...reading.notes];
    final planned = _diff(
      resolved,
      reading.states,
      ledger,
      notes,
      purgeAdopted: request.purgeAdopted,
    );

    // A dry run stops here, having run exactly the code a real one runs up to
    // this point. A dry run that took a different path would be a dry run that
    // lies about what the real one will do.
    if (request.dryRun) {
      return BlueprintApplyResult(
        requestId: request.requestId,
        success: true,
        changes: _withRestarts(resolved, planned),
        appliedHash: ledger?.hash ?? '',
        notes: [...notes, 'dry run: nothing was changed'],
      );
    }

    // Adoption is a fact about history, not about this run: a resource is
    // adopted if it was already correct the **first** time this blueprint saw
    // it, which is why the ledger is consulted before the reading is.
    //
    // Re-deciding it every time would be wrong in the worst direction. A
    // resource this blueprint installed is, by the second apply, "already
    // correct" — so it would be marked adopted, and dropping it from the
    // blueprint later would leave it behind forever.
    final known = ledger?.entries ?? const <ResourceId, LedgerEntry>{};
    final adopted = <ResourceId>{
      for (final resource in resolved.resources)
        if (!known.containsKey(resource.id) &&
            _satisfied(resource, reading.states[resource.id]))
          resource.id,
      // Once adopted, always adopted: the machine's history does not change
      // because a later apply touched something else.
      for (final entry in known.values)
        if (entry.adopted) entry.id,
    };

    final done = <ResourceId, ResourceChange>{};
    final failed = <ResourceId>{};
    // What this run actually changed — not what it planned to. A `restartOn`
    // fires on a change that happened, so a release whose install turned out to
    // be a no-op does not bounce the service that runs it.
    final changed = <ResourceId>{};

    for (final change in planned) {
      // A resource whose dependency failed is not attempted, and says so. The
      // branches that do not depend on the failure carry on: a blueprint of
      // forty resources with one bad package should report the other
      // thirty-nine, not stop at the third.
      final declaration = _resourceFor(resolved, change.id);
      final blocker = _blockedBy(declaration, failed);
      if (blocker != null) {
        done[change.id] = change.completed(
          kind: ChangeKind.skipped,
          reason: 'skipped: $blocker failed',
        );
        failed.add(change.id);
        continue;
      }

      final ResourceChange applied;
      if (change.kind.isWork) {
        applied = await _applyOne(
          change,
          declaration,
          reading.states[change.id],
        );
      } else {
        final trigger = change.kind == ChangeKind.noop
            ? _triggeredBy(declaration, changed)
            : null;
        if (trigger == null) {
          done[change.id] = change;
          continue;
        }
        // Already what it should be, but something it runs was just replaced:
        // refreshed in place rather than reinstalled.
        applied = await _refreshOne(change, declaration, trigger);
      }

      done[change.id] = applied;
      if (applied.kind.isWork) changed.add(change.id);
      if (applied.kind != ChangeKind.failed) continue;
      failed.add(change.id);

      // A failure right after something it restarts on changed is, as often as
      // not, the change's fault: the new release went in and the service will
      // not come up on it. Put back what worked.
      await _recover(
        declaration,
        resolved: resolved,
        before: reading.states,
        done: done,
        failed: failed,
        changed: changed,
      );
    }

    final changes = [for (final change in planned) done[change.id] ?? change];

    // A resource we tried to remove and could not is still on the machine, and
    // so is still ours. It has to stay in the ledger or it is leaked: see
    // `Ledger.recording`.
    final unremoved = {
      for (final change in planned)
        if (change.kind == ChangeKind.remove &&
            done[change.id]?.kind != ChangeKind.remove)
          change.id,
    };

    // The ledger records what was *declared*, not what succeeded: a resource
    // whose install failed is still this system's responsibility, and forgetting
    // it would orphan whatever half of it landed.
    await ledgers.write(
      (ledger ?? Ledger.empty(resolved.blueprint, clock.now())).recording(
        resolved,
        clock.now(),
        adopted: request.purgeAdopted ? const {} : adopted,
        states: reading.states,
        retain: unremoved,
      ),
    );

    return BlueprintApplyResult(
      requestId: request.requestId,
      success: failed.isEmpty,
      changes: changes,
      appliedHash: resolved.hash,
      notes: notes,
    );
  }

  /// Reads every declared resource, and everything the ledger still owns.
  Future<_Reading> _read(ResolvedBlueprint resolved) async {
    final states = <ResourceId, ResourceState>{};
    final notes = <String>[];
    final ledger = await ledgers.read(resolved.blueprint.value);

    final wanted = [
      for (final r in resolved.resources) r.id,
      // Orphans too: their state decides whether a removal is work or already
      // done, and a plan cannot say "remove this" without knowing it is there.
      if (ledger != null)
        for (final orphan in ledger.orphansOf(resolved)) orphan.id,
    ];

    for (final id in wanted) {
      final provider = providers.byType(id.type);
      if (provider == null) {
        notes.add('no provider for "${id.type}" on this node');
        states[id] = ResourceState.unknown(
          id,
          clock.now(),
          message: 'this node has no "${id.type}" provider',
        );
        continue;
      }

      final resource = _resourceFor(resolved, id);
      if (!provider.supportedEnsure.contains(resource.ensure)) {
        states[id] = ResourceState.unknown(
          id,
          clock.now(),
          message:
              '${id.type} cannot be asked for ensure=${resource.ensure.name}',
        );
        continue;
      }

      try {
        states[id] = await provider.read(resource, _context());
      } on Object catch (e) {
        // A provider that could not look has said nothing. Unknown, never
        // absent — reporting absent would invite a create, and creating over
        // something that already works is how a failed probe becomes an outage.
        states[id] = ResourceState.unknown(
          id,
          clock.now(),
          message: 'could not read $id: $e',
        );
      }
    }

    return _Reading(states, notes);
  }

  /// The declaration for [id]: the blueprint's, or a synthesised one for a
  /// resource the blueprint has stopped mentioning.
  ///
  /// An orphan's synthesised `ensure` is [Ensure.absent] — not whatever it was
  /// last declared as. Carrying the old value forward would be reading the
  /// ledger as a second blueprint, and the apply would dutifully reinstall the
  /// very thing it was asked to remove.
  ResolvedResource _resourceFor(ResolvedBlueprint resolved, ResourceId id) {
    for (final resource in resolved.resources) {
      if (resource.id == id) return resource;
    }
    return ResolvedResource(
      resource: Resource(id: id, ensure: Ensure.absent),
      origin: 'ledger',
    );
  }

  /// What would have to change for the node to match.
  List<ResourceChange> _diff(
    ResolvedBlueprint resolved,
    Map<ResourceId, ResourceState> states,
    Ledger? ledger,
    List<String> notes, {
    bool purgeAdopted = false,
  }) {
    final changes = <ResourceChange>[];

    for (final resource in resolved.resources) {
      final state = states[resource.id];

      if (state == null || state.status == FormulaStatus.unknown) {
        changes.add(
          ResourceChange(
            id: resource.id,
            kind: ChangeKind.unknown,
            reason: state?.message ?? 'nothing read this resource',
            origin: resource.origin,
          ),
        );
        continue;
      }

      if (_satisfied(resource, state)) {
        changes.add(
          ResourceChange(
            id: resource.id,
            kind: ChangeKind.noop,
            reason: 'already ${resource.ensure.name}',
            origin: resource.origin,
          ),
        );
        continue;
      }

      changes.add(
        ResourceChange(
          id: resource.id,
          kind: _kindFor(resource.ensure, state),
          reason: state.satisfies(resource.ensure)
              // The status is right and the provider still said no: it is the
              // contents — the version, the unit's command — that differ.
              ? _contentReason(resource, state)
              : _reasonFor(resource.ensure, state),
          origin: resource.origin,
        ),
      );
    }

    // Everything the ledger owns that the blueprint has stopped declaring. This
    // is the only way a *removal* can be planned at all: the document no longer
    // mentions the resource, so the document cannot ask for it to go.
    if (ledger != null) {
      for (final orphan in ledger.orphansOf(resolved)) {
        final state = states[orphan.id];
        if (state != null && state.satisfies(Ensure.absent)) continue;

        // Something that was already on this machine before the blueprint ever
        // touched it is *released*, not removed: it drops out of the ledger and
        // is left exactly where it was. This system did not put it there, and
        // no-longer-managing something is not the same as deleting it.
        //
        // The ledger entry disappears either way, because `recording` keeps
        // only what the blueprint declares — so the next plan will not mention
        // it again.
        if (orphan.adopted && !purgeAdopted) {
          notes.add(
            '${orphan.id}: no longer declared, and left alone — it was '
            'already here before this blueprint',
          );
          continue;
        }

        changes.add(
          ResourceChange(
            id: orphan.id,
            kind: ChangeKind.remove,
            reason: 'no longer declared by this blueprint',
            origin: 'ledger',
          ),
        );
      }
    }

    return changes;
  }

  /// Whether [state] already is what [resource] declares — asked of the
  /// provider when it has an opinion, and of the status alone otherwise.
  bool _satisfied(ResolvedResource resource, ResourceState? state) {
    if (state == null || state.status == FormulaStatus.unknown) return false;
    // A pattern rather than `is`: the optional interfaces are not subtypes of
    // ResourceProvider, so `is` would not promote.
    if (providers.byType(resource.id.type) case final ConvergenceJudge judge) {
      return judge.satisfies(resource, state);
    }
    return state.satisfies(resource.ensure);
  }

  String _contentReason(ResolvedResource resource, ResourceState state) {
    final want = resource.resource.version;
    final have = state.version;
    if (want != null && want != have) {
      // The provider's own note, when it has one, is the part an operator
      // needs — "1.2.0 was rolled back at …" is why it is not 1.2.0.
      final note = state.message.isEmpty ? '' : ' — ${state.message}';
      return 'is ${have ?? 'unversioned'}, should be $want$note';
    }
    return state.message.isNotEmpty
        ? state.message
        : 'differs from what is declared';
  }

  /// The first resource in [resource]'s `restartOn` that [changed] this run.
  ResourceId? _triggeredBy(ResolvedResource resource, Set<ResourceId> changed) {
    for (final trigger in resource.resource.restartOn) {
      if (changed.contains(trigger)) return trigger;
    }
    return null;
  }

  /// The plan, saying which converged resources a planned change will restart.
  ///
  /// Only for what is *reported* — a plan or a dry run. The apply decides from
  /// what really changed, which a plan cannot know: an install planned as a
  /// create may turn out to have nothing to do.
  List<ResourceChange> _withRestarts(
    ResolvedBlueprint resolved,
    List<ResourceChange> changes,
  ) {
    final planned = {
      for (final c in changes)
        if (c.kind.isWork) c.id,
    };
    if (planned.isEmpty) return changes;
    final out = <ResourceChange>[];
    for (final change in changes) {
      final trigger = change.kind == ChangeKind.noop
          ? _triggeredBy(_resourceFor(resolved, change.id), planned)
          : null;
      out.add(
        trigger == null
            ? change
            : change.completed(
                kind: ChangeKind.update,
                reason: 'restart: $trigger will change',
              ),
      );
    }
    return out;
  }

  /// Refreshes [resource] because [trigger] changed under it.
  Future<ResourceChange> _refreshOne(
    ResourceChange change,
    ResolvedResource resource,
    ResourceId trigger,
  ) async {
    if (providers.byType(change.id.type)
        case final RefreshableProvider refreshable) {
      return _runRefresh(refreshable, change, resource, trigger);
    }
    // The Hub refuses this before sending, so reaching here means a node and a
    // Hub that disagree about what this node can do. Fail loudly: a restart
    // that silently does not happen is a deploy running the old code.
    return change.completed(
      kind: ChangeKind.failed,
      reason:
          '$trigger changed, but this node cannot restart a '
          '"${change.id.type}"',
    );
  }

  Future<ResourceChange> _runRefresh(
    RefreshableProvider provider,
    ResourceChange change,
    ResolvedResource resource,
    ResourceId trigger,
  ) async {
    final log = _ResourceLog(
      tag: runTag(change.id),
      sink: onLog,
      limit: logLimit,
    );
    try {
      final refreshed = await provider.refresh(
        resource,
        _context(log: log.add),
      );
      final kind = refreshed.kind;
      return ResourceChange(
        id: change.id,
        kind: kind,
        reason: kind == ChangeKind.failed
            ? refreshed.reason
            : 'restarted: $trigger changed',
        origin: change.origin,
        logs: log.lines,
      );
    } on Object catch (e) {
      return change
          .completed(kind: ChangeKind.failed, reason: '$e')
          .withLogs(log.lines);
    }
  }

  /// Puts back what [failedResource] restarts on, if it changed in this run and
  /// can be put back — then restarts whatever had already been restarted onto
  /// the version that has just been taken away.
  ///
  /// Records the outcome in [done]: the upstream resource as `failed`, rolled
  /// back, since the deploy it was part of did not happen; the resource that
  /// failed still `failed`, saying what it is running now.
  Future<void> _recover(
    ResolvedResource failedResource, {
    required ResolvedBlueprint resolved,
    required Map<ResourceId, ResourceState> before,
    required Map<ResourceId, ResourceChange> done,
    required Set<ResourceId> failed,
    required Set<ResourceId> changed,
  }) async {
    for (final trigger in failedResource.resource.restartOn) {
      if (!changed.contains(trigger)) continue;
      final upstream = _resourceFor(resolved, trigger);
      if (upstream.resource.params['rollback'] == 'none') continue;
      final previous = before[trigger];
      if (previous == null) continue;
      if (providers.byType(trigger.type)
          case final RevertibleProvider provider) {
        await _revertOne(
          provider,
          upstream,
          previous,
          failedResource,
          resolved: resolved,
          done: done,
          failed: failed,
          changed: changed,
        );
      }
    }
  }

  Future<void> _revertOne(
    RevertibleProvider provider,
    ResolvedResource upstream,
    ResourceState previous,
    ResolvedResource failedResource, {
    required ResolvedBlueprint resolved,
    required Map<ResourceId, ResourceChange> done,
    required Set<ResourceId> failed,
    required Set<ResourceId> changed,
  }) async {
    final trigger = upstream.id;
    final log = _ResourceLog(
      tag: runTag(trigger),
      sink: onLog,
      limit: logLimit,
    );
    ResourceChange reverted;
    try {
      reverted = await provider.revert(
        upstream,
        previous,
        _context(log: log.add),
      );
    } on Object catch (e) {
      reverted = ResourceChange(
        id: trigger,
        kind: ChangeKind.failed,
        reason: '$e',
        origin: upstream.origin,
      );
    }

    final applied = done[trigger];
    final rolledBack = reverted.kind != ChangeKind.failed;
    done[trigger] = ResourceChange(
      id: trigger,
      kind: ChangeKind.failed,
      reason: rolledBack
          ? 'rolled back (${reverted.reason}): ${failedResource.id} failed '
                'on the new version'
          : '${failedResource.id} failed on the new version, and it could '
                'not be rolled back: ${reverted.reason}',
      origin: upstream.origin,
      logs: [...?applied?.logs, ...log.lines],
    );
    failed.add(trigger);
    if (!rolledBack) return;
    changed.remove(trigger);

    // Everything already restarted onto the new version — the one that
    // failed, and any sibling that came up on it first — goes back too.
    for (final resource in resolved.resources) {
      if (!resource.resource.restartOn.contains(trigger)) continue;
      final earlier = done[resource.id];
      if (earlier == null ||
          !(earlier.kind.isWork || earlier.kind == ChangeKind.failed)) {
        continue;
      }
      final again = await _refreshOne(earlier, resource, trigger);
      final isTheFailure = resource.id == failedResource.id;
      final stillFails = again.kind == ChangeKind.failed;
      final String reason;
      if (isTheFailure) {
        reason = stillFails
            ? '${earlier.reason} — and it still fails on the previous '
                  'version: ${again.reason}'
            : '${earlier.reason} — restarted on the previous version';
      } else {
        reason = stillFails
            ? again.reason
            : 'restarted again on the previous version';
      }
      done[resource.id] = ResourceChange(
        id: resource.id,
        kind: isTheFailure ? ChangeKind.failed : again.kind,
        reason: reason,
        origin: resource.origin,
        logs: [...earlier.logs, ...again.logs],
      );
      if (done[resource.id]!.kind == ChangeKind.failed) {
        failed.add(resource.id);
      }
    }
  }

  ChangeKind _kindFor(Ensure ensure, ResourceState state) {
    if (ensure == Ensure.absent) return ChangeKind.remove;
    return state.isPresent ? ChangeKind.update : ChangeKind.create;
  }

  String _reasonFor(Ensure ensure, ResourceState state) => switch (ensure) {
    Ensure.absent => 'installed, and should not be',
    Ensure.latest => 'checking for a newer version',
    _ when !state.isPresent => 'not installed',
    _ => 'is ${state.status.name}, should be ${ensure.name}',
  };

  /// The first failed dependency of [resource], if any.
  String? _blockedBy(ResolvedResource resource, Set<ResourceId> failed) {
    for (final need in resource.resource.dependencies) {
      if (failed.contains(need)) return need.toString();
    }
    return null;
  }

  /// Runs one change, capturing what it printed.
  Future<ResourceChange> _applyOne(
    ResourceChange change,
    ResolvedResource resource,
    ResourceState? state,
  ) async {
    final provider = providers.byType(change.id.type);
    if (provider == null) {
      return change.completed(
        kind: ChangeKind.failed,
        reason: 'this node has no "${change.id.type}" provider',
      );
    }

    final log = _ResourceLog(
      tag: runTag(change.id),
      sink: onLog,
      limit: logLimit,
    );

    try {
      final applied = await provider.apply(
        resource,
        state ?? ResourceState.unknown(change.id, clock.now()),
        _context(log: log.add),
      );
      return applied.withLogs(log.lines);
    } on Object catch (e) {
      return change
          .completed(kind: ChangeKind.failed, reason: '$e')
          .withLogs(log.lines);
    }
  }
}

/// What a read found, and anything worth saying about the reading itself.
class _Reading {
  _Reading(this.states, this.notes);

  final Map<ResourceId, ResourceState> states;
  final List<String> notes;
}

/// One resource's output: tagged and forwarded live, tail kept for the change.
class _ResourceLog {
  _ResourceLog({required this.tag, required this.sink, required this.limit});

  /// The prefix identifying this resource on the shared node log stream.
  final String tag;

  /// The agent's logger, when the node was wired with one.
  final void Function(String line)? sink;

  /// How many lines the change keeps.
  final int limit;

  final List<String> _tail = [];
  int _dropped = 0;

  /// Forwards [line] to the live stream, and remembers it.
  void add(String line) {
    sink?.call('$tag $line');
    _tail.add(line);
    if (_tail.length > limit) {
      _tail.removeAt(0);
      _dropped++;
    }
  }

  /// The tail, said plainly when there is more that was not kept — a change that
  /// silently starts in the middle reads like the beginning.
  List<String> get lines => _dropped == 0
      ? List.unmodifiable(_tail)
      : List.unmodifiable([
          '… $_dropped earlier lines not kept; the full output went to the '
              'node log',
          ..._tail,
        ]);
}
