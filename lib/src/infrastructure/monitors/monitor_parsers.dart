import '../../domain/entities/resource_metrics.dart';

/// Pure parsers for the textual output of the system probes the monitors run.
///
/// Kept side-effect-free (no process spawning) so they can be unit-tested with
/// captured sample output across platforms.
class MonitorParsers {
  const MonitorParsers._();

  /// Parses `/proc/loadavg` (Linux) — the first three fields are the 1/5/15
  /// minute load averages.
  static List<double> parseLoadAvg(String content) {
    final parts = content.trim().split(RegExp(r'\s+'));
    final out = <double>[];
    for (var i = 0; i < parts.length && i < 3; i++) {
      final v = double.tryParse(parts[i]);
      if (v != null) out.add(v);
    }
    return out;
  }

  /// Parses `/proc/meminfo` (Linux) into a [MemoryInfo] (values are in kB).
  static MemoryInfo parseLinuxMemInfo(String content) {
    int field(String key) {
      final match = RegExp(
        '^$key:\\s+(\\d+)',
        multiLine: true,
      ).firstMatch(content);
      return match == null ? 0 : (int.tryParse(match.group(1)!) ?? 0) * 1024;
    }

    final total = field('MemTotal');
    var available = field('MemAvailable');
    if (available == 0) {
      available = field('MemFree') + field('Buffers') + field('Cached');
    }
    final used = (total - available).clamp(0, total);
    return MemoryInfo(
      totalBytes: total,
      usedBytes: used,
      availableBytes: available,
    );
  }

  /// Parses POSIX `df -k -P` output into storage devices (sizes in 1 KiB
  /// blocks). The header line is skipped.
  static List<StorageDevice> parseDf(String content) {
    final lines = content.trim().split('\n');
    final out = <StorageDevice>[];
    for (final line in lines.skip(1)) {
      final cols = line.trim().split(RegExp(r'\s+'));
      if (cols.length < 6) continue;
      final capacity = (int.tryParse(cols[1]) ?? 0) * 1024;
      final available = (int.tryParse(cols[3]) ?? 0) * 1024;
      final mount = cols.sublist(5).join(' ');
      if (capacity == 0) continue;
      out.add(
        StorageDevice(
          name: mount,
          capacityBytes: capacity,
          freeBytes: available,
        ),
      );
    }
    return out;
  }

  /// Parses POSIX `ps` output with columns `pid %cpu rss comm` (rss in kB).
  /// The header line is skipped. Results are sorted by CPU descending and
  /// truncated to [limit].
  static List<ProcessInfo> parsePs(String content, {int limit = 20}) {
    final lines = content.trim().split('\n');
    final out = <ProcessInfo>[];
    for (final line in lines.skip(1)) {
      final cols = line.trim().split(RegExp(r'\s+'));
      if (cols.length < 4) continue;
      final pid = int.tryParse(cols[0]) ?? 0;
      final cpu = double.tryParse(cols[1]) ?? 0;
      final rss = (int.tryParse(cols[2]) ?? 0) * 1024;
      final name = cols.sublist(3).join(' ');
      if (pid == 0) continue;
      out.add(
        ProcessInfo(pid: pid, name: name, cpuPercent: cpu, memoryBytes: rss),
      );
    }
    out.sort((a, b) => b.cpuPercent.compareTo(a.cpuPercent));
    return out.take(limit).toList();
  }
}
