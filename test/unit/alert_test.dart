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

    test('seconds and hours, not only minutes', () {
      expect(
        AlertRule.parse('cpu>90 for 30s').duration,
        const Duration(seconds: 30),
      );
      expect(
        AlertRule.parse('cpu>90 for 2h').duration,
        const Duration(hours: 2),
      );
    });

    test('a rule survives the wire', () {
      final rule = AlertRule.parse('cpu>95 for 5m');
      final back = AlertRule.fromJson(rule.toJson());
      expect(back.id, rule.id);
      expect(back.metric, AlertMetric.cpu);
      expect(back.threshold, 95);
      expect(back.duration, const Duration(minutes: 5));

      expect(
        () => AlertMetric.parse('humidity'),
        throwsA(isA<ProtocolException>()),
        reason: 'an unknown metric on the wire is not silently dropped',
      );
    });
  });

  group('what a rule counts as a breach', () {
    MetricPoint point({
      double cpu = 0,
      int memUsed = 0,
      int memTotal = 0,
      int diskUsed = 0,
      int diskTotal = 0,
    }) => MetricPoint(
      at: DateTime.utc(2026, 1, 1),
      cpuPercent: cpu,
      memoryUsedBytes: memUsed,
      memoryTotalBytes: memTotal,
      storageUsedBytes: diskUsed,
      storageCapacityBytes: diskTotal,
    );

    test('each metric reads its own number', () {
      expect(AlertRule.parse('cpu>90').breachedBy(point(cpu: 95)), isTrue);
      expect(
        AlertRule.parse('cpu>90').breachedBy(point(cpu: 90)),
        isFalse,
        reason: 'the threshold is a floor to exceed, not to reach',
      );

      final memory = AlertRule.parse('memory>50');
      expect(memory.breachedBy(point(memUsed: 900, memTotal: 1000)), isTrue);
      expect(memory.breachedBy(point(memUsed: 100, memTotal: 1000)), isFalse);

      final disk = AlertRule.parse('disk>80');
      expect(disk.breachedBy(point(diskUsed: 900, diskTotal: 1000)), isTrue);
      expect(disk.breachedBy(point(diskUsed: 100, diskTotal: 1000)), isFalse);
    });

    test('a metric the host did not report is not a breach', () {
      // memoryPercent and storagePercent are null on a host that reports no
      // totals; treating null as 0 keeps a missing reading quiet rather than
      // alerting on an absence.
      expect(AlertRule.parse('memory>50').breachedBy(point()), isFalse);
      expect(AlertRule.parse('disk>50').breachedBy(point()), isFalse);
    });

    test('offline is never decided by a sample', () {
      // It is decided by the absence of samples, so no MetricPoint can breach
      // it — including one that looks alarming.
      expect(
        AlertRule.parse('offline for 2m').breachedBy(point(cpu: 100)),
        isFalse,
      );
    });
  });

  group('an alert says what is wrong, in words', () {
    final rule = AlertRule.parse('disk>90');

    test('a threshold breach names the metric, value and limit', () {
      final alert = Alert(
        rule: rule,
        nodeId: 'worker-01',
        since: DateTime.utc(2026, 1, 1, 9),
        value: 94.6,
      );
      expect(alert.message, 'worker-01 disk is 95% (over 90%)');
      expect(alert.toString(), alert.message);
    });

    test('a value nobody reported is not invented', () {
      final alert = Alert(
        rule: rule,
        nodeId: 'worker-01',
        since: DateTime.utc(2026, 1, 1, 9),
      );
      expect(alert.message, contains('?%'));
    });

    test('offline reads as a duration, not a percentage', () {
      expect(
        Alert(
          rule: AlertRule.parse('offline for 2m'),
          nodeId: 'worker-01',
          since: DateTime.utc(2026, 1, 1, 9),
        ).message,
        'worker-01 has been offline for 2m',
      );
      expect(
        Alert(
          rule: AlertRule.parse('offline for 90s'),
          nodeId: 'worker-01',
          since: DateTime.utc(2026, 1, 1, 9),
        ).message,
        contains('1m'),
      );
      expect(
        Alert(
          rule: AlertRule.parse('offline for 3h'),
          nodeId: 'worker-01',
          since: DateTime.utc(2026, 1, 1, 9),
        ).message,
        contains('3h'),
      );
    });

    test('round-trips, message included, so a client need not rebuild it', () {
      final alert = Alert(
        rule: rule,
        nodeId: 'worker-01',
        since: DateTime.utc(2026, 1, 1, 9),
        value: 94.6,
      );
      final json = alert.toJson();
      expect(json['message'], alert.message);

      final back = Alert.fromJson(json);
      expect(back.nodeId, 'worker-01');
      expect(back.value, 94.6);
      expect(back.rule.metric, AlertMetric.disk);
      expect(back.since, alert.since);
    });
  });
}
