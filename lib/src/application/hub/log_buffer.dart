import 'dart:async';

import '../../domain/entities/log_line.dart';

/// The Hub's log sink: a bounded, per-node tail of what nodes have reported,
/// plus a live stream of it.
///
/// **In memory, and bounded on purpose.** Logs are the highest-volume thing a
/// fleet produces, and a Hub that wrote every line of every node to disk would
/// quietly become a log server nobody asked for — filling the disk that the
/// audit trail and the metric history actually need. This is a *tail*: the last
/// [capacityPerNode] lines, for looking at a node that is misbehaving right now.
/// It is not the audit trail (which is persisted, and answers "who did what"),
/// and it is not a substitute for shipping logs somewhere that keeps them.
///
/// Nodes have been able to push log batches since the beginning, and the Hub
/// decoded them and threw them away. This is where they land instead.
class LogBuffer {
  /// How many lines are retained per node.
  final int capacityPerNode;

  final Map<String, List<LogLine>> _lines = {};
  final StreamController<LogLine> _live = StreamController<LogLine>.broadcast();

  /// Creates a buffer retaining [capacityPerNode] lines for each node.
  LogBuffer({this.capacityPerNode = 500});

  /// Every line as it arrives — for tailing.
  Stream<LogLine> get stream => _live.stream;

  /// Records [lines], evicting the oldest beyond the cap.
  void record(Iterable<LogLine> lines) {
    for (final line in lines) {
      final tail = _lines.putIfAbsent(line.nodeId, () => <LogLine>[])
        ..add(line);
      if (tail.length > capacityPerNode) {
        tail.removeRange(0, tail.length - capacityPerNode);
      }
      if (!_live.isClosed) _live.add(line);
    }
  }

  /// The last [tail] lines from [nodeId], oldest first — the order a log is read
  /// in.
  List<LogLine> recentFor(String nodeId, {int tail = 200}) {
    final lines = _lines[nodeId] ?? const <LogLine>[];
    if (lines.length <= tail) return List.of(lines);
    return lines.sublist(lines.length - tail);
  }

  /// Forgets everything a node reported (it was removed, or is being replaced).
  void clear(String nodeId) => _lines.remove(nodeId);

  /// Releases the live stream.
  Future<void> close() => _live.close();
}
