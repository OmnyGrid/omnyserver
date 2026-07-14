import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import 'node_status.dart';

/// One node's resource usage at an instant — the chartable projection of a
/// [NodeStatus].
///
/// The Hub stores a whole `NodeStatus` per heartbeat, process table included. A
/// day of history is thousands of those, and a chart needs none of it: this is
/// the handful of numbers a series is actually drawn from, so asking for a
/// node's history costs kilobytes rather than megabytes.
@immutable
class MetricPoint {
  /// When the sample was captured (UTC).
  final DateTime at;

  /// CPU usage across all cores, as a percentage.
  final double cpuPercent;

  /// The 1-minute load average, when the platform reports one.
  final double? loadAverage;

  /// Memory in use, in bytes.
  final int memoryUsedBytes;

  /// Total memory, in bytes.
  final int memoryTotalBytes;

  /// Storage in use across every device, in bytes.
  final int storageUsedBytes;

  /// Total storage capacity across every device, in bytes.
  final int storageCapacityBytes;

  /// Creates a point.
  const MetricPoint({
    required this.at,
    required this.cpuPercent,
    this.loadAverage,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
    required this.storageUsedBytes,
    required this.storageCapacityBytes,
  });

  /// Projects a full [status] snapshot down to its chartable numbers.
  ///
  /// Storage is summed across devices: a fleet view asks "is this machine
  /// filling up", not "which partition".
  factory MetricPoint.fromStatus(NodeStatus status) {
    var capacity = 0;
    var free = 0;
    for (final device in status.storage) {
      capacity += device.capacityBytes;
      free += device.freeBytes;
    }
    return MetricPoint(
      at: status.capturedAt,
      cpuPercent: status.cpu.usagePercent,
      loadAverage: status.cpu.loadAverage.isEmpty
          ? null
          : status.cpu.loadAverage.first,
      memoryUsedBytes: status.memory.usedBytes,
      memoryTotalBytes: status.memory.totalBytes,
      storageUsedBytes: capacity - free,
      storageCapacityBytes: capacity,
    );
  }

  /// Memory in use as a percentage, or `null` when the total is unknown.
  double? get memoryPercent =>
      memoryTotalBytes <= 0 ? null : memoryUsedBytes / memoryTotalBytes * 100;

  /// Storage in use as a percentage, or `null` when the capacity is unknown.
  double? get storagePercent => storageCapacityBytes <= 0
      ? null
      : storageUsedBytes / storageCapacityBytes * 100;

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'cpuPercent': cpuPercent,
    'loadAverage': ?loadAverage,
    'memoryUsedBytes': memoryUsedBytes,
    'memoryTotalBytes': memoryTotalBytes,
    'storageUsedBytes': storageUsedBytes,
    'storageCapacityBytes': storageCapacityBytes,
  };

  /// Decodes from JSON.
  static MetricPoint fromJson(Map<String, dynamic> json) => MetricPoint(
    at: Json.requireTimestamp(json, 'at'),
    cpuPercent: Json.requireDouble(json, 'cpuPercent'),
    loadAverage: Json.optDouble(json, 'loadAverage'),
    memoryUsedBytes: Json.requireInt(json, 'memoryUsedBytes'),
    memoryTotalBytes: Json.requireInt(json, 'memoryTotalBytes'),
    storageUsedBytes: Json.requireInt(json, 'storageUsedBytes'),
    storageCapacityBytes: Json.requireInt(json, 'storageCapacityBytes'),
  );

  @override
  String toString() =>
      'MetricPoint($at, cpu ${cpuPercent.toStringAsFixed(1)}%)';
}
