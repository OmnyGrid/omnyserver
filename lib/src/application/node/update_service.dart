import 'dart:async';
import 'dart:io';

import '../../infrastructure/formulas/command_executor.dart';
import '../../protocol/operations.dart';

/// The exit code an agent leaves with when the Hub asked it to **restart**.
///
/// Non-zero on purpose, and that is the whole mechanism: a supervisor set to
/// restart on failure (`Restart=on-failure`, Docker's `restart: on-failure`)
/// brings the agent back, while the clean exit after a `shutdown` leaves it
/// stopped. 75 is `EX_TEMPFAIL` — "temporary failure, try again" — which is
/// precisely what a restart request is.
const int agentRestartExitCode = 75;

/// Handles the node-control requests the Hub dispatches (`NodeControl`).
///
/// **Every one of these is about the agent, not the machine it runs on.**
/// `restart` restarts the OmnyServer agent; `shutdown` stops it; `update`
/// updates what the agent can reach. Nothing here reboots or powers off a
/// host, and nothing should be read as if it did.
///
/// * `restart` — stop the agent so its supervisor starts it again
/// * `shutdown` — stop the agent, and leave it stopped
/// * `update` — with three targets:
///   * `os` — apply OS package updates via the platform package manager
///   * `agent` — self-update the OmnyServer agent (placeholder: reports the
///     mechanism; full remote self-update is on the roadmap)
///   * `<package>` — update a single named package
///
/// Stopping is the caller's to arrange, because only the process that owns the
/// agent's lifecycle can end it: pass [onRestartAgent] and [onStopAgent]. An
/// agent wired without them **says so** rather than reporting a success it did
/// not deliver — which is what this used to do, leaving an operator watching a
/// green result and an untouched node.
///
/// Returns `(success, message)` suitable for a `NodeControlHandler`.
class UpdateService {
  /// Runs the underlying commands.
  final CommandExecutor executor;

  /// Stops the agent in a way its supervisor will undo — the agent comes back.
  final Future<void> Function()? onRestartAgent;

  /// Stops the agent and leaves it stopped.
  final Future<void> Function()? onStopAgent;

  /// How long to wait before acting, so the answer reaches the Hub first.
  ///
  /// The reply travels over the connection the agent is about to close. Acting
  /// immediately would race it, and the operator would see a dropped
  /// connection where a confirmation belongs.
  static const Duration replyGrace = Duration(milliseconds: 250);

  /// Creates an update service.
  const UpdateService({
    this.executor = const ProcessCommandExecutor(),
    this.onRestartAgent,
    this.onStopAgent,
  });

  /// Handles a node-control [request].
  Future<(bool, String)> handle(NodeControl request) async {
    switch (request.action) {
      case 'restart':
        return _stopAgent(onRestartAgent, 'restart', 'the agent is restarting');
      case 'shutdown':
        return _stopAgent(onStopAgent, 'shutdown', 'the agent is stopping');
      case 'update':
        return _update(request);
      default:
        return (false, 'unknown node control action "${request.action}"');
    }
  }

  (bool, String) _stopAgent(
    Future<void> Function()? stop,
    String action,
    String message,
  ) {
    if (stop == null) {
      return (
        false,
        'cannot $action the agent: this one was started without a way to stop '
            'itself',
      );
    }
    unawaited(Future<void>.delayed(replyGrace).then((_) => stop()));
    return (true, message);
  }

  Future<(bool, String)> _update(NodeControl request) async {
    final target = request.parameters['target'] ?? 'os';
    switch (target) {
      case 'agent':
        // Full remote self-update is a roadmap item; acknowledge the intent.
        return (true, 'agent self-update is not yet automated');
      case 'os':
        return _runOsUpdate();
      default:
        return _runPackageUpdate(target);
    }
  }

  Future<(bool, String)> _runOsUpdate() async {
    final step = _osUpdateCommand();
    if (step == null) {
      return (false, 'OS update not supported on ${Platform.operatingSystem}');
    }
    final result = await executor.run(step.$1, step.$2);
    return (result.ok, result.ok ? 'OS update applied' : result.stderr.trim());
  }

  Future<(bool, String)> _runPackageUpdate(String package) async {
    final step = _packageUpdateCommand(package);
    if (step == null) {
      return (
        false,
        'package update not supported on ${Platform.operatingSystem}',
      );
    }
    final result = await executor.run(step.$1, step.$2);
    return (result.ok, result.ok ? 'updated $package' : result.stderr.trim());
  }

  (String, List<String>)? _osUpdateCommand() {
    if (Platform.isLinux) {
      return ('sh', ['-c', 'apt-get update && apt-get upgrade -y']);
    }
    if (Platform.isMacOS) {
      return ('softwareupdate', ['-i', '-a']);
    }
    return null;
  }

  (String, List<String>)? _packageUpdateCommand(String package) {
    if (Platform.isLinux) {
      return ('sh', ['-c', 'apt-get install -y --only-upgrade $package']);
    }
    if (Platform.isMacOS) {
      return ('brew', ['upgrade', package]);
    }
    return null;
  }
}
