import 'package:omnyshell_web/client.dart'
    show
        AiSettingsController,
        KeyValueStore,
        OmnyShellService,
        Router,
        SettingsStore,
        ThemeController;
import 'package:omnyshell_web/ui_kit.dart' show Toasts;
import 'package:web/web.dart' as web;

import '../core/omnyserver_service.dart';
import '../state/auth_controller.dart';
import '../state/nodes_controller.dart';

/// Everything a screen needs, wired once in `bootstrap`.
class AppContext {
  /// The only thing that talks to the Hub.
  final OmnyServerService service;

  /// The OmnyShell client behind a node shell — the Hub brokers OmnyShell on the
  /// same port (`hub start --shell`), so one login serves both. Also backs the
  /// AI settings' Hub-default lookup.
  final OmnyShellService shellService;

  /// The session.
  final AuthController auth;

  /// The fleet.
  final NodesController nodes;

  /// Persisted preferences (namespaced `omnyserver.`).
  final SettingsStore settings;

  /// The raw persistence behind [settings] — e.g. per-node shell command
  /// history.
  final KeyValueStore kv;

  /// Light/dark/system theme.
  final ThemeController theme;

  /// The AI agent preferences behind the terminal `:ai` command.
  final AiSettingsController ai;

  /// Hash-based routing.
  final Router router;

  /// Transient messages.
  final Toasts toasts;

  /// Creates the context.
  const AppContext({
    required this.service,
    required this.shellService,
    required this.auth,
    required this.nodes,
    required this.settings,
    required this.kv,
    required this.theme,
    required this.ai,
    required this.router,
    required this.toasts,
  });
}

/// A mounted screen.
abstract class Screen {
  /// The screen's root element.
  web.HTMLElement get element;

  /// Releases timers, listeners and subscriptions.
  void dispose();
}

/// The route table, most specific first — the router matches in this order.
abstract final class Routes {
  /// The login form.
  static const String login = '/login';

  /// The fleet.
  static const String nodes = '/nodes';

  /// One node.
  static const String node = '/nodes/:id';

  /// A shell session on one node.
  static const String shell = '/nodes/:id/shell';

  /// Events and the audit trail.
  static const String activity = '/activity';

  /// Issued credentials (admin only).
  static const String grants = '/credentials';

  /// Every pattern, most specific first.
  static const List<String> all = [shell, node, nodes, activity, grants, login];
}
