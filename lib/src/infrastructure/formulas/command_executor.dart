import 'dart:io';

/// The result of running an external command.
class ExecResult {
  /// The process exit code.
  final int exitCode;

  /// Captured stdout.
  final String stdout;

  /// Captured stderr.
  final String stderr;

  /// Creates an exec result.
  const ExecResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  /// Whether the command succeeded.
  bool get ok => exitCode == 0;
}

/// Runs external commands on behalf of formulas.
///
/// Abstracted so formula logic is unit-testable with a fake executor (no real
/// installs) while production uses [ProcessCommandExecutor].
abstract class CommandExecutor {
  /// Runs [executable] with [args], returning the captured result.
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  });
}

/// The default [CommandExecutor], backed by [Process.run].
class ProcessCommandExecutor implements CommandExecutor {
  /// Creates a process-backed executor.
  const ProcessCommandExecutor();

  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    try {
      final result = await Process.run(
        executable,
        args,
        environment: environment,
      );
      return ExecResult(
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } on ProcessException catch (e) {
      return ExecResult(exitCode: 127, stderr: e.message);
    }
  }
}
