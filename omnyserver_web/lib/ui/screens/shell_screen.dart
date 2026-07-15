import 'dart:async';

import 'package:omnyshell/omnyshell_client_web.dart'
    show LocalCommandRegistry, NodeDescriptor, RemoteSession, ShellSessionPort;
import 'package:omnyshell_web/client.dart'
    show AppError, AppErrorKind, OmnyShellService;
import 'package:omnyshell_web/terminal.dart';
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';
import '../settings_dialog.dart';

/// A live shell on a node, in the browser.
///
/// The whole terminal stack — xterm surface, shell driver, on-screen key bar,
/// and the sizing engine that keeps it usable against a soft keyboard — is
/// imported from `omnyshell_web`. None of it is reimplemented here; this screen
/// only connects an OmnyShell session and hands it over.
///
/// It works because one Hub can serve both fleets: `hub start --shell` mounts an
/// OmnyShell broker on the very port the REST API answers on, and the *same*
/// grant authenticates against both. So the dashboard reuses the credentials the
/// operator already gave it.
///
/// The node must be running its shell agent (`node start --with-shell`).
class ShellScreen implements Screen {
  /// The app context.
  final AppContext ctx;

  /// The node to open a shell on.
  final String nodeId;

  /// Builds the terminal surface (injectable so tests need no xterm.js).
  final TerminalView Function(web.HTMLElement host) terminalFactory;

  @override
  late final web.HTMLElement element;

  late final web.HTMLElement _host;
  late final web.HTMLElement _accessory;
  late final web.HTMLElement _status;

  final OmnyShellService _shellService = OmnyShellService();
  TerminalView? _term;
  WebShellHost? _shell;
  TerminalFitter? _fitter;
  NodeDescriptor? _node;
  bool _disposed = false;

  /// Loads the shell node's descriptor in the background so `:info`, `:tree`,
  /// `:node` and friends have metadata. Best-effort — they report it as
  /// unavailable if this fails.
  Future<void> _loadNode() async {
    try {
      for (final n in await _shellService.listNodes()) {
        if (n.id.value == nodeId) {
          _node = n;
          break;
        }
      }
    } on Object {
      // Local commands needing node metadata will say it is unavailable.
    }
  }

  /// Builds the screen.
  ShellScreen(
    this.ctx,
    this.nodeId, {
    TerminalView Function(web.HTMLElement host)? terminalFactory,
  }) : terminalFactory =
           terminalFactory ?? ((host) => XtermTerminalView(host)) {
    _host = el('div', classes: 'terminal-host');
    _accessory = div();
    _status = div();

    element = el(
      'div',
      classes: 'stack terminal-screen',
      children: [
        el(
          'div',
          classes: 'toolbar row',
          children: [
            button('← Node', onClick: () => ctx.router.go('/nodes/$nodeId')),
            el('h1', classes: 'grow', text: '$nodeId · shell'),
          ],
        ),
        _status,
        el('div', classes: 'card terminal-card', children: [_host]),
        _accessory,
      ],
    );

    unawaited(_start());
  }

  Future<void> _start() async {
    final auth = ctx.auth.state.value;
    final hub = auth.hubUri;
    final identity = auth.identity;
    if (hub == null || identity == null) return;

    _status.appendChild(loadingRow('Opening a shell on $nodeId…'));

    try {
      // The shell broker rides the Hub's own port, on the `/shell` mount, and
      // takes the grant the operator already signed in with. A master API token
      // has no principal and so cannot authenticate to it — say so plainly
      // rather than failing with a protocol error.
      final token = ctx.settings.tokenFor(hub.toString());
      if (token == null) {
        throw const AppError(
          AppErrorKind.auth,
          'The shell needs your token, which was not remembered.',
          hint: 'Sign in again with "Remember this token" to open a shell.',
        );
      }
      if (identity.principal == 'api') {
        throw const AppError(
          AppErrorKind.auth,
          'The master API token cannot open a shell.',
          hint: 'Sign in with a grant (a principal and its token) instead.',
        );
      }

      final shellUri = hub.replace(scheme: 'wss', path: '/shell');
      await _shellService.connect(
        hubUri: shellUri.toString(),
        principal: identity.principal,
        token: token,
      );

      if (_disposed) return;

      final term = terminalFactory(_host);
      _term = term;

      // Auto-fit: let xterm derive the grid from the container, then open the
      // PTY at exactly that size.
      final fitter = TerminalFitter(
        term: term,
        host: _host,
        accessory: _accessory,
        scaleTarget: element,
      );
      _fitter = fitter;
      fitter.applyFont();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (_disposed) return;
      if (term is XtermTerminalView) term.fit();

      final size = term.size;
      final ShellSessionPort session = await _shellService.openShell(
        nodeId: nodeId,
        cols: size.cols,
        rows: size.rows,
      );
      if (_disposed) return;

      // The same local `:` commands the OmnyShell dashboard offers: the
      // omnyshell built-ins (:info, :whoami, :os, :tree, :tunnel, :ping,
      // :latency, :clear, :exit, …) plus :ai (the agent, proxied through the
      // Hub) and :ide (a terminal IDE on the node). Best-effort — :ai falls back
      // to a setup stub that points at Settings when no provider is configured.
      final commands = LocalCommandRegistry.withDefaults();
      await registerAiCommand(
        registry: commands,
        settings: ctx.settings,
        service: _shellService,
        openSettings: () => showOmnyServerSettings(ctx),
      );
      if (_disposed) return;
      unawaited(_loadNode());
      final shell = WebShellHost(
        term: term,
        session: session,
        principal: identity.principal,
        nodeId: nodeId,
        commands: commands,
        client: _shellService.client,
        nodeInfo: () => _node,
        principalInfo: _shellService.principal,
        remoteSession: session is RemoteSession ? session : null,
        // Per principal+node command history (Up/Down), persisted to
        // localStorage.
        history: CommandHistory.load(
          kv: ctx.kv,
          key: '${identity.principal}@$nodeId',
        ),
        onSessionExit: () => ctx.toasts.show('Session ended.'),
      );
      // Registered once the host exists — it supplies the resize stream the IDE
      // driver reflows on.
      registerIdeCommand(
        registry: commands,
        term: term,
        resizeEvents: shell.resizeEvents,
        service: _shellService,
        settings: ctx.settings,
      );
      _shell = shell;

      clearChildren(_status);
      mount(
        _accessory,
        TerminalAccessoryBar(
          keys: shell,
          term: term,
          clipboardRead: defaultClipboardRead,
          clipboardWrite: defaultClipboardWrite,
          onToast: ctx.toasts.show,
        ).element,
      );
      fitter.attach();
      fitter.settle();
      term.focus();
    } on Object catch (e) {
      if (_disposed) return;
      clearChildren(_status);
      _status.appendChild(
        errorBanner(
          e is AppError
              ? e
              : AppError(
                  AppErrorKind.transport,
                  'Could not open a shell on $nodeId.',
                  hint:
                      'The Hub must host a shell broker (hub start --shell) and '
                      'the node must run one (node start --with-shell).',
                  cause: e,
                ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _fitter?.dispose();
    unawaited(_shell?.dispose());
    _term?.dispose();
    unawaited(_shellService.disconnect());
  }
}
