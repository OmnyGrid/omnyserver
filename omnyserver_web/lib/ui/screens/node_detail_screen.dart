import 'dart:async';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/client.dart' show AppError, LoadStatus;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';
import '../../state/nodes_controller.dart';
import '../format.dart';
import '../sparkline.dart';

/// One node: what it is, what it is doing, and what you can do to it.
///
/// The live panel is polled rather than pushed — the Hub has no event stream
/// yet — so it keeps the last reading on screen through a failed poll instead of
/// flashing an error and back.
class NodeDetailScreen implements Screen {
  /// The app context.
  final AppContext ctx;

  /// The node id from the route.
  final String nodeId;

  @override
  late final web.HTMLElement element;

  late final NodeStatusController _status;
  late final web.HTMLElement _statusBody;
  late final web.HTMLElement _infoBody;
  late final web.HTMLElement _actionsBody;
  late final web.HTMLElement _historyBody;
  StreamSubscription<void>? _sub;
  Timer? _historyTimer;
  bool _disposed = false;

  /// Builds the screen.
  NodeDetailScreen(this.ctx, this.nodeId) {
    _status = NodeStatusController(ctx.service, nodeId);
    _statusBody = div();
    _infoBody = div();
    _actionsBody = el('div', classes: 'row');
    _historyBody = div();

    element = el(
      'div',
      classes: 'stack',
      children: [
        el(
          'div',
          classes: 'toolbar row',
          children: [
            button('← Fleet', onClick: () => ctx.router.go(Routes.nodes)),
            el('h1', classes: 'grow', text: nodeId),
            button(
              'Open shell',
              onClick: () => ctx.router.go('/nodes/$nodeId/shell'),
            ),
          ],
        ),
        el('div', classes: 'card stack', children: [_infoBody]),
        el(
          'div',
          classes: 'card stack',
          children: [
            el('h3', text: 'Live status'),
            _statusBody,
          ],
        ),
        el(
          'div',
          classes: 'card stack',
          children: [
            el('h3', text: 'Last hour'),
            _historyBody,
          ],
        ),
        el(
          'div',
          classes: 'card stack',
          children: [
            el('h3', text: 'Actions'),
            _actionsBody,
          ],
        ),
      ],
    );

    _renderInfo();
    _renderActions();
    _sub = _status.state.stream.listen((_) => _renderStatus());
    _renderStatus();
    unawaited(_status.start());
    unawaited(_loadDescriptor());
    unawaited(_loadHistory());
    // The Hub records a sample per heartbeat; re-reading every half minute keeps
    // the charts moving without hammering it.
    _historyTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_loadHistory()),
    );
  }

  /// The resource history the Hub has been recording on every heartbeat all
  /// along — and which, until now, nothing ever read back.
  Future<void> _loadHistory() async {
    try {
      final points = await ctx.service.metrics(nodeId, since: '1h');
      if (_disposed) return;
      clearChildren(_historyBody);

      if (points.length < 2) {
        _historyBody.appendChild(
          emptyState(
            'Not enough history yet — samples land on each heartbeat.',
          ),
        );
        return;
      }

      // The API returns newest-first; a chart reads left-to-right in time.
      final series = points.reversed.toList();
      final cpu = [for (final p in series) p.cpuPercent];
      final memory = [for (final p in series) p.memoryPercent ?? 0];
      final disk = [for (final p in series) p.storagePercent ?? 0];

      _historyBody
        ..appendChild(
          sparkline(
            cpu,
            label: 'CPU',
            caption: '${cpu.last.toStringAsFixed(1)}%',
          ),
        )
        ..appendChild(
          sparkline(
            memory,
            label: 'Memory',
            caption: '${memory.last.toStringAsFixed(0)}%',
          ),
        )
        ..appendChild(
          sparkline(
            disk,
            label: 'Disk',
            caption: '${disk.last.toStringAsFixed(0)}%',
          ),
        )
        ..appendChild(
          el(
            'div',
            classes: 'hint',
            text: '${series.length} samples over the last hour.',
          ),
        );
    } on AppError catch (e) {
      if (_disposed) return;
      clearChildren(_historyBody);
      _historyBody.appendChild(errorBanner(e));
    }
  }

  Future<void> _loadDescriptor() async {
    // The fleet list may not be loaded (a deep link straight to this node), so
    // fetch the descriptor rather than assuming it is in memory.
    if (ctx.nodes.byId(nodeId) != null) return;
    try {
      await ctx.nodes.refresh();
      _renderInfo();
    } on AppError {
      // The status panel will surface the failure; the header still works.
    }
  }

  void _renderInfo() {
    final node = ctx.nodes.byId(nodeId);
    clearChildren(_infoBody);
    if (node == null) {
      _infoBody.appendChild(loadingRow('Loading the node…'));
      return;
    }
    _infoBody.appendChild(
      el(
        'div',
        classes: 'row',
        children: [
          el('div', classes: 'grow', text: node.platform.osName),
          statusBadge(online: node.online),
        ],
      ),
    );
    _infoBody.appendChild(
      _facts({
        'Platform':
            '${node.platform.osName} ${node.platform.osVersion} '
            '(${node.platform.architecture})',
        'Hostname': node.platform.hostname,
        'Agent': node.platform.agentVersion,
        if (node.uid != null) 'UID': node.uid!.value,
        if (node.labels.isNotEmpty)
          'Labels': node.labels.entries
              .map((l) => '${l.key}=${l.value}')
              .join(', '),
        'Capabilities': node.capabilities.capabilities.isEmpty
            ? '—'
            : node.capabilities.capabilities.map((c) => c.name).join(', '),
      }),
    );
  }

  void _renderStatus() {
    final state = _status.state.value;
    clearChildren(_statusBody);

    if (state.status == LoadStatus.error && state.data == null) {
      _statusBody.appendChild(errorBanner(state.error!));
      return;
    }
    if (state.status == LoadStatus.loading && state.data == null) {
      _statusBody.appendChild(loadingRow('Reading status…'));
      return;
    }

    final status = state.data;
    if (status == null) {
      // Not an error: a node has no status until its first heartbeat.
      _statusBody.appendChild(
        emptyState('No status yet — waiting for the first heartbeat.'),
      );
      return;
    }

    final memUsed = status.memory.usedBytes;
    final memTotal = status.memory.totalBytes;
    _statusBody.appendChild(
      _facts({
        'CPU':
            '${status.cpu.usagePercent.toStringAsFixed(1)}% '
            'across ${status.cpu.coreCount} cores'
            '${status.cpu.loadAverage.isEmpty ? '' : ' · load '
                      '${status.cpu.loadAverage.map((l) => l.toStringAsFixed(2)).join(' ')}'}',
        'Memory':
            '${formatBytes(memUsed)} / ${formatBytes(memTotal)} '
            '(${percent(memUsed, memTotal)})',
        for (final disk in status.storage)
          'Disk ${disk.name}':
              '${formatBytes(disk.capacityBytes - disk.freeBytes)} / '
              '${formatBytes(disk.capacityBytes)} '
              '(${percent(disk.capacityBytes - disk.freeBytes, disk.capacityBytes)})',
        'Captured': status.capturedAt.toLocal().toString(),
      }),
    );

    if (status.processes.isNotEmpty) {
      _statusBody.appendChild(el('h3', text: 'Processes'));
      _statusBody.appendChild(_processTable(status.processes));
    }
  }

  web.HTMLElement _processTable(List<ProcessInfo> processes) {
    // Busiest first — the reason anyone opens a process table.
    final top = [...processes]
      ..sort((a, b) => b.cpuPercent.compareTo(a.cpuPercent));
    return el(
      'div',
      classes: 'stack',
      children: [
        for (final p in top.take(15))
          el(
            'div',
            classes: 'row',
            children: [
              el('div', classes: 'muted mono', text: '${p.pid}'),
              el('div', classes: 'grow', text: p.name),
              el(
                'div',
                classes: 'mono',
                text: '${p.cpuPercent.toStringAsFixed(1)}%',
              ),
              el('div', classes: 'mono', text: formatBytes(p.memoryBytes)),
            ],
          ),
      ],
    );
  }

  void _renderActions() {
    clearChildren(_actionsBody);
    if (!ctx.auth.state.value.canOperate) {
      _actionsBody.appendChild(
        el(
          'div',
          classes: 'hint',
          text:
              'Your roles do not permit operating the fleet — this is a '
              'read-only view.',
        ),
      );
      return;
    }
    _actionsBody
      ..appendChild(
        button(
          'Restart',
          onClick: () => _confirm(
            'Restart $nodeId?',
            'The agent reconnects on its own.',
            () => ctx.service.restart(nodeId),
            'Restart requested.',
          ),
        ),
      )
      ..appendChild(
        button(
          'Shut down',
          className: 'danger',
          onClick: () => _confirm(
            'Shut down $nodeId?',
            'The node goes offline and will not come back on its own.',
            () => ctx.service.shutdown(nodeId),
            'Shutdown requested.',
          ),
        ),
      )
      ..appendChild(
        button(
          'Update agent',
          onClick: () => _confirm(
            'Update the agent on $nodeId?',
            'The agent updates itself and restarts.',
            () => ctx.service.update(nodeId),
            'Update requested.',
          ),
        ),
      );
  }

  /// Every fleet-changing action is confirmed: these are not undoable, and a
  /// misplaced click shuts down a machine.
  void _confirm(
    String title,
    String detail,
    Future<void> Function() action,
    String done,
  ) {
    late final Modal modal;
    modal = Modal(
      title: title,
      body: el(
        'div',
        classes: 'stack',
        children: [el('div', text: detail)],
      ),
      actions: [
        button('Cancel', onClick: () => modal.close()),
        button(
          'Confirm',
          primary: true,
          onClick: () async {
            modal.close();
            try {
              await action();
              ctx.toasts.success(done);
            } on AppError catch (e) {
              ctx.toasts.error(e.message);
            }
          },
        ),
      ],
    );
    modal.show();
  }

  web.HTMLElement _facts(Map<String, String> facts) => el(
    'div',
    classes: 'stack',
    children: [
      for (final f in facts.entries)
        el(
          'div',
          classes: 'row',
          children: [
            el('div', classes: 'muted', text: f.key),
            el('div', classes: 'grow ellipsis', text: f.value),
          ],
        ),
    ],
  );

  @override
  void dispose() {
    _disposed = true;
    _historyTimer?.cancel();
    _status.dispose();
    unawaited(_sub?.cancel());
  }
}
