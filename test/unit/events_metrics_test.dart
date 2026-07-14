@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

void main() {
  group('OmnyEvent JSON', () {
    final at = DateTime.utc(2026, 7, 13, 12, 30);

    // The Hub encodes these on /events; a client — the dashboard, or anything
    // reading the stream — has to be able to decode them back.
    test('every event type survives a round trip', () {
      final events = <OmnyEvent>[
        NodeConnected(NodeId('worker-01'), at),
        NodeDisconnected(NodeId('worker-01'), at, reason: 'socket closed'),
        HeartbeatReceived(NodeId('worker-01'), 7, at),
        FormulaStarted(NodeId('worker-01'), 'docker', 'install', at),
        FormulaFinished(NodeId('worker-01'), 'docker', 'install', true, at),
        PresetApplied(NodeId('worker-01'), 'docker-host', false, at),
        NodeUpdated(NodeId('worker-01'), 'agent', at),
      ];

      for (final event in events) {
        final decoded = OmnyEvent.fromJson(event.toJson());
        expect(decoded.runtimeType, event.runtimeType);
        expect(decoded.type, event.type);
        expect(decoded.at, event.at);
        expect(decoded.toJson(), event.toJson());
      }
    });

    test('an unknown type is rejected, not silently dropped', () {
      // A client that quietly ignores what it does not understand is how a fleet
      // view goes stale after the Hub learns a new event.
      expect(
        () => OmnyEvent.fromJson({
          'type': 'node.teleported',
          'at': at.toIso8601String(),
          'nodeId': 'worker-01',
        }),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('EventAggregator', () {
    test('records recent events and per-type counts', () async {
      final bus = BroadcastEventBus();
      final agg = EventAggregator()..attach(bus);
      final now = DateTime.utc(2026, 6, 18);
      bus.publish(NodeConnected(NodeId('n1'), now));
      bus.publish(HeartbeatReceived(NodeId('n1'), 1, now));
      bus.publish(HeartbeatReceived(NodeId('n1'), 2, now));
      await Future<void>.delayed(Duration.zero);

      expect(agg.countOf('heartbeat.received'), 2);
      expect(agg.countOf('node.connected'), 1);
      expect(agg.recent(limit: 1).single, isA<HeartbeatReceived>());
      await agg.detach();
      await bus.close();
    });
  });

  group('HubMetrics', () {
    test('renders Prometheus exposition reflecting events', () async {
      final registry = NodeRegistry();
      final bus = BroadcastEventBus();
      final metrics = HubMetrics(registry)..attach(bus);
      final now = DateTime.utc(2026, 6, 18);
      bus.publish(NodeConnected(NodeId('n1'), now));
      bus.publish(HeartbeatReceived(NodeId('n1'), 1, now));
      metrics.recordApiRequest();
      await Future<void>.delayed(Duration.zero);

      final text = metrics.render();
      expect(text, contains('omnyserver_node_connections_total 1'));
      expect(text, contains('omnyserver_heartbeats_total 1'));
      expect(text, contains('omnyserver_api_requests_total 1'));
      expect(text, contains('# TYPE omnyserver_nodes_connected gauge'));
      await metrics.detach();
      await bus.close();
    });
  });
}
