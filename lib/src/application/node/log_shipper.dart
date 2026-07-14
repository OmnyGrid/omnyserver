import 'dart:async';

/// Batches a node's log lines and ships them to the Hub.
///
/// A node agent already knows how to push a [LogBatch]; nothing ever called it,
/// so a node's own log stayed on the node — where you can only read it by logging
/// into the machine, which is the thing a fleet tool exists to avoid.
///
/// Batched rather than sent line by line: a log line is small and a control-frame
/// round trip is not, so a chatty agent would spend more effort announcing what
/// it did than doing it. Lines are flushed when [maxLines] accumulate, or after
/// [interval], whichever comes first — so a burst is coalesced and a trickle
/// still arrives promptly.
///
/// Best-effort by design: if the link is down the lines are dropped rather than
/// queued forever. A node's log tail is for looking at what a machine is doing
/// *now*; a backlog replayed on reconnect would be a different, less useful
/// thing, and an unbounded queue is how an agent runs a machine out of memory.
class LogShipper {
  /// How many lines to accumulate before flushing early.
  final int maxLines;

  /// How long to wait before flushing whatever has accumulated.
  final Duration interval;

  /// Sends a batch. Wired to `NodeAgent.sendLogs`.
  final void Function(List<String> lines) send;

  final List<String> _pending = [];
  Timer? _timer;
  bool _closed = false;

  /// Creates a shipper that hands batches to [send].
  LogShipper({
    required this.send,
    this.maxLines = 50,
    this.interval = const Duration(seconds: 2),
  });

  /// Queues [line] for shipping.
  void add(String line) {
    if (_closed) return;
    _pending.add(line);

    if (_pending.length >= maxLines) {
      flush();
      return;
    }
    _timer ??= Timer(interval, flush);
  }

  /// Ships whatever has accumulated.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;

    final batch = List<String>.of(_pending);
    _pending.clear();
    try {
      send(batch);
    } on Object {
      // The link is down. Dropping the batch is the point: a node's log tail is
      // about what is happening now, and an agent that queues forever is an agent
      // that eventually eats the machine.
    }
  }

  /// Flushes and stops.
  void close() {
    flush();
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
