import '../../domain/blueprint/ledger.dart';
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

  /// Works out what applying [request] would change, without changing anything.
  Future<BlueprintPlanResult> plan(BlueprintPlanRequest request) async {
    final ledger = await ledgers.read(request.blueprint.blueprint.value);
    final reading = await _read(request.blueprint);

    return BlueprintPlanResult(
      requestId: request.requestId,
      changes: _diff(request.blueprint, reading.states, ledger),
      states: reading.states.values.toList(),
      appliedHash: ledger?.hash ?? '',
      notes: reading.notes,
    );
  }

  /// Moves the node to what [request] declares.
  Future<BlueprintApplyResult> apply(BlueprintApplyRequest request) async {
    final resolved = request.blueprint;
    final ledger = await ledgers.read(resolved.blueprint.value);
    final reading = await _read(resolved);
    final planned = _diff(resolved, reading.states, ledger);
    final notes = [...reading.notes];

    // A dry run stops here, having run exactly the code a real one runs up to
    // this point. A dry run that took a different path would be a dry run that
    // lies about what the real one will do.
    if (request.dryRun) {
      return BlueprintApplyResult(
        requestId: request.requestId,
        success: true,
        changes: planned,
        appliedHash: ledger?.hash ?? '',
        notes: [...notes, 'dry run: nothing was changed'],
      );
    }

    // Anything already correct before a single write is adopted: this system
    // did not put it there, so unassigning must not take it away.
    final adopted = <ResourceId>{
      for (final resource in resolved.resources)
        if (reading.states[resource.id]?.satisfies(resource.ensure) ?? false)
          resource.id,
      ...?ledger?.entries.values.where((e) => e.adopted).map((e) => e.id),
    };

    final done = <ResourceId, ResourceChange>{};
    final failed = <ResourceId>{};

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

      if (!change.kind.isWork) {
        done[change.id] = change;
        continue;
      }

      final applied = await _applyOne(
        change,
        declaration,
        reading.states[change.id],
      );
      done[change.id] = applied;
      if (applied.kind == ChangeKind.failed) failed.add(change.id);
    }

    final changes = [for (final change in planned) done[change.id] ?? change];

    // The ledger records what was *declared*, not what succeeded: a resource
    // whose install failed is still this system's responsibility, and forgetting
    // it would orphan whatever half of it landed.
    await ledgers.write(
      (ledger ?? Ledger.empty(resolved.blueprint, clock.now())).recording(
        resolved,
        clock.now(),
        adopted: request.purgeAdopted ? const {} : adopted,
        states: reading.states,
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
  ) {
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

      if (state.satisfies(resource.ensure)) {
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
          reason: _reasonFor(resource.ensure, state),
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
    for (final need in resource.resource.requires) {
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
