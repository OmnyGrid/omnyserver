import 'dart:async';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/foundation.dart' show AppError;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';

/// A node's log, tailed live.
///
/// The tail is fetched once to fill the pane and everything after it is pushed,
/// so the pane keeps up with the machine instead of being however stale the last
/// refresh left it. It follows the bottom — a log you have to keep scrolling is a
/// log you stop reading — unless the operator has scrolled up, which is a
/// deliberate act of looking at something, and yanking them back to the bottom
/// would undo it.
class NodeLogs {
  /// The app context.
  final AppContext ctx;

  /// The node whose log this is.
  final String nodeId;

  /// The panel root.
  late final web.HTMLElement element;

  final web.HTMLElement _lines = el('div', classes: 'log-lines');
  late final web.HTMLElement _liveBadge;
  StreamSubscription<LogLine>? _stream;
  bool _disposed = false;

  /// Builds the panel.
  NodeLogs(this.ctx, this.nodeId) {
    _liveBadge = el('span', classes: 'badge', text: 'connecting…');

    element = el(
      'div',
      classes: 'card stack',
      children: [
        el(
          'div',
          classes: 'row',
          children: [
            el('h3', classes: 'grow', text: 'Log'),
            _liveBadge,
          ],
        ),
        _lines,
      ],
    );

    unawaited(_load());
  }

  Future<void> _load() async {
    clearChildren(_lines);
    _lines.appendChild(loadingRow('Loading the log…'));
    try {
      final tail = await ctx.service.logs(nodeId);
      if (_disposed) return;
      clearChildren(_lines);

      if (tail.isEmpty) {
        _lines.appendChild(
          emptyState(
            'This node has reported nothing. It ships its log only when run '
            'with --ship-logs, which is the default.',
          ),
        );
      } else {
        for (final line in tail) {
          _lines.appendChild(_row(line));
        }
        _scrollToBottom();
      }
      _listen();
    } on AppError catch (e) {
      if (_disposed) return;
      clearChildren(_lines);
      _lines.appendChild(errorBanner(e));
    }
  }

  void _listen() {
    _stream = ctx.service.logStream(nodeId).listen(
      _append,
      onError: (Object _) => _setBadge('offline', online: false),
      onDone: () => _setBadge('disconnected', online: false),
    );
    _setBadge('live', online: true);
  }

  void _append(LogLine line) {
    if (_disposed) return;
    // The first live line replaces the "nothing reported" placeholder.
    if (_lines.querySelector('.empty') != null) clearChildren(_lines);

    // Was the operator already at the bottom? Decide *before* appending, or the
    // new line makes the answer no.
    final following = _atBottom();
    _lines.appendChild(_row(line));

    // Bounded: this stream runs for as long as the tab is open.
    while (_lines.childElementCount > 500) {
      _lines.firstElementChild?.remove();
    }
    if (following) _scrollToBottom();
  }

  web.HTMLElement _row(LogLine line) => el(
    'div',
    classes: 'row log-line',
    children: [
      el(
        'span',
        classes: 'muted mono',
        text: line.at.toLocal().toString().split('.').first.split(' ').last,
      ),
      el('span', classes: 'muted', text: line.source),
      el('span', classes: 'grow mono', text: line.message),
    ],
  );

  bool _atBottom() =>
      _lines.scrollHeight - _lines.scrollTop - _lines.clientHeight < 24;

  void _scrollToBottom() => _lines.scrollTop = _lines.scrollHeight;

  void _setBadge(String text, {required bool online}) {
    if (_disposed) return;
    _liveBadge
      ..textContent = text
      ..className = online ? 'badge online' : 'badge offline';
  }

  /// Stops tailing. Cancelling aborts the request, which is how the Hub learns
  /// this client is gone.
  void dispose() {
    _disposed = true;
    unawaited(_stream?.cancel());
  }
}
