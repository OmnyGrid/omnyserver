import 'dart:async';

import 'package:omnyshell_web/client.dart' show RouteMatch;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../state/auth_controller.dart';
import '../ui/screens/activity_screen.dart';
import '../ui/screens/grants_screen.dart';
import '../ui/screens/login_screen.dart';
import '../ui/screens/node_detail_screen.dart';
import '../ui/screens/nodes_screen.dart';
import '../ui/screens/shell_screen.dart';
import '../ui/settings_dialog.dart';
import 'app_context.dart';

/// The app shell: a header, and whichever screen the route names.
///
/// It also enforces the guard both ways — a signed-out user is sent to the login
/// form, and a signed-in one is sent away from it — so no screen has to check
/// for credentials it can then assume it has.
class App {
  /// The app context.
  final AppContext ctx;

  /// Where the app renders.
  final web.HTMLElement root;

  late final web.HTMLElement _main;
  late final web.HTMLElement _identity;
  late final web.HTMLElement _nav;
  Screen? _screen;
  StreamSubscription<void>? _routeSub;
  StreamSubscription<void>? _authSub;

  /// Creates the app.
  App(this.ctx, this.root);

  /// Renders the shell and starts routing.
  void start() {
    _main = el('main', classes: 'app-main');
    _identity = el('div', classes: 'meta hide-sm');
    _nav = el('div', classes: 'row');

    final header = el(
      'header',
      classes: 'app-header row',
      children: [
        el(
          'div',
          classes: 'brand',
          onClick: (_) => ctx.router.go(Routes.nodes),
          children: [textNode('OmnyServer')],
        ),
        _nav,
        el('div', classes: 'spacer grow'),
        _identity,
        button(
          '⚙',
          className: 'icon ghost settings-icon',
          ariaLabel: 'Settings',
          onClick: () => showOmnyServerSettings(ctx),
        ),
      ],
    );

    mount(root, el('div', children: [header, _main]));

    _routeSub = ctx.router.current.stream.listen((_) => _render());
    _authSub = ctx.auth.state.stream.listen((_) {
      _renderHeader();
      _render();
    });
    ctx.router.start();
    _renderHeader();
    _render();
  }

  void _renderHeader() {
    final snapshot = ctx.auth.state.value;
    final signedIn = snapshot.status == AuthStatus.signedIn;

    clearChildren(_nav);
    clearChildren(_identity);
    if (!signedIn) return;

    _nav
      ..appendChild(
        button(
          'Fleet',
          className: 'btn-sm',
          onClick: () => ctx.router.go(Routes.nodes),
        ),
      )
      ..appendChild(
        button(
          'Activity',
          className: 'btn-sm',
          onClick: () => ctx.router.go(Routes.activity),
        ),
      );

    // Issuing and revoking credentials is admin-only at the Hub, so offering it
    // to anyone else would be an invitation to a 403.
    if (snapshot.identity?.roles.contains('admin') ?? false) {
      _nav.appendChild(
        button(
          'Credentials',
          className: 'btn-sm',
          onClick: () => ctx.router.go(Routes.grants),
        ),
      );
    }

    final identity = snapshot.identity;
    _identity.appendChild(
      textNode(
        '${identity?.principal ?? ''} · '
        '${(identity?.roles ?? const <String>{}).join(', ')} · '
        '${snapshot.hubUri?.host ?? ''}',
      ),
    );
    _identity.appendChild(
      button(
        'Sign out',
        className: 'btn-sm ghost',
        onClick: () {
          ctx.auth.logout();
          ctx.nodes.reset();
          ctx.router.go(Routes.login);
        },
      ),
    );
  }

  void _render() {
    final route = ctx.router.current.value;
    final signedIn = ctx.auth.state.value.status == AuthStatus.signedIn;

    // The guard, both ways. Redirecting rather than rendering keeps the URL and
    // what is on screen from disagreeing.
    if (!signedIn && route.pattern != Routes.login) {
      ctx.router.replace(Routes.login);
      return;
    }
    if (signedIn && (route.pattern == Routes.login || route.pattern.isEmpty)) {
      ctx.router.replace(Routes.nodes);
      return;
    }

    _mountScreen(_screenFor(route, signedIn));
  }

  Screen? _screenFor(RouteMatch route, bool signedIn) {
    if (!signedIn) return LoginScreen(ctx);
    return switch (route.pattern) {
      Routes.nodes => NodesScreen(ctx),
      Routes.node => NodeDetailScreen(ctx, route.params['id']!),
      Routes.shell => ShellScreen(ctx, route.params['id']!),
      Routes.activity => ActivityScreen(ctx),
      Routes.grants => GrantsScreen(ctx),
      _ => null,
    };
  }

  void _mountScreen(Screen? screen) {
    _screen?.dispose();
    _screen = screen;
    clearChildren(_main);
    if (screen == null) {
      _main.appendChild(emptyState('That page does not exist.'));
      return;
    }
    _main.appendChild(screen.element);
  }

  /// Tears the app down (tests; the page itself never does).
  void dispose() {
    unawaited(_routeSub?.cancel());
    unawaited(_authSub?.cancel());
    _screen?.dispose();
    ctx.router.stop();
  }
}
