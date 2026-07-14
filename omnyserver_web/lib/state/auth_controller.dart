import 'package:omnyshell_web/foundation.dart'
    show AppError, Observable, SettingsStore;

import '../core/omnyserver_service.dart';

/// Where the session stands.
enum AuthStatus {
  /// No credentials yet.
  signedOut,

  /// A login (or a restore) is in flight.
  authenticating,

  /// The Hub accepted the credentials.
  signedIn,
}

/// An immutable snapshot of the session, for screens to render.
class AuthSnapshot {
  /// The current status.
  final AuthStatus status;

  /// Who the Hub says you are, once signed in.
  final Identity? identity;

  /// The Hub, once signed in.
  final Uri? hubUri;

  /// The last failure, if the login was rejected.
  final AppError? error;

  /// Creates a snapshot.
  const AuthSnapshot({
    required this.status,
    this.identity,
    this.hubUri,
    this.error,
  });

  /// Whether the UI should offer fleet-changing actions.
  bool get canOperate => identity?.canOperate ?? false;
}

/// Owns the session: login, logout, and restoring a remembered one.
class AuthController {
  final OmnyServerService _service;
  final SettingsStore _settings;

  /// The observable session state.
  final Observable<AuthSnapshot> state = Observable(
    const AuthSnapshot(status: AuthStatus.signedOut),
  );

  /// Creates the controller.
  AuthController(this._service, this._settings);

  /// The last Hub, for prefilling the login form.
  String? get lastHub => _settings.hub;

  /// The last principal, for prefilling the login form.
  String? get lastPrincipal => _settings.principal;

  /// Whether the user asked for their token to be remembered.
  bool get rememberToken => _settings.rememberToken;

  /// Signs in, and persists what the user allowed.
  Future<void> login({
    required String hub,
    required String principal,
    required String token,
    required bool remember,
  }) async {
    state.value = const AuthSnapshot(status: AuthStatus.authenticating);
    try {
      final identity = await _service.connect(
        hubUri: hub,
        principal: principal,
        token: token,
      );
      final uri = _service.hubUri!;
      _settings
        ..hub = hub
        ..principal = principal.isEmpty ? null : principal
        ..rememberToken = remember;
      // A token in localStorage is readable by any script on the page, so it is
      // only ever stored when the user asks for it — and forgotten the moment
      // they stop asking.
      if (remember) {
        _settings.saveToken(uri.toString(), token);
      } else {
        _settings.clearToken(uri.toString());
      }
      state.value = AuthSnapshot(
        status: AuthStatus.signedIn,
        identity: identity,
        hubUri: uri,
      );
    } on AppError catch (e) {
      state.value = AuthSnapshot(status: AuthStatus.signedOut, error: e);
    }
  }

  /// Restores a remembered session, if there is one. Returns whether it worked.
  ///
  /// A stored token can have been revoked since, so this *verifies* it against
  /// the Hub rather than trusting it — a silent failure here just lands the user
  /// on the login form, which is what they would expect.
  Future<bool> tryRestore() async {
    final hub = _settings.hub;
    if (hub == null || !_settings.rememberToken) return false;
    final uri = OmnyServerService.normalizeHubUri(hub).toString();
    final token = _settings.tokenFor(uri);
    if (token == null) return false;

    await login(
      hub: hub,
      principal: _settings.principal ?? '',
      token: token,
      remember: true,
    );
    return state.value.status == AuthStatus.signedIn;
  }

  /// Signs out and forgets the token.
  void logout() {
    final uri = _service.hubUri;
    if (uri != null) _settings.clearToken(uri.toString());
    _service.disconnect();
    state.value = const AuthSnapshot(status: AuthStatus.signedOut);
  }
}
