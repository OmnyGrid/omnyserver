import 'dart:async';
import 'dart:convert';

import 'package:omnyserver/omnyserver_client_web.dart';
// The DOM-free barrel: this layer holds no elements, so it stays unit-testable
// on the VM.
import 'package:omnyshell_web/foundation.dart'
    show AppError, AsyncState, KeyValueStore, Observable;

import '../core/omnyserver_service.dart';

/// The fleet: the node list, cached so the grid paints instantly on reload.
class NodesController {
  final OmnyServerService _service;
  final KeyValueStore _kv;
  final String _cacheKey;

  /// The observable node list.
  final Observable<AsyncState<List<NodeDescriptor>>> state = Observable(
    const AsyncState.idle(),
  );

  /// Creates the controller. [prefix] namespaces the cache — `localStorage` is
  /// per-origin, and one Hub can serve this dashboard *and* the OmnyShell app.
  NodesController(this._service, this._kv, {String prefix = 'omnyserver.'})
    : _cacheKey = '${prefix}cache.nodes';

  /// Loads the fleet, painting the cache first so the grid is never empty while
  /// the network is in flight.
  Future<void> load() async {
    final cached = _readCache();
    state.value = cached == null
        ? const AsyncState.loading()
        : AsyncState.loading(data: cached, stale: true);
    await refresh();
  }

  /// Re-fetches, keeping the last-known list visible under the spinner.
  Future<void> refresh() async {
    final previous = state.value.data;
    state.value = AsyncState.loading(data: previous, stale: previous != null);
    try {
      final nodes = await _service.listNodes();
      _writeCache(nodes);
      state.value = AsyncState.ready(nodes);
    } on AppError catch (e) {
      // Keep showing what we had: a failed refresh should not blank the fleet.
      state.value = AsyncState.error(e, data: previous);
    }
  }

  /// The node with [id] from the loaded list, if present.
  NodeDescriptor? byId(String id) {
    for (final n in state.value.data ?? const <NodeDescriptor>[]) {
      if (n.id.value == id) return n;
    }
    return null;
  }

  /// Clears the list and its cache (on sign-out).
  void reset() {
    _kv.remove(_cacheKey);
    state.value = const AsyncState.idle();
  }

  List<NodeDescriptor>? _readCache() {
    final raw = _kv.read(_cacheKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return [
        for (final n in decoded)
          NodeDescriptor.fromJson((n as Map).cast<String, dynamic>()),
      ];
    } on Object {
      return null; // A corrupt cache is a cold cache, never an error.
    }
  }

  void _writeCache(List<NodeDescriptor> nodes) {
    try {
      _kv.write(_cacheKey, jsonEncode([for (final n in nodes) n.toJson()]));
    } on Object {
      // Storage full or blocked: the fleet still works, it just paints cold.
    }
  }
}

/// One node's live status, polled while its screen is open.
///
/// Polling, not pushing: the Hub's `/events` is a snapshot and there is no live
/// stream yet (a Server-Sent Events endpoint is the next step — omnyhub 1.6.0
/// can already serve one). Until then the interval is the honest mechanism.
class NodeStatusController {
  final OmnyServerService _service;

  /// How often the status is re-read.
  final Duration interval;

  /// The node this controller watches.
  final String nodeId;

  /// The observable status. `null` data means the node has not heartbeated yet.
  final Observable<AsyncState<NodeStatus?>> state = Observable(
    const AsyncState.idle(),
  );

  Timer? _timer;
  bool _disposed = false;

  /// Creates a controller for [nodeId].
  NodeStatusController(
    this._service,
    this.nodeId, {
    this.interval = const Duration(seconds: 5),
  });

  /// Fetches now, then keeps fetching until [dispose].
  Future<void> start() async {
    await _poll();
    _timer = Timer.periodic(interval, (_) => _poll());
  }

  Future<void> _poll() async {
    if (_disposed) return;
    final previous = state.value.data;
    try {
      final status = await _service.status(nodeId);
      if (_disposed) return;
      state.value = AsyncState.ready(status);
    } on AppError catch (e) {
      if (_disposed) return;
      // A transient failure keeps the last reading on screen rather than
      // flashing the panel to an error and back.
      state.value = AsyncState.error(e, data: previous);
    }
  }

  /// Stops polling.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
