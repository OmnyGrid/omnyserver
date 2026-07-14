import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../value_objects/principal_id.dart';

/// A credential the Hub has issued: who it is for, what it may do, and the
/// fingerprint of the token that proves it.
///
/// **The token itself is not here, and cannot be recovered.** Only its SHA-256
/// hash is stored, so a Hub's grant file — or a stolen backup of it — hands an
/// attacker nothing they can authenticate with. The plaintext exists exactly
/// once, in the response to the request that created it, and if the operator
/// loses it the answer is to issue another and revoke this one. That is the
/// whole reason a grant has an [id]: you revoke what you cannot read.
@immutable
class Grant {
  /// A short, stable handle used to revoke this grant.
  final String id;

  /// Who the token authenticates as.
  final PrincipalId principal;

  /// What that principal may do.
  final Set<String> roles;

  /// SHA-256 of the token, hex-encoded. Never the token.
  final String tokenHash;

  /// When the grant was issued (UTC).
  final DateTime createdAt;

  /// A human note — who it was issued to, and why.
  final String note;

  /// Creates a grant.
  const Grant({
    required this.id,
    required this.principal,
    required this.roles,
    required this.tokenHash,
    required this.createdAt,
    this.note = '',
  });

  /// JSON form.
  ///
  /// Safe to return from the API and to write to disk: it carries a hash, not a
  /// credential.
  Map<String, dynamic> toJson() => {
    'id': id,
    'principal': principal.value,
    'roles': roles.toList()..sort(),
    'tokenHash': tokenHash,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'note': note,
  };

  /// Decodes from JSON.
  static Grant fromJson(Map<String, dynamic> json) => Grant(
    id: Json.requireString(json, 'id'),
    principal: PrincipalId(Json.requireString(json, 'principal')),
    roles: Json.optStringList(json, 'roles').toSet(),
    tokenHash: Json.requireString(json, 'tokenHash'),
    createdAt: Json.requireTimestamp(json, 'createdAt'),
    note: Json.optString(json, 'note') ?? '',
  );

  @override
  String toString() => 'Grant($id, ${principal.value}, ${roles.join(',')})';
}
