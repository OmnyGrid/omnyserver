@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

void main() {
  group('MonitorParsers', () {
    test('parseLoadAvg reads the first three fields', () {
      expect(MonitorParsers.parseLoadAvg('0.52 0.58 0.59 1/util 12345'), [
        0.52,
        0.58,
        0.59,
      ]);
    });

    test('parseLinuxMemInfo computes used from total and available', () {
      const meminfo = '''
MemTotal:       16384000 kB
MemFree:         1000000 kB
MemAvailable:    8192000 kB
Buffers:          200000 kB
Cached:          3000000 kB
''';
      final mem = MonitorParsers.parseLinuxMemInfo(meminfo);
      expect(mem.totalBytes, 16384000 * 1024);
      expect(mem.availableBytes, 8192000 * 1024);
      expect(mem.usedBytes, (16384000 - 8192000) * 1024);
      expect(mem.usagePercent, closeTo(50, 0.01));
    });

    test('parseDf skips the header and parses mounts', () {
      const df = '''
Filesystem     1024-blocks      Used Available Capacity Mounted on
/dev/disk1s1     488245288 200000000 288245288      41% /
devfs                  200       200         0     100% /dev
''';
      final devices = MonitorParsers.parseDf(df);
      expect(devices, hasLength(2));
      final root = devices.first;
      expect(root.name, '/');
      expect(root.capacityBytes, 488245288 * 1024);
      expect(root.freeBytes, 288245288 * 1024);
      expect(root.usagePercent, greaterThan(0));
    });

    test('parsePs sorts by cpu and truncates', () {
      const ps = '''
pid pcpu rss comm
101 2.0 100000 bash
102 9.5 200000 dart
103 0.1 50000 sshd
''';
      final procs = MonitorParsers.parsePs(ps, limit: 2);
      expect(procs, hasLength(2));
      expect(procs.first.name, 'dart');
      expect(procs.first.cpuPercent, 9.5);
      expect(procs.first.memoryBytes, 200000 * 1024);
    });
  });

  group('SystemMonitor', () {
    test('snapshot returns a usable status on the host', () async {
      const monitor = SystemMonitor();
      final status = await monitor.snapshot();
      expect(status.os.osName, isNotEmpty);
      expect(status.cpu.coreCount, greaterThan(0));
    });
  });
}
