import 'dart:async';

import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';
import '../../state/auth_controller.dart';
import '../../version.dart';

/// Sign in to a Hub.
///
/// Two credentials work here, and the form says so, because the difference is
/// not obvious and getting it wrong looks identical to a wrong password:
///
/// * a **grant** — a principal *and* the token granted to it
///   (`hub start --grant alice:admin-token:admin`), which is an identity the Hub
///   verifies and whose roles decide what you may do; or
/// * the Hub's **master API token** (`--api-token`), which has no identity of
///   its own — leave the principal empty.
class LoginScreen implements Screen {
  /// The app context.
  final AppContext ctx;

  @override
  late final web.HTMLElement element;

  late final web.HTMLInputElement _hub;
  late final web.HTMLInputElement _principal;
  late final web.HTMLInputElement _token;
  late final ({web.HTMLElement root, web.HTMLInputElement box}) _remember;
  late final web.HTMLElement _status;
  late final web.HTMLButtonElement _submit;

  StreamSubscription<void>? _sub;

  /// Builds the screen.
  LoginScreen(this.ctx) {
    _hub = input(
      id: 'hub',
      value: ctx.auth.lastHub ?? '',
      placeholder: 'hub.example.com:8443',
      autocomplete: 'url',
    );
    _principal = input(
      id: 'principal',
      value: ctx.auth.lastPrincipal ?? '',
      placeholder: 'alice (leave empty for the API token)',
      autocomplete: 'username',
    );
    _token = input(
      id: 'token',
      type: 'password',
      autocomplete: 'current-password',
    );
    _remember = checkbox(
      'Remember this token in the browser',
      id: 'remember',
      checked: ctx.auth.rememberToken,
    );
    _status = div();
    _submit = button('Connect', primary: true, onClick: _submitForm);

    final form = el(
      'form',
      classes: 'stack',
      children: [
        field('Hub', _hub, hint: 'The Hub address; port 8443 is assumed.'),
        field(
          'Principal',
          _principal,
          hint: 'Half of a grant credential. Empty when using the API token.',
        ),
        field('Token', _token),
        _remember.root,
        el(
          'div',
          classes: 'hint',
          text:
              'A token stored here is readable by any script on this page. '
              'Leave it unchecked on a shared machine.',
        ),
        _status,
        _submit,
      ],
    );
    on(form, 'submit', (e) {
      e.preventDefault();
      _submitForm();
    });

    element = el(
      'div',
      classes: 'center-host',
      children: [
        el(
          'div',
          classes: 'card pad-lg',
          children: [
            el('h1', text: 'OmnyServer'),
            el('div', classes: 'muted', text: 'Fleet dashboard'),
            el('hr'),
            form,
            el('hr'),
            _versions(),
          ],
        ),
      ],
    );

    _sub = ctx.auth.state.stream.listen((_) => _render());
    _render();
  }

  /// The version line — see [versionLabel]. The tooltip is the one bit local to
  /// the login screen, where "not the Hub you connect to" is worth saying.
  web.HTMLElement _versions() => el(
    'div',
    classes: 'muted version-footer',
    attrs: {
      'title':
          'This dashboard build, and the OmnyServer version it was built '
          'against — not the version of the Hub you connect to.',
    },
    text: versionLabel,
  );

  void _render() {
    final snapshot = ctx.auth.state.value;
    final busy = snapshot.status == AuthStatus.authenticating;
    _submit.disabled = busy;
    _submit.textContent = busy ? 'Connecting…' : 'Connect';

    clearChildren(_status);
    final error = snapshot.error;
    if (error != null && !busy) _status.appendChild(errorBanner(error));
  }

  Future<void> _submitForm() async {
    if (ctx.auth.state.value.status == AuthStatus.authenticating) return;
    await ctx.auth.login(
      hub: _hub.value,
      principal: _principal.value,
      token: _token.value,
      remember: _remember.box.checked,
    );
    if (ctx.auth.state.value.status == AuthStatus.signedIn) {
      ctx.router.go(Routes.nodes);
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
  }
}
