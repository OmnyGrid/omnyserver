import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import 'platform_info.dart';
import 'resource_metrics.dart';

/// A point-in-time live snapshot of a node's health and resource utilisation.
///
/// Assembled by the agent's monitors and reported to the Hub via heartbeats /
/// status reports. Designed to feed future real-time dashboards.
@immutable
class NodeStatus {
  /// When this snapshot was captured (UTC).
  final DateTime capturedAt;

  /// CPU utilisation.
  final CpuInfo cpu;

  /// Memory utilisation.
  final MemoryInfo memory;

  /// Storage devices / mount points.
  final List<StorageDevice> storage;

  /// Operating-system facts.
  final PlatformInfo os;

  /// Top processes by resource consumption (may be truncated).
  final List<ProcessInfo> processes;

  /// Creates a node status snapshot.
  const NodeStatus({
    required this.capturedAt,
    required this.cpu,
    required this.memory,
    required this.storage,
    required this.os,
    this.processes = const [],
  });

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'cpu': cpu.toJson(),
    'memory': memory.toJson(),
    'storage': storage.map((s) => s.toJson()).toList(),
    'os': os.toJson(),
    if (processes.isNotEmpty)
      'processes': processes.map((p) => p.toJson()).toList(),
  };

  /// Decodes from JSON.
  static NodeStatus fromJson(Map<String, dynamic> json) => NodeStatus(
    capturedAt: Json.requireTimestamp(json, 'capturedAt'),
    cpu: CpuInfo.fromJson(Json.asObject(json['cpu'], 'cpu')),
    memory: MemoryInfo.fromJson(Json.asObject(json['memory'], 'memory')),
    storage: Json.optObjectList(
      json,
      'storage',
    ).map(StorageDevice.fromJson).toList(),
    os: PlatformInfo.fromJson(Json.asObject(json['os'], 'os')),
    processes: Json.optObjectList(
      json,
      'processes',
    ).map(ProcessInfo.fromJson).toList(),
  );
}
