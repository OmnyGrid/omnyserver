import 'dart:async';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/client.dart' show AsyncState, LoadStatus;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';

/// The fleet: every registered node, with its platform and online state.
///
/// The cached list paints immediately on reload while the fetch is in flight —
/// a fleet dashboard that blanks for a second on every visit reads as broken.
class NodesScreen implements Screen {
  /// The app context.
  final AppContext ctx;

  @override
  late final web.HTMLElement element;

  late final web.HTMLElement _body;
  late final web.HTMLInputElement _search;
  StreamSubscription<void>? _sub;

  /// Builds the screen.
  NodesScreen(this.ctx) {
    _body = div();
    _search = input(id: 'search', placeholder: 'Filter nodes…');
    on(_search, 'input', (_) => _render());

    element = el(
      'div',
      classes: 'stack',
      children: [
        el(
          'div',
          classes: 'toolbar row',
          children: [
            el('h1', text: 'Fleet'),
            el('div', classes: 'grow'),
            _search,
            button('Refresh', onClick: () => ctx.nodes.refresh()),
          ],
        ),
        _body,
      ],
    );

    _sub = ctx.nodes.state.stream.listen((_) => _render());
    _render();
    unawaited(ctx.nodes.load());
  }

  void _render() {
    final state = ctx.nodes.state.value;
    clearChildren(_body);

    final nodes = state.data;
    if (nodes == null) {
      _body.appendChild(
        state.status == LoadStatus.error
            ? errorBanner(state.error!)
            : loadingRow('Loading the fleet…'),
      );
      return;
    }

    // A refresh that failed still shows the fleet — with a banner above it, so
    // the list on screen is never silently stale.
    if (state.status == LoadStatus.error) {
      _body.appendChild(errorBanner(state.error!));
    }

    if (nodes.isEmpty) {
      _body.appendChild(
        emptyState('No nodes are registered with this Hub yet.'),
      );
      return;
    }

    final query = _search.value.trim().toLowerCase();
    final shown = query.isEmpty
        ? nodes
        : nodes
              .where(
                (n) =>
                    n.id.value.toLowerCase().contains(query) ||
                    n.platform.osName.toLowerCase().contains(query) ||
                    n.labels.entries.any(
                      (l) =>
                          '${l.key}=${l.value}'.toLowerCase().contains(query),
                    ),
              )
              .toList();

    if (shown.isEmpty) {
      _body.appendChild(emptyState('No node matches "$query".'));
      return;
    }

    // Offline nodes first: they are the ones that need attention.
    final sorted = [...shown]
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? 1 : -1;
        return a.id.value.compareTo(b.id.value);
      });

    for (final node in sorted) {
      _body.appendChild(_row(node));
    }
  }

  web.HTMLElement _row(NodeDescriptor node) => el(
    'div',
    classes: 'card list-item row',
    onClick: (_) => ctx.router.go('/nodes/${node.id.value}'),
    children: [
      el(
        'div',
        classes: 'stack grow',
        children: [
          el('strong', text: node.id.value),
          el(
            'div',
            classes: 'muted',
            text: [
              node.platform.osName,
              if (node.platform.architecture.isNotEmpty)
                node.platform.architecture,
              if (node.labels.isNotEmpty)
                node.labels.entries.map((l) => '${l.key}=${l.value}').join(' '),
            ].join(' · '),
          ),
        ],
      ),
      statusBadge(online: node.online),
    ],
  );

  @override
  void dispose() {
    unawaited(_sub?.cancel());
  }
}

/// Keeps the import of [AsyncState] meaningful to readers of this file.
typedef NodesState = AsyncState<List<NodeDescriptor>>;
