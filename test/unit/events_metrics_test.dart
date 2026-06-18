@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

void main() {
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
