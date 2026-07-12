import 'dart:async';

import 'package:omnyhub/omnyhub.dart' show NodeRegistry;

import '../../domain/events/event_bus.dart';
import '../../domain/events/omny_event.dart';
import '../../infrastructure/metrics/metrics_registry.dart';

/// Wires Hub lifecycle/operational events and live registry state into a
/// [MetricsRegistry], producing Prometheus-ready metrics:
///
/// * `omnyserver_nodes_connected` (gauge) — currently online nodes
/// * `omnyserver_node_connections_total` (counter)
/// * `omnyserver_heartbeats_total` (counter)
/// * `omnyserver_formula_runs_total` (counter)
/// * `omnyserver_presets_applied_total` (counter)
/// * `omnyserver_api_requests_total` (counter, incremented by the HTTP API)
class HubMetrics {
  /// The underlying registry (exposed for the HTTP API to render/scrape).
  final MetricsRegistry registry;

  final NodeRegistry _nodes;
  StreamSubscription<OmnyEvent>? _subscription;

  /// Creates Hub metrics over [registry], reading liveness from a
  /// [NodeRegistry].
  HubMetrics(this._nodes, {MetricsRegistry? registry})
    : registry = registry ?? MetricsRegistry() {
    this.registry
      ..describe('omnyserver_nodes_connected', 'Currently online nodes')
      ..describe('omnyserver_node_connections_total', 'Node connections')
      ..describe('omnyserver_heartbeats_total', 'Heartbeats received')
      ..describe('omnyserver_formula_runs_total', 'Formula runs')
      ..describe('omnyserver_presets_applied_total', 'Presets applied')
      ..describe('omnyserver_api_requests_total', 'HTTP API requests')
      ..registerGauge(
        'omnyserver_nodes_connected',
        () => _nodes.discover().length.toDouble(),
      );
  }

  /// Begins observing [bus].
  void attach(EventBus bus) {
    _subscription = bus.events.listen(_onEvent);
  }

  void _onEvent(OmnyEvent event) {
    switch (event) {
      case NodeConnected():
        registry.incrementCounter('omnyserver_node_connections_total');
      case HeartbeatReceived():
        registry.incrementCounter('omnyserver_heartbeats_total');
      case FormulaFinished():
        registry.incrementCounter('omnyserver_formula_runs_total');
      case PresetApplied():
        registry.incrementCounter('omnyserver_presets_applied_total');
      default:
        break;
    }
  }

  /// Records an HTTP API request (called by the HTTP layer).
  void recordApiRequest() =>
      registry.incrementCounter('omnyserver_api_requests_total');

  /// Renders the Prometheus exposition.
  String render() => registry.render();

  /// Stops observing events.
  Future<void> detach() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
