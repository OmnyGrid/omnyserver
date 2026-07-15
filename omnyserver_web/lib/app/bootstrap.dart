import 'dart:js_interop';

import 'package:omnyshell_web/client.dart'
    show
        AiSettingsController,
        LocalStorageStore,
        OmnyShellService,
        Router,
        SettingsStore,
        ThemeController;
import 'package:omnyshell_web/ui_kit.dart' show Toasts;
import 'package:web/web.dart' as web;

import '../core/omnyserver_service.dart';
import '../state/auth_controller.dart';
import '../state/nodes_controller.dart';
import 'app.dart';
import 'app_context.dart';

/// The `omnyserver.` namespace.
///
/// One Hub can serve this dashboard *and* the OmnyShell web app from the same
/// origin, and `localStorage` is per-origin — without separate prefixes the two
/// would share, and clobber, each other's theme, Hub and token.
const String storagePrefix = 'omnyserver.';

/// Wires the app and starts it.
Future<App> bootstrap(web.HTMLElement root) async {
  final kv = LocalStorageStore();
  final settings = SettingsStore(kv, prefix: storagePrefix);
  final service = OmnyServerService();
  // One OmnyShell client for the whole app: a node shell connects it (the Hub
  // brokers OmnyShell on the same port), and the AI settings read the Hub's
  // default provider through it.
  final shellService = OmnyShellService();

  final theme = ThemeController(
    settings,
    prefersDark: () =>
        web.window.matchMedia('(prefers-color-scheme: dark)').matches,
    onApply: (resolved) {
      web.document.documentElement?.setAttribute('data-theme', resolved.attr);
      // Keep the PWA's status bar in step with the theme.
      web.document
          .getElementById('theme-color')
          ?.setAttribute(
            'content',
            resolved.attr == 'dark' ? '#0f1318' : '#f6f7f9',
          );
    },
  );
  theme.set(theme.mode.value);
  web.window
      .matchMedia('(prefers-color-scheme: dark)')
      .addEventListener(
        'change',
        ((web.Event _) => theme.refreshSystem()).toJS,
      );

  final ctx = AppContext(
    service: service,
    shellService: shellService,
    auth: AuthController(service, settings),
    nodes: NodesController(service, kv, prefix: storagePrefix),
    settings: settings,
    kv: kv,
    theme: theme,
    ai: AiSettingsController(settings, shellService),
    router: Router(Routes.all),
    toasts: Toasts(web.document.getElementById('toasts')!),
  );

  final app = App(ctx, root);
  // Restore a remembered session *before* the first render, so a returning
  // operator lands on the fleet rather than watching the login form flash past.
  await ctx.auth.tryRestore();
  app.start();
  return app;
}
