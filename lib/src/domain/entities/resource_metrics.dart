import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

/// CPU utilisation snapshot for a node.
@immutable
class CpuInfo {
  /// Overall CPU usage as a percentage (0–100).
  final double usagePercent;

  /// Number of logical cores.
  final int coreCount;

  /// Load averages over 1/5/15 minutes (may be empty on platforms without it).
  final List<double> loadAverage;

  /// Creates a CPU snapshot.
  const CpuInfo({
    required this.usagePercent,
    required this.coreCount,
    this.loadAverage = const [],
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'usagePercent': usagePercent,
    'coreCount': coreCount,
    if (loadAverage.isNotEmpty) 'loadAverage': loadAverage,
  };

  /// Decodes from JSON.
  static CpuInfo fromJson(Map<String, dynamic> json) => CpuInfo(
    usagePercent: Json.optDouble(json, 'usagePercent', 0) ?? 0,
    coreCount: Json.optInt(json, 'coreCount', 0) ?? 0,
    loadAverage:
        (json['loadAverage'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        const [],
  );
}

/// Memory utilisation snapshot for a node (bytes).
@immutable
class MemoryInfo {
  /// Total physical memory in bytes.
  final int totalBytes;

  /// Used memory in bytes.
  final int usedBytes;

  /// Available memory in bytes.
  final int availableBytes;

  /// Creates a memory snapshot.
  const MemoryInfo({
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
  });

  /// Usage as a percentage (0–100); 0 when [totalBytes] is 0.
  double get usagePercent =>
      totalBytes == 0 ? 0 : (usedBytes / totalBytes) * 100;

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'totalBytes': totalBytes,
    'usedBytes': usedBytes,
    'availableBytes': availableBytes,
  };

  /// Decodes from JSON.
  static MemoryInfo fromJson(Map<String, dynamic> json) => MemoryInfo(
    totalBytes: Json.optInt(json, 'totalBytes', 0) ?? 0,
    usedBytes: Json.optInt(json, 'usedBytes', 0) ?? 0,
    availableBytes: Json.optInt(json, 'availableBytes', 0) ?? 0,
  );
}

/// A single storage device / mount point snapshot (bytes).
@immutable
class StorageDevice {
  /// The device or mount identifier (e.g. `/`, `C:\`).
  final String name;

  /// Total capacity in bytes.
  final int capacityBytes;

  /// Free space in bytes.
  final int freeBytes;

  /// Creates a storage snapshot.
  const StorageDevice({
    required this.name,
    required this.capacityBytes,
    required this.freeBytes,
  });

  /// Used bytes (capacity minus free).
  int get usedBytes => capacityBytes - freeBytes;

  /// Usage as a percentage (0–100); 0 when [capacityBytes] is 0.
  double get usagePercent =>
      capacityBytes == 0 ? 0 : (usedBytes / capacityBytes) * 100;

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'name': name,
    'capacityBytes': capacityBytes,
    'freeBytes': freeBytes,
  };

  /// Decodes from JSON.
  static StorageDevice fromJson(Map<String, dynamic> json) => StorageDevice(
    name: Json.optString(json, 'name') ?? '',
    capacityBytes: Json.optInt(json, 'capacityBytes', 0) ?? 0,
    freeBytes: Json.optInt(json, 'freeBytes', 0) ?? 0,
  );
}

/// A running process snapshot and its resource consumption.
@immutable
class ProcessInfo {
  /// Process id.
  final int pid;

  /// Executable / command name.
  final String name;

  /// CPU usage as a percentage (0–100).
  final double cpuPercent;

  /// Resident memory in bytes.
  final int memoryBytes;

  /// Creates a process snapshot.
  const ProcessInfo({
    required this.pid,
    required this.name,
    required this.cpuPercent,
    required this.memoryBytes,
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'pid': pid,
    'name': name,
    'cpuPercent': cpuPercent,
    'memoryBytes': memoryBytes,
  };

  /// Decodes from JSON.
  static ProcessInfo fromJson(Map<String, dynamic> json) => ProcessInfo(
    pid: Json.optInt(json, 'pid', 0) ?? 0,
    name: Json.optString(json, 'name') ?? '',
    cpuPercent: Json.optDouble(json, 'cpuPercent', 0) ?? 0,
    memoryBytes: Json.optInt(json, 'memoryBytes', 0) ?? 0,
  );
}
