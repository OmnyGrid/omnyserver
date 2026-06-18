import 'package:meta/meta.dart';

import '../value_objects/principal_id.dart';

/// An authenticated identity, with the roles it holds. Used by the Hub to make
/// authorization decisions.
///
/// The role model is deliberately simple now (a set of string roles) but is the
/// designed extension point for future RBAC / multi-tenant support.
@immutable
class Principal {
  /// The principal identity.
  final PrincipalId id;

  /// The roles granted to this principal (e.g. `admin`, `operator`, `node`).
  final Set<String> roles;

  /// Creates a principal.
  const Principal({required this.id, this.roles = const {}});

  /// Whether this principal holds [role].
  bool hasRole(String role) => roles.contains(role);

  @override
  String toString() => 'Principal(${id.value}, roles: ${roles.join(',')})';
}
