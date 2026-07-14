import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Alerting, and the one distinction the whole thing rests on: **a condition is
/// not an alert**.
///
/// A node at 95% CPU for one heartbeat is a build running. At 95% for five
/// minutes it is a problem. A tool that cannot tell those apart produces noise,
/// and an operator who has learned to ignore alerts has no alerting at all.
void main() {
  late FixedClock clock;
  late BroadcastEventBus bus;
  late List<OmnyEvent> events;

  setUp(() {
    clock = FixedClock(DateTime.utc(2026, 1, 1, 9));
    bus = BroadcastEventBus();
    events = [];
    bus.events.listen(events.add);
  });

  AlertMonitor monitorFor(String rule) =>
      AlertMonitor(rules: [AlertRule.parse(rule)], eventBus: bus, clock: clock);

  MetricPoint point({double cpu = 0, int diskUsed = 0, int diskTotal = 100}) =>
      MetricPoint(
        at: clock.now(),
        cpuPercent: cpu,
        memoryUsedBytes: 0,
        memoryTotalBytes: 100,
        storageUsedBytes: diskUsed,
        storageCapacityBytes: diskTotal,
      );

  /// Lets the event listener run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('a condition is not an alert', () {
    test('a breach that has not held long enough raises nothing', () async {
      final monitor = monitorFor('cpu>90 for 5m');

      monitor.onStatus('worker-01', point(cpu: 95));
      await settle();

      // Observed, but not announced: this is a build, until it isn't.
      expect(monitor.active, isEmpty);
      expect(events, isEmpty);
    });

    test('the same breach, once it has held, is raised', () async {
      final monitor = monitorFor('cpu>90 for 5m');

      monitor.onStatus('worker-01', point(cpu: 95));
      clock.current = clock.current.add(const Duration(minutes: 6));
      monitor.onStatus('worker-01', point(cpu: 95));
      await settle();

      expect(monitor.active, hasLength(1));
      expect(monitor.active.single.message, contains('cpu is 95%'));
      expect(events.whereType<AlertRaised>(), hasLength(1));
    });

    test(
      'a breach that goes away before it holds is never mentioned',
      () async {
        final monitor = monitorFor('cpu>90 for 5m');

        monitor.onStatus('worker-01', point(cpu: 95));
        clock.current = clock.current.add(const Duration(minutes: 1));
        monitor.onStatus('worker-01', point(cpu: 10));

        clock.current = clock.current.add(const Duration(minutes: 10));
        monitor.onStatus('worker-01', point(cpu: 10));
        await settle();

        expect(monitor.active, isEmpty);
        expect(events, isEmpty);
      },
    );

    test('a rule with no duration fires at once', () async {
      final monitor = monitorFor('disk>90');
      monitor.onStatus('worker-01', point(diskUsed: 95));
      await settle();

      expect(monitor.active.single.message, contains('disk is 95%'));
    });
  });

  group('raising and resolving', () {
    test('an alert is announced once, not on every heartbeat', () async {
      final monitor = monitorFor('disk>90');

      for (var i = 0; i < 5; i++) {
        monitor.onStatus('worker-01', point(diskUsed: 95));
      }
      await settle();

      // An alert that repeats itself every heartbeat is an alert that gets muted.
      expect(events.whereType<AlertRaised>(), hasLength(1));
      expect(monitor.active, hasLength(1));
    });

    test('recovering resolves it — and says so', () async {
      final monitor = monitorFor('disk>90');

      monitor.onStatus('worker-01', point(diskUsed: 95));
      monitor.onStatus('worker-01', point(diskUsed: 50));
      await settle();

      expect(monitor.active, isEmpty);
      // The counterpart matters: an alert that fires and never clears teaches an
      // operator to ignore alerts.
      expect(events.whereType<AlertResolved>(), hasLength(1));
    });

    test('the alert holds the value, and when the condition began', () async {
      final monitor = monitorFor('disk>90');
      final began = clock.current;

      monitor.onStatus('worker-01', point(diskUsed: 95));
      clock.current = clock.current.add(const Duration(minutes: 10));
      monitor.onStatus('worker-01', point(diskUsed: 97));
      await settle();

      final alert = monitor.active.single;
      expect(alert.value, 97);
      // Since the condition started, not since the alert fired: the first is a
      // fact about the machine.
      expect(alert.since, began);
    });
  });

  group('offline', () {
    test(
      'a node gone long enough alerts — an absence sends no events',
      () async {
        final monitor = monitorFor('offline for 2m');

        monitor.onDisconnected('worker-01');
        await settle();
        expect(monitor.active, isEmpty, reason: 'not gone long enough yet');

        clock.current = clock.current.add(const Duration(minutes: 3));
        // Nothing arrives from a node that is gone, so something has to look.
        monitor.tick();
        await settle();

        expect(monitor.active.single.message, contains('offline'));
        expect(events.whereType<AlertRaised>(), hasLength(1));
      },
    );

    test('coming back resolves it', () async {
      final monitor = monitorFor('offline for 0s');

      monitor.onDisconnected('worker-01');
      await settle();
      expect(monitor.active, hasLength(1));

      monitor.onConnected('worker-01');
      await settle();
      expect(monitor.active, isEmpty);
      expect(events.whereType<AlertResolved>(), hasLength(1));
    });
  });

  group('rules are parsed from what an operator can type', () {
    test('the three shapes', () {
      expect(AlertRule.parse('disk>90').metric, AlertMetric.disk);
      expect(AlertRule.parse('disk>90').threshold, 90);
      expect(AlertRule.parse('disk>90').duration, Duration.zero);

      final held = AlertRule.parse('cpu>95 for 5m');
      expect(held.metric, AlertMetric.cpu);
      expect(held.duration, const Duration(minutes: 5));

      final offline = AlertRule.parse('offline for 2m');
      expect(offline.metric, AlertMetric.offline);
      expect(offline.duration, const Duration(minutes: 2));
    });

    test('nonsense is rejected rather than guessed at', () {
      expect(() => AlertRule.parse('disk'), throwsA(isA<ProtocolException>()));
      expect(
        () => AlertRule.parse('humidity>90'),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => AlertRule.parse('cpu>95 for ages'),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}
