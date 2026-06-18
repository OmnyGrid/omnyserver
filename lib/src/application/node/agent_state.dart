/// The connection lifecycle state of a [NodeAgent].
enum AgentState {
  /// Establishing the connection / performing the handshake.
  connecting,

  /// Connected, authenticated and registered with the Hub.
  connected,

  /// The connection dropped; backing off before the next attempt.
  reconnecting,

  /// Stopped and not attempting to reconnect.
  offline,

  /// Authentication was rejected; will not reconnect until reconfigured.
  authenticationFailed,
}

/// An exponential-backoff policy for reconnection attempts.
class ReconnectPolicy {
  /// The delay before the first retry.
  final Duration initial;

  /// The cap on the delay.
  final Duration max;

  /// The multiplier applied after each failed attempt.
  final double factor;

  /// Creates a reconnect policy.
  const ReconnectPolicy({
    this.initial = const Duration(seconds: 1),
    this.max = const Duration(seconds: 30),
    this.factor = 2.0,
  });

  /// The delay before retry [attempt] (0-based).
  Duration delayFor(int attempt) {
    final millis = initial.inMilliseconds * _pow(factor, attempt);
    final capped = millis.clamp(0, max.inMilliseconds.toDouble());
    return Duration(milliseconds: capped.toInt());
  }

  static double _pow(double base, int exp) {
    var result = 1.0;
    for (var i = 0; i < exp; i++) {
      result *= base;
    }
    return result;
  }
}
