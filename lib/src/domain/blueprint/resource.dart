import 'package:meta/meta.dart';

import '../../shared/errors/omnyserver_exception.dart';
import '../../shared/json/json_codec_helpers.dart';
import '../formula/formula_action.dart';

/// What a resource should *be*, as opposed to what should be done to it.
///
/// This is the whole difference between a blueprint and a preset. A preset says
/// `install docker`; a blueprint says `docker should be running`. The second one
/// can be checked, so it can be applied twice without doing the work twice, and
/// the same comparison that decides whether to act is also what reports drift.
///
/// Not every value is meaningful for every resource type — a command has nothing
/// to be [running] — so each provider declares the subset it accepts and the
/// resolver rejects the rest at save time rather than at apply time.
enum Ensure {
  /// On the node, by whatever definition its provider uses.
  present,

  /// Not on the node. This is how uninstall is expressed.
  absent,

  /// Installed at whatever version is already there, or any if none is.
  installed,

  /// Installed, and moved to the newest version available.
  latest,

  /// Installed, and its service running.
  running,

  /// Installed, and its service not running.
  stopped;

  /// Parses a wire name, rejecting anything unknown.
  ///
  /// Unlike [FormulaAction.parse], which defaults to the harmless `verify`,
  /// there is no safe default here: guessing at an unrecognised `ensure` would
  /// silently do something other than what the blueprint asked for.
  static Ensure parse(String value) => Ensure.values.firstWhere(
    (e) => e.name == value,
    orElse: () => throw ProtocolException('Unknown ensure: "$value"'),
  );

  /// The [FormulaAction] a preset step would have used to reach this state.
  ///
  /// The inverse of [fromAction], and the reason an existing preset can be read
  /// as a resource set without being rewritten.
  FormulaAction get action => switch (this) {
    Ensure.present || Ensure.installed => FormulaAction.install,
    Ensure.latest => FormulaAction.update,
    Ensure.running => FormulaAction.start,
    Ensure.stopped => FormulaAction.stop,
    Ensure.absent => FormulaAction.uninstall,
  };

  /// Reads an imperative [FormulaAction] as the state it was trying to reach.
  ///
  /// Total, which is what makes every preset ever saved composable into a
  /// blueprint with no migration:
  ///
  /// | action              | ensure      |
  /// |---------------------|-------------|
  /// | `install`, `verify` | `installed` |
  /// | `update`            | `latest`    |
  /// | `start`, `restart`  | `running`   |
  /// | `stop`              | `stopped`   |
  /// | `uninstall`         | `absent`    |
  ///
  /// `restart` collapsing onto [running] is the one lossy edge, and it is the
  /// right loss: a restart is a transition, and a declaration of what a machine
  /// should be has no room for one. Refreshing a service when its configuration
  /// changes is what `notifies:` is for.
  static Ensure fromAction(FormulaAction action) => switch (action) {
    FormulaAction.install || FormulaAction.verify => Ensure.installed,
    FormulaAction.update => Ensure.latest,
    FormulaAction.start || FormulaAction.restart => Ensure.running,
    FormulaAction.stop => Ensure.stopped,
    FormulaAction.uninstall => Ensure.absent,
  };
}

/// What a resource is called: its type, and its name within that type.
///
/// Rendered and parsed as `type:name` — `formula:docker`,
/// `file:/etc/nginx/nginx.conf`. This composite is load-bearing in four places
/// at once: it keys the node's ledger, it names a node in the dependency graph,
/// it tags the run's lines on the node log stream, and it is what stays stable
/// when a blueprint is edited. That last one is why identity is declared rather
/// than positional: delete a resource from a blueprint and the planner can see
/// it in the ledger and plan its removal. A list of anonymous entries makes "no
/// longer declared" unrepresentable.
@immutable
class ResourceId {
  /// The resource type — the provider that owns it (`formula`, `file`, …).
  final String type;

  /// The name within that type. Free-form: a formula id, an absolute path, a
  /// service name.
  final String name;

  /// Creates and validates a resource id.
  factory ResourceId(String type, String name) {
    final t = type.trim().toLowerCase();
    final n = name.trim();
    if (t.isEmpty) {
      throw const ProtocolException('Resource type cannot be empty');
    }
    if (!_validType.hasMatch(t)) {
      throw ProtocolException('Invalid resource type: "$type"');
    }
    if (n.isEmpty) {
      throw ProtocolException('Resource $t has an empty name');
    }
    return ResourceId._(t, n);
  }

  const ResourceId._(this.type, this.name);

  static final RegExp _validType = RegExp(r'^[a-z][a-z0-9_-]*$');

  /// Parses the `type:name` wire form.
  ///
  /// Splits on the **first** colon only, so a name may contain one — which it
  /// routinely does, for a URL or a Windows path.
  static ResourceId parse(String value) {
    final split = value.indexOf(':');
    if (split <= 0) {
      throw ProtocolException(
        'Invalid resource id "$value" — expected "type:name", '
        'for example "formula:docker"',
      );
    }
    return ResourceId(value.substring(0, split), value.substring(split + 1));
  }

  @override
  bool operator ==(Object other) =>
      other is ResourceId && other.type == type && other.name == name;

  @override
  int get hashCode => Object.hash(type, name);

  @override
  String toString() => '$type:$name';
}

/// One declared thing a blueprint wants on a node.
@immutable
class Resource {
  /// What this resource is.
  final ResourceId id;

  /// The state it should be in.
  final Ensure ensure;

  /// Type-specific settings — a pinned `version`, a file's `mode`, and so on.
  ///
  /// Deliberately a flat string map rather than a typed field per resource type:
  /// a provider is a class, and adding one should not mean touching this model.
  /// The provider validates what it needs.
  final Map<String, String> params;

  /// Resources that must be settled before this one.
  ///
  /// The only ordering there is. Declaration order breaks ties between
  /// independent resources so a run is reproducible, but it is *not* a
  /// dependency: position meaning order is how a blueprint comes to work by
  /// accident and break when somebody sorts the list.
  final List<ResourceId> requires;

  /// Creates a resource.
  const Resource({
    required this.id,
    this.ensure = Ensure.present,
    this.params = const {},
    this.requires = const [],
  });

  /// The pinned version, when one was given.
  String? get version => params['version'];

  /// A copy with [params] substituted — used by the resolver for `${var}`.
  Resource withParams(Map<String, String> params) =>
      Resource(id: id, ensure: ensure, params: params, requires: requires);

  /// JSON form.
  ///
  /// `type` and `name` are written flat rather than as a single `type:name`
  /// string, because this is also the authoring form and two fields read better
  /// than one that has to be split.
  Map<String, dynamic> toJson() => {
    'type': id.type,
    'name': id.name,
    'ensure': ensure.name,
    if (params.isNotEmpty) 'params': params,
    if (requires.isNotEmpty)
      'requires': [for (final r in requires) r.toString()],
  };

  /// Decodes from JSON.
  ///
  /// Anything that is not a reserved key is folded into [params], so a blueprint
  /// can write `version: "3.13.3"` inline instead of nesting it under `params`.
  /// The nested form wins where both are present.
  static Resource fromJson(Map<String, dynamic> json) {
    final params = <String, String>{};
    for (final entry in json.entries) {
      if (_reserved.contains(entry.key)) continue;
      final value = entry.value;
      if (value == null) continue;
      params[entry.key] = value is String ? value : '$value';
    }
    params.addAll(Json.optStringMap(json, 'params'));

    return Resource(
      id: ResourceId(
        Json.requireString(json, 'type'),
        Json.requireString(json, 'name'),
      ),
      ensure: Ensure.parse(Json.optString(json, 'ensure') ?? 'present'),
      params: params,
      requires: [
        for (final r in Json.optStringList(json, 'requires'))
          ResourceId.parse(r),
      ],
    );
  }

  static const Set<String> _reserved = {
    'type',
    'name',
    'ensure',
    'params',
    'requires',
  };

  @override
  String toString() => '$id ensure=${ensure.name}';
}
