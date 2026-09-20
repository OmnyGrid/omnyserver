import '../../shared/utils/clock.dart';
import '../entities/platform_info.dart';

/// Ambient context handed to a [Formula] action: the host platform, an
/// optional pinned target version, free-form parameters, a clock and a log
/// sink for streaming progress.
class FormulaContext {
  /// Static facts about the host the formula runs on.
  final PlatformInfo platform;

  /// The target version to converge to, if pinned.
  final String? targetVersion;

  /// Free-form parameters supplied by the preset / caller.
  final Map<String, String> parameters;

  /// Time source (injectable for tests).
  final Clock clock;

  /// Sink for streaming log lines as the action runs.
  final void Function(String line) log;

  /// Creates a formula context.
  FormulaContext({
    required this.platform,
    this.targetVersion,
    this.parameters = const {},
    this.clock = const SystemClock(),
    void Function(String line)? log,
  }) : log = log ?? _noop;

  static void _noop(String _) {}

  /// A copy carrying different per-action settings.
  ///
  /// The platform, the clock and the log sink are the *node's*, and stay put; a
  /// pinned version and parameters belong to whatever is being run. This is how
  /// a blueprint's resource hands a formula its own `version` without the caller
  /// rebuilding a whole context — and, more to the point, without accidentally
  /// dropping the log sink on the way, which is how a run goes silent.
  FormulaContext copyWith({
    String? targetVersion,
    Map<String, String>? parameters,
    void Function(String line)? log,
  }) => FormulaContext(
    platform: platform,
    targetVersion: targetVersion ?? this.targetVersion,
    parameters: parameters ?? this.parameters,
    clock: clock,
    log: log ?? this.log,
  );

  /// The current instant (UTC), via [clock].
  DateTime now() => clock.now();
}
