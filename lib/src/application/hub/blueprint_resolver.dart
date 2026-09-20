import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../domain/blueprint/blueprint.dart';
import '../../domain/blueprint/resolved_blueprint.dart';
import '../../domain/blueprint/resource.dart';
import '../../domain/entities/preset.dart';
import '../../domain/formula/standard_formulas.dart';
import '../../shared/errors/omnyserver_exception.dart';

/// Turns a blueprint and the presets it includes into the flat, ordered,
/// fully-substituted resource list a node is actually sent.
///
/// Resolution happens **once, on the Hub**. The node never learns what a preset
/// is or what a variable was — it receives resources in the order to settle
/// them. Two nodes given "the same blueprint" are therefore given the same
/// bytes, and the hash over those bytes is a convergence check that costs no
/// round trip at all.
///
/// Six steps, in this order:
///
/// 1. expand [Blueprint.includes] in order, reading each preset's steps as
///    resources through [Ensure.fromAction];
/// 2. append the blueprint's own resources;
/// 3. collapse duplicates, last wins, recording where each survivor came from
///    and what it overrode;
/// 4. substitute `${var}`;
/// 5. sort by `requires`, declaration order breaking ties;
/// 6. hash.
///
/// Steps 3 and 5 are separate on purpose. Overriding is about *identity* and has
/// to settle before ordering can mean anything, because the winner's `requires`
/// is the one that counts.
class BlueprintResolver {
  /// Creates a resolver.
  const BlueprintResolver();

  /// Resolves [blueprint] against the [presets] it includes.
  ///
  /// [presets] is looked up by id; an include naming a preset that is not there
  /// is an error rather than a silent omission, because a blueprint that half
  /// applies is worse than one that refuses to.
  ResolvedBlueprint resolve(Blueprint blueprint, List<Preset> presets) {
    final byId = {for (final preset in presets) preset.id.value: preset};
    final notes = <String>[];

    // 1 + 2 — includes in order, then local. Order is the override rule: later
    // wins, and local is last, so a blueprint can always overrule a piece it
    // borrowed.
    final declared = <_Declared>[];
    for (final include in blueprint.includes) {
      final preset = byId[include.value];
      if (preset == null) {
        throw ProtocolException(
          'Blueprint "${blueprint.id}" includes preset "${include.value}", '
          'which is not saved on this Hub',
        );
      }
      final origin = 'preset:${preset.id.value}';
      for (final step in preset.steps) {
        declared.add(
          _Declared(
            Resource(
              id: ResourceId('formula', step.formula.value),
              ensure: Ensure.fromAction(step.action),
              params: {if (step.version != null) 'version': step.version!},
            ),
            origin,
          ),
        );
      }
    }
    for (final resource in blueprint.resources) {
      declared.add(_Declared(resource, 'local'));
    }

    // 3 — last wins, and the loser is named rather than dropped in silence. An
    // override is how "the base says running, this role deliberately says
    // stopped" is written; it is not an error, but it must never be invisible.
    final merged = <ResourceId, ResolvedResource>{};
    for (final entry in declared) {
      final existing = merged[entry.resource.id];
      if (existing != null) {
        notes.add(
          '${entry.resource.id}: ${entry.origin} overrides ${existing.origin}',
        );
      }
      merged[entry.resource.id] = ResolvedResource(
        resource: entry.resource,
        origin: entry.origin,
        overrides: existing?.origin,
      );
    }

    // 4 — substitution, over everything. A preset can therefore read a variable
    // the including blueprint declares, which is what makes a shared fragment
    // parameterisable at all.
    final substituted = [
      for (final r in merged.values) _substitute(r, blueprint),
    ];

    _checkRequires(blueprint, substituted);
    _checkEnsure(blueprint, substituted, notes);

    // 5 + 6
    final ordered = _sort(blueprint, substituted);
    return ResolvedBlueprint(
      blueprint: blueprint.id,
      hash: hashOf(ordered),
      resources: ordered,
      notes: notes,
    );
  }

  /// The digest of a resolved resource list.
  ///
  /// Taken over the resources alone — not the notes, not the blueprint's name or
  /// description — because this answers one question: would applying this change
  /// the machine? Renaming a blueprint must not make every node look drifted.
  ///
  /// Provenance *is* included: a resource that arrived from a different preset
  /// is a different fact about the fleet, even when it asks for the same thing.
  static String hashOf(List<ResolvedResource> resources) {
    final canonical = jsonEncode([for (final r in resources) r.toJson()]);
    final digest = Sha256().toSync().hashSync(utf8.encode(canonical));
    return 'sha256:${_hex(digest.bytes)}';
  }

  static String _hex(List<int> bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

  /// Replaces every `${name}` in a resource's params.
  ///
  /// An unresolved variable is an error, never a pass-through. A `${app_root}`
  /// that survived into a file path would be created on a real machine as a
  /// directory with a dollar sign in its name, and nobody would find out until
  /// they went looking for why the deploy was empty.
  ResolvedResource _substitute(ResolvedResource resource, Blueprint blueprint) {
    if (resource.resource.params.isEmpty) return resource;
    final params = {
      for (final entry in resource.resource.params.entries)
        entry.key: _expand(entry.value, blueprint, resource.id, entry.key),
    };
    return ResolvedResource(
      resource: resource.resource.withParams(params),
      origin: resource.origin,
      overrides: resource.overrides,
    );
  }

  String _expand(
    String value,
    Blueprint blueprint,
    ResourceId id,
    String field,
  ) => value.replaceAllMapped(_varPattern, (match) {
    final name = match.group(1)!;
    final replacement = blueprint.vars[name];
    if (replacement == null) {
      throw ProtocolException(
        'Blueprint "${blueprint.id}" uses \${$name} in $id.$field, '
        'but declares no such var',
      );
    }
    return replacement;
  });

  static final RegExp _varPattern = RegExp(r'\$\{([A-Za-z0-9_.-]+)\}');

  /// Every `requires` has to name something the blueprint declares.
  ///
  /// Caught here rather than on the node: a dangling edge means the author meant
  /// an ordering that will not happen, and finding that out during an apply —
  /// half way through, on a real machine — is the expensive time to find out.
  void _checkRequires(Blueprint blueprint, List<ResolvedResource> resources) {
    final declared = {for (final r in resources) r.id};
    for (final resource in resources) {
      for (final need in resource.resource.requires) {
        if (!declared.contains(need)) {
          throw ProtocolException(
            'Blueprint "${blueprint.id}": ${resource.id} requires $need, '
            'which nothing declares',
          );
        }
      }
    }
  }

  /// Rejects an `ensure` a built-in formula cannot reach.
  ///
  /// `ensure: running` on a formula that installs a command is a blueprint that
  /// can never converge — it would plan a `start` on every single apply, forever
  /// reporting drift that no amount of applying fixes. The Hub knows the
  /// built-in specs, so it can say so while the author is still looking at the
  /// file.
  ///
  /// Only the built-ins, and only a note for anything else: a site registers its
  /// own formulas and its own providers, and the Hub refusing a resource it has
  /// simply never heard of would make the system closed.
  void _checkEnsure(
    Blueprint blueprint,
    List<ResolvedResource> resources,
    List<String> notes,
  ) {
    for (final resource in resources) {
      if (resource.id.type != 'formula') continue;
      final matches = standardFormulaSpecs.where(
        (s) => s.id.value == resource.id.name,
      );
      if (matches.isEmpty) {
        notes.add(
          '${resource.id}: not a built-in formula — the node must have it '
          'registered',
        );
        continue;
      }
      final spec = matches.first;
      final action = resource.ensure.action;
      if (!spec.actions.contains(action)) {
        throw ProtocolException(
          'Blueprint "${blueprint.id}": ${resource.id} asks for '
          'ensure=${resource.ensure.name}, but ${spec.name} does not implement '
          '${action.name} — it manages no service',
        );
      }
    }
  }

  /// Orders resources so nothing is settled before what it requires.
  ///
  /// Kahn's algorithm, taking ready resources in **declaration order** so the
  /// output is deterministic. That determinism is the point: a plan that
  /// reshuffles between runs cannot be reviewed, and a diff of two plans is only
  /// meaningful if the order is stable.
  List<ResolvedResource> _sort(
    Blueprint blueprint,
    List<ResolvedResource> resources,
  ) {
    final remaining = [...resources];
    final settled = <ResourceId>{};
    final ordered = <ResolvedResource>[];

    while (remaining.isNotEmpty) {
      final ready = remaining
          .where((r) => r.resource.requires.every(settled.contains))
          .toList();

      if (ready.isEmpty) {
        // Everything left is waiting on something else that is also left.
        final stuck = [for (final r in remaining) r.id.toString()]..sort();
        throw ProtocolException(
          'Blueprint "${blueprint.id}" has a dependency cycle among: '
          '${stuck.join(', ')}',
        );
      }

      for (final resource in ready) {
        ordered.add(resource);
        settled.add(resource.id);
        remaining.remove(resource);
      }
    }

    return ordered;
  }
}

/// A resource as declared, before duplicates are collapsed.
class _Declared {
  _Declared(this.resource, this.origin);

  final Resource resource;
  final String origin;
}
