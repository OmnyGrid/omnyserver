import 'dart:async';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/client.dart' show AppError, relativeTime;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';

/// What the Hub has been doing, and who told it to.
///
/// Two feeds side by side, because they answer different questions. *Events* are
/// what happened to the fleet (a node connected, a formula finished). The *audit
/// trail* is who asked for it — and since the Hub verifies a grant rather than
/// believing a header, the principal shown here is one it established, not one
/// the caller claimed.
class ActivityScreen implements Screen {
  /// The app context.
  final AppContext ctx;

  @override
  late final web.HTMLElement element;

  late final web.HTMLElement _events;
  late final web.HTMLElement _audit;

  /// Builds the screen.
  ActivityScreen(this.ctx) {
    _events = div();
    _audit = div();

    element = el(
      'div',
      classes: 'stack',
      children: [
        el(
          'div',
          classes: 'toolbar row',
          children: [
            el('h1', classes: 'grow', text: 'Activity'),
            button('Refresh', onClick: _load),
          ],
        ),
        el(
          'div',
          classes: 'card stack',
          children: [
            el('h3', text: 'Events'),
            _events,
          ],
        ),
        el(
          'div',
          classes: 'card stack',
          children: [
            el('h3', text: 'Audit trail'),
            _audit,
          ],
        ),
      ],
    );

    _load();
  }

  void _load() {
    unawaited(_loadEvents());
    unawaited(_loadAudit());
  }

  Future<void> _loadEvents() async {
    clearChildren(_events);
    _events.appendChild(loadingRow('Loading events…'));
    try {
      final events = await ctx.service.events();
      clearChildren(_events);
      if (events.isEmpty) {
        _events.appendChild(emptyState('Nothing has happened yet.'));
        return;
      }
      final now = DateTime.now();
      for (final event in events.reversed.take(50)) {
        final json = event.toJson();
        _events.appendChild(
          el(
            'div',
            classes: 'row',
            children: [
              el('div', classes: 'mono grow', text: _describe(json)),
              el(
                'div',
                classes: 'muted',
                text: relativeTime(event.at.toLocal(), now),
              ),
            ],
          ),
        );
      }
    } on AppError catch (e) {
      clearChildren(_events);
      _events.appendChild(errorBanner(e));
    }
  }

  Future<void> _loadAudit() async {
    clearChildren(_audit);
    _audit.appendChild(loadingRow('Loading the audit trail…'));
    try {
      final entries = await ctx.service.audit();
      clearChildren(_audit);
      if (entries.isEmpty) {
        _audit.appendChild(emptyState('No audited actions yet.'));
        return;
      }
      final now = DateTime.now();
      for (final entry in entries.take(50)) {
        _audit.appendChild(_auditRow(entry, now));
      }
    } on AppError catch (e) {
      clearChildren(_audit);
      _audit.appendChild(errorBanner(e));
    }
  }

  web.HTMLElement _auditRow(AuditEntry entry, DateTime now) => el(
    'div',
    classes: 'row',
    children: [
      el('div', classes: 'mono', text: entry.principal),
      el(
        'div',
        classes: 'grow',
        text: [
          entry.action,
          if (entry.target != null) entry.target!,
        ].join(' · '),
      ),
      el('div', classes: 'muted', text: entry.outcome.name),
      el('div', classes: 'muted', text: relativeTime(entry.at.toLocal(), now)),
    ],
  );

  /// An event's own JSON is the most faithful description of it — the payload
  /// differs per type, and inventing a sentence per type would drift.
  String _describe(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? 'event';
    final rest = {...json}
      ..remove('type')
      ..remove('at');
    if (rest.isEmpty) return type;
    return '$type  ${rest.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
  }

  @override
  void dispose() {}
}
