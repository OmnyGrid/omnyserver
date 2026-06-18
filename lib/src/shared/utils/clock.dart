/// Time source used throughout OmnyServer so tests can fix `now`.
///
/// Heartbeat watchdogs, keepalive timers and reconnection backoff depend on a
/// [Clock] rather than calling [DateTime.now] directly, which keeps their
/// behaviour deterministic under test.
abstract class Clock {
  /// The current instant, in UTC.
  DateTime now();
}

/// The default [Clock], backed by the system wall clock (UTC).
class SystemClock implements Clock {
  /// Creates a system clock.
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}
