import '../../domain/auth/authenticator.dart';
import '../../domain/auth/principal.dart';

/// A simple role-based [Authorizer]: a principal may perform an action if it
/// holds one of the roles mapped to that action's required role set, or holds
/// the wildcard [adminRole].
///
/// Actions not explicitly mapped require [adminRole] by default (fail-closed).
/// This is the designed extension point for richer RBAC / multi-tenant rules.
class RoleBasedAuthorizer implements Authorizer {
  /// The default policy: a principal holding the `node` role may register a
  /// node; everything else requires [adminRole].
  ///
  /// A node agent authenticates as an ordinary principal, so without this the
  /// fail-closed default would deny every registration. Granting exactly
  /// `node.register` keeps a node credential useless for anything an operator
  /// does — it can enrol a node and nothing more.
  static const Map<String, Set<String>> defaultActionRoles = {
    'node.register': {'node'},
  };

  /// The role that is permitted to do everything.
  final String adminRole;

  /// Maps an action prefix (e.g. `node.`, `preset.`) to the roles allowed.
  final Map<String, Set<String>> actionRoles;

  /// Creates a role-based authorizer.
  const RoleBasedAuthorizer({
    this.adminRole = 'admin',
    this.actionRoles = defaultActionRoles,
  });

  @override
  bool authorize(Principal principal, String action, {String? target}) {
    if (principal.hasRole(adminRole)) return true;
    for (final entry in actionRoles.entries) {
      if (action == entry.key || action.startsWith(entry.key)) {
        if (principal.roles.any(entry.value.contains)) return true;
      }
    }
    return false;
  }
}
