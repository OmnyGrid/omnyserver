import 'dart:io';

import '../../infrastructure/formulas/command_executor.dart';
import '../../protocol/control_message.dart';

/// Handles node update requests dispatched by the Hub (`NodeControl` with
/// action `update`). Supports three update targets:
///
/// * `os` — apply OS package updates via the platform package manager
/// * `agent` — self-update the OmnyServer agent (placeholder: reports the
///   mechanism; full remote self-update is on the roadmap)
/// * `<package>` — update a single named package
///
/// Returns `(success, message)` suitable for a [NodeControlHandler].
class UpdateService {
  /// Runs the underlying commands.
  final CommandExecutor executor;

  /// Creates an update service.
  const UpdateService({this.executor = const ProcessCommandExecutor()});

  /// Handles a node-control [request]; only `update` is acted on here.
  Future<(bool, String)> handle(NodeControl request) async {
    if (request.action != 'update') {
      return (true, 'acknowledged ${request.action}');
    }
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
