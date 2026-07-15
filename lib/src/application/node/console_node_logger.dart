import 'package:omnyhub/omnyhub_node.dart' as omnyhub;

/// Bridges the node runtime's structured [omnyhub.Logger] to a plain line sink
/// (the CLI's stdout), so what the Hub tells a node actually reaches the
/// operator.
///
/// The runtime already emits the useful things — a Hub rejection with its code
/// and message (`principal … may not register node …`), a connection failure
/// with its cause — but its default logger is a [omnyhub.NoopLogger], so
/// embedding OmnyServer prints nothing unless asked. Without this, a node that
/// authenticates and is then refused registration retries in total silence.
///
/// [minLevel] gates verbosity: the default surfaces only problems
/// ([omnyhub.LogLevel.warn] and up); `--verbose` lowers it to see the lifecycle.
/// Consecutive identical lines are collapsed, so a node that keeps retrying a
/// rejection it cannot fix says why once, not once per backoff.
class ConsoleNodeLogger with omnyhub.LoggerBase {
  /// Where formatted lines go — typically the CLI's stdout writer.
  final void Function(String message) sink;

  /// The lowest severity that is emitted.
  final omnyhub.LogLevel minLevel;

  /// How many recent lines are remembered for de-duplication. A failing node
  /// re-emits the same handful each backoff (the rejection, the drop); holding a
  /// few is enough to say each once and then fall quiet until something changes.
  static const int _recentWindow = 8;

  final List<String> _recent = [];

  /// Creates a logger writing to [sink].
  ConsoleNodeLogger(this.sink, {this.minLevel = omnyhub.LogLevel.warn});

  @override
  void log(
    omnyhub.LogLevel level,
    String message, {
    Map<String, Object?> context = const {},
  }) {
    if (!(level >= minLevel)) return;
    final line = _format(message, context);
    if (_recent.contains(line)) return;
    _recent.add(line);
    if (_recent.length > _recentWindow) _recent.removeAt(0);
    sink(line);
  }

  /// The runtime tags its records; translate the ones that carry a cause into a
  /// sentence, and fall back to `message (k=v, …)` for the rest.
  String _format(String message, Map<String, Object?> context) {
    final code = context['code'];
    final detail = context['message'];
    if (code != null) {
      // A NodeErrorMessage from the Hub — the rejection reason we were dropping.
      return detail == null || '$detail'.isEmpty
          ? 'hub rejected the connection ($code)'
          : 'hub rejected the connection ($code): $detail';
    }
    final error = context['error'];
    if (error != null) return '$message: $error';
    if (context.isEmpty) return message;
    final rest = context.entries.map((e) => '${e.key}=${e.value}').join(', ');
    return '$message ($rest)';
  }

  // The CLI has a single flat output; scoped context adds nothing here, so a
  // child logger is just this logger.
  @override
  omnyhub.Logger child(Map<String, Object?> context) => this;
}
