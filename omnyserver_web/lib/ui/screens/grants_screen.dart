import 'dart:async';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/foundation.dart' show AppError, relativeTime;
import 'package:omnyshell_web/terminal.dart' show defaultClipboardWrite;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';

/// Credentials: who can reach this Hub, and with what.
///
/// The screen is shaped around one fact: **the token is readable exactly once.**
/// The Hub keeps a hash and cannot show it again, so a newly issued token has to
/// be put in front of the operator *now*, unmissably, with the reason stated —
/// otherwise they close the dialog, lose it, and blame the tool rather than
/// issuing another.
class GrantsScreen implements Screen {
  /// The app context.
  final AppContext ctx;

  @override
  late final web.HTMLElement element;

  late final web.HTMLElement _body;

  /// Builds the screen.
  GrantsScreen(this.ctx) {
    _body = div();

    element = el(
      'div',
      classes: 'stack',
      children: [
        el(
          'div',
          classes: 'toolbar row',
          children: [
            el('h1', classes: 'grow', text: 'Credentials'),
            button('Issue…', primary: true, onClick: _issueDialog),
            button('Refresh', onClick: _load),
          ],
        ),
        el(
          'div',
          classes: 'card stack',
          children: [
            el(
              'div',
              classes: 'hint',
              text:
                  'The Hub stores a hash of each token, never the token. One is '
                  'shown only when issued, and cannot be recovered — a lost '
                  'token is revoked and replaced.',
            ),
            _body,
          ],
        ),
      ],
    );

    _load();
  }

  void _load() {
    unawaited(_loadGrants());
  }

  Future<void> _loadGrants() async {
    clearChildren(_body);
    _body.appendChild(loadingRow('Loading credentials…'));
    try {
      final grants = await ctx.service.grants();
      clearChildren(_body);
      if (grants.isEmpty) {
        _body.appendChild(
          emptyState('No credentials have been issued from this Hub.'),
        );
        return;
      }
      final now = DateTime.now();
      for (final grant in grants) {
        _body.appendChild(_row(grant, now));
      }
    } on AppError catch (e) {
      clearChildren(_body);
      _body.appendChild(errorBanner(e));
    }
  }

  web.HTMLElement _row(Grant grant, DateTime now) => el(
    'div',
    classes: 'row list-item',
    children: [
      el(
        'div',
        classes: 'stack grow',
        children: [
          el('strong', text: grant.principal.value),
          el(
            'div',
            classes: 'muted',
            text: [
              (grant.roles.toList()..sort()).join(', '),
              if (grant.note.isNotEmpty) grant.note,
              'issued ${relativeTime(grant.createdAt.toLocal(), now)}',
            ].join(' · '),
          ),
        ],
      ),
      button('Revoke', className: 'danger', onClick: () => _revoke(grant)),
    ],
  );

  void _revoke(Grant grant) {
    late final Modal modal;
    modal = Modal(
      title: 'Revoke ${grant.principal.value}?',
      body: el(
        'div',
        classes: 'stack',
        children: [
          el(
            'div',
            text:
                'The next request presenting this token fails. Anyone using it '
                'right now — a dashboard, a script — stops working immediately.',
          ),
        ],
      ),
      actions: [
        button('Cancel', onClick: () => modal.close()),
        button(
          'Revoke',
          className: 'danger',
          onClick: () async {
            modal.close();
            try {
              await ctx.service.revokeGrant(grant.id);
              ctx.toasts.success('Revoked.');
              await _loadGrants();
            } on AppError catch (e) {
              ctx.toasts.error(e.message);
            }
          },
        ),
      ],
    );
    modal.show();
  }

  void _issueDialog() {
    final principal = input(id: 'grant-principal', placeholder: 'alice');
    final note = input(id: 'grant-note', placeholder: 'who this is for');
    final roles = <String, web.HTMLInputElement>{};

    final roleBoxes = el(
      'div',
      classes: 'stack',
      children: [
        for (final role in const ['viewer', 'operator', 'admin', 'node'])
          () {
            final box = checkbox(_describeRole(role), id: 'role-$role');
            roles[role] = box.box;
            return box.root;
          }(),
      ],
    );

    late final Modal modal;
    modal = Modal(
      title: 'Issue a credential',
      body: el(
        'div',
        classes: 'stack',
        children: [
          field('Principal', principal),
          field(
            'Note',
            note,
            hint: 'Shown in the list; not part of the token.',
          ),
          el('div', classes: 'hint', text: 'Roles'),
          roleBoxes,
        ],
      ),
      actions: [
        button('Cancel', onClick: () => modal.close()),
        button(
          'Issue',
          primary: true,
          onClick: () async {
            final chosen = {
              for (final entry in roles.entries)
                if (entry.value.checked) entry.key,
            };
            if (principal.value.trim().isEmpty || chosen.isEmpty) {
              ctx.toasts.error('Name a principal and at least one role.');
              return;
            }
            modal.close();
            try {
              final issued = await ctx.service.issueGrant(
                principal: principal.value.trim(),
                roles: chosen,
                note: note.value.trim(),
              );
              _showToken(issued.token);
              await _loadGrants();
            } on AppError catch (e) {
              ctx.toasts.error(e.message);
            }
          },
        ),
      ],
    );
    modal.show();
  }

  /// The one moment the token exists in readable form.
  ///
  /// A toast would be wrong here: it disappears. This is a modal the operator has
  /// to dismiss, with a copy button and the reason it cannot be shown again.
  void _showToken(String token) {
    final field = el('div', classes: 'card mono', text: token);

    late final Modal modal;
    modal = Modal(
      title: 'Copy this token now',
      body: el(
        'div',
        classes: 'stack',
        children: [
          el(
            'div',
            text:
                'This is the only time it can be read. The Hub stores a hash of '
                'it, so it cannot be shown again — if it is lost, revoke this '
                'credential and issue another.',
          ),
          field,
        ],
      ),
      actions: [
        button(
          'Copy',
          onClick: () async {
            await defaultClipboardWrite(token);
            ctx.toasts.success('Copied.');
          },
        ),
        button('Done', primary: true, onClick: () => modal.close()),
      ],
    );
    modal.show();
  }

  static String _describeRole(String role) => switch (role) {
    'viewer' => 'viewer — read the fleet, change nothing',
    'operator' => 'operator — also restart, run formulas, apply presets',
    'admin' => 'admin — everything, including issuing credentials',
    _ => 'node — enrol a node; cannot reach the API at all',
  };

  @override
  void dispose() {}
}
