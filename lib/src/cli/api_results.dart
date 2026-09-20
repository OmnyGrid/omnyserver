/// The handful of API replies that are not already a domain entity.
///
/// Most endpoints answer with something the model already names — a
/// `NodeDescriptor`, a `Drift`, an `Operation` — and `HubApiClient` returns
/// those directly. These are the rest: replies assembled by the API for a
/// caller's benefit, which would otherwise arrive as a raw map for everyone to
/// pick at in their own way and get subtly wrong.
library;

import 'package:meta/meta.dart';

import '../domain/blueprint/resource_change.dart';
import '../domain/entities/grant.dart';
import '../domain/formula/formula_result.dart';
import '../shared/json/json_codec_helpers.dart';

/// Who the Hub says you are.
///
/// The answer to `GET /whoami`, and the reason a login is a real login: without
/// asking, a bad token would sail through and fail on the first screen instead.
@immutable
class Identity {
  /// The principal id (`alice`, or `api` for the Hub's own token).
  final String principal;

  /// The roles the Hub resolved for this credential.
  final Set<String> roles;

  /// Whether a credential was presented at all.
  ///
  /// False on a Hub running with no `--api-token`, where there is no identity
  /// to report rather than a rejected one.
  final bool authenticated;

  /// Creates an identity.
  const Identity({
    required this.principal,
    this.roles = const {},
    this.authenticated = true,
  });

  /// Whether these roles permit changing the fleet, as opposed to watching it.
  ///
  /// The Hub is the real gate; this only decides what a client bothers to
  /// offer, so that a viewer is not shown buttons that will be refused.
  bool get canOperate => roles.contains('admin') || roles.contains('operator');

  /// Decodes the reply.
  static Identity fromJson(Map<String, dynamic> json) => Identity(
    principal: Json.optString(json, 'principal') ?? 'anonymous',
    roles: Json.optStringList(json, 'roles').toSet(),
    authenticated: Json.optBool(json, 'authenticated', fallback: true),
  );

  @override
  String toString() => 'Identity($principal, ${roles.join('+')})';
}

/// What converging a node came to.
///
/// `POST /nodes/<id>/reconcile` answers in one of two shapes, because a node is
/// declared in one of two ways: a blueprint reports [changes], a preset
/// declaration reports [results]. Exactly one is ever filled.
///
/// [changed] and [success] are the same question either way, which is what most
/// callers want — a line of output, or a decision about an exit code. The lists
/// are there for the ones that want to say what moved.
@immutable
class ConvergeResult {
  /// Whether everything attempted worked.
  final bool success;

  /// How many things were actually changed.
  final int changed;

  /// How many were not attempted, because something they required failed.
  final int skipped;

  /// Per-resource outcomes, for a node declared by a blueprint.
  final List<ResourceChange> changes;

  /// Per-step outcomes, for a node declared by preset steps.
  final List<FormulaResult> results;

  /// Anything worth saying that is not a change — a dry run, a provider the
  /// node does not have.
  final List<String> notes;

  /// Creates a converge result.
  const ConvergeResult({
    required this.success,
    this.changed = 0,
    this.skipped = 0,
    this.changes = const [],
    this.results = const [],
    this.notes = const [],
  });

  /// Whether there was nothing to do.
  bool get converged => changed == 0 && skipped == 0;

  /// Decodes either shape.
  ///
  /// The blueprint path sends `changed` and `skipped` already counted; the
  /// preset path sends a list of step results and no counts, so they are
  /// derived here rather than left for each caller to derive differently.
  static ConvergeResult fromJson(Map<String, dynamic> json) {
    final results = Json.optObjectList(
      json,
      'results',
    ).map(FormulaResult.fromJson).toList();

    return ConvergeResult(
      success:
          Json.optBool(json, 'success', fallback: true) &&
          results.every((r) => r.success),
      changed:
          Json.optInt(json, 'changed') ??
          results.where((r) => r.changed).length,
      skipped: Json.optInt(json, 'skipped') ?? 0,
      changes: Json.optObjectList(
        json,
        'changes',
      ).map(ResourceChange.fromJson).toList(),
      results: results,
      notes: Json.optStringList(json, 'notes'),
    );
  }

  @override
  String toString() =>
      'ConvergeResult(${success ? 'ok' : 'failed'}, $changed changed)';
}

/// A credential, and the one and only time its token is readable.
///
/// The Hub keeps a hash. If this token is lost it cannot be recovered — only
/// revoked and reissued — which is why it is a distinct type rather than a
/// field on [Grant] that is null everywhere else.
@immutable
class IssuedGrant {
  /// The credential as the Hub recorded it.
  final Grant grant;

  /// The bearer token. Shown once.
  final String token;

  /// Creates an issued grant.
  const IssuedGrant({required this.grant, required this.token});

  /// The credential's id.
  String get id => grant.id;

  /// Decodes the reply, which carries the grant's fields and the token
  /// alongside them.
  static IssuedGrant fromJson(Map<String, dynamic> json) => IssuedGrant(
    grant: Grant.fromJson(json),
    token: Json.requireString(json, 'token'),
  );

  @override
  String toString() => 'IssuedGrant(${grant.id})';
}
