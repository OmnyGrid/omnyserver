import 'dart:io';

import '../../domain/entities/node_status.dart';
import '../../domain/entities/platform_info.dart';
import '../../domain/entities/resource_metrics.dart';
import '../../shared/utils/clock.dart';
import '../../version.dart';
import 'monitor_parsers.dart';

/// Assembles a live [NodeStatus] for the host by probing the OS for CPU,
/// memory, storage, OS facts and top processes.
///
/// Every probe is best-effort and failure-tolerant: if a command is missing or
/// errors, that section degrades to zeros/empties rather than throwing, so a
/// heartbeat always carries a usable snapshot.
class SystemMonitor {
  /// The agent version reported in the OS section.
  final String agentVersion;

  /// Time source.
  final Clock clock;

  /// The maximum number of processes to include.
  final int processLimit;

  /// Creates a system monitor.
  const SystemMonitor({
    this.agentVersion = omnyServerVersion,
    this.clock = const SystemClock(),
    this.processLimit = 20,
  });

  /// Captures a full status snapshot.
  Future<NodeStatus> snapshot() async {
    final results = await Future.wait([
      _cpu(),
      _memory(),
      _storage(),
      _processes(),
    ]);
    return NodeStatus(
      capturedAt: clock.now(),
      cpu: results[0] as CpuInfo,
      memory: results[1] as MemoryInfo,
      storage: results[2] as List<StorageDevice>,
      os: PlatformInfo.local(agentVersion: agentVersion),
      processes: results[3] as List<ProcessInfo>,
    );
  }

  Future<CpuInfo> _cpu() async {
    final cores = Platform.numberOfProcessors;
    var load = <double>[];
    try {
      if (Platform.isLinux) {
        load = MonitorParsers.parseLoadAvg(
          File('/proc/loadavg').readAsStringSync(),
        );
      } else if (Platform.isMacOS) {
        final out = await Process.run('sysctl', ['-n', 'vm.loadavg']);
        load = MonitorParsers.parseLoadAvg(
          (out.stdout as String).replaceAll(RegExp(r'[{}]'), ''),
        );
      }
    } on Object {
      load = const [];
    }
    // Approximate utilisation from the 1-minute load average over core count.
    final usage = load.isEmpty
        ? 0.0
        : (load.first / cores * 100).clamp(0, 100).toDouble();
    return CpuInfo(usagePercent: usage, coreCount: cores, loadAverage: load);
  }

  Future<MemoryInfo> _memory() async {
    try {
      if (Platform.isLinux) {
        return MonitorParsers.parseLinuxMemInfo(
          File('/proc/meminfo').readAsStringSync(),
        );
      } else if (Platform.isMacOS) {
        return _macMemory();
      }
    } on Object {
      // Fall through.
    }
    return const MemoryInfo(totalBytes: 0, usedBytes: 0, availableBytes: 0);
  }

  Future<MemoryInfo> _macMemory() async {
    final totalOut = await Process.run('sysctl', ['-n', 'hw.memsize']);
    final total = int.tryParse((totalOut.stdout as String).trim()) ?? 0;
    final vmOut = await Process.run('vm_stat', const []);
    final text = vmOut.stdout as String;
    final pageMatch = RegExp(r'page size of (\d+) bytes').firstMatch(text);
    final pageSize = pageMatch == null ? 4096 : int.parse(pageMatch.group(1)!);
    int pages(String key) {
      final m = RegExp('$key:\\s+(\\d+)').firstMatch(text);
      return m == null ? 0 : int.parse(m.group(1)!);
    }

    final free = pages('Pages free') * pageSize;
    final inactive = pages('Pages inactive') * pageSize;
    final available = free + inactive;
    final used = (total - available).clamp(0, total);
    return MemoryInfo(
      totalBytes: total,
      usedBytes: used,
      availableBytes: available,
    );
  }

  Future<List<StorageDevice>> _storage() async {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        final out = await Process.run('df', ['-k', '-P']);
        return MonitorParsers.parseDf(out.stdout as String);
      }
    } on Object {
      // Fall through.
    }
    return const [];
  }

  Future<List<ProcessInfo>> _processes() async {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        final out = await Process.run('ps', [
          '-A',
          '-o',
          'pid=,pcpu=,rss=,comm=',
        ]);
        return MonitorParsers.parsePs(
          'pid pcpu rss comm\n${out.stdout}',
          limit: processLimit,
        );
      }
    } on Object {
      // Fall through.
    }
    return const [];
  }
}
