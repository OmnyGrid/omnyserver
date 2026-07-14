import 'dart:async';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/client.dart' show AppError, relativeTime;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';

/// What the Hub has been doing, and who told it to.
///
/// Two feeds, because they answer different questions. *Events* are what happened
/// to the fleet (a node connected, a formula finished) and arrive **live**, over
/// Server-Sent Events — the recent ones are fetched once to fill the pane, and
/// everything after that is pushed. The *audit trail* is who asked for it, and
/// since the Hub verifies a grant rather than believing a header, the principal
/// shown is one it established, not one the caller claimed.
class ActivityScreen implements Screen {
  /// The app context.
  final AppContext ctx;

  @override
  late final web.HTMLElement element;

  late final web.HTMLElement _events;
  late final web.HTMLElement _audit;
  late final web.HTMLElement _liveBadge;
  StreamSubscription<OmnyEvent>? _stream;
  bool _disposed = false;

  /// Builds the screen.
  ActivityScreen(this.ctx) {
    _events = div();
    _audit = div();
    _liveBadge = el('span', classes: 'badge', text: 'connecting…');

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
            el(
              'div',
              classes: 'row',
              children: [
                el('h3', classes: 'grow', text: 'Events'),
                _liveBadge,
              ],
            ),
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
    _listen();
  }

  /// Subscribes to the live stream, so the pane keeps up with the fleet instead
  /// of being however stale the last refresh left it.
  void _listen() {
    unawaited(_stream?.cancel());
    _stream = ctx.service.eventStream().listen(
      _prepend,
      onError: (Object e) {
        if (_disposed) return;
        // The list still holds what was fetched; only the *live* half is gone,
        // so say that rather than blanking the pane.
        _liveBadge
          ..textContent = 'offline'
          ..className = 'badge offline';
      },
      onDone: () {
        if (_disposed) return;
        _liveBadge
          ..textContent = 'disconnected'
          ..className = 'badge offline';
      },
    );
    _liveBadge
      ..textContent = 'live'
      ..className = 'badge online';
  }

  /// Puts a freshly-arrived event at the top of the feed.
  void _prepend(OmnyEvent event) {
    if (_disposed) return;
    // The first live event replaces whatever placeholder the fetch left.
    final placeholder = _events.querySelector('.empty');
    if (placeholder != null) clearChildren(_events);

    _events.insertBefore(_eventRow(event, DateTime.now()), _events.firstChild);

    // Keep the pane bounded: this stream runs for as long as the tab is open.
    while (_events.childElementCount > 100) {
      _events.lastElementChild?.remove();
    }
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
      // Newest first, matching the live feed that prepends onto the same list.
      for (final event in events.take(50)) {
        _events.appendChild(_eventRow(event, now));
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

  /// One row, used for both the fetched history and the live feed, so an event
  /// does not change appearance the moment it stops being new.
  web.HTMLElement _eventRow(OmnyEvent event, DateTime now) => el(
    'div',
    classes: 'row',
    children: [
      el('div', classes: 'mono grow', text: _describe(event.toJson())),
      el('div', classes: 'muted', text: relativeTime(event.at.toLocal(), now)),
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
  void dispose() {
    _disposed = true;
    // Cancelling aborts the fetch, which is how the Hub learns this client is
    // gone rather than waiting for a keep-alive ping to fail.
    unawaited(_stream?.cancel());
  }
}
